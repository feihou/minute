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
    typealias Extractor = @MainActor (_ transcript: String, _ knownEntityNames: [String]) async throws -> [KnowledgeCandidate]

    /// Unstamped meetings remaining, for the m2 "catching up" row.
    private(set) var pendingCount = 0

    /// True only while the loop is actively processing. The Brain tab's live
    /// catch-up row keys on this, not on pendingCount — pending work can sit
    /// skip-listed while the loop is idle, and a spinner would be a lie.
    private(set) var isWorking = false

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
        meeting.timestampedTranscriptText.hashValue
    }

    /// Skip-lists a meeting under the text that was actually read. `key`
    /// must be passed wherever an `await` sits between reading the text and
    /// skipping: a re-transcription landing in that window would otherwise
    /// skip-list text no extractor has ever seen, which is the very
    /// wait-for-relaunch this list's content key exists to avoid.
    private func skip(_ meeting: Meeting, key: Int? = nil) {
        skippedThisSession[meeting.id] = key ?? Self.contentKey(for: meeting)
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
        extract: @escaping Extractor = { transcript, names in
            try await KnowledgeExtractionService().extract(transcript: transcript, knownEntityNames: names)
        }
    ) {
        self.availabilityMessage = availabilityMessage
        self.extract = extract
    }

    /// Starts the loop if it isn't running. Cheap to call often.
    func nudge(context: ModelContext) {
        if let running {
            if running.isCancelled {
                restartRequested = context
            }
            return
        }
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

    /// Stops after the in-flight meeting. Call when the scene deactivates.
    /// Also disarms any restart a mid-teardown nudge queued: that nudge
    /// belonged to a foreground moment this pause has already ended, and
    /// consuming it later would start an uncancelled loop while the app is
    /// inactive — burning rate-limited FoundationModels calls and
    /// skip-listing every meeting they fail on until the next launch.
    func pause() {
        running?.cancel()
        restartRequested = nil
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
        guard availabilityMessage() == nil else { return }

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
                let candidates = try await extract(transcript, names)
                guard !meeting.isDeleted else { continue }
                // A re-transcription may have replaced the segments while the
                // model was reading the old text; facts from a stale transcript
                // must not be ingested or stamped over. The meeting stays
                // unstamped and un-skipped, so this same loop picks it up again
                // with the fresh transcript.
                guard meeting.timestampedTranscriptText == transcript else { continue }
                try KnowledgeIngest.apply(candidates, from: meeting, context: context)
                meeting.knowledgeExtractedAt = .now
                try context.save()
            } catch is CancellationError {
                return
            } catch let error as SummarizerError {
                // The model went away mid-loop (the per-meeting check inside
                // the extractor caught it). Not a verdict on this meeting:
                // stop without skip-listing, exactly like the availability
                // guard at the top of run(), and let the next nudge retry.
                if case .unavailable = error { return }
                skip(meeting, key: transcript.hashValue)
            } catch let error as LanguageModelSession.GenerationError {
                // Rate limiting is the device saying "not now", not a verdict
                // on this meeting: stop without skip-listing (spec §5
                // pause-and-resume) — the next nudge retries from here.
                if case .rateLimited = error { return }
                // Assets being evicted mid-loop is the same kind of "not now":
                // the model is gone, not this meeting's fault.
                if case .assetsUnavailable = error { return }
                // Permanent (refusal, etc.) failures skip for this session
                // and retry at next launch.
                skip(meeting, key: transcript.hashValue)
            } catch {
                // Non-FoundationModels failures skip for this session and
                // retry at next launch.
                skip(meeting, key: transcript.hashValue)
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
