import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import Minute

@MainActor
struct SummaryGenerationTests {
    // The container must outlive the meeting — a deallocated store makes
    // every model access undefined.
    private func makeMeeting() throws -> (ModelContainer, Meeting) {
        let container = try ModelContainer(
            for: Meeting.self,
            configurations: MeetingStore.modelConfiguration(inMemory: true)
        )
        let meeting = Meeting(title: "Empty")
        container.mainContext.insert(meeting)
        return (container, meeting)
    }

    /// Half a second of silence, written as a real WAV file — re-transcription
    /// opens the audio with AVAudioFile before it ever reaches the engine.
    private func makeWavFixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("retranscribe-fixture-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000)!
        buffer.frameLength = 8_000
        try file.write(from: buffer)
        return url
    }

    /// An engine that is "available" and recognizes nothing — audio in a
    /// language the device isn't set to, or plain silence.
    @MainActor
    private final class EmptyTranscriptionEngine: TranscriptionEngine {
        var availability: TranscriptionAvailability = .available
        var volatileText = ""
        var segments: [TranscriptSegment] = []
        var timestampOffset: TimeInterval = 0
        func prepare() async {}
        func start(inputFormat: AVAudioFormat) async -> (@Sendable (AVAudioPCMBuffer) -> Void)? { nil }
        func finish() async -> [TranscriptSegment] { [] }
        func cancel() async {}
        func transcribe(file: AVAudioFile) async throws -> [TranscriptSegment] { [] }
    }

    @Test func failedGenerationClearsInFlightStateAndRecordsError() async throws {
        let (container, meeting) = try makeMeeting()
        defer { _ = container }
        let jobs = MeetingJobs()

        let task = jobs.summarize(meeting, template: .standard, context: "", language: nil)
        #expect(jobs.isRunning(.summary, for: meeting))
        await task?.value

        // No transcript: generation fails fast, clears the in-flight state,
        // and surfaces an error the view can show on any later visit.
        #expect(!jobs.isRunning(.summary, for: meeting))
        #expect(!jobs.isBusy(meeting))
        #expect(jobs.status(for: meeting) == nil)
        #expect(jobs.error(.summary, for: meeting) != nil)
        #expect(meeting.summary == nil)
    }

    @Test func generateWhileRunningReturnsTheSameTask() async throws {
        let (container, meeting) = try makeMeeting()
        defer { _ = container }
        let jobs = MeetingJobs()

        let first = jobs.summarize(meeting, template: .standard, context: "", language: nil)
        let second = jobs.summarize(meeting, template: .standard, context: "", language: nil)
        // Re-entering the screen must attach to the running generation, never
        // start a second one for the same meeting.
        #expect(first == second)
        await first?.value
        #expect(!jobs.isBusy(meeting))
    }

    @Test func aSecondKindOfJobIsRefusedWhileOneIsRunning() async throws {
        let (container, meeting) = try makeMeeting()
        defer { _ = container }
        let jobs = MeetingJobs()

        let summary = jobs.summarize(meeting, template: .standard, context: "", language: nil)
        // The whole point of the single slot: re-transcription and speaker
        // identification rewrite the same segments a summary is reading, so
        // they must attach to the running job rather than start alongside it.
        let other = jobs.retranscribe(meeting, audioAt: URL(fileURLWithPath: "/dev/null"))
        #expect(other == summary)
        #expect(jobs.isRunning(.summary, for: meeting))
        #expect(!jobs.isRunning(.transcription, for: meeting))

        await summary?.value
        #expect(!jobs.isBusy(meeting))
    }

    @Test func errorsAreReportedOnlyForTheKindThatFailed() async throws {
        let (container, meeting) = try makeMeeting()
        defer { _ = container }
        let jobs = MeetingJobs()

        await jobs.summarize(meeting, template: .standard, context: "", language: nil)?.value

        // The detail view renders summary and transcript errors in different
        // sections; a summary failure must not light up the transcript one.
        #expect(jobs.error(.summary, for: meeting) != nil)
        #expect(jobs.error(.transcription, for: meeting) == nil)
        #expect(jobs.error(.diarization, for: meeting) == nil)
    }

    @Test func autoSummaryIsClaimedOnlyOncePerMeeting() throws {
        let (container, meeting) = try makeMeeting()
        defer { _ = container }
        let jobs = MeetingJobs()

        // The detail view's .task re-runs on every re-appearance (tab switch,
        // a cover dismissed over it). Automatic generation must not restart
        // one the user stopped: first ask wins, every later ask is refused.
        #expect(jobs.claimAutoSummary(for: meeting))
        #expect(!jobs.claimAutoSummary(for: meeting))

        let other = Meeting(title: "Other")
        container.mainContext.insert(other)
        #expect(jobs.claimAutoSummary(for: other))
    }

    @Test func autoSummaryIsNotClaimedWhileAFailureIsShowing() async throws {
        let (container, meeting) = try makeMeeting()
        defer { _ = container }
        let jobs = MeetingJobs()

        // No transcript: the job fails fast and records an error.
        await jobs.summarize(meeting, template: .standard, context: "", language: nil)?.value
        #expect(jobs.error(.summary, for: meeting) != nil)

        // A failed generation is retried only by an explicit tap; restarting
        // it automatically would also wipe the error the user should read.
        #expect(!jobs.claimAutoSummary(for: meeting))
    }

    @Test func noTextMessageSaysWhetherTheOldTranscriptWasKept() {
        let kept = MeetingJobs.noTextMessage(keptExistingTranscript: true)
        let fresh = MeetingJobs.noTextMessage(keptExistingTranscript: false)
        #expect(kept.contains("existing transcript was kept"))
        #expect(!fresh.contains("kept"))
        #expect(fresh.hasPrefix("Re-transcription produced no text"))
    }

    @Test func retranscriptionThatRecognizedNothingReportsInsteadOfApplying() async throws {
        let (container, meeting) = try makeMeeting()
        defer { _ = container }
        let source = try makeWavFixture()
        defer { try? FileManager.default.removeItem(at: source) }
        let jobs = MeetingJobs()

        await jobs.retranscribe(meeting, audioAt: source, transcription: EmptyTranscriptionEngine())?.value

        // An empty pass must never be mistaken for "this meeting has no
        // speech": the user hears why, and nothing is written over.
        let message = try #require(jobs.error(.transcription, for: meeting))
        #expect(message.contains("produced no text"))
        #expect(meeting.segments.isEmpty)
        #expect(!jobs.isBusy(meeting))
    }
}
