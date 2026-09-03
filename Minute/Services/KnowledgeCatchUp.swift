import Foundation
import FoundationModels
import SwiftData

/// The knowledge layer's catch-up loop (spec §5): extract facts from any
/// meeting not yet stamped, newest first, one at a time, only while the app
/// is active and the device is cool. Plumbing, not a feature — covers
/// retries, meetings from before extraction existed, bulk imports, and
/// future extractor upgrades with one mechanism.
@MainActor
@Observable
final class KnowledgeCatchUp {
    typealias Extractor = @MainActor (_ transcript: String, _ knownEntityNames: [String]) async throws -> KnowledgeExtractionResult

    /// Unstamped meetings remaining, for the m2 "catching up" row.
    private(set) var pendingCount = 0

    /// True only while the loop is actively processing. The Brain tab's live
    /// catch-up row keys on this, not on pendingCount — pending work can sit
    /// skip-listed while the loop is idle, and a spinner would be a lie.
    private(set) var isWorking = false

    /// Chunks the guardrails refused, per meeting, as of the last read of it.
    /// Such a meeting stays unstamped so a later launch retries it; this is
    /// what a Brain surface can show meanwhile, the way a summary shows
    /// "N parts couldn't be summarized".
    private(set) var skippedChunksByMeeting: [UUID: Int] = [:]

    private let availabilityMessage: @MainActor () -> String?
    private let extract: Extractor
    private var running: Task<Void, Never>?
    /// A nudge that arrived while a cancelled loop was still unwinding.
    /// `pause()` cancels the task but the task clears `running` itself when
    /// it finishes, and cancellation is only noticed between chunks — so a
    /// quick scene flicker (Notification Center, a call banner) would
    /// otherwise hand the restart nudge to a task that is about to exit,
    /// and nothing would run again until the next scene transition.
    private var restartRequested: ModelContext?
    /// True between `pause()` and `resume(context:)` — the app is not
    /// foreground. The loop is foreground-only (spec §5): FoundationModels
    /// rate-limits background apps, and once a finished job's background token
    /// ends the app is suspended mid-request. Only the scene coming back lifts
    /// this, so a job that completes in the background cannot restart reading
    /// there by nudging.
    private var pausedByScene = false
    /// True between `pauseForWork()` and the next nudge — a job the user asked
    /// for holds the on-device model. Kept apart from the scene pause because
    /// it expires differently: every nudge caller (a finished job, the Brain
    /// tab appearing) is a moment reading again is wanted, and a job pause that
    /// outlived them would silence the Brain for the rest of the session.
    private var pausedByWork = false
    /// The loop may run only while neither reason to stop is in force.
    private var isPaused: Bool { pausedByScene || pausedByWork }
    /// The context of the most recent nudge, so a loop the device paused
    /// (thermal, rate limit) can restart itself without waiting for the next
    /// scene transition. Every caller nudges with the same main-actor context.
    private var lastContext: ModelContext?
    /// How long a loop the device stopped waits before nudging itself. A rate
    /// limit and an unready model are both "not now", not "never" — and
    /// nothing else asks again while the app stays in the foreground.
    /// Injectable so tests don't wait a minute.
    private let retryDelay: Duration
    /// At most one delayed retry outstanding: the loop's own guards are cheap,
    /// but a timer per stalled pass would pile up.
    private var retryTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var observerTokens: [any NSObjectProtocol] = []
    /// Meetings that failed or were empty this session, keyed by the
    /// transcript they had at the time. Skipped, not retried hot, so one
    /// permanently-refusing meeting can't head-of-line-block the queue —
    /// but a re-transcription changes the key, so the meeting is read again
    /// in this session instead of waiting for the next launch. Cleared
    /// naturally at next launch.
    private var skippedThisSession: [UUID: Int] = [:]

    /// What the skip-list remembers a meeting by: identity plus the text
    /// the extractor would read, so new text means a new attempt.
    static func contentKey(for meeting: Meeting) -> Int {
        contentKey(for: meeting.timestampedTranscriptText)
    }

    /// The same derivation from text already in hand. Stated once here so the
    /// loop — which must key on the transcript it actually handed the
    /// extractor, not on whatever the meeting holds after the await — cannot
    /// drift from what `isSkipped` computes.
    private static func contentKey(for transcript: String) -> Int {
        transcript.hashValue
    }

    /// Skip-lists a meeting under the text that was actually read. The key is
    /// always passed in because an `await` sits between reading the text and
    /// skipping: a re-transcription landing in that window would otherwise
    /// skip-list text no extractor has ever seen, which is the very
    /// wait-for-relaunch this list's content key exists to avoid.
    private func skip(_ meeting: Meeting, key: Int) {
        skippedThisSession[meeting.id] = key
    }

