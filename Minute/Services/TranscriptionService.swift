import AVFoundation
import CoreMedia
import Foundation
import Observation
import OSLog
import Speech

/// Live, fully on-device transcription built on SpeechAnalyzer/SpeechTranscriber
/// (iOS 26). Audio buffers come in from the recorder's tap; volatile text and
/// finalized, timestamped segments come out for the UI.
@MainActor
@Observable
final class TranscriptionService: TranscriptionEngine {
    private static let logger = Logger(subsystem: "com.minuteapp.Minute", category: "Transcription")

    private(set) var availability: TranscriptionAvailability = .unknown
    /// In-progress (not yet finalized) text for the live transcript view.
    private(set) var volatileText: String = ""
    /// Finalized transcript segments in audio order.
    private(set) var segments: [TranscriptSegment] = []
    /// Non-nil while the speech model is downloading.
    private(set) var downloadProgress: Progress?

    /// Seconds of audio already written to the file before the first buffer
    /// reaches the analyzer (transcription can attach late, e.g. after a model
    /// download). Added to every segment timestamp so transcript taps and
    /// exports seek the right spot in the recording. Set before buffers flow.
    var timestampOffset: TimeInterval = 0

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    #if DEBUG
    /// Screenshot staging: simulators can't run SpeechTranscriber, so the
    /// live-transcript panel can never show its real content there. Staging
    /// fills it with the state a supported iPhone shows; `prepare()` then
    /// backs off so the availability probe doesn't overwrite it.
    private var demoStaged = false

    func stageDemo(segments: [TranscriptSegment], volatileText: String) {
        demoStaged = true
        availability = .available
        self.segments = segments
        self.volatileText = volatileText
    }
    #endif

    /// Checks device/locale support and downloads the speech model if needed.
    func prepare() async {
        #if DEBUG
        if demoStaged { return }
        #endif
        guard SpeechTranscriber.isAvailable else {
            availability = .unavailable("On-device transcription isn't supported on this device. Recording still works.")
            return
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
            availability = .unavailable("Your language isn't supported for on-device transcription yet. Recording still works.")
            return
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        self.transcriber = transcriber

        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                availability = .downloadingModel
                downloadProgress = request.progress
                try await request.downloadAndInstall()
                downloadProgress = nil
            }
            availability = .available
        } catch {
            downloadProgress = nil
            availability = .unavailable("The transcription model couldn't be downloaded. Recording still works.")
            Self.logger.error("Speech asset install failed: \(error.localizedDescription)")
        }
    }

    /// Starts a live session and returns the closure the recorder calls with
    /// each audio buffer, or nil when transcription can't run (never throws —
    /// the recording must not depend on it).
    func start(inputFormat: AVAudioFormat) async -> (@Sendable (AVAudioPCMBuffer) -> Void)? {
        guard availability == .available, let transcriber else { return nil }

        segments = []
        volatileText = ""

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
              let converter = AudioBufferConverter(from: inputFormat, to: analyzerFormat)
        else {
            availability = .unavailable("Transcription can't process this microphone's audio format. Recording still works.")
            return nil
        }

        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        inputContinuation = continuation

        resultsTask = Task { @MainActor [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { break }
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if result.isFinal {
                        if !text.isEmpty {
                            self.segments.append(TranscriptSegment(
                                text: text,
                                start: self.timestampOffset + result.range.start.seconds,
                                end: self.timestampOffset + result.range.end.seconds
                            ))
                        }
                        self.volatileText = ""
                    } else {
                        self.volatileText = text
                    }
                }
            } catch {
                // Losing live results is non-fatal for the recording — but
                // silence here left the panel showing stale segments (or
                // "Listening…") for the rest of the meeting and the saved
                // transcript simply stopped mid-sentence. Say it where the
                // user is looking. Everything finalized so far stays in
                // `segments` and is still saved.
                Self.logger.error("Transcriber results stream failed: \(error.localizedDescription)")
                self?.volatileText = ""
                self?.availability = .unavailable(Self.liveStoppedMessage(error))
            }
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            // Clean up everything created above, or finish() would wait on a
            // results stream that never ends.
            Self.logger.error("SpeechAnalyzer failed to start: \(error.localizedDescription)")
            continuation.finish()
            inputContinuation = nil
            resultsTask?.cancel()
            resultsTask = nil
            availability = .unavailable("Live transcription couldn't start. Recording still works.")
            return nil
        }
        self.analyzer = analyzer

        return { @Sendable buffer in
            guard let converted = converter.convert(buffer) else { return }
            continuation.yield(AnalyzerInput(buffer: converted))
        }
    }

    /// Transcribes a whole audio file (the import and re-transcribe path).
    /// Unlike the live path, ANY failure throws — including a failure of the
    /// results stream after partial output. Callers replacing an existing
    /// transcript must never mistake a partial result for a complete one.
    func transcribe(file: AVAudioFile) async throws -> [TranscriptSegment] {
        guard availability == .available, let transcriber else {
            if case .unavailable(let message) = availability {
                throw TranscriptionUnavailableError(message: message)
            }
            throw TranscriptionUnavailableError(
                message: "On-device speech recognition isn't ready yet. Try again in a moment."
            )
        }

        // Collected locally (not via the live path's shared state) so a
        // stream error propagates instead of being logged away.
        let collector = Task { @MainActor () throws -> [TranscriptSegment] in
            var collected: [TranscriptSegment] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                if result.isFinal, !text.isEmpty {
                    collected.append(TranscriptSegment(
                        text: text,
                        start: result.range.start.seconds,
                        end: result.range.end.seconds
                    ))
                }
            }
            return collected
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        do {
            if let lastSample = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            // The caller replaces the meeting's entire transcript with what
            // comes back, so a re-transcription the user stopped must be
            // thrown away rather than applied. `collector` is an unstructured
            // Task and does not inherit this cancellation, which is why the
            // check has to be explicit.
            try Task.checkCancellation()
        } catch {
            await analyzer.cancelAndFinishNow()
            collector.cancel()
            throw error
        }
        return try await collector.value
    }

    /// Flushes remaining audio, waits for final results, and returns them.
    func finish() async -> [TranscriptSegment] {
        inputContinuation?.finish()
        inputContinuation = nil

        if let analyzer {
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                Self.logger.error("Finalizing transcription failed: \(error.localizedDescription)")
            }
        } else {
            // Analysis never started; don't wait on a stream that won't end.
            resultsTask?.cancel()
        }
        await resultsTask?.value
        resultsTask = nil
        analyzer = nil

        // Anything still volatile after finalization is kept rather than lost.
        if !volatileText.isEmpty {
            let lastEnd = segments.last?.end ?? timestampOffset
            segments.append(TranscriptSegment(text: volatileText, start: lastEnd, end: lastEnd))
            volatileText = ""
        }
        return segments
    }

    /// What the recording screen shows once the live results stream has died.
    /// The recording itself is unaffected, so the message has to say that as
    /// well as what stopped — otherwise a user watching the panel assumes the
    /// meeting is being lost and stops it.
    static func liveStoppedMessage(_ error: any Error) -> String {
        "Live transcription stopped: \(error.localizedDescription). Recording continues; you can re-transcribe the audio after saving."
    }

    /// Abandons the session without waiting for final results (user discarded).
    func cancel() async {
        inputContinuation?.finish()
        inputContinuation = nil
        await analyzer?.cancelAndFinishNow()
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
        volatileText = ""
        segments = []
    }
}
