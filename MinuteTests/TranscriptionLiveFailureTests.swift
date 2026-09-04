import Foundation
import Testing
@testable import Minute

/// When the live results stream dies mid-recording the panel used to keep
/// showing the segments it already had (or "Listening…") for the rest of the
/// meeting, and the saved transcript simply stopped mid-sentence with nothing
/// anywhere to explain it.
@MainActor
struct TranscriptionLiveFailureTests {
    private struct StreamFailure: LocalizedError {
        var errorDescription: String? { "The analyzer stopped responding" }
    }

    @Test func liveFailureMessageNamesTheCauseAndPromisesTheRecordingContinues() {
        let message = TranscriptionService.liveStoppedMessage(StreamFailure())

        #expect(message == "Live transcription stopped: The analyzer stopped responding. Recording continues; you can re-transcribe the audio after saving.")
    }
}
