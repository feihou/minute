import Foundation
import Testing
@testable import Minute

/// The Whisper live decode loop used to log-and-retry every failed pass
/// forever: a decoder that died mid-meeting left the panel showing stale
/// segments for the rest of the recording and the saved transcript simply
/// stopped mid-sentence, with nothing anywhere to explain it. The Apple
/// engine already says it; these pin the Whisper half's policy. The loop
/// itself can't be exercised here — it needs a downloaded model and a live
/// audio feed — so the two decisions it makes live in statics that can.
@MainActor
struct WhisperLiveFailureTests {
    private struct DecodeFailure: LocalizedError {
        var errorDescription: String? { "The decoder ran out of memory" }
    }

    @Test("Two failed passes are retried; three in a row give up")
    func givesUpAfterThreeConsecutiveFailures() {
        // One bad pass is usually transient — a decode that raced a purge, a
        // moment of memory pressure — and retrying costs half a second.
        #expect(!WhisperTranscriptionService.liveLoopShouldStop(consecutiveFailures: 0))
        #expect(!WhisperTranscriptionService.liveLoopShouldStop(consecutiveFailures: 1))
        #expect(!WhisperTranscriptionService.liveLoopShouldStop(consecutiveFailures: 2))
        // Three in a row is a decoder that isn't coming back.
        #expect(WhisperTranscriptionService.liveLoopShouldStop(consecutiveFailures: 3))
        #expect(WhisperTranscriptionService.liveLoopShouldStop(consecutiveFailures: 4))
        #expect(WhisperTranscriptionService.liveFailureLimit == 3)
    }

    @Test("Giving up says exactly what the Apple engine says")
    func stoppedAvailabilityReusesTheSharedMessage() {
        let availability = WhisperTranscriptionService.liveStoppedAvailability(DecodeFailure())

        // One sentence for both engines: what stopped, and that the recording
        // did not — a user watching the panel must not conclude the meeting
        // is being lost and stop it.
        #expect(availability == .unavailable(
            "Live transcription stopped: The decoder ran out of memory. Recording continues; you can re-transcribe the audio after saving."
        ))
        // And it is literally the same string, not a copy that can drift.
        #expect(availability == .unavailable(TranscriptionService.liveStoppedMessage(DecodeFailure())))
    }
}
