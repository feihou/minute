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

    private(set) var phase: Phase = .idle
    /// True once audio capture began — a later failure should offer to keep it.
    private(set) var didStartRecording = false
    /// Transient, user-visible explanation (e.g. why recording auto-paused).
    private(set) var notice: String?
    var title: String
    private var audioFileName: String?
    private var transcriptionTask: Task<Void, Never>?
    private let startedAt = Date()

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

        // Start capturing audio immediately — recording never waits on the
        // speech model. Transcription attaches below once it's ready.
        do {
            try recorder.activateSession()
            let fileName = MeetingStore.newAudioFileName()
            let url = try MeetingStore.audioURL(fileName: fileName)
            audioFileName = fileName
            try recorder.start(writingTo: url)
            didStartRecording = true
            phase = .recording
        } catch {
            phase = .failed("Recording couldn't start: \(error.localizedDescription)")
            return
        }

        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            await self.transcription.prepare()
            guard !Task.isCancelled, self.phase == .recording || self.phase == .paused else { return }
            guard let format = self.recorder.recordingFormat else { return }
            let handler = await self.transcription.start(inputFormat: format)
            guard !Task.isCancelled, self.phase == .recording || self.phase == .paused else { return }
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

    /// Stops everything, saves the meeting, and returns it.
    func finish(in context: ModelContext) async -> Meeting {
        phase = .saving
        transcriptionTask?.cancel()
        let duration = recorder.stop()
        let segments = await transcription.finish()

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let meeting = Meeting(
            title: trimmedTitle.isEmpty ? Self.defaultTitle(for: startedAt) : trimmedTitle,
            createdAt: startedAt,
            duration: duration,
            audioFileName: audioFileName,
            segments: segments
        )
        context.insert(meeting)
        do {
            try context.save()
        } catch {
            Self.logger.error("Saving meeting failed: \(error.localizedDescription)")
        }
        phase = .idle
        return meeting
    }

    /// Stops everything and deletes the partial audio file (user discarded).
    func discard() async {
        transcriptionTask?.cancel()
        recorder.stop()
        await transcription.cancel()
        if let audioFileName {
            MeetingStore.deleteAudioFile(named: audioFileName)
        }
        audioFileName = nil
        didStartRecording = false
        phase = .idle
    }

    static func defaultTitle(for date: Date = .now) -> String {
        "Meeting \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}
