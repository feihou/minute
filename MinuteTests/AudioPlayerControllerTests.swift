import AVFoundation
import Foundation
import Testing
@testable import Minute

/// A player that refuses to start, the way AVAudioPlayer does while another
/// app's non-mixable session (a phone call) holds the audio hardware.
private final class RefusingPlayer: AVAudioPlayer {
    override func play() -> Bool { false }
}

/// A player that starts, without depending on the test simulator actually
/// having an audio route.
private final class StartingPlayer: AVAudioPlayer {
    override func play() -> Bool { true }
}

/// `play()` used to discard AVAudioPlayer's Bool: when the player refused to
/// start, the bar showed the pause icon and "Pause playback" over silence with
/// a frozen clock, and nothing ever corrected it.
@MainActor
struct AudioPlayerControllerTests {
    /// Half a second of silence, written as a real WAV file so AVAudioPlayer
    /// can open it.
    private func makeWavFixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("playback-fixture-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000)!
        buffer.frameLength = 8_000
        try file.write(from: buffer)
        return url
    }

    @Test func aPlayerThatRefusesToStartLeavesTheBarOnPlayAndSaysWhy() throws {
        let url = try makeWavFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = AudioPlayerController()
        try controller.load(url: url) { try RefusingPlayer(contentsOf: $0) }

        controller.play()

        #expect(controller.isPlaying == false)
        #expect(controller.lastError == AudioPlayerController.playbackFailedMessage)
        controller.stop()
    }

    @Test func aPlayerThatStartsClearsTheEarlierFailure() throws {
        let url = try makeWavFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = AudioPlayerController()
        try controller.load(url: url) { try RefusingPlayer(contentsOf: $0) }
        controller.play()
        #expect(controller.lastError != nil)

        try controller.load(url: url) { try StartingPlayer(contentsOf: $0) }
        controller.play()

        #expect(controller.isPlaying)
        #expect(controller.lastError == nil)
        controller.stop()
    }
}
