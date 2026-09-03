import Accelerate
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
/// A lock guards the state: the main actor writes it while the realtime tap
/// thread reads it, and an unsynchronized ARC handoff would be a data race.
///
/// Buffers offered before a handler attaches are kept — bounded — and replayed
/// into the handler the moment it arrives. Without that, everything said in
/// the seconds (on a first run, minutes) between `recorder.start()` and the
/// engine attaching was written to the file but never transcribed, so every
/// transcript silently began mid-sentence.
final class BufferHandlerBox: Sendable {
    typealias Handler = @Sendable (AVAudioPCMBuffer) -> Void

    /// Longest stretch of audio held for a handler that hasn't attached yet.
    /// This is a lead-in for the transcriber, not a recording buffer — the
    /// file already has every one of these samples.
    static let backlogLimit: TimeInterval = 30

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

    /// A copy of one captured buffer. `@unchecked Sendable` because
    /// AVAudioPCMBuffer isn't Sendable: these are private copies the tap's
    /// buffer never aliases, handed on only under the lock below.
    private final class PendingBuffer: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        let seconds: TimeInterval

        init(_ buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
            seconds = buffer.format.sampleRate > 0
                ? Double(buffer.frameLength) / buffer.format.sampleRate
                : 0
        }
    }

    private struct State {
        var entry: HandlerEntry?
        /// Captured audio waiting for a handler, oldest first.
        var backlog: [PendingBuffer] = []
        var backlogSeconds: TimeInterval = 0
        /// Cleared by the first `install` call, whatever it installs: after
        /// the session has decided (engine attached, or engine unavailable),
        /// a buffer with no handler is dropped instead of held for one that
        /// is never coming.
        var isCollecting = true
        /// True while the backlog is being replayed. Live buffers queue behind
        /// it so nothing overtakes the lead-in mid-replay.
        var isDraining = false
    }

    private let storage = OSAllocatedUnfairLock<State>(initialState: State())

    /// Seconds of captured audio waiting for a handler. The session reads this
    /// BEFORE installing, to move the transcription engine's clock origin back
    /// to the start of the lead-in it is about to be handed: the engine stamps
    /// its first buffer as time zero plus the offset it was given, so an offset
    /// of "now" would place every replayed segment a whole lead-in too late.
    var backlogSeconds: TimeInterval {
        storage.withLock { $0.backlogSeconds }
    }

    /// Called by the audio tap for every buffer: straight to the handler when
    /// one is attached, into the backlog while none is.
    func offer(_ buffer: AVAudioPCMBuffer) {
        let handler = storage.withLock { state -> Handler? in
            if let entry = state.entry, !state.isDraining {
                return entry.value
            }
            guard state.isCollecting || state.isDraining,
                  let pending = Self.copy(buffer)
            else { return nil }
            Self.enqueue(pending, in: &state)
            return nil
        }
        handler?(buffer)
    }

    /// Attaches (or clears) the handler. A handler arriving late gets the
    /// backlog replayed into it first, in order, before any live buffer.
    func install(_ handler: Handler?) {
        let replacement = handler.map(HandlerEntry.init)
        // Hand the old handler back out and let it die at the end of this
        // scope, i.e. after unlocking. Besides shortening the critical
        // section, this avoids running arbitrary capture cleanup while the
        // non-recursive lock is held.
        let previous = storage.withLock { state -> HandlerEntry? in
            let old = state.entry
            state.entry = replacement
            state.isCollecting = false
            if replacement == nil {
                state.backlog = []
                state.backlogSeconds = 0
                state.isDraining = false
            } else {
                state.isDraining = !state.backlog.isEmpty
            }
            return old
        }
        _ = previous
        if let value = replacement?.value {
            drain(into: value)
        }
    }

    /// Re-arms the box for a new recording: no handler, no backlog, collecting
    /// again. `install` latches collecting off for the rest of a recording, so
    /// without this a recorder reused across a stop/start cycle would silently
    /// drop the next recording's lead-in. Called from
    /// `AudioRecorder.start(writingTo:quality:)` so the contract lives here
    /// rather than in the caller.
    func reset() {
        // Hand the whole old state back out so the handler and every buffered
        // copy are released after unlocking, not inside the critical section.
        let previous = storage.withLock { state -> State in
            let old = state
            state = State()
            return old
        }
        _ = previous
    }

    /// Replays the backlog one buffer at a time. Popping and the "queue is
    /// empty" verdict happen under the same lock as `offer`'s append, so a
    /// buffer arriving mid-replay is either picked up by this loop or
    /// delivered live afterwards — never both, never out of order.
    private func drain(into handler: Handler) {
        while true {
            let next = storage.withLock { state -> PendingBuffer? in
                guard !state.backlog.isEmpty else {
                    state.isDraining = false
                    state.backlogSeconds = 0
                    return nil
                }
                let first = state.backlog.removeFirst()
                state.backlogSeconds -= first.seconds
                return first
            }
            guard let next else { return }
            handler(next.buffer)
        }
    }

    private static func enqueue(_ pending: PendingBuffer, in state: inout State) {
        state.backlog.append(pending)
        state.backlogSeconds += pending.seconds
        while state.backlogSeconds > backlogLimit, let oldest = state.backlog.first {
            state.backlog.removeFirst()
            state.backlogSeconds -= oldest.seconds
        }
    }

    /// The tap's buffer is the engine's to reuse once the callback returns, so
    /// anything held past it has to be a copy.
    private static func copy(_ buffer: AVAudioPCMBuffer) -> PendingBuffer? {
        guard buffer.frameLength > 0,
              !buffer.format.isInterleaved,
              let source = buffer.floatChannelData,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
              let destination = copy.floatChannelData
        else { return nil }
        copy.frameLength = buffer.frameLength
        let frames = Int(buffer.frameLength)
        for channel in 0..<Int(buffer.format.channelCount) {
            destination[channel].update(from: source[channel], count: frames)
        }
        return PendingBuffer(copy)
    }
}

