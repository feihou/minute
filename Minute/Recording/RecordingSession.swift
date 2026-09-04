import AVFoundation
import Foundation
import Observation
import OSLog
import SwiftData

/// Orchestrates one recording: microphone permission, the recorder, live
/// transcription, and saving the finished meeting.
@MainActor
@Observable
final class RecordingSession: Identifiable {
    nonisolated let id = UUID()

    enum Phase: Equatable {
        case idle
        case preparing
        case recording
        case paused
        case saving
        /// `canOpenSettings` is true only for the microphone-permission
        /// failure: it is the one failure the user fixes in iOS Settings, and
        /// the recording screen puts an Open Settings button on screen for it
        /// instead of leaving them to navigate there by hand.
        case failed(String, canOpenSettings: Bool)
    }

    private static let logger = Logger(subsystem: "com.minuteapp.Minute", category: "RecordingSession")

    let recorder = AudioRecorder()
    /// The engine selected in Settings (Apple Speech or Whisper), captured at
    /// session creation like the settings below — or the one injected by a
    /// test.
    let transcription: any TranscriptionEngine
    /// Captured when the session is created so a settings change mid-recording
    /// can't half-apply.
    let isTranscriptionEnabled = AppSettings.liveTranscriptionEnabled

    private let liveActivity = RecordingLiveActivityController()

    private(set) var phase: Phase = .idle {
        didSet { syncLiveActivity(from: oldValue) }
    }
    /// True once audio capture began — a later failure should offer to keep it.
    private(set) var didStartRecording = false
    /// True while a discard's delete refuses to commit. The meeting is still in
    /// the library pointing at its own audio and nothing is half-deleted, so
    /// the recording screen is free to close on it: this flag is what tells it
    /// to offer that escape next to the retry. Without one the sheet — which
    /// can't be swiped away — has no control left that doesn't retry the same
    /// failing delete, and the storage that delete is waiting on does not free
    /// itself while the user is held there.
    private(set) var discardFailed = false
    /// Transient, user-visible explanation (e.g. why recording auto-paused).
    private(set) var notice: String?
    var title: String
    /// The default the New Meeting sheet prefilled — stored, not regenerated:
    /// see `savedTitles(draft:prefilledDefault:)`.
    let prefilledDefaultTitle: String
    private var audioFileName: String?
    private var transcriptionTask: Task<Void, Never>?
    /// Pushes the Live Activity's stale date forward while this session is
    /// alive. Cancelled the moment recording ends, so a process that dies
    /// mid-recording simply stops refreshing and the card goes stale.
    private var activityRefreshTask: Task<Void, Never>?
    /// Clears a notice that explains something already resolved (a route
    /// change the recorder recovered from), so it doesn't sit on screen
    /// implying the recording still needs attention.
    private var noticeClearTask: Task<Void, Never>?
    private let startedAt = Date()
    /// Recorded duration banked when capture stopped, so a retried save still
    /// has it after the recorder went idle.
    private var recordedDuration: TimeInterval?
    /// The row written as soon as capture stopped, before the transcript was
    /// finalized. Kept so a retry (the transcript save failed) updates that
    /// meeting instead of inserting a second one for the same audio.
    private var savedMeeting: Meeting?
    /// The finalized transcript, banked so a retried save doesn't wait on the
    /// engine a second time — and so `saveWithoutTranscript()` can decide what
    /// gets written.
    private var pendingSegments: [TranscriptSegment]?
    /// Set the moment the user discards; a finish() resuming from an await
    /// afterwards must not save the meeting they just threw away.
    private var didDiscard = false
    /// Set after a successful save; a stale queued finish() must not insert a
    /// second meeting referencing the same audio file.
    private var didSave = false
    /// How a saved meeting is removed — `MeetingStore.delete` in the app.
    /// Injectable because the branch that decides whether this session can
    /// corrupt the library is the one where that delete does NOT commit:
    /// MeetingStore re-inserts the row and returns false, and the audio the
    /// live row still points at then has to be left alone. The delete fails
    /// only when `context.save()` throws, which SwiftData's in-memory store
    /// has no way to be made to do, so that branch is unreachable otherwise.
    private let deleteMeeting: @MainActor (Meeting, ModelContext) -> Bool

