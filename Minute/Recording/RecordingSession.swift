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
    /// session creation like the settings below.
    let transcription: any TranscriptionEngine = TranscriptionEngines.current()
    /// Captured when the session is created so a settings change mid-recording
    /// can't half-apply.
    let isTranscriptionEnabled = AppSettings.liveTranscriptionEnabled

    private let liveActivity = RecordingLiveActivityController()

    private(set) var phase: Phase = .idle {
        didSet { syncLiveActivity(from: oldValue) }
    }
    /// True once audio capture began — a later failure should offer to keep it.
    private(set) var didStartRecording = false
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
    /// Captured once when recording stops; kept until a save succeeds so a
    /// failed context.save() can be retried without touching the recorder.
    /// Value data (not a Meeting instance) so every save attempt inserts a
    /// fresh model object and a failed attempt can be discarded cleanly.
    private var finishedRecording: (duration: TimeInterval, segments: [TranscriptSegment])?
    /// Set the moment the user discards; a finish() resuming from an await
    /// afterwards must not save the meeting they just threw away.
    private var didDiscard = false
    /// Set after a successful save; a stale queued finish() must not insert a
    /// second meeting referencing the same audio file.
    private var didSave = false

    init(title: String, prefilledDefaultTitle: String = RecordingSession.defaultTitle()) {
        self.title = title
        self.prefilledDefaultTitle = prefilledDefaultTitle
    }

    func start() async {
        guard phase == .idle else { return }
        phase = .preparing

        guard await AudioRecorder.requestPermission() else {
            phase = .failed(
                "Microphone access is off. Enable it in Settings › Privacy & Security › Microphone.",
                canOpenSettings: true
            )
            return
        }

        recorder.onAutoPause = { [weak self] in
            guard let self, self.phase == .recording else { return }
            self.phase = .paused
            self.notice = "Recording was paused by the system (a call or audio change). Tap resume to continue."
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

    /// Stops everything, saves the meeting, and returns it. Returns nil when
    /// persistence fails — the session enters `.failed` with the audio intact,
    /// and calling finish again retries just the save.
    func finish(in context: ModelContext) async -> Meeting? {
        // One finish at a time, never after a discard, and never again after
        // a successful save — a stale second call would otherwise build a
        // second meeting sharing the same audio file.
        guard phase != .saving, !didDiscard, !didSave else { return nil }
        phase = .saving
        // recorder.stop() below deactivates the audio session, which is the
        // only thing keeping a backgrounded app alive. Swiping Home while the
        // transcript finalizes would otherwise let iOS suspend us mid-save and
        // cost the user the whole meeting.
        let token = BackgroundTaskToken(name: "Save recording")
        defer { token.end() }

        if finishedRecording == nil {
            transcriptionTask?.cancel()
            let duration = recorder.stop()
            let segments = await transcription.finish()
            // The user may have discarded while the transcript finalized —
            // never resurrect a recording they threw away.
            guard !didDiscard else { return nil }
            finishedRecording = (duration, segments)
        }
        guard let finishedRecording else { return nil }

        let saved = Self.savedTitles(draft: title, prefilledDefault: prefilledDefaultTitle)
        let meeting = Meeting(
            title: saved.title,
            defaultTitle: saved.defaultTitle,
            createdAt: startedAt,
            duration: finishedRecording.duration,
            audioFileName: audioFileName,
            segments: finishedRecording.segments
        )
        context.insert(meeting)
        do {
            try context.save()
            didSave = true
            self.finishedRecording = nil
            phase = .idle
            return meeting
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

    /// Stops everything and deletes the partial audio file (user discarded).
    func discard() async {
        didDiscard = true
        transcriptionTask?.cancel()
        recorder.stop()
        await transcription.cancel()
        if let audioFileName {
            MeetingStore.deleteAudioFile(named: audioFileName)
        }
        audioFileName = nil
        finishedRecording = nil
        didStartRecording = false
        phase = .idle
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
