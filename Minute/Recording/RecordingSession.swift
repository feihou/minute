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
        case failed(String)
    }

    private static let logger = Logger(subsystem: "com.minuteapp.Minute", category: "RecordingSession")

    let recorder = AudioRecorder()
    let transcription = TranscriptionService()
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
    private var audioFileName: String?
    private var transcriptionTask: Task<Void, Never>?
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

    init(title: String) {
        self.title = title
    }

    func start() async {
        guard phase == .idle else { return }
        phase = .preparing

        guard await AudioRecorder.requestPermission() else {
            phase = .failed("Microphone access is off. Enable it in Settings › Privacy & Security › Microphone.")
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
            self.phase = .failed(message)
        }

        recorder.onWriteError = { [weak self] _ in
            guard let self, self.phase == .recording else { return }
            // The recorder already paused itself; keep the UI in sync and
            // tell the user why instead of pretending the recording is healthy.
            self.phase = .paused
            self.notice = "Recording paused — audio couldn't be written (storage may be full). Free up space and resume, or stop to save what's been captured."
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
            phase = .failed("Recording couldn't start: \(error.localizedDescription)")
            return
        }

        guard isTranscriptionEnabled else { return }
        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            await self.transcription.prepare()
            guard !Task.isCancelled, self.phase == .recording || self.phase == .paused else { return }
            guard let format = self.recorder.recordingFormat else { return }
            let handler = await self.transcription.start(inputFormat: format)
            guard !Task.isCancelled, self.phase == .recording || self.phase == .paused else { return }
            // The analyzer's clock starts at the first buffer it receives, but
            // the file already contains everything recorded while the model
            // prepared — offset segment timestamps so taps seek correctly.
            self.transcription.timestampOffset = self.recorder.elapsed
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

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // The default is stored verbatim so "still has the default title" can
        // be checked later even if the locale or time zone changes.
        let generatedDefault = Self.defaultTitle(for: startedAt)
        let meeting = Meeting(
            title: trimmedTitle.isEmpty ? generatedDefault : trimmedTitle,
            defaultTitle: generatedDefault,
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
            phase = .failed("The meeting couldn't be saved — storage may be full. Free up space and tap Save Recording to try again.")
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
                liveActivity.start(title: title)
            } else {
                liveActivity.update(isPaused: false, elapsed: recorder.elapsed)
            }
        case .paused:
            liveActivity.update(isPaused: true, elapsed: recorder.elapsed)
        case .idle, .saving, .failed:
            // The recorder has stopped (or never started) in all three —
            // ending is a no-op when no activity was requested.
            liveActivity.end()
        case .preparing:
            break
        }
    }

    static func defaultTitle(for date: Date = .now) -> String {
        "Meeting \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}