    /// How microphone permission is asked for — `AudioRecorder.requestPermission`
    /// in the app. Injectable because a denial is the only thing that produces
    /// `canOpenSettings: true`, the flag that puts the Open Settings button on
    /// the recording screen, and a real system prompt can't be answered from a
    /// test. Unlike the rest of the recording path this branch needs no audio
    /// hardware: it returns before the recorder is touched.
    private let requestPermission: @Sendable () async -> Bool

    /// `transcription` and `requestPermission` are injectable for tests; both
    /// default to nil rather than to their real implementations because a
    /// default argument is evaluated outside this type's main-actor isolation
    /// and both real values are main-actor isolated.
    init(
        title: String,
        prefilledDefaultTitle: String = RecordingSession.defaultTitle(),
        transcription: (any TranscriptionEngine)? = nil,
        deleteMeeting: @escaping @MainActor (Meeting, ModelContext) -> Bool = MeetingStore.delete,
        requestPermission: (@Sendable () async -> Bool)? = nil
    ) {
        self.title = title
        self.prefilledDefaultTitle = prefilledDefaultTitle
        self.transcription = transcription ?? TranscriptionEngines.current()
        self.deleteMeeting = deleteMeeting
        self.requestPermission = requestPermission ?? { await AudioRecorder.requestPermission() }
    }

