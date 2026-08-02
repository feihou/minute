import AVFoundation
import Foundation
import Observation
import OSLog

/// Plays back a meeting recording with progress, seek, and play/pause.
@MainActor
@Observable
final class AudioPlayerController: NSObject, AVAudioPlayerDelegate {
    private static let logger = Logger(subsystem: "com.minuteapp.Minute", category: "Playback")

    private var player: AVAudioPlayer?
    private var ticker: Task<Void, Never>?

    private(set) var isPlaying = false
    private(set) var duration: TimeInterval = 0
    var currentTime: TimeInterval = 0

    var isLoaded: Bool { player != nil }

    func load(url: URL) throws {
        stop()
        let player = try AVAudioPlayer(contentsOf: url)
        player.delegate = self
        player.prepareToPlay()
        self.player = player
        duration = player.duration
        currentTime = 0
    }

    func togglePlayback() {
        guard let player else { return }
        if player.isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        guard let player else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
        } catch {
            Self.logger.error("Audio session for playback failed: \(error.localizedDescription)")
        }
        player.play()
        isPlaying = true
        startTicker()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTicker()
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = min(max(0, time), duration)
        currentTime = player.currentTime
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        stopTicker()
    }

    private func startTicker() {
        stopTicker()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, let player = self.player else { break }
                self.currentTime = player.currentTime
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.currentTime = 0
            self.stopTicker()
        }
    }
}
