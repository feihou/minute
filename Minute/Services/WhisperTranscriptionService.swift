import AVFoundation
import Foundation
import Observation
import OSLog
import WhisperKit

/// A Whisper model the user can download. The variant is the folder name in
/// the argmaxinc/whisperkit-coreml Hugging Face repo.
struct WhisperModel: Identifiable, Equatable {
    let variant: String
    let label: String
    let detail: String
    /// Approximate download size, shown before downloading.
    let approximateMegabytes: Int

    var id: String { variant }
}

/// Curated subset of argmaxinc/whisperkit-coreml — every entry is
/// multilingual with automatic language detection.
enum WhisperModelCatalog {
    static let models: [WhisperModel] = [
        WhisperModel(
            variant: "openai_whisper-base",
            label: "Base",
            detail: "Fastest and smallest. Fine for clear speech.",
            approximateMegabytes: 150
        ),
        WhisperModel(
            variant: "openai_whisper-small",
            label: "Small",
            detail: "Balanced speed and accuracy.",
            approximateMegabytes: 490
        ),
        WhisperModel(
            variant: "openai_whisper-large-v3-v20240930_626MB",
            label: "Large v3 (Compressed)",
            detail: "Best accuracy. Recommended for non-English meetings.",
            approximateMegabytes: 630
        ),
    ]

    /// Preselected when the user switches to Whisper without choosing:
    /// accuracy is why someone opts out of Apple Speech in the first place.
    static let defaultModel = models.last!

    static func model(for variant: String) -> WhisperModel? {
        models.first { $0.variant == variant }
    }
}

/// Downloads, locates, and deletes Whisper models on disk. Models live in
/// Application Support (excluded from backups — they're re-downloadable)
/// under the Hugging Face hub layout WhisperKit writes into.
enum WhisperModelStore {
    static let repo = "argmaxinc/whisperkit-coreml"

    static var baseDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "WhisperKitModels", directoryHint: .isDirectory)
        if !FileManager.default.fileExists(atPath: base.path) {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            var url = base
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
        return base
    }

    /// Where WhisperKit.download places a variant.
    /// ponytail: mirrors the hub layout (models/<repo>/<variant>) instead of
    /// persisting returned paths — revisit if WhisperKit changes its layout.
    static func folder(for variant: String) -> URL {
        baseDirectory.appending(path: "models/\(repo)/\(variant)", directoryHint: .isDirectory)
    }

    /// True when the pieces WhisperKit needs to load are all present.
    /// ponytail: presence checks, no checksums — a corrupted model fails at
    /// load time and the fix is delete + re-download.
    static func isDownloaded(_ variant: String) -> Bool {
        let folder = folder(for: variant)
        let required = ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc", "config.json"]
        return required.allSatisfy {
            FileManager.default.fileExists(atPath: folder.appending(path: $0).path)
        }
    }

    /// Streams the model from Hugging Face; partially downloaded files are
    /// kept so a retry resumes instead of starting over.
    static func download(
        _ variant: String,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws {
        _ = try await WhisperKit.download(
            variant: variant,
            downloadBase: baseDirectory,
            from: repo,
            progressCallback: { progress in
                let fraction = progress.fractionCompleted
                Task { @MainActor in onProgress(fraction) }
            }
        )
    }

    static func delete(_ variant: String) {
        try? FileManager.default.removeItem(at: folder(for: variant))
    }
}

/// Transcription on a user-downloaded Whisper model (WhisperKit): live
/// streaming during recording plus the import and re-transcribe file paths.
/// The spoken language is auto-detected, so a meeting in Chinese transcribes
/// correctly on an English-language iPhone.
@MainActor
@Observable
final class WhisperTranscriptionService: TranscriptionEngine {
    private static let logger = Logger(subsystem: "com.minuteapp.Minute", category: "WhisperTranscription")

