import AVFoundation
import Foundation
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

    @Test func whisperFileTranscriptionWithoutAModelThrowsTheExplanation() async throws {
        let engine = WhisperTranscriptionService()
        await engine.prepare()
        guard case .unavailable(let message) = engine.availability else {
            // A downloaded model on this machine makes the unavailable path
            // unreachable; nothing to assert.
            return
        }
        let url = try makeWavFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)

        await #expect(throws: TranscriptionUnavailableError(message: message)) {
            _ = try await engine.transcribe(file: file)
        }
    }

    @Test func appleSpeechFileTranscriptionWhenUnavailableThrowsTheExplanation() async throws {
        let engine = TranscriptionService()
        await engine.prepare()
        guard case .unavailable(let message) = engine.availability else {
            // Only a physical iPhone has SpeechTranscriber; on one, nothing to assert.
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
