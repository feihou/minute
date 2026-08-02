import AVFoundation
import Foundation
import Observation
import OSLog

enum RecorderError: LocalizedError {
    case noAudioInput

    var errorDescription: String? {
        switch self {
        case .noAudioInput:
            return "No microphone input is available."
        }
    }
}

/// Box the audio tap reads on every buffer, so live transcription can attach
/// after recording has already started (e.g. while the speech model downloads).
/// ponytail: @unchecked Sendable — one writer (main actor), reads on the tap
/// thread; worst case a single buffer goes to the previous handler.
final class BufferHandlerBox: @unchecked Sendable {
    var handler: (@Sendable (AVAudioPCMBuffer) -> Void)?
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
    }

    private static let logger = Logger(subsystem: "com.minuteapp.Minute", category: "AudioRecorder")

    private(set) var state: State = .idle
    /// Smoothed input level in 0...1 for the recording indicator.
    private(set) var level: Float = 0

    /// Called after the system auto-pauses recording (phone call, Siri, or an
    /// audio route/configuration change), so the owner can reflect it in UI.
    var onAutoPause: (() -> Void)?

    private let engine = AVAudioEngine()
    private let tapHandler = BufferHandlerBox()
    private var file: AVAudioFile?
    private var accumulatedTime: TimeInterval = 0
    private var segmentStartedAt: Date?
    nonisolated(unsafe) private var observerTokens: [any NSObjectProtocol] = []

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
                guard let self, self.state == .recording else { return }
                self.pause()
                self.onAutoPause?()
            }
        }
        // Phone call / Siri interruption: iOS suspends our audio session.
        observerTokens.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { notification in
            let began = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                == AVAudioSession.InterruptionType.began.rawValue
            if began { pauseOnNotification(notification) }
        })
        // Route/config change (e.g. AirPods connect): the engine stops itself
        // and the tap's format may no longer match the hardware.
        observerTokens.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main,
            using: pauseOnNotification
        ))
    }

    deinit {
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    static var permissionGranted: Bool {
        AVAudioApplication.shared.recordPermission == .granted
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

    /// Starts recording to `url`.
    func start(writingTo url: URL) throws {
        guard state == .idle else { return }

        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecorderError.noAudioInput
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings)

        try installTap()
        engine.prepare()
        try engine.start()
        segmentStartedAt = Date()
        state = .recording
    }

    /// Installs the tap against the CURRENT hardware format, converting to the
    /// file's processing format when they differ (e.g. after a route change).
    private func installTap() throws {
        guard let file else { throw RecorderError.noAudioInput }
        let hardwareFormat = engine.inputNode.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw RecorderError.noAudioInput
        }

        let converter: AudioBufferConverter? = hardwareFormat == file.processingFormat
            ? nil
            : AudioBufferConverter(from: hardwareFormat, to: file.processingFormat)

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
        engine.pause()
        if let startedAt = segmentStartedAt {
            accumulatedTime += Date().timeIntervalSince(startedAt)
        }
        segmentStartedAt = nil
        level = 0
        state = .paused
    }

    func resume() throws {
        guard state == .paused else { return }
        // An interruption deactivates the session; reactivate before
        // restarting the engine or start() throws.
        try AVAudioSession.sharedInstance().setActive(true)
        // The hardware format may have changed while paused (route change) —
        // reinstall the tap so it matches, avoiding a format-mismatch crash.
        engine.inputNode.removeTap(onBus: 0)
        try installTap()
        try engine.start()
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
