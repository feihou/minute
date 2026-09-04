import AVFoundation
import Foundation
import Speech
import Testing
@testable import Minute

@MainActor
struct TranscriptionUnavailableErrorTests {
    private func makeWavFixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("unavailable-fixture-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000)!
        buffer.frameLength = 8_000
        try file.write(from: buffer)
        return url
    }

    @Test func errorSurfacesItsMessageAsTheLocalizedDescription() {
        let error = TranscriptionUnavailableError(message: "The model isn't downloaded yet.")
        // MeetingJobs and AudioImporter render localizedDescription verbatim.
        #expect(error.localizedDescription == "The model isn't downloaded yet.")
    }

    /// A downloaded model on this machine makes the unavailable path
    /// unreachable. Stated as a condition rather than an early `return`, so
    /// the run output names the skip instead of reporting a test that
    /// asserted nothing. The predicate is the one `prepare()` itself gates
    /// on (WhisperTranscriptionService.swift:279), over the same variant the
    /// engine picks up from AppSettings.
    ///
    /// If this ever fails on a developer machine, look here first:
    /// TranscriptionEngineSettingsTests.whisperModelDefaultsToCatalog removes
    /// the "transcription.whisperModel" key for the length of its body, and
    /// suites run in parallel with each other. A trait evaluated inside that
    /// window reads the catalog default while the engine's `variant` — read
    /// once at init, from the same key — can resolve to a different, actually
    /// downloaded model, and Issue.record fires. Simulator and CI have
    /// nothing downloaded, so the window is harmless there.
    @Test(
        "Whisper's file path explains itself when the model isn't downloaded",
        .enabled(if: !WhisperModelStore.isDownloaded(AppSettings.whisperModel))
    )
    func whisperFileTranscriptionWithoutAModelThrowsTheExplanation() async throws {
        let engine = WhisperTranscriptionService()
        await engine.prepare()
        guard case .unavailable(let message) = engine.availability else {
            Issue.record("prepare() reported \(engine.availability); the condition above guarantees the model isn't downloaded")
            return
        }
        let url = try makeWavFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)

        await #expect(throws: TranscriptionUnavailableError(message: message)) {
            _ = try await engine.transcribe(file: file)
        }
    }

    /// Only a physical iPhone has SpeechTranscriber. Gating on isAvailable
    /// before the body rather than after `prepare()` is what keeps a device
    /// run honest: prepare() calls AssetInventory.assetInstallationRequest
    /// and downloadAndInstall (TranscriptionService.swift:73-76), so the old
    /// early return started a speech-model download and only then decided it
    /// had nothing to assert.
    @Test(
        "Apple Speech's file path explains itself when the engine is unavailable",
        .enabled(if: !SpeechTranscriber.isAvailable)
    )
    func appleSpeechFileTranscriptionWhenUnavailableThrowsTheExplanation() async throws {
        let engine = TranscriptionService()
        await engine.prepare()
        guard case .unavailable(let message) = engine.availability else {
            Issue.record("prepare() reported \(engine.availability); the condition above guarantees SpeechTranscriber is unavailable")
            return
        }
        let url = try makeWavFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)

        await #expect(throws: TranscriptionUnavailableError(message: message)) {
            _ = try await engine.transcribe(file: file)
        }
    }
}
