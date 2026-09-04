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
    /// Why playback couldn't start, for the playback bar to show. Cleared by
    /// the next successful start and by `stop()`.
    private(set) var lastError: String?

    /// Shown when AVAudioPlayer refuses to start. Named so the view and the
    /// tests agree on one string.
    static let playbackFailedMessage = "Couldn't start playback — another app may be using the audio."

    var isLoaded: Bool { player != nil }

    @ObservationIgnored nonisolated(unsafe) private var observerToken: (any NSObjectProtocol)?

    /// True only while playback was paused *by* an audio-session interruption,
    /// so the matching "interruption ended" resumes what it interrupted and
    /// nothing else. Cleared by every other route into or out of playback.
    private var pausedByInterruption = false

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
                    self.pausedByInterruption = true
                }
            case .ended:
                let options = (info?[AVAudioSessionInterruptionOptionKey] as? UInt)
                    .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
                let allowsResume = options.contains(.shouldResume)
                // Always delivered, resume or not: ownership has to be retired
                // even when the system refuses the resume.
                Task { @MainActor [weak self] in
                    self?.endInterruption(resuming: allowsResume)
                }
            default:
                break
            }
        }
    }

    /// The interruption that paused playback is over. Resumes only what that
    /// interruption stopped: the detail view loads the player as soon as a
    /// meeting is opened, so a recording the user never started is loaded and
    /// paused, and resuming it would play private audio out loud unasked.
    ///
    /// Ownership retires here whether or not the system permits the resume —
    /// left armed through a `.ended` that denied it, the claim would be
    /// inherited by an unrelated later interruption, which `.began` cannot
    /// reset because it only arms while actually playing.
    private func endInterruption(resuming: Bool) {
        let wasOurs = pausedByInterruption
        pausedByInterruption = false
        guard resuming, wasOurs, isLoaded, !isPlaying else { return }
        play()
    }

    deinit {
        if let observerToken {
            NotificationCenter.default.removeObserver(observerToken)
        }
    }

    /// Loads the recording at `url`. `makePlayer` is injectable for tests:
    /// AVAudioPlayer's refusal to start can't be provoked from a unit test any
    /// other way, and that refusal is the case this controller has to survive.
    func load(url: URL, makePlayer: (URL) throws -> AVAudioPlayer = { try AVAudioPlayer(contentsOf: $0) }) throws {
        stop()
        let player = try makePlayer(url)
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
        pausedByInterruption = false
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            sessionActivated = true
        } catch {
            Self.logger.error("Audio session for playback failed: \(error.localizedDescription)")
        }
        guard player.play() else {
            // The player did not start (typically a phone call or another
            // non-mixable session holds the hardware). Saying "playing" here
            // is the exact symptom this class exists to prevent: a pause icon
            // over silence with a clock that never moves.
            Self.logger.error("AVAudioPlayer refused to start playback")
            isPlaying = false
            stopTicker()
            deactivateSessionIfNeeded()
            lastError = Self.playbackFailedMessage
            return
        }
        lastError = nil
        isPlaying = true
        startTicker()
    }

    func pause() {
        // A deliberate pause is not an interruption. The `.began` handler
        // re-arms this immediately afterwards for the one case that is.
        pausedByInterruption = false
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
        pausedByInterruption = false
        lastError = nil
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
            // Reaching the end is not an interruption to come back from.
            self.pausedByInterruption = false
            self.isPlaying = false
            self.currentTime = 0
            self.stopTicker()
            self.deactivateSessionIfNeeded()
        }
    }
}
