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

    /// An engine whose file pass parks until the job is cancelled — the Stop
    /// button's path, and the one exit that reports no failure anywhere.
    @MainActor
    private final class ParkedTranscriptionEngine: TranscriptionEngine {
        var availability: TranscriptionAvailability = .available
        var volatileText = ""
        var segments: [TranscriptSegment] = []
        var timestampOffset: TimeInterval = 0
        /// Fires as the pass begins, so Stop lands while the job is running
        /// rather than before it started.
        var onTranscribeEntered: (() -> Void)?
        func prepare() async {}
        func start(inputFormat: AVAudioFormat) async -> (@Sendable (AVAudioPCMBuffer) -> Void)? { nil }
        func finish() async -> [TranscriptSegment] { [] }
        func cancel() async {}
        func transcribe(file: AVAudioFile) async throws -> [TranscriptSegment] {
            onTranscribeEntered?()
            // Cancellation-responsive: a wedged job fails the time limit
            // instead of hanging the suite.
            try await Task.sleep(for: .seconds(60))
            return []
        }
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

    /// An engine that recognizes one line. This file's only fixture for a job
    /// that actually succeeds — every other one fails, stops, or produces
    /// nothing, so nothing here ever reached the tail of `start`'s do block.
    @MainActor
    private final class OneSegmentTranscriptionEngine: TranscriptionEngine {
        var availability: TranscriptionAvailability = .available
        var volatileText = ""
        var segments: [TranscriptSegment] = []
        var timestampOffset: TimeInterval = 0
        func prepare() async {}
        func start(inputFormat: AVAudioFormat) async -> (@Sendable (AVAudioPCMBuffer) -> Void)? { nil }
        func finish() async -> [TranscriptSegment] { [] }
        func cancel() async {}
        func transcribe(file: AVAudioFile) async throws -> [TranscriptSegment] {
            [TranscriptSegment(text: "Atlas ships in Q3.", start: 0, end: 1)]
        }
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

    @Test func startingAJobAnnouncesThatUserWorkBegan() async throws {
        let (container, meeting) = try makeMeeting()
        defer { _ = container }
        let jobs = MeetingJobs()

        var started = 0
        jobs.onWorkStarted = { started += 1 }

        let task = jobs.summarize(meeting, template: .standard, context: "", language: nil)
        // Fired before the work runs: the knowledge catch-up loop has to stop
        // competing for the on-device model with the summary the user is
        // watching, not learn about it once the summary is over.
        #expect(started == 1)

        // Re-entering the screen attaches to the running job; that is not new
        // work and must not fire again.
        jobs.summarize(meeting, template: .standard, context: "", language: nil)
        #expect(started == 1)

        await task?.value
        #expect(started == 1)
    }

    @Test func aJobThatFailsStillAnnouncesThatItsWorkEnded() async throws {
        let (container, meeting) = try makeMeeting()
        defer { _ = container }
        let jobs = MeetingJobs()

        var started = 0
        var ended = 0
        var changed = 0
        jobs.onWorkStarted = { started += 1 }
        jobs.onWorkEnded = { ended += 1 }
        jobs.onContentChanged = { changed += 1 }

        // No transcript: the summary throws. Nothing else speaks for this job
        // — onContentChanged fires only on success — so the catch-up pause it
        // took is given back here or never, and the Brain goes quiet for the
        // rest of the foreground session.
        await jobs.summarize(meeting, template: .standard, context: "", language: nil)?.value

        #expect(started == 1)
        #expect(ended == 1)
        // The other half of that sentence, and the whole basis of the catch-up
        // loop's "only success nudges" reasoning: a failed job wrote nothing,
        // so there is nothing new for the Brain to read.
        #expect(changed == 0)
        #expect(jobs.error(.summary, for: meeting) != nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func aStoppedJobStillAnnouncesThatItsWorkEnded() async throws {
        let (container, meeting) = try makeMeeting()
        defer { _ = container }
        let source = try makeWavFixture()
        defer { try? FileManager.default.removeItem(at: source) }
        let jobs = MeetingJobs()

        var ended = 0
        var changed = 0
        jobs.onWorkEnded = { ended += 1 }
        jobs.onContentChanged = { changed += 1 }

        let engine = ParkedTranscriptionEngine()
        let (entered, enteredContinuation) = AsyncStream.makeStream(of: Void.self)
        engine.onTranscribeEntered = { enteredContinuation.yield(()) }
        let task = jobs.retranscribe(meeting, audioAt: source, transcription: engine)
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()   // the pass is definitely in flight

        // The user tapped Stop. A cancelled job records no failure and never
        // nudges, so this is the only announcement it makes.
        jobs.cancel(meeting)
        await task?.value

        #expect(ended == 1)
        // A cancelled job left the transcript exactly as it was.
        #expect(changed == 0)
        #expect(!jobs.isBusy(meeting))
    }

    @Test func aSuccessfulJobAnnouncesThatTheContentChanged() async throws {
        let (container, meeting) = try makeMeeting()
        defer { _ = container }
        let source = try makeWavFixture()
        defer { try? FileManager.default.removeItem(at: source) }
        let jobs = MeetingJobs()

        var changed = 0
        var ended = 0
        jobs.onContentChanged = { changed += 1 }
        jobs.onWorkEnded = { ended += 1 }

        await jobs.retranscribe(meeting, audioAt: source, transcription: OneSegmentTranscriptionEngine())?.value

        // The knowledge catch-up loop reads this as "there is new text to
        // extract" — exactly once, for a job that really wrote something.
        #expect(changed == 1)
        #expect(ended == 1)
        #expect(meeting.segments.count == 1)
        #expect(jobs.error(.transcription, for: meeting) == nil)
        #expect(!jobs.isBusy(meeting))
    }
}
