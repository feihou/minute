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
}
