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
    private let storage = OSAllocatedUnfairLock<(@Sendable (AVAudioPCMBuffer) -> Void)?>(initialState: nil)

    var handler: (@Sendable (AVAudioPCMBuffer) -> Void)? {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
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
    }

    private static let logger = Logger(subsystem: "com.minuteapp.Minute", category: "AudioRecorder")

    private(set) var state: State = .idle
    /// Smoothed input level in 0...1 for the recording indicator.
    private(set) var level: Float = 0

    /// Called after the system auto-pauses recording (phone call, Siri, or an
    /// audio route/configuration change), so the owner can reflect it in UI.
    var onAutoPause: (() -> Void)?

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
        // An interruption deactivates the session; reactivate before
        // restarting the engine or start() throws.
        try AVAudioSession.sharedInstance().setActive(true)
        // Give writes another chance after resume (the user may have freed space).
        didReportWriteError = false
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
