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
    /// Tracks whether we activated the playback session, so stopping can
    /// deactivate it and let other apps' audio resume.
    private var sessionActivated = false

    private(set) var isPlaying = false
    private(set) var duration: TimeInterval = 0
    var currentTime: TimeInterval = 0

    var isLoaded: Bool { player != nil }

    @ObservationIgnored nonisolated(unsafe) private var observerToken: (any NSObjectProtocol)?

    override init() {
        super.init()
        // A phone call stops playback down in the audio layer without telling
        // this controller, so `isPlaying` stayed true and the button kept
        // reading "Pause" over silence — and tapping it then "paused" an
        // already-stopped player, taking two taps to get sound back.
        observerToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            let info = notification.userInfo
            let rawType = info?[AVAudioSessionInterruptionTypeKey] as? UInt
            switch rawType.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) {
            case .began:
                Task { @MainActor [weak self] in
                    guard let self, self.isPlaying else { return }
                    self.pause()
                }
            case .ended:
                let options = (info?[AVAudioSessionInterruptionOptionKey] as? UInt)
                    .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
                guard options.contains(.shouldResume) else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.isLoaded, !self.isPlaying else { return }
                    self.play()
                }
            default:
                break
            }
        }
    }

    deinit {
        if let observerToken {
            NotificationCenter.default.removeObserver(observerToken)
        }
    }

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
            sessionActivated = true
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
        // Release the non-mixable session while paused so other apps' audio
        // resumes; play() reactivates it.
        deactivateSessionIfNeeded()
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
        deactivateSessionIfNeeded()
    }

    private func deactivateSessionIfNeeded() {
        guard sessionActivated else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            sessionActivated = false
        } catch {
            // Keep the flag set so a later pause/stop/finish retries the
            // deactivation instead of leaving the session active for good.
            Self.logger.error("Deactivating playback session failed: \(error.localizedDescription)")
        }
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
            // Stale callback: playback was restarted (or a new file loaded)
            // between the delegate firing and this task running — don't tear
            // down the session the new playback just activated.
            guard self.player === player, !player.isPlaying else { return }
            self.isPlaying = false
            self.currentTime = 0
            self.stopTicker()
            self.deactivateSessionIfNeeded()
        }
    }
}