    private(set) var availability: TranscriptionAvailability = .unknown
    /// In-progress (not yet finalized) text for the live transcript view.
    private(set) var volatileText: String = ""
    /// Finalized transcript segments in audio order.
    private(set) var segments: [TranscriptSegment] = []
    /// See TranscriptionEngine — set before buffers flow.
    var timestampOffset: TimeInterval = 0

    private let variant = AppSettings.whisperModel
    private var whisperKit: WhisperKit?
    private var liveFeed: WhisperLiveFeed?
    private var liveTask: Task<Void, Never>?

    /// Checks the model is downloaded — deliberately WITHOUT loading it.
    /// Loading takes seconds (Core ML compiles on first use), and the live
    /// path must attach its buffer tap immediately so a meeting's opening
    /// words aren't lost while the model loads; the decode loop and the file
    /// path load lazily via loadedWhisperKit() instead. Never downloads —
    /// the user downloads models explicitly in Settings, so a big Hugging
    /// Face fetch can't start as a surprise side effect.
    func prepare() async {
        guard WhisperModelStore.isDownloaded(variant) else {
            availability = .unavailable(
                "The Whisper model isn't downloaded yet. Get it in Settings → Transcription Model, or switch back to Apple Speech."
            )
            return
        }
        availability = .available
    }

    /// Loads the model on first use and caches it; flips availability and
    /// returns nil when loading fails. Each engine instance has a single
    /// consumer (one live loop, or one file job), so plain check-then-load
    /// caching is race-free here.
    private func loadedWhisperKit() async -> WhisperKit? {
        if let whisperKit { return whisperKit }
        do {
            let config = WhisperKitConfig(
                modelFolder: WhisperModelStore.folder(for: variant).path,
                verbose: false,
                logLevel: .error,
                load: true,
                download: false
            )
            let loaded = try await WhisperKit(config)
            whisperKit = loaded
            return loaded
        } catch {
            Self.logger.error("WhisperKit load failed: \(error.localizedDescription)")
            availability = .unavailable(
                "The Whisper model couldn't be loaded. Re-download it in Settings → Transcription Model, or switch back to Apple Speech."
            )
            return nil
        }
    }

    // MARK: - Live session

    /// Starts a live streaming session: buffers from the recorder feed a
    /// lock-guarded sample store, and a decode loop turns the growing tail
    /// into confirmed segments plus a volatile hypothesis.
    func start(inputFormat: AVAudioFormat) async -> (@Sendable (AVAudioPCMBuffer) -> Void)? {
        guard availability == .available else { return nil }

        segments = []
        volatileText = ""

        guard let whisperFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(WhisperKit.sampleRate),
            channels: 1,
            interleaved: false
        ), let converter = AudioBufferConverter(from: inputFormat, to: whisperFormat) else {
            availability = .unavailable("Transcription can't process this microphone's audio format. Recording still works.")
            return nil
        }

        let feed = WhisperLiveFeed()
        liveFeed = feed
        // weak: the task must not keep a dropped service (and its loaded
        // model) alive — matching TranscriptionService's resultsTask.
        liveTask = Task { [weak self] in
            await self?.runLiveLoop(feed: feed)
        }

