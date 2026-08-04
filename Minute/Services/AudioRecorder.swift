import AVFoundation
import Foundation
import Observation
import os
import OSLog

enum RecorderError: LocalizedError {
    case noAudioInput
    case formatConversionFailed

    var errorDescription: String? {
        switch self {
        case .noAudioInput:
            return "No microphone input is available."
        case .formatConversionFailed:
            return "The microphone's audio format changed and couldn't be converted."
        }
    }
}

/// Box the audio tap reads on every buffer, so live transcription can attach
/// after recording has already started (e.g. while the speech model downloads).
/// A lock guards the closure: the main actor writes it while the realtime tap
/// thread reads it, and an unsynchronized ARC handoff would be a data race.
final class BufferHandlerBox: Sendable {
    typealias Handler = @Sendable (AVAudioPCMBuffer) -> Void

    /// Keep the closure behind a stable reference. Returning a closure stored
    /// directly as `OSAllocatedUnfairLock` state adds a reabstraction wrapper
    /// on every read; a long recording then overflows the stack when stop()
    /// clears and recursively releases that wrapper chain.
    private final class HandlerEntry: Sendable {
        let value: Handler

        init(_ value: @escaping Handler) {
            self.value = value
        }
    }

    private let storage = OSAllocatedUnfairLock<HandlerEntry?>(initialState: nil)

    var handler: Handler? {
        get {
            let entry = storage.withLock { $0 }
            return entry?.value
        }
        set {
            let replacement = newValue.map(HandlerEntry.init)
            // Hand the old handler back out and let it die at the end of this
            // scope, i.e. after unlocking. Besides shortening the critical
            // section, this avoids running arbitrary capture cleanup while the
            // non-recursive lock is held. Returning it (rather than swapping
            // with a captured var) also keeps this legal under Swift 6, which
            // rejects mutating a captured var from a concurrently-executing
            // closure.
            let previous = storage.withLock { state -> HandlerEntry? in
                let old = state
                state = replacement
                return old
            }
            _ = previous
        }
    }
}

/// Records microphone audio to an AAC file with pause/resume, level metering,
/// and a live buffer feed for transcription. All audio stays on device.
@MainActor
@Observable
final class AudioRecorder {
    enum State: Equatable {
        case idle
        case recording
        case paused
        /// Capture ended in a way that cannot be resumed in place: a media
        /// services reset took the engine, the session, and the file's encoder
        /// with it. Distinct from `.paused` because everything captured so far
        /// is still saveable, but resuming can never succeed — the file has
        /// been closed and `installTap()` would have nothing to write to.
        case captureLost
    }

    private static let logger = Logger(subsystem: "com.minuteapp.Minute", category: "AudioRecorder")

    private(set) var state: State = .idle
    /// Smoothed input level in 0...1 for the recording indicator.
    private(set) var level: Float = 0

    /// Called after the system auto-pauses recording (phone call, Siri, or an
    /// audio route/configuration change), so the owner can reflect it in UI.
    var onAutoPause: (() -> Void)?

    /// Called when the recorder resumed itself after the system said the
    /// interruption is over, so the owner can clear the "paused" notice.
    var onAutoResume: (() -> Void)?

    /// Called when capture died in a way that cannot be resumed in place
    /// (media services reset). Everything recorded so far is still on disk and
    /// saveable; nothing more will be captured.
    var onCaptureLost: ((String) -> Void)?

    /// Called once per recording when writing audio to disk starts failing
    /// (e.g. storage full). The recorder auto-pauses first, so everything
    /// captured so far stays saveable.
    var onWriteError: ((Error) -> Void)?
    private var didReportWriteError = false

    private let engine = AVAudioEngine()
    private let tapHandler = BufferHandlerBox()
    private var file: AVAudioFile?
    private var accumulatedTime: TimeInterval = 0
    private var segmentStartedAt: Date?
    /// True only while paused *by* an audio-session interruption, so the
    /// matching "interruption ended" can resume what it interrupted and
    /// nothing else. Cleared by every other route out of `.recording`.
    private var pausedByInterruption = false
    @ObservationIgnored nonisolated(unsafe) private var observerTokens: [any NSObjectProtocol] = []

    /// Total recorded time, excluding paused stretches.
    var elapsed: TimeInterval {
        accumulatedTime + (segmentStartedAt.map { Date().timeIntervalSince($0) } ?? 0)
    }