/// Frames written to the recording file, counted on the realtime audio tap
/// thread and read on the main actor. A class (not a stored property) so the
/// tap closure and the recorder share one counter, and a lock so the
/// cross-thread read is defined rather than a data race.
final class RecordedFrameCounter: Sendable {
    private let storage = OSAllocatedUnfairLock<AVAudioFramePosition>(initialState: 0)

    var value: AVAudioFramePosition {
        storage.withLock { $0 }
    }

    func add(_ frames: AVAudioFrameCount) {
        storage.withLock { $0 += AVAudioFramePosition(frames) }
    }

    func reset() {
        storage.withLock { $0 = 0 }
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
    private let frameCounter = RecordedFrameCounter()
    /// Sample rate of the file's processing format, kept in its own property
    /// so `stop()` can still convert the frame count after the file is closed.
    private var fileSampleRate: Double = 0
    /// True only while paused *by* an audio-session interruption, so the
    /// matching "interruption ended" can resume what it interrupted and
    /// nothing else. Cleared by every other route out of `.recording`.
    private var pausedByInterruption = false
    @ObservationIgnored nonisolated(unsafe) private var observerTokens: [any NSObjectProtocol] = []

    /// Total recorded time, excluding paused stretches — derived from the
    /// frames actually written to the file rather than a `Date()` delta.
    /// `Date()` is not monotonic: a carrier or NTP correction mid-meeting used
    /// to stretch (or shrink) the saved duration, the transcript's timestamp
    /// offset, and the Live Activity's paused clock by the size of the
    /// correction, while playback still used the file's real length. Frames
    /// only advance while the tap is running, so pauses bank themselves.
    ///
    /// Not observable: `frameCounter` is a `let` and `fileSampleRate` only
    /// changes at start/stop, so reading this no longer invalidates a SwiftUI
    /// view on every tick the way the old `Date()` delta did. The one reader
    /// (`RecordingView`'s elapsed label) is inside a
    /// `TimelineView(.periodic(from: .now, by: 0.5))` and redraws on its own
    /// schedule; a plain `Text(recorder.elapsed…)` elsewhere would sit frozen.
    var elapsed: TimeInterval {
        Self.seconds(frames: frameCounter.value, sampleRate: fileSampleRate)
    }

    /// Seconds of audio a frame count represents. Zero when nothing has been
    /// written yet (no file, so no sample rate), so a duration can never come
    /// back infinite or NaN.
    static func seconds(frames: AVAudioFramePosition, sampleRate: Double) -> TimeInterval {
        guard frames > 0, sampleRate > 0 else { return 0 }
        return Double(frames) / sampleRate
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

    /// Media services reset: stop pretending to record. The recorded time is
    /// already banked — the frame count stopped when the tap did — and the file
    /// is closed so what was captured stays playable, and the state goes to
    /// `.captureLost` rather than `.paused` — there is nothing left to resume
    /// into, so offering Resume would only ever produce an error in place of
    /// the explanation the user needs.
    private func handleMediaServicesReset() {
        guard state == .recording || state == .paused else { return }
        pausedByInterruption = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        tapHandler.install(nil)
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

    /// Seconds of already-captured audio the next `setBufferHandler(_:)` will
    /// replay into its handler. Read it BEFORE installing: installing drains
    /// the queue, so a read afterwards always reports zero. `RecordingSession`
    /// subtracts it from `elapsed` to place the transcription engine's clock
    /// origin at the start of that lead-in.
    var pendingBacklogSeconds: TimeInterval {
        tapHandler.backlogSeconds
    }

    /// Streams every buffer (already in `recordingFormat`) to `handler` on the
    /// audio tap thread, replaying the lead-in captured before this call.
    /// Passing nil says no handler is coming and drops that lead-in. Safe to
    /// call mid-recording.
    func setBufferHandler(_ handler: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        tapHandler.install(handler)
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
        let file = try AVAudioFile(forWriting: url, settings: settings)
        self.file = file
        // The tap counts frames in the file's processing format; keep its rate
        // so stop() can convert them after the file is closed.
        fileSampleRate = file.processingFormat.sampleRate
        frameCounter.reset()
        // The first `install` of a recording latches the box out of
        // collecting; re-arm it so a recorder reused after stop() holds this
        // recording's lead-in exactly like a fresh one would.
        tapHandler.reset()

        didReportWriteError = false
        try installTap()
        engine.prepare()
        try engine.start()
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
        tapHandler.install(nil)
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

        // The converter is a passthrough when the formats already match, and
        // init only fails on a real conversion-setup failure.
        guard let converter = AudioBufferConverter(from: hardwareFormat, to: file.processingFormat) else {
            throw RecorderError.formatConversionFailed
        }

        let handlerBox = tapHandler
        let frameCounter = self.frameCounter
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { [weak self] buffer, _ in
            // Audio tap thread: normalize format, write to disk, feed the
            // transcriber, meter.
            guard let normalized = converter.convert(buffer) else { return }
            do {
                try file.write(from: normalized)
                frameCounter.add(normalized.frameLength)
            } catch {
                Self.logger.error("Audio write failed: \(error.localizedDescription)")
                Task { @MainActor [weak self] in
                    self?.reportWriteFailure(error)
                }
            }
            handlerBox.offer(normalized)
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
        // Retire interruption ownership only once the resume succeeds. The
        // notice tells the user to tap Resume, and a tap while the call still
        // holds the microphone throws below; clearing first would also cancel
        // the automatic resume the interruption's `.ended` is about to offer,
        // and the rest of the meeting would silently go uncaptured.
        let wasInterrupted = pausedByInterruption
        pausedByInterruption = false
        // An interruption deactivates the session; reactivate before
        // restarting the engine or start() throws.
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            pausedByInterruption = wasInterrupted
            throw error
        }
        // Give writes another chance after resume (the user may have freed space).
        didReportWriteError = false
        // The hardware format may have changed while paused (route change) —
        // reinstall the tap so it matches, avoiding a format-mismatch crash.
        engine.inputNode.removeTap(onBus: 0)
        do {
            try installTap()
            try engine.start()
        } catch {
            pausedByInterruption = wasInterrupted
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
        state = .recording
    }

    /// Stops recording, closes the file, and returns the recorded duration.
    @discardableResult
    func stop() -> TimeInterval {
        guard state != .idle else { return 0 }
        pausedByInterruption = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        tapHandler.install(nil)
        file = nil // Closes and flushes the file.
        level = 0
        state = .idle

        // Read before resetting: this is the number the meeting is saved with.
        let duration = elapsed
        frameCounter.reset()
        fileSampleRate = 0

        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            Self.logger.error("Deactivating audio session failed: \(error.localizedDescription)")
        }
        return duration
    }

    private nonisolated static func rmsLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let rms = vDSP.rootMeanSquare(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
        // Rough perceptual scaling so quiet speech still moves the meter.
        return min(1, rms * 12)
    }
}