        return { @Sendable buffer in
            guard let converted = converter.convert(buffer),
                  let channel = converted.floatChannelData else { return }
            feed.append(Array(UnsafeBufferPointer(start: channel[0], count: Int(converted.frameLength))))
        }
    }

    /// Flushes remaining audio (one final decode pass) and returns the
    /// complete segment list.
    func finish() async -> [TranscriptSegment] {
        liveFeed?.stop()
        await liveTask?.value
        liveTask = nil
        liveFeed = nil
        // The final pass normally clears this; only its failure path leaves
        // a hypothesis behind, kept rather than lost.
        promoteVolatileText()
        return segments
    }

    /// Abandons the session without waiting for results (user discarded).
    /// Deliberately does NOT await the loop: an in-flight decode can't be
    /// preempted mid-window (WhisperKit only checks cancellation between
    /// stages), and Discard must not freeze the screen for those seconds.
    /// The orphaned pass observes the cancellation and exits without
    /// touching state.
    func cancel() async {
        liveFeed?.stop()
        liveTask?.cancel()
        liveTask = nil
        liveFeed = nil
        volatileText = ""
        segments = []
    }

    /// The streaming decode loop. Runs as a MainActor task, but the heavy
    /// whisperKit.transcribe calls are async and execute off the main thread;
    /// only cheap bookkeeping between awaits touches main. Mirrors WhisperKit's
    /// AudioStreamTranscriber algorithm (decode the unconfirmed tail, confirm
    /// all but the trailing segments) without its microphone ownership.
    private func runLiveLoop(feed: WhisperLiveFeed) async {
        // The model loads HERE, not in prepare(), so the feed is already
        // capturing while Core ML compiles — the backlog decodes on the
        // first pass and the meeting's opening words aren't lost.
        guard let whisperKit = await loadedWhisperKit() else {
            // Retire the feed: its only consumer is gone, and the recorder's
            // handler would otherwise keep piling audio into it for the rest
            // of the recording (~230 MB/hour) for nothing.
            feed.stop()
            return
        }
        // Cancellation bails; a merely-stopped feed does NOT — a recording
        // finished while the model was still loading must fall through to
        // the final pass below, or everything the feed buffered is discarded
        // and a short meeting saves without a transcript.
        guard !Task.isCancelled else { return }

        // Absolute sample count (purged + kept) already decoded.
        var decodedSampleCount = 0
        // Recording-clock end of the last appended segment. The monotonic
        // guard below (mirrored from WhisperKit's AudioStreamTranscriber)
        // refuses non-advancing "confirmations" — a hallucinated near-zero
        // timestamp would otherwise re-confirm the same audio every pass,
        // duplicating transcript text.
        var lastConfirmedEnd: TimeInterval = -1
        // Pinned after the first pass so live text stops flickering between
        // per-window detection hypotheses; nil means "detect on this pass".
        var pinnedLanguage: String?

        while !feed.isStopped, !Task.isCancelled {
            let snapshot = feed.snapshot()
            let totalSamples = snapshot.droppedSamples + snapshot.samples.count
            // Bound the retained tail: through a long silence the voice gate
            // below skips every decode, so nothing confirms and nothing
            // purges — an hour of quiet would otherwise hold ~230 MB. Audio
            // older than the cap has sat unconfirmable for minutes; drop it.
            if snapshot.samples.count > Self.maximumTailSamples {
                feed.purge(throughAbsoluteSample: totalSamples - Self.maximumTailSamples)
                continue
            }
            let newSeconds = Float(totalSamples - decodedSampleCount) / Float(WhisperKit.sampleRate)
            // Decode only once at least a second of new audio arrived, and
            // only when it contains voice — otherwise idle cheaply.
            if newSeconds < 1 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                continue
            }
            if !AudioProcessor.isVoiceDetected(
                in: snapshot.relativeEnergies,
                nextBufferInSeconds: newSeconds,
                silenceThreshold: 0.3
            ) {
                try? await Task.sleep(nanoseconds: 200_000_000)
                continue
            }

            decodedSampleCount = totalSamples
            let timeBase = TimeInterval(snapshot.droppedSamples) / TimeInterval(WhisperKit.sampleRate) + timestampOffset
            do {
                let results = try await whisperKit.transcribe(
                    audioArray: snapshot.samples,
                    decodeOptions: liveOptions(language: pinnedLanguage)
                )
                // A pass that raced finish() still applies its confirmations
                // below, so the final pass only re-decodes the shrunken tail
                // instead of repeating this whole pass's work.
                guard !Task.isCancelled else { break }
                // Pin only once detection has heard enough audio — the very
                // first 1-second pass is too short to trust, and a wrong pin
                // would mistranscribe the rest of the meeting. Measured
                // cumulatively (totalSamples): the retained tail shrinks with
                // every purge and might never span the threshold itself.
                if pinnedLanguage == nil,
                   totalSamples >= Self.languagePinMinimumSamples {
                    pinnedLanguage = results.first?.language
                }
                let mapped = Self.mapSegments(results, timeBase: timeBase)
                let split = Self.splitForConfirmation(mapped, keepingLast: 2)
                if let lastConfirmed = split.confirmed.last, lastConfirmed.end > lastConfirmedEnd {
                    lastConfirmedEnd = lastConfirmed.end
                    segments.append(contentsOf: split.confirmed)
                    // Purge audio the loop will never decode again, keeping
                    // memory and per-pass copy cost bounded to the tail; the
                    // cap above bounds the voiceless stretches the gate skips.
                    let cutoff = Int((lastConfirmed.end - timestampOffset) * TimeInterval(WhisperKit.sampleRate))
                    feed.purge(throughAbsoluteSample: cutoff)
                    volatileText = split.unconfirmed.map(\.text).joined(separator: " ")
                } else {
                    // Nothing safely confirmable — keep the whole hypothesis
                    // visible and try again on the next pass.
                    volatileText = mapped.map(\.text).joined(separator: " ")
                }
            } catch is CancellationError {
                break
            } catch {
                Self.logger.error("Live whisper pass failed: \(error.localizedDescription)")
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }

        // One final pass over the remaining tail so the last words aren't
        // lost to the one-second/voice gates. Cancellation (discard) skips it.
        guard !Task.isCancelled else { return }
        let snapshot = feed.snapshot()
        guard !snapshot.samples.isEmpty else { return }
        let timeBase = TimeInterval(snapshot.droppedSamples) / TimeInterval(WhisperKit.sampleRate) + timestampOffset
        do {
            let results = try await whisperKit.transcribe(
                audioArray: snapshot.samples,
                decodeOptions: liveOptions(language: pinnedLanguage)
            )
            segments.append(contentsOf: Self.mapSegments(results, timeBase: timeBase))
            volatileText = ""
        } catch {
            // Keep the best hypothesis rather than losing the tail.
            Self.logger.error("Final whisper pass failed: \(error.localizedDescription)")
            promoteVolatileText()
        }
    }

    /// Language detection needs at least this much audio before its result
    /// is trusted enough to pin for the rest of the meeting.
    private static let languagePinMinimumSamples = 5 * WhisperKit.sampleRate
    /// The most unconfirmed audio the live feed retains (5 minutes ≈ 19 MB).
    private static let maximumTailSamples = 5 * 60 * WhisperKit.sampleRate

    /// detectLanguage must be explicit: it defaults to !usePrefillPrompt,
    /// i.e. false, and then a nil language silently decodes as English.
    private func liveOptions(language: String?) -> DecodingOptions {
        DecodingOptions(
            task: .transcribe,
            language: language,
            detectLanguage: language == nil,
            skipSpecialTokens: true
        )
    }

    private func promoteVolatileText() {
        guard !volatileText.isEmpty else { return }
        let lastEnd = segments.last?.end ?? timestampOffset
        segments.append(TranscriptSegment(text: volatileText, start: lastEnd, end: lastEnd))
        volatileText = ""
    }

    // MARK: - File transcription

    func transcribe(file: AVAudioFile) async throws -> [TranscriptSegment] {
        guard availability == .available, let whisperKit = await loadedWhisperKit() else {
            throw CocoaError(.featureUnsupported)
        }

        // detectLanguage must be explicit: it defaults to !usePrefillPrompt,
        // i.e. false, and then a nil language silently decodes as English.
        // VAD chunking keeps hour-long meetings from decoding one 30-second
        // window at a time.
        let options = DecodingOptions(
            task: .transcribe,
            language: nil,
            detectLanguage: true,
            skipSpecialTokens: true,
            chunkingStrategy: .vad
        )
        let results = try await whisperKit.transcribe(
            audioPath: file.url.path,
            decodeOptions: options,
            // Returning false stops decoding early; checkCancellation below
            // turns that early stop into a thrown CancellationError so a
            // partial transcript is never mistaken for a complete one.
            callback: { _ in Task.isCancelled ? false : nil }
        )
        try Task.checkCancellation()

        return Self.mapSegments(results, timeBase: 0)
    }

    // MARK: - Segment mapping

    /// Maps WhisperKit segments to TranscriptSegments with absolute
    /// timestamps; timeBase covers purged audio and the recording offset.
    private static func mapSegments(_ results: [TranscriptionResult], timeBase: TimeInterval) -> [TranscriptSegment] {
        results
            .flatMap(\.segments)
            .compactMap { segment in
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return TranscriptSegment(
                    text: text,
                    start: timeBase + TimeInterval(segment.start),
                    end: timeBase + TimeInterval(segment.end)
                )
            }
            .sorted { $0.start < $1.start }
    }

    /// Splits a live pass's segments into ones stable enough to show as final
    /// and the trailing ones whisper may still revise on the next pass.
    static func splitForConfirmation(
        _ segments: [TranscriptSegment],
        keepingLast keep: Int
    ) -> (confirmed: [TranscriptSegment], unconfirmed: [TranscriptSegment]) {
        guard segments.count > keep else { return ([], segments) }
        return (Array(segments.prefix(segments.count - keep)), Array(segments.suffix(keep)))
    }
}