    func start() async {
        guard phase == .idle else { return }
        phase = .preparing

        guard await requestPermission() else {
            phase = .failed(
                "Microphone access is off. Enable it in Settings › Privacy & Security › Microphone.",
                canOpenSettings: true
            )
            return
        }

        recorder.onAutoPause = { [weak self] in
            guard let self, self.phase == .recording else { return }
            self.phase = .paused
            // Names what actually gets here: a call or Siri taking the
            // microphone. A route change restarts capture in place now, and
            // the transient "Microphone changed — still recording" notice says
            // so; blaming an "audio change" here sent people looking at their
            // headphones for a pause a phone call caused.
            self.notice = "Recording was paused by the system (a call or Siri). Tap resume to continue."
        }

        recorder.onAutoResume = { [weak self] in
            guard let self, self.phase == .paused else { return }
            self.notice = nil
            self.phase = .recording
        }

        recorder.onCaptureLost = { [weak self] message in
            guard let self, self.phase == .recording || self.phase == .paused else { return }
            // `.failed`, not `.paused`: capture cannot be restarted in place,
            // and `.paused` is what puts a Resume button on screen. The audio
            // file is closed and intact and `didStartRecording` is already
            // set, so the failed state offers Save Recording / Discard — which
            // is exactly the choice the user has left.
            self.notice = nil
            self.phase = .failed(message, canOpenSettings: false)
        }

        recorder.onWriteError = { [weak self] _ in
            guard let self, self.phase == .recording else { return }
            // The recorder already paused itself; keep the UI in sync and
            // tell the user why instead of pretending the recording is healthy.
            self.phase = .paused
            self.notice = "Recording paused — audio couldn't be written (storage may be full). Free up space and resume, or stop to save what's been captured."
        }

        recorder.onRouteChanged = { [weak self] message in
            guard let self, self.phase == .recording else { return }
            self.showTransientNotice(message)
        }

        // Start capturing audio immediately — recording never waits on the
        // speech model. Transcription attaches below once it's ready.
        do {
            try recorder.activateSession()
            let fileName = MeetingStore.newAudioFileName()
            let url = try MeetingStore.audioURL(fileName: fileName)
            audioFileName = fileName
            try recorder.start(writingTo: url, quality: AppSettings.audioQuality.encoderQuality)
            didStartRecording = true
            phase = .recording
        } catch {
            // The session may already be active — release it so other apps'
            // audio isn't left interrupted by a recording that never began.
            recorder.cleanupAfterFailedStart()
            phase = .failed("Recording couldn't start: \(error.localizedDescription)", canOpenSettings: false)
            return
        }

        guard isTranscriptionEnabled else {
            // No engine will attach, so nothing should hold a lead-in for one.
            recorder.setBufferHandler(nil)
            return
        }
        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            await self.transcription.prepare()
            guard !Task.isCancelled, self.phase == .recording || self.phase == .paused else { return }
            guard let format = self.recorder.recordingFormat else { return }
            let handler = await self.transcription.start(inputFormat: format)
            guard !Task.isCancelled, self.phase == .recording || self.phase == .paused else { return }
            // The analyzer's clock starts at the first buffer it receives, and
            // that first buffer is now the OLDEST one the recorder held back
            // while the model prepared — not the one arriving live. So the
            // offset is the file time where the replay begins, `elapsed`
            // minus that lead-in, and not `elapsed` itself: offsetting by
            // `elapsed` would stamp every replayed segment a full lead-in too
            // late (a second or two here, up to the 30 s cap after a first-run
            // model download) and could push the last segment past the saved
            // meeting's duration, which is exactly the wrong-seek defect the
            // frame-derived clock fixes elsewhere. Read the lead-in BEFORE
            // installing: `setBufferHandler` drains the queue, so a read
            // afterwards is always zero. `max(0,)` because a buffer whose disk
            // write failed is still replayed but was never counted in
            // `elapsed`.
            let leadIn = self.recorder.pendingBacklogSeconds
            self.transcription.timestampOffset = max(0, self.recorder.elapsed - leadIn)
            self.recorder.setBufferHandler(handler)
        }
    }

    func pause() {
        guard phase == .recording else { return }
        recorder.pause()
        notice = nil
        phase = .paused
    }

    func resume() {
        guard phase == .paused else { return }
        do {
            try recorder.resume()
            notice = nil
            phase = .recording
        } catch {
            // Never turn a resume failure into a dead end — everything
            // recorded so far stays saveable from the paused state.
            Self.logger.error("Resume failed: \(error.localizedDescription)")
            notice = "Couldn't resume the microphone. You can try again, or stop to save what's recorded."
        }
    }

    /// A notice about something the recorder already handled: shown briefly,
    /// then cleared. The pause notices stay up because they name an action the
    /// user still has to take; this one doesn't.
    private func showTransientNotice(_ message: String) {
        notice = message
        noticeClearTask?.cancel()
        noticeClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, self.notice == message else { return }
            self.notice = nil
        }
    }

    /// Stops everything, saves the meeting, and returns it.
    ///
    /// The row is written BEFORE the transcript is finalized. The audio file is
    /// complete and playable the moment `recorder.stop()` returns, but nothing
    /// references it until a Meeting exists and the launch sweep deletes every
    /// unreferenced recording — while finalizing (a Whisper final pass over up
    /// to five minutes of tail) can easily outlive the ~30 s background
    /// assertion that is all we have once stop() deactivates the audio session.
    /// Persisting first means a suspension or jettison there costs the
    /// transcript, which Re-transcribe can rebuild, instead of the meeting.
    ///
    /// Returns nil when a save failed — the session enters `.failed` with the
    /// audio (and, past the first save, the meeting) intact, and calling finish
    /// again retries only the step that failed.
    func finish(in context: ModelContext) async -> Meeting? {
        // One finish at a time, never after a discard, and never again after
        // a successful save — a stale second call would otherwise build a
        // second meeting sharing the same audio file.
        guard phase != .saving, !didDiscard, !didSave else { return nil }
        phase = .saving
        // recorder.stop() below deactivates the audio session, which is the
        // only thing keeping a backgrounded app alive. Swiping Home while the
        // transcript finalizes would otherwise let iOS suspend us mid-save.
        let token = BackgroundTaskToken(name: "Save recording")
        defer { token.end() }

        if recordedDuration == nil {
            transcriptionTask?.cancel()
            recordedDuration = recorder.stop()
        }
        guard let duration = recordedDuration else { return nil }

        if savedMeeting == nil {
            let saved = Self.savedTitles(draft: title, prefilledDefault: prefilledDefaultTitle)
            let meeting = Meeting(
                title: saved.title,
                defaultTitle: saved.defaultTitle,
                createdAt: startedAt,
                duration: duration,
                audioFileName: audioFileName,
                segments: []
            )
            context.insert(meeting)
            do {
                try context.save()
                savedMeeting = meeting
            } catch {
                Self.logger.error("Saving meeting failed: \(error.localizedDescription)")
                // Cancel only THIS pending insert — a context-wide rollback()
                // would also destroy unrelated unsaved edits in the shared main
                // context. Declaring the meeting saved instead would let the next
                // orphan sweep delete its audio.
                context.delete(meeting)
                phase = .failed(
                    "The meeting couldn't be saved — storage may be full. Free up space and tap Save Recording to try again.",
                    canOpenSettings: false
                )
                return nil
            }
        }
        guard let meeting = savedMeeting else { return nil }

        if pendingSegments == nil {
            let finalized = await transcription.finish()
            if didDiscard {
                // Discarded while the transcript finalized: the row written
                // above points at audio `discard(in:)` has already deleted, so
                // it goes with it. Never resurrect a recording the user threw
                // away, and never leave a meeting pointing at nothing.
                // `discard(in:)` runs on this actor between our awaits and may
                // already have removed the row, so ask before removing it
                // again — a committed delete leaves isDeleted false. A delete
                // that did NOT commit left the row alive (MeetingStore
                // re-inserts it), so keep the handle rather than dropping the
                // only reference the retrying discard has: forgetting it here
                // would strand a meeting in the library pointing at audio
                // `discard(in:)` deletes.
                if meeting.isGone || deleteMeeting(meeting, context) {
                    savedMeeting = nil
                }
                return nil
            }
            // `saveWithoutTranscript()` may have banked the segments while we
            // waited — it cancels the engine, which clears the engine's copy.
            if pendingSegments == nil {
                pendingSegments = finalized
            }
        }
        guard let segments = pendingSegments else { return nil }

        meeting.segments = segments
        do {
            try context.save()
            didSave = true
            phase = .idle
            return meeting
        } catch {
            Self.logger.error("Saving the transcript failed: \(error.localizedDescription)")
            // The recording itself is safe — the meeting and its audio were
            // committed above. Only the transcript is unwritten, so keep the
            // meeting and let Save Recording retry just this step.
            phase = .failed(
                "The transcript couldn't be saved — storage may be full. The recording is saved; free up space and tap Save Recording to try again.",
                canOpenSettings: false
            )
            return nil
        }
    }

    /// Whether "Save without transcript" still has anything to do. The phase
    /// stays `.saving` until the parked finalization returns, so the phase
    /// alone can't drive the button: without this it stays lit behind the same
    /// ProgressView after the first tap has already banked the segments, and
    /// every further tap hits the guard below and does nothing — which is what
    /// the user with a slow engine keeps doing. It is also already false on
    /// the retry-after-a-failed-transcript-save path, where the transcript is
    /// banked and there is nothing left to skip, so the dead case is never
    /// offered at all. Mirrors the guard exactly, and the guard reads it, so
    /// the two cannot drift apart.
    var canSaveWithoutTranscript: Bool {
        phase == .saving && pendingSegments == nil
    }

    /// Stops waiting for the transcript and finishes the save with whatever the
    /// engine has already produced. Nothing bounds a finalization — Whisper's
    /// final pass covers up to five minutes of retained tail, and Apple Speech
    /// waits on its results stream — while `.saving` disables Discard and both
    /// controls, so without this the user has no way out of a recording that is
    /// already safely on disk.
    func saveWithoutTranscript() async {
        guard canSaveWithoutTranscript else { return }
        // Bank first: cancelling clears the engine's own collection, and the
        // whole point of this action is to keep what it heard.
        var banked = transcription.segments
        // The hypothesis in flight is the most recent thing said — usually the
        // sentence the user was still speaking when they gave up waiting.
        // `finish()` promotes it; this path has to as well, or the one action
        // offered for a stuck finalization is also the one that silently drops
        // the tail. Zero-length at the last segment's end, exactly like
        // TranscriptionService.finish, so nothing seeks past the recording.
        if !transcription.volatileText.isEmpty {
            let lastEnd = banked.last?.end ?? transcription.timestampOffset
            banked.append(TranscriptSegment(text: transcription.volatileText, start: lastEnd, end: lastEnd))
        }
        pendingSegments = banked
        await transcription.cancel()
    }

    /// Stops everything and deletes the partial audio file (user discarded).
    /// Takes the context because `finish(in:)` persists the meeting before the
    /// transcript is finalized: a discard arriving after that (or after a
    /// failed transcript save) has a row to remove, and leaving it would keep
    /// a meeting whose audio this method just deleted.
    ///
    /// Returns false when that row could not be deleted, and then nothing else
    /// is thrown away: a delete that fails to commit is undone by MeetingStore,
    /// so the meeting is still in the library, and removing its audio here
    /// would leave exactly the wreck MeetingStore refuses to create — a meeting
    /// whose recording is gone, its playback and Re-transcribe both dead. The
    /// session enters `.failed` and sets `discardFailed` instead, keeping the
    /// meeting so the caller can retry the same delete. Returning false says
    /// the discard didn't happen — NOT that the caller has to stay: the row and
    /// its audio are consistent, so closing the screen on them is safe, and
    /// `discardFailed` is there so the screen offers exactly that.
    func discard(in context: ModelContext) async -> Bool {
        // A meeting that already saved is the library's, not this session's:
        // the caller has it and the screen is closing on it. The toolbar
        // Discard goes live again the moment finish() returns the phase to
        // .idle, and acting on it here would delete the meeting just handed
        // over along with the audio it points at. Nothing is left to throw
        // away, so report success and let the screen close.
        guard !didSave else { return true }
        didDiscard = true
        transcriptionTask?.cancel()
        recorder.stop()
        await transcription.cancel()
        if let savedMeeting, !savedMeeting.isGone, !deleteMeeting(savedMeeting, context) {
            // Say what is true — the meeting and the audio it points at both
            // survived, together — and mark the state that lets the screen
            // offer a way out beside the retry. The user is not trapped in
            // here waiting for storage to free itself: they can leave the
            // meeting in the library and delete it from the list later.
            discardFailed = true
            phase = .failed(
                "The recording couldn't be discarded — storage may be full. It's still saved in your library: keep it there and delete it from the list later, or free up space and try again.",
                canOpenSettings: false
            )
            return false
        }
        discardFailed = false
        savedMeeting = nil
        if let audioFileName {
            MeetingStore.deleteAudioFile(named: audioFileName)
        }
        audioFileName = nil
        recordedDuration = nil
        pendingSegments = nil
        didStartRecording = false
        phase = .idle
        return true
    }

    /// Every phase change funnels through here (phase's didSet), so system
    /// auto-pauses and failures reach the lock screen the same way user taps do.
    private func syncLiveActivity(from oldPhase: Phase) {
        guard phase != oldPhase else { return }
        switch phase {
        case .recording:
            if oldPhase == .preparing {
                liveActivity.start(title: liveActivityTitle)
            } else {
                liveActivity.update(isPaused: false, elapsed: recorder.elapsed)
            }
            startActivityRefresh()
        case .paused:
            liveActivity.update(isPaused: true, elapsed: recorder.elapsed)
            startActivityRefresh()
        case .idle, .saving, .failed:
            // The recorder has stopped (or never started) in all three —
            // ending is a no-op when no activity was requested.
            stopActivityRefresh()
            liveActivity.end()
        case .preparing:
            break
        }
    }

    /// The title the Live Activity is started with. `ActivityAttributes` are
    /// immutable for the life of the activity, so this is the only title the
    /// lock screen ever shows — take it through the same trim-and-fall-back
    /// the save uses, or clearing the title field in the New Meeting sheet
    /// leaves the card (and the expanded Dynamic Island) with a blank line
    /// while the saved meeting is named "Meeting <date>".
    var liveActivityTitle: String {
        Self.savedTitles(draft: title, prefilledDefault: prefilledDefaultTitle).title
    }

    /// How often the Live Activity's stale date is pushed forward.
    static let liveActivityRefreshInterval: TimeInterval = 60

    private func startActivityRefresh() {
        guard activityRefreshTask == nil else { return }
        activityRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.liveActivityRefreshInterval))
                guard !Task.isCancelled, let self else { return }
                guard self.phase == .recording || self.phase == .paused else { return }
                self.liveActivity.update(isPaused: self.phase == .paused, elapsed: self.recorder.elapsed)
            }
        }
    }

    private func stopActivityRefresh() {
        activityRefreshTask?.cancel()
        activityRefreshTask = nil
    }

    /// `nonisolated` because it touches no session state: that lets it stand
    /// as the default argument of `init(title:prefilledDefaultTitle:)`, which
    /// Swift evaluates outside the main actor.
    nonisolated static func defaultTitle(for date: Date = .now) -> String {
        "Meeting \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    /// The title to store and the default it is later compared against
    /// (MeetingJobs adopts the model's suggested title only while the two
    /// still match). The default is the exact string the sheet prefilled,
    /// never one regenerated now: both have minute resolution, so
    /// regenerating drifted whenever the sheet stayed open across a minute
    /// boundary, and the suggested title was then silently never adopted.
    static func savedTitles(draft: String, prefilledDefault: String) -> (title: String, defaultTitle: String) {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.isEmpty ? prefilledDefault : trimmed, prefilledDefault)
    }
}
