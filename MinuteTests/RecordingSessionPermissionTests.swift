import AVFoundation
import Foundation
import Testing
@testable import Minute

/// An engine that does nothing. The permission guard returns before the
/// recorder or the engine is touched; injecting one only keeps the session
/// from constructing the real Whisper / Apple Speech service in a test process.
@MainActor
private final class InertTranscriptionEngine: TranscriptionEngine {
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

/// A denied microphone is the one recording failure the user can fix without
/// leaving the meeting behind, and `canOpenSettings` is what puts the Open
/// Settings button on the recording screen for it. Until permission was
/// injectable that flag could only be produced by denying the real system
/// prompt on a device, so the branch had no coverage at all.
@MainActor
struct RecordingSessionPermissionTests {
    @Test func aDeniedMicrophoneFailsWithTheOpenSettingsAffordance() async {
        let session = RecordingSession(
            title: "No microphone",
            prefilledDefaultTitle: "No microphone",
            transcription: InertTranscriptionEngine(),
            requestPermission: { false }
        )

        await session.start()

        guard case .failed(let message, let canOpenSettings) = session.phase else {
            Issue.record("Expected a failed phase after permission was denied, got \(session.phase)")
            return
        }
        // The flag RecordingView keys the Open Settings button off.
        #expect(canOpenSettings)
        #expect(message.contains("Settings"))
        // The guard returns before any hardware is touched, so nothing was
        // captured and the failure must not offer to save a recording.
        #expect(session.didStartRecording == false)
    }
}
