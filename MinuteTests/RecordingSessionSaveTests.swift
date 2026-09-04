import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import Minute

/// A live engine whose `finish()` parks until the test releases it. The real
/// engines' finish() waits on a final decode pass that can run for minutes
/// (Whisper's tail is capped at five), which is the window every test in this
/// file is about.
@MainActor
private final class ParkedTranscriptionEngine: TranscriptionEngine {
    var availability: TranscriptionAvailability = .available
    var volatileText = ""
    /// What the engine has heard so far — what "Save without transcript" keeps.
    var segments: [TranscriptSegment] = []
    var timestampOffset: TimeInterval = 0
    /// What a finish() that runs to completion returns.
    var finalSegments: [TranscriptSegment] = []
    private(set) var didCancel = false
    /// Fires as finish() is entered, so a test can inspect the store at the
    /// exact moment the real engine would begin its final pass.
    var onFinishEntered: (() -> Void)?

    private let releases: AsyncStream<Void>
    private let releaseContinuation: AsyncStream<Void>.Continuation

    init() {
        (releases, releaseContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    func prepare() async {}

    func start(inputFormat: AVAudioFormat) async -> (@Sendable (AVAudioPCMBuffer) -> Void)? { nil }

    func finish() async -> [TranscriptSegment] {
        onFinishEntered?()
        var iterator = releases.makeAsyncIterator()
        _ = await iterator.next()
        return didCancel ? [] : finalSegments
    }

    func cancel() async {
        didCancel = true
        // The real engines clear their own collection here — which is why the
        // session has to bank the segments before cancelling.
        segments = []
        volatileText = ""
        release()
    }

    func transcribe(file: AVAudioFile) async throws -> [TranscriptSegment] { [] }

    /// Lets a parked finish() return, the way the final pass completing does.
    func release() {
        releaseContinuation.yield(())
    }
}

/// A `MeetingStore.delete` stand-in whose commit can be switched off. The real
/// one fails when `context.save()` throws — storage full, store unavailable —
/// which SwiftData's in-memory store cannot be made to do, and that failure is
/// the branch that decides whether a discard can leave a meeting in the library
/// pointing at audio the session already deleted.
@MainActor
private final class StubbedMeetingDelete {
    /// While false, behaves like a delete whose save threw: MeetingStore undoes
    /// the deletion by re-inserting the row, so the meeting stays live and the
    /// caller is told the delete didn't happen.
    var commits = true

    func delete(_ meeting: Meeting, in context: ModelContext) -> Bool {
        guard commits else { return false }
        return MeetingStore.delete(meeting, context: context)
    }
}

@MainActor
struct RecordingSessionSaveTests {
    /// Containers are retained for the process lifetime: ModelContainer
    /// teardown is not actor-isolated, and a container deiniting in the
    /// background while another test runs crashes the test host inside
    /// SwiftData.framework. Pattern copied from
    /// MinuteTests/KnowledgeCatchUpTests.swift.
    private static var retainedContainers: [ModelContainer] = []

    @discardableResult
    private static func retain(_ container: ModelContainer) -> ModelContainer {
        retainedContainers.append(container)
        return container
    }

    private func makeContext() throws -> ModelContext {
        try Self.retain(ModelContainer(
            for: Meeting.self, KnowledgeEntity.self, KnowledgeFact.self,
            configurations: MeetingStore.modelConfiguration(inMemory: true)
        )).mainContext
    }

    @Test func theSessionUsesTheEngineItWasGiven() {
        let engine = ParkedTranscriptionEngine()
        let session = RecordingSession(
            title: "Injected",
            prefilledDefaultTitle: "Injected",
            transcription: engine
        )

        #expect(session.transcription === engine)
    }

    /// The audio file is complete and playable the moment recorder.stop()
    /// returns, but nothing references it until a Meeting row exists — and the
    /// launch sweep deletes unreferenced recordings. Finalizing a Whisper tail
    /// can outlast the ~30 s background assertion, so the row has to be written
    /// first: a suspension then costs the transcript, not the meeting.
    @Test func theMeetingIsSavedBeforeTheTranscriptIsFinalized() async throws {
        let context = try makeContext()
        let engine = ParkedTranscriptionEngine()
        engine.finalSegments = [TranscriptSegment(text: "landed after the save", start: 0, end: 1)]
        let session = RecordingSession(
            title: "  Board review  ",
            prefilledDefaultTitle: "Meeting Sep 2, 2026 at 9:30 AM",
            transcription: engine
        )

        let (entered, enteredContinuation) = AsyncStream.makeStream(of: Void.self)
        engine.onFinishEntered = { enteredContinuation.yield(()) }
        let finishTask = Task { @MainActor in await session.finish(in: context)?.id }
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()

        // Mid-finalization: the meeting is already on disk, transcript pending.
        let parked = try context.fetch(FetchDescriptor<Meeting>())
        #expect(parked.count == 1)
        #expect(parked.first?.title == "Board review")
        #expect(parked.first?.segments.isEmpty == true)

        engine.release()
        let finishedID = await finishTask.value
        #expect(finishedID != nil)

        // Same row, now carrying the transcript — never a second meeting for
        // the same audio.
        let saved = try context.fetch(FetchDescriptor<Meeting>())
        #expect(saved.count == 1)
        #expect(saved.first?.id == finishedID)
        #expect(saved.first?.segments.map(\.text) == ["landed after the save"])
        #expect(session.phase == .idle)
    }

    /// Persisting first means a discard arriving mid-finalization has a row to
    /// clean up: the audio it points at is already gone, and a meeting must
    /// never survive pointing at deleted audio.
    @Test func discardingWhileTheTranscriptFinalizesRemovesTheRowItAlreadyWrote() async throws {
        let context = try makeContext()
        let engine = ParkedTranscriptionEngine()
        engine.finalSegments = [TranscriptSegment(text: "never wanted", start: 0, end: 1)]
        let session = RecordingSession(
            title: "Throwaway",
            prefilledDefaultTitle: "Throwaway",
            transcription: engine
        )

        let (entered, enteredContinuation) = AsyncStream.makeStream(of: Void.self)
        engine.onFinishEntered = { enteredContinuation.yield(()) }
        let finishTask = Task { @MainActor in await session.finish(in: context)?.id }
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()
        #expect(try context.fetch(FetchDescriptor<Meeting>()).count == 1)

        let discarded = await session.discard(in: context)
        let finishedID = await finishTask.value

        #expect(discarded)
        #expect(finishedID == nil)
        #expect(try context.fetch(FetchDescriptor<Meeting>()).isEmpty)
        #expect(session.phase == .idle)
    }

    /// `.saving` is otherwise unbounded — a Whisper final pass over a long tail
    /// runs for minutes on an older device, with Discard disabled and both
    /// controls greyed out. The way out keeps what the engine already heard.
    @Test func saveWithoutTranscriptStopsWaitingAndKeepsWhatWasHeard() async throws {
        let context = try makeContext()
        let engine = ParkedTranscriptionEngine()
        engine.segments = [TranscriptSegment(text: "heard before the user gave up", start: 0, end: 1)]
        // The sentence in flight when the user gave up. finish() promotes this
        // into a segment; the way out must not be the one path that drops it.
        engine.volatileText = "and the half-said sentence"
        engine.finalSegments = [TranscriptSegment(text: "never finalized", start: 0, end: 1)]
        let session = RecordingSession(
            title: "Long tail",
            prefilledDefaultTitle: "Long tail",
            transcription: engine
        )

        let (entered, enteredContinuation) = AsyncStream.makeStream(of: Void.self)
        engine.onFinishEntered = { enteredContinuation.yield(()) }
        let finishTask = Task { @MainActor in await session.finish(in: context)?.id }
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()

        await session.saveWithoutTranscript()
        let finishedID = await finishTask.value

        #expect(finishedID != nil)
        #expect(engine.didCancel)
        let saved = try context.fetch(FetchDescriptor<Meeting>())
        #expect(saved.count == 1)
        #expect(saved.first?.segments.map(\.text) == ["heard before the user gave up", "and the half-said sentence"])
        // Promoted the way finish() does it: a zero-length segment at the end
        // of the last one, so the transcript's timeline stays sane.
        #expect(saved.first?.segments.last?.start == 1)
        #expect(saved.first?.segments.last?.end == 1)
        #expect(session.phase == .idle)
    }

    /// A delete that doesn't commit is undone by MeetingStore, so the meeting
    /// is still in the library. Deleting its audio anyway — or reporting the
    /// discard as done and letting the screen dismiss — produces the one state
    /// MeetingStore is written to prevent: a visible meeting whose recording is
    /// gone, with playback and Re-transcribe both dead. So a discard that can't
    /// remove the row keeps the recording, says so, and holds the meeting for a
    /// retry — while flagging that the screen may still be left, since the row
    /// and its audio came through the failure consistent with each other.
    @Test func aDiscardWhoseDeleteDoesNotCommitKeepsTheRecordingAndReportsFailure() async throws {
        let context = try makeContext()
        let engine = ParkedTranscriptionEngine()
        engine.finalSegments = [TranscriptSegment(text: "still here", start: 0, end: 1)]
        let deletes = StubbedMeetingDelete()
        deletes.commits = false
        let session = RecordingSession(
            title: "Undeletable",
            prefilledDefaultTitle: "Undeletable",
            transcription: engine,
            deleteMeeting: { deletes.delete($0, in: $1) }
        )

        let (entered, enteredContinuation) = AsyncStream.makeStream(of: Void.self)
        engine.onFinishEntered = { enteredContinuation.yield(()) }
        let finishTask = Task { @MainActor in await session.finish(in: context)?.id }
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()

        let discarded = await session.discard(in: context)
        let finishedID = await finishTask.value

        #expect(discarded == false)
        #expect(finishedID == nil)
        // The row survived the failed delete, so its audio has to survive too.
        #expect(try context.fetch(FetchDescriptor<Meeting>()).count == 1)
        if case .failed(let message, let canOpenSettings) = session.phase {
            #expect(message.contains("still saved in your library"))
            #expect(canOpenSettings == false)
        } else {
            Issue.record("Expected a failed phase after the delete didn't commit, got \(session.phase)")
        }
        // Nothing here is half-deleted, so the screen has to stay escapable:
        // this flag is what puts "Keep in Library" beside the retry. Without
        // it the recording sheet — which can't be swiped away — has no control
        // left that doesn't retry the same failing delete, and storage does
        // not free itself while the user is held there.
        #expect(session.discardFailed)

        // The meeting handle survived, so the retry finishes the discard
        // instead of leaving a row nothing can reach.
        deletes.commits = true
        let retried = await session.discard(in: context)

        #expect(retried)
        #expect(session.discardFailed == false)
        #expect(try context.fetch(FetchDescriptor<Meeting>()).isEmpty)
        #expect(session.phase == .idle)
    }

    /// Once finish() has saved, the meeting belongs to the library rather than
    /// to this session — and the toolbar's Discard goes live again the instant
    /// the phase returns to .idle, a runloop turn before the screen closes. A
    /// discard landing in that gap must not delete the meeting the caller was
    /// just handed, nor the audio it points at.
    @Test func discardingAfterASuccessfulSaveLeavesTheSavedMeetingAlone() async throws {
        let context = try makeContext()
        let engine = ParkedTranscriptionEngine()
        engine.finalSegments = [TranscriptSegment(text: "keep me", start: 0, end: 1)]
        let session = RecordingSession(
            title: "Kept",
            prefilledDefaultTitle: "Kept",
            transcription: engine
        )
        // Buffered, so the finish below never parks.
        engine.release()
        let saved = await session.finish(in: context)
        #expect(saved != nil)

        let discarded = await session.discard(in: context)

        #expect(discarded)
        let survivors = try context.fetch(FetchDescriptor<Meeting>())
        #expect(survivors.count == 1)
        #expect(survivors.first?.segments.map(\.text) == ["keep me"])
    }
}