    /// Cheap for the common case: only meetings that actually failed pay for
    /// rebuilding their transcript text, and `nextPending` asks per candidate
    /// per loop iteration.
    private func isSkipped(_ meeting: Meeting) -> Bool {
        guard let key = skippedThisSession[meeting.id] else { return false }
        return key == Self.contentKey(for: meeting)
    }

    init(
        availabilityMessage: @escaping @MainActor () -> String? = { KnowledgeExtractionService.availabilityMessage },
        retryDelay: Duration = .seconds(60),
        extract: @escaping Extractor = { transcript, names in
            try await KnowledgeExtractionService().extract(transcript: transcript, knownEntityNames: names)
        }
    ) {
        self.availabilityMessage = availabilityMessage
        self.retryDelay = retryDelay
        self.extract = extract
        observerTokens.append(NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.thermalStateDidChange()
            }
        })
    }

    deinit {
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// The device cooled back to nominal or fair: the only signal that the
    /// loop's thermal guard no longer holds. Tests call this directly — the
    /// notification itself cannot be provoked, and the observer above is one
    /// line of wiring.
    func thermalStateDidChange() {
        let thermal = ProcessInfo.processInfo.thermalState
        guard thermal == .nominal || thermal == .fair else { return }
        guard !isPaused, let lastContext else { return }
        nudge(context: lastContext)
    }

    /// One delayed re-nudge after the device said "not now". Weak, so a
    /// discarded loop is not kept alive by a pending timer.
    private func scheduleRetry() {
        guard retryTask == nil, !isPaused, lastContext != nil else { return }
        let delay = retryDelay
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            retryTask = nil
            guard !isPaused, let lastContext else { return }
            // The loop that armed this retry may still be unwinding —
            // scheduleRetry() runs inside run(), before the task that owns it
            // clears `running` — and a nudge into a live loop arms nothing.
            // Hand that loop a restart instead; its tail consumes it.
            if running != nil {
                restartRequested = lastContext
                return
            }
            nudge(context: lastContext)
        }
    }

    /// Starts the loop if it isn't running. Cheap to call often.
    ///
    /// Every caller is a moment reading is wanted: a job finishing
    /// (`MeetingJobs.onContentChanged`), the Brain tab appearing, the scene
    /// coming back. So a nudge lifts the work pause itself — but never the
    /// scene pause, or a job that finished after the user left would restart
    /// extraction in the background.
    func nudge(context: ModelContext) {
        lastContext = context
        pausedByWork = false
        guard !isPaused else { return }
        if let running {
            if running.isCancelled {
                restartRequested = context
            }
            return
        }
        // A loop is starting now, so a timer waiting to start one is spent —
        // and leaving it armed would block the next retry the loop needs.
        retryTask?.cancel()
        retryTask = nil
        running = Task { [self] in
            isWorking = true
            await run(context: context)
            isWorking = false
            running = nil
            if let restartContext = restartRequested {
                restartRequested = nil
                nudge(context: restartContext)
            }
        }
    }

    /// What both pauses do: stop after the in-flight meeting, and disarm any
    /// restart a mid-teardown nudge queued — that nudge belonged to a moment
    /// the pause has already ended, and consuming it later would start an
    /// uncancelled loop, burning rate-limited FoundationModels calls and
    /// skip-listing every meeting they fail on until the next launch.
    private func stopLoop() {
        running?.cancel()
        restartRequested = nil
        retryTask?.cancel()
        retryTask = nil
    }

    /// The scene left `.active`. Call from the scene-phase handler; only
    /// `resume(context:)` lifts it.
    func pause() {
        pausedByScene = true
        stopLoop()
    }

    /// A job the user started wants the on-device model. Extraction gets out
    /// of the way until the next nudge — which the job itself sends when it
    /// finishes.
    func pauseForWork() {
        pausedByWork = true
        stopLoop()
    }

    /// The scene came back to `.active`: the one door out of `pause()`.
    func resume(context: ModelContext) {
        pausedByScene = false
        nudge(context: context)
    }

    /// Test hook: resolves when the loop (and any restart it queued) has
    /// finished.
    func waitUntilIdle() async {
        while let task = running {
            await task.value
        }
    }

    private func run(context: ModelContext) async {
        // Count before any guard can bail: even when the model isn't ready
        // or the device is warm, the Brain tab must know unread work exists.
        refreshPendingCount(context: context)
        // Not a per-meeting failure: when the model isn't ready, leave the
        // queue untouched and wait for a later nudge (mirrors the thermal
        // guard's return-without-consuming semantics).
        guard availabilityMessage() == nil else {
            scheduleRetry()
            return
        }

        while !Task.isCancelled {
            // Sustained ANE work on a warm phone throttles everything; wait
            // for the next nudge instead (spec §5).
            let thermal = ProcessInfo.processInfo.thermalState
            guard thermal == .nominal || thermal == .fair else { return }

            // pendingCount is owned by nextPending, which sets it from the
            // pre-skip-list fetch on every call — it only reaches 0 when
            // that fetch itself is empty, not merely when everything left is
            // skip-listed.
            guard let meeting = nextPending(context: context) else { return }
            // Read once, before the await: every branch below — the staleness
            // guard and both skip-listing catches — must reason about the text
            // the extractor was given, not whatever the meeting holds later.
            let transcript = meeting.timestampedTranscriptText
            do {
                let names = knownEntityNames(context: context)
                let result = try await extract(transcript, names)
                // Deleted while the model was reading it — routine, since
                // saving a recording is both what nudges this loop and when a
                // botched take gets deleted. `isGone`, not `isDeleted`: the
                // delete has committed by now, so `isDeleted` is false again
                // and the staleness guard below sees the detached object's
                // last-known transcript, which of course still matches.
                // Ingesting here would write facts keyed to a meeting that no
                // longer exists, and no later delete could remove them.
                guard !meeting.isGone else { continue }
                // A re-transcription may have replaced the segments while the
                // model was reading the old text; facts from a stale transcript
                // must not be ingested or stamped over. The meeting stays
                // unstamped and un-skipped, so this same loop picks it up again
                // with the fresh transcript.
                guard meeting.timestampedTranscriptText == transcript else { continue }
                try KnowledgeIngest.apply(result.candidates, from: meeting, context: context)
                if result.refusedChunkCount > 0 {
                    // Stamping would retire the meeting with those passages
                    // never read — and the meetings richest in durable facts
                    // are exactly the ones a guardrail refuses. Keep what was
                    // extracted, remember how much was missed, and skip-list
                    // the text that was read: a refusal is near-deterministic,
                    // so retrying it inside this session would only spin, while
                    // the next launch (or a re-transcription, which changes the
                    // key) reads the meeting again.
                    skippedChunksByMeeting[meeting.id] = result.refusedChunkCount
                    skip(meeting, key: Self.contentKey(for: transcript))
                } else {
                    meeting.knowledgeExtractedAt = .now
                    skippedChunksByMeeting[meeting.id] = nil
                }
                try context.save()
            } catch is CancellationError {
                return
            } catch let error as SummarizerError {
                // The model went away mid-loop (the per-meeting check inside
                // the extractor caught it). Not a verdict on this meeting:
                // stop without skip-listing, exactly like the availability
                // guard at the top of run(), and let the next nudge retry.
                if case .unavailable = error { return }
                skip(meeting, key: Self.contentKey(for: transcript))
            } catch let error as LanguageModelSession.GenerationError {
                // Rate limiting is the device saying "not now", not a verdict
                // on this meeting: stop without skip-listing (spec §5
                // pause-and-resume), and ask again after a delay — while the
                // app stays open nothing else would.
                if case .rateLimited = error {
                    scheduleRetry()
                    return
                }
                // Assets being evicted mid-loop is the same kind of "not now":
                // the model is gone, not this meeting's fault.
                if case .assetsUnavailable = error {
                    scheduleRetry()
                    return
                }
                // Permanent (refusal, etc.) failures skip for this session
                // and retry at next launch.
                skip(meeting, key: Self.contentKey(for: transcript))
            } catch {
                // Non-FoundationModels failures skip for this session and
                // retry at next launch.
                skip(meeting, key: Self.contentKey(for: transcript))
            }
        }
    }

    /// Unstamped meetings the loop can actually read. `segments` can't be
    /// predicated, so the transcript filter runs in memory.
    private func pendingMeetings(context: ModelContext) -> [Meeting] {
        let descriptor = FetchDescriptor<Meeting>(
            predicate: #Predicate { $0.knowledgeExtractedAt == nil },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let unstamped = (try? context.fetch(descriptor)) ?? []
        // A meeting with no transcript is deliberately left unstamped (text
        // may arrive later), but it is not "still to read" — counting it
        // shows the Brain tab a number that never goes down.
        return unstamped.filter(\.hasTranscript)
    }

    private func nextPending(context: ModelContext) -> Meeting? {
        let pending = pendingMeetings(context: context)
        pendingCount = pending.count
        return pending.first { !isSkipped($0) }
    }

    private func refreshPendingCount(context: ModelContext) {
        pendingCount = pendingMeetings(context: context).count
    }

    private func knownEntityNames(context: ModelContext) -> [String] {
        let entities = (try? context.fetch(FetchDescriptor<KnowledgeEntity>())) ?? []
        return entities.filter { $0.redirectTo == nil }.flatMap { [$0.name] + $0.aliases }
    }
}