/// Lock-guarded 16 kHz mono sample store bridging the audio tap thread
/// (writes) and the decode loop (reads). Confirmed audio is purged, so the
/// buffer only ever holds the unconfirmed tail of the recording.
final class WhisperLiveFeed: @unchecked Sendable {
    struct Snapshot {
        let samples: [Float]
        /// Samples already purged — the absolute position of samples[0].
        let droppedSamples: Int
        let relativeEnergies: [Float]
    }

    /// The silence baseline looks back this many chunks (~2 s of audio).
    private static let averageEnergyWindow = 20
    /// The VAD gate only ever inspects the recent window; older entries are
    /// dead weight.
    private static let relativeEnergyCap = 200

    private let lock = NSLock()
    private var samples: ContiguousArray<Float> = []
    private var droppedSamples = 0
    private var relativeEnergies: [Float] = []
    private var averageEnergies: [Float] = []
    private var stopped = false

    func append(_ chunk: [Float]) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        // A stopped feed DROPS audio: after the decode loop retires (model
        // failed to load, session finished), the recorder's handler may still
        // call in — retaining those samples would grow memory with nobody
        // ever consuming them.
        guard !stopped else { return }
        // ponytail: the VAD gate assumes one energy entry ≈ 100 ms; tap
        // chunks are ~85 ms after resampling, close enough that the gate's
        // lookback window is only approximately calibrated.
        let baseline = averageEnergies.isEmpty
            ? nil
            : averageEnergies.reduce(Float.infinity, Swift.min)
        relativeEnergies.append(AudioProcessor.calculateRelativeEnergy(of: chunk, relativeTo: baseline))
        averageEnergies.append(AudioProcessor.calculateAverageEnergy(of: chunk))
        if averageEnergies.count > Self.averageEnergyWindow {
            averageEnergies.removeFirst(averageEnergies.count - Self.averageEnergyWindow)
        }
        if relativeEnergies.count > Self.relativeEnergyCap {
            relativeEnergies.removeFirst(relativeEnergies.count - Self.relativeEnergyCap)
        }
        samples.append(contentsOf: chunk)
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            samples: Array(samples),
            droppedSamples: droppedSamples,
            relativeEnergies: relativeEnergies
        )
    }

    /// Drops samples up to an absolute position (clamped; never past the end).
    func purge(throughAbsoluteSample cutoff: Int) {
        lock.lock()
        defer { lock.unlock() }
        let toDrop = min(max(0, cutoff - droppedSamples), samples.count)
        guard toDrop > 0 else { return }
        samples.removeFirst(toDrop)
        droppedSamples += toDrop
    }

    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        stopped = true
    }
}