    /// The stable format buffers are delivered in (the file's processing
    /// format) — hardware format changes are converted to this.
    var recordingFormat: AVAudioFormat? {
        file?.processingFormat
    }

    init() {
        let pauseOnNotification: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.systemPause(causedByInterruption: false)
            }
        }
        // Phone call / Siri interruption: iOS suspends our audio session.
        observerTokens.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            let info = notification.userInfo
            let rawType = info?[AVAudioSessionInterruptionTypeKey] as? UInt
            switch rawType.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) {
            case .began:
                Task { @MainActor [weak self] in
                    self?.systemPause(causedByInterruption: true)
                }
            case .ended:
                // The system tells us when it is safe to pick the microphone
                // back up. Without this a call or a Siri invocation ends the
                // meeting's capture for good — the user puts the phone down
                // believing it is still recording.
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
        })
        // Route/config change (e.g. AirPods connect): the engine stops itself
        // and the tap's format may no longer match the hardware.
        observerTokens.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main,
            using: pauseOnNotification
        ))
        // The audio daemon crashed and took the engine, the file's encoder,
        // and the session with it. Nothing can be resumed in place; say so
        // instead of counting up over silence.
        observerTokens.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleMediaServicesReset()
            }
        })
    }

    /// Pauses because the system took the microphone away, not because the
    /// user asked. Only an interruption arms the auto-resume: a route change
    /// gets no matching "ended" callback, so treating it as resumable would
    /// let an unrelated later interruption restart a recording nobody asked to
    /// restart.
    private func systemPause(causedByInterruption: Bool) {
        guard state == .recording else { return }
        pause()
        pausedByInterruption = causedByInterruption
        onAutoPause?()
    }

    /// The interruption that paused us is over. Picks capture back up, but
    /// only when that interruption is what stopped us — resuming a recording
    /// the *user* paused would turn a phone call or a Siri question into a
    /// microphone they never switched back on.
    ///
    /// Ownership retires here whether or not the system permits the resume.
    /// Leaving it armed through a `.ended` that denied the resume would hand
    /// it to the *next* interruption: `systemPause` only arms while
    /// `.recording`, so nothing would reset it while we sat paused, and an
    /// unrelated later interruption ending with `.shouldResume` would restart
    /// the microphone on the strength of a claim that expired long ago.
    ///
    /// A resume failure is not fatal: everything recorded so far stays on disk
    /// and the user can resume by hand from the paused state.
    private func endInterruption(resuming: Bool) {
        let wasOurs = pausedByInterruption
        pausedByInterruption = false
        guard resuming, wasOurs, state == .paused else { return }
        do {
            try resume()
            onAutoResume?()
        } catch {
            Self.logger.error("Auto-resume after interruption failed: \(error.localizedDescription)")
        }
    }

    /// Media services reset: stop pretending to record. The elapsed time is
    /// banked and the file is closed so what was captured stays playable, and
    /// the state goes to `.captureLost` rather than `.paused` — there is
    /// nothing left to resume into, so offering Resume would only ever produce
    /// an error in place of the explanation the user needs.
    private func handleMediaServicesReset() {
        guard state == .recording || state == .paused else { return }
        if let startedAt = segmentStartedAt {
            accumulatedTime += Date().timeIntervalSince(startedAt)
        }
        segmentStartedAt = nil
        pausedByInterruption = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        tapHandler.handler = nil
        file = nil // Closes and flushes what was captured.
        level = 0
        state = .captureLost
        onCaptureLost?("Recording stopped — the system's audio service restarted. Everything captured up to this point can still be saved.")
    }

    deinit {
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    /// Activates the audio session so the input node reports the real hardware
    /// format. Call before starting.
    func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP])
        try session.setActive(true)
    }

    /// Streams every buffer (already in `recordingFormat`) to `handler` on the
    /// audio tap thread. Safe to set or clear mid-recording.
    func setBufferHandler(_ handler: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        tapHandler.handler = handler
    }

    /// Starts recording to `url` at the given encoder quality.
    func start(writingTo url: URL, quality: AVAudioQuality = .high) throws {
        guard state == .idle else { return }

        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecorderError.noAudioInput
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderAudioQualityKey: quality.rawValue,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings)

        didReportWriteError = false
        try installTap()
        engine.prepare()
        try engine.start()
        segmentStartedAt = Date()
        state = .recording
    }

    /// Releases everything a partially failed start may have claimed — the
    /// tap, the file, and the audio session, which would otherwise keep
    /// interrupting other apps' audio. stop() can't do this: it returns early
    /// while the state is still `.idle`.
    func cleanupAfterFailedStart() {
        guard state == .idle else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        tapHandler.handler = nil
        file = nil
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            Self.logger.error("Deactivating audio session after failed start failed: \(error.localizedDescription)")
        }
    }

    /// Installs the tap against the CURRENT hardware format, converting to the
    /// file's processing format when they differ (e.g. after a route change).
    private func installTap() throws {
        guard let file else { throw RecorderError.noAudioInput }
        let hardwareFormat = engine.inputNode.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw RecorderError.noAudioInput
        }

        // nil converter means "formats already match" — a FAILED converter
        // construction must not be conflated with that, or the tap would write
        // mismatched-format buffers into the file.
        let converter: AudioBufferConverter?
        if hardwareFormat == file.processingFormat {
            converter = nil
        } else if let created = AudioBufferConverter(from: hardwareFormat, to: file.processingFormat) {
            converter = created
        } else {
            throw RecorderError.formatConversionFailed
        }

        let handlerBox = tapHandler
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { [weak self] buffer, _ in
            // Audio tap thread: normalize format, write to disk, feed the
            // transcriber, meter.
            let normalized: AVAudioPCMBuffer
            if let converter {
                guard let converted = converter.convert(buffer) else { return }
                normalized = converted
            } else {
                normalized = buffer
            }
            do {
                try file.write(from: normalized)
            } catch {
                Self.logger.error("Audio write failed: \(error.localizedDescription)")
                Task { @MainActor [weak self] in
                    self?.reportWriteFailure(error)
                }
            }
            handlerBox.handler?(normalized)
            let rms = Self.rmsLevel(of: normalized)
            Task { @MainActor [weak self] in
                self?.level = rms
            }
        }
    }

    func pause() {
        guard state == .recording else { return }
        // A deliberate pause is not an interruption. `systemPause` re-arms this
        // immediately afterwards for the one case that is.
        pausedByInterruption = false
        engine.pause()
        if let startedAt = segmentStartedAt {
            accumulatedTime += Date().timeIntervalSince(startedAt)
        }
        segmentStartedAt = nil
        level = 0
        state = .paused
    }

    /// Pauses and surfaces the first disk-write failure of a recording, so a
    /// full disk shows up as a visible, saveable state instead of a silently
    /// truncated file.
    private func reportWriteFailure(_ error: Error) {
        guard !didReportWriteError, state == .recording else { return }
        didReportWriteError = true
        pause()
        onWriteError?(error)
    }

    func resume() throws {
        guard state == .paused else { return }
        pausedByInterruption = false
        // An interruption deactivates the session; reactivate before
        // restarting the engine or start() throws.
        try AVAudioSession.sharedInstance().setActive(true)
        // Give writes another chance after resume (the user may have freed space).
        didReportWriteError = false
        // The hardware format may have changed while paused (route change) —
        // reinstall the tap so it matches, avoiding a format-mismatch crash.
        engine.inputNode.removeTap(onBus: 0)
        do {
            try installTap()
            try engine.start()
        } catch {
            // Resume failed after the session was reactivated above — release
            // it so other apps' audio isn't left interrupted while we stay
            // paused; the next resume attempt reactivates it.
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                Self.logger.error("Deactivating session after failed resume failed: \(error.localizedDescription)")
            }
            throw error
        }
        segmentStartedAt = Date()
        state = .recording
    }

    /// Stops recording, closes the file, and returns the recorded duration.
    @discardableResult
    func stop() -> TimeInterval {
        guard state != .idle else { return accumulatedTime }
        if let startedAt = segmentStartedAt {
            accumulatedTime += Date().timeIntervalSince(startedAt)
        }
        segmentStartedAt = nil
        pausedByInterruption = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        tapHandler.handler = nil
        file = nil // Closes and flushes the file.
        level = 0
        state = .idle

        let duration = accumulatedTime
        accumulatedTime = 0

        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            Self.logger.error("Deactivating audio session failed: \(error.localizedDescription)")
        }
        return duration
    }

    private nonisolated static func rmsLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for frame in 0..<Int(buffer.frameLength) {
            let sample = data[frame]
            sum += sample * sample
        }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        // Rough perceptual scaling so quiet speech still moves the meter.
        return min(1, rms * 12)
    }
}
