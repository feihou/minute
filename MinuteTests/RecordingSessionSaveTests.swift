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
        release()
    }

    func transcribe(file: AVAudioFile) async throws -> [TranscriptSegment] { [] }

    /// Lets a parked finish() return, the way the final pass completing does.
    func release() {
        releaseContinuation.yield(())
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

        await session.discard(in: context)
        let finishedID = await finishTask.value

        #expect(finishedID == nil)
        #expect(try context.fetch(FetchDescriptor<Meeting>()).isEmpty)
        #expect(session.phase == .idle)
    }
}
