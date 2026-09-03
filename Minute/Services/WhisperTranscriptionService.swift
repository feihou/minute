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

    /// Where the tokenizers live: a sibling of the model folders inside the
    /// store, so baseDirectory's backup exclusion covers them and delete can
    /// reclaim them. WhisperKit treats this URL as a Hub download base and
    /// resolves each tokenizer to <base>/models/openai/whisper-<size>
    /// (HubApiWrapper.localRepoLocation → HubApi.swift:350-352).
    static var tokenizerBaseDirectory: URL {
        baseDirectory.appending(path: "tokenizers", directoryHint: .isDirectory)
    }

    /// Whisper sizes, most specific name first: "large-v3" must win over
    /// "large", and "base.en" over "base".
    private static let tokenizerVariants: [ModelVariant] = [
        .largev3, .largev2, .large, .mediumEn, .medium, .smallEn, .small, .baseEn, .base, .tinyEn, .tiny,
    ]

    /// The Whisper size a catalog folder name belongs to
    /// ("openai_whisper-large-v3-v20240930_626MB" → .largev3), or nil when
    /// the name is not a Whisper model at all.
    static func tokenizerVariant(for variant: String) -> ModelVariant? {
        tokenizerVariants.first { variant.contains($0.description) }
    }

    /// The folder holding one size's tokenizer files, or nil when the variant
    /// name maps to no Whisper size. The path is built, not asked for:
    /// HubApiWrapper's initializer starts an NWPathMonitor on a fresh queue
    /// (HubApi.swift:75, 114, 810-830), and isDownloaded calls this once per
    /// catalog row on every Settings refresh.
    /// ponytail: mirrors the hub layout (<base>/models/<repo>) and rebuilds
    /// the repo name ("openai/whisper-" + size) because WhisperKit's
    /// tokenizerNameForVariant is internal — the same bet folder(for:)
    /// already makes; revisit both if WhisperKit changes its layout.
    static func tokenizerFolder(for variant: String) -> URL? {
        guard let size = tokenizerVariant(for: variant) else { return nil }
        return tokenizerBaseDirectory.appending(
            path: "models/openai/whisper-\(size.description)",
            directoryHint: .isDirectory
        )
    }

    /// True when the tokenizer WhisperKit loads is in the store. Both files
    /// are needed: tokenizer.json is the vocabulary and tokenizer_config.json
    /// picks the tokenizer class, and a folder holding only one of them sends
    /// the load back to Hugging Face. A variant with no mapped size reports
    /// true so an off-catalog model never looks missing over a tokenizer that
    /// was never meant to exist.
    static func hasTokenizer(_ variant: String) -> Bool {
        guard let folder = tokenizerFolder(for: variant) else { return true }
        return ["tokenizer.json", "tokenizer_config.json"].allSatisfy {
            FileManager.default.fileExists(atPath: folder.appending(path: $0).path)
        }
    }

    /// True when the Core ML files WhisperKit decodes with are all present.
    /// ponytail: presence checks, no checksums — a corrupted model fails at
    /// load time and the fix is delete + re-download.
    private static func hasModelFiles(_ variant: String) -> Bool {
        let folder = folder(for: variant)
        let required = ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc", "config.json"]
        return required.allSatisfy {
            FileManager.default.fileExists(atPath: folder.appending(path: $0).path)
        }
    }

    /// True when the pieces WhisperKit needs to load are all present — Core
    /// ML files AND the tokenizer, because a model without its tokenizer
    /// still needs the network on its first transcription, which is exactly
    /// what "downloaded" is supposed to rule out.
    static func isDownloaded(_ variant: String) -> Bool {
        hasModelFiles(variant) && hasTokenizer(variant)
    }

    /// The transitional state every install from before the tokenizer counted
    /// is in exactly once: the hundreds of megabytes are on disk, only the few
    /// megabytes of tokenizer JSON are missing. Worth its own question because
    /// the alternative is telling someone who already has the model that it
    /// "isn't downloaded yet" and offering them a 626 MB Get — which is both
    /// untrue and a download they don't need.
    static func needsTokenizerUpdate(_ variant: String) -> Bool {
        hasModelFiles(variant) && !hasTokenizer(variant)
    }

    /// What every surface says about that state, in one place so the recording
    /// screen, the model row, and Settings can't drift apart. Nothing is
    /// fetched automatically: downloads start at the button the user taps.
    static let tokenizerUpdateMessage = "The Whisper model needs a small one-time update. Tap Update in Settings → Transcription Model."
    /// The size line under the model row while it needs that update — the full
    /// download size would be a lie about what tapping the button costs.
    static let tokenizerUpdateSizeText = "One-time update (a few MB)."

    /// Streams the model and its tokenizer from Hugging Face; partially
    /// downloaded files are kept so a retry resumes instead of starting over.
    static func download(
        _ variant: String,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws {
        _ = try await WhisperKit.download(
            variant: variant,
            downloadBase: baseDirectory,
            from: repo,
            progressCallback: { progress in
                // The bar's last percent belongs to the tokenizer fetched
                // below. Without it a re-Get of an already-complete model —
                // which every existing install needs once now that the
                // tokenizer counts — would sit at a full bar for the seconds
                // that fetch takes and read as a hang.
                let fraction = progress.fractionCompleted * 0.99
                Task { @MainActor in onProgress(fraction) }
            }
        )
        // Don't start a fresh fetch on a cancel that landed at a file
        // boundary (WhisperKit returns normally from those).
        try Task.checkCancellation()
        try await downloadTokenizer(variant)
        await MainActor.run { onProgress(1) }
    }

    /// Fetches the variant's tokenizer into the store. WhisperKit would
    /// otherwise fetch it during the FIRST TRANSCRIPTION — which fails
    /// offline and reports "the model couldn't be loaded, re-download it",
    /// sending the user after 630 MB that were never the problem. A few
    /// megabytes of JSON here makes Get the only network step.
    /// ponytail: loadTokenizer also builds the tokenizer in memory (there is
    /// no download-only entry point); that is JSON parsing, no Core ML.
    private static func downloadTokenizer(_ variant: String) async throws {
        // An off-catalog variant maps to no Whisper size; hasTokenizer treats
        // those as satisfied, so there is nothing to fetch.
        guard let size = tokenizerVariant(for: variant) else { return }
        _ = try await ModelUtilities.loadTokenizer(for: size, tokenizerFolder: tokenizerBaseDirectory)
    }

    /// Where WhisperKit streams in-flight files (as *.incomplete) before
    /// moving each one into folder(for:) on completion. A partial download's
    /// real bytes — the big half-fetched weight blobs — live HERE, so delete
    /// and hasLocalData must cover it or Delete strands the actual space.
    static func downloadCache(for variant: String) -> URL {
        baseDirectory.appending(
            path: "models/\(repo)/.cache/huggingface/download/\(variant)",
            directoryHint: .isDirectory
        )
    }

    static func delete(_ variant: String) {
        try? FileManager.default.removeItem(at: folder(for: variant))
        try? FileManager.default.removeItem(at: downloadCache(for: variant))
        // Safe to take the whole tokenizer folder: no two catalog models
        // share a Whisper size, so this can't strand another model.
        if let tokenizer = tokenizerFolder(for: variant) {
            try? FileManager.default.removeItem(at: tokenizer)
        }
    }

    /// Any bytes on disk for this variant — including a cancelled or failed
    /// partial download, which the user must still be able to delete: a
    /// disk-full failure can strand hundreds of megabytes that finishing
    /// the download could never reclaim. The tokenizer folder counts too, or
    /// a leftover tokenizer (its model download failed, or a delete half
    /// succeeded) would sit there with no Delete affordance on the row.
    static func hasLocalData(_ variant: String) -> Bool {
        if FileManager.default.fileExists(atPath: folder(for: variant).path)
            || FileManager.default.fileExists(atPath: downloadCache(for: variant).path) {
            return true
        }
        guard let tokenizer = tokenizerFolder(for: variant) else { return false }
        return FileManager.default.fileExists(atPath: tokenizer.path)
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
    /// What `finish()` waits on — opened when the live loop exits, and opened
    /// early by `cancel()` so a finisher is never stuck behind a decode that
    /// cancellation cannot interrupt.
    private var liveGate: LiveLoopGate?

    /// Checks the model is downloaded — deliberately WITHOUT loading it.
    /// Loading takes seconds (Core ML compiles on first use), and the live
    /// path must attach its buffer tap immediately so a meeting's opening
    /// words aren't lost while the model loads; the decode loop and the file
    /// path load lazily via loadedWhisperKit() instead. Never downloads —
    /// the user downloads models explicitly in Settings, so a big Hugging
    /// Face fetch can't start as a surprise side effect.
    func prepare() async {
        guard WhisperModelStore.isDownloaded(variant) else {
            // Someone who downloaded this model before the tokenizer counted
            // as part of it has the model — telling them it "isn't downloaded
            // yet" contradicts what they did and points them at a 626 MB fetch
            // they don't need.
            availability = .unavailable(
                WhisperModelStore.needsTokenizerUpdate(variant)
                    ? WhisperModelStore.tokenizerUpdateMessage
                    : "The Whisper model isn't downloaded yet. Get it in Settings → Transcription Model, or switch back to Apple Speech."
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
                // Without this the tokenizer is looked up in HubApi's default
                // location (Documents/huggingface) and fetched from Hugging
                // Face on first use — outside the store, outside Delete, and
                // impossible offline. The download put it here.
                tokenizerFolder: WhisperModelStore.tokenizerBaseDirectory,
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
        // Handed to the loop rather than read back off the instance: a
        // cancelled pass can still be unwinding when the next recording starts,
        // and it must open the gate it was born with, never the new session's.
        let gate = LiveLoopGate()
        liveGate = gate
        // weak: the task must not keep a dropped service (and its loaded
        // model) alive — matching TranscriptionService's resultsTask.
        liveTask = Task { [weak self] in
            await self?.runLiveLoop(feed: feed, gate: gate)
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
        // The gate, not the task: WhisperKit checks cancellation only between
        // stages, so a load or a decode can run for minutes yet, and awaiting
        // the task would hold the screen on "Finishing transcript…" for all of
        // it. `cancel()` opens the gate, which is how the Save-without-
        // transcript button gets out of exactly this wait — and whatever
        // `segments` holds by then is what the user keeps.
        await liveGate?.wait()
        liveTask = nil
        liveGate = nil
        liveFeed = nil
        // The final pass normally clears this; only its failure path leaves
        // a hypothesis behind, kept rather than lost.
        promoteVolatileText()
        return segments
    }

    /// Abandons the session without waiting for results (user discarded, or
    /// asked to save with whatever the engine already heard).
    /// Deliberately does NOT await the loop: an in-flight decode can't be
    /// preempted mid-window (WhisperKit only checks cancellation between
    /// stages), and Discard must not freeze the screen for those seconds.
    /// The orphaned pass observes the cancellation and exits without
    /// touching state.
    func cancel() async {
        liveFeed?.stop()
        liveTask?.cancel()
        // A `finish()` already suspended on the gate has to be let go here for
        // the same reason: cancelling the task does not stop the stage it is
        // inside, so waiting for it is the very wait "Save without transcript"
        // is offered to escape.
        liveGate?.open()
        liveTask = nil
        liveGate = nil
        liveFeed = nil
        volatileText = ""
        segments = []
    }

    /// The streaming decode loop. Runs as a MainActor task, but the heavy
    /// whisperKit.transcribe calls are async and execute off the main thread;
    /// only cheap bookkeeping between awaits touches main. Mirrors WhisperKit's
    /// AudioStreamTranscriber algorithm (decode the unconfirmed tail, confirm
    /// all but the trailing segments) without its microphone ownership.
    private func runLiveLoop(feed: WhisperLiveFeed, gate: LiveLoopGate) async {
        // However this loop ends — the model failing to load, cancellation, or
        // the final pass returning — a `finish()` waiting on it has to be let
        // go, and every early return below is one more way to strand it.
        defer { gate.open() }
        // The model loads HERE, not in prepare(), so the feed is already
        // capturing while Core ML compiles — the backlog decodes on the
        // first pass and the meeting's opening words aren't lost. Say so:
        // prepare() reported .available without loading, and the load can
        // run for minutes on first use with nothing to show for it.
        availability = .loadingModel
        guard let whisperKit = await loadedWhisperKit() else {
            // loadedWhisperKit() has already written the actionable
            // .unavailable text; leave it there rather than claiming ready.
            // Retire the feed: its only consumer is gone, and the recorder's
            // handler would otherwise keep piling audio into it for the rest
            // of the recording (~230 MB/hour) for nothing.
            feed.stop()
            return
        }
        availability = .available
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
        // Pinned once two passes agree on enough speech, so live text stops
        // flickering between per-window detection hypotheses; nil means
        // "detect on this pass".
        var pinnedLanguage: String?
        // What the previous pass detected — a pin needs the same answer twice.
        var previousDetection: String?
        // Speech confirmed so far, summed over segment durations. Confirmed
        // audio is purged from the tail, so adding the current pass's
        // segments double-counts nothing.
        var decodedSpeechSeconds: TimeInterval = 0

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
                let mapped = Self.mapSegments(results, timeBase: timeBase)
                // Pin only on evidence: the same detection twice in a row and
                // at least five seconds of speech actually decoded. A wrong
                // pin mistranscribes the rest of the meeting, and a recording
                // that starts with a quiet room hands the first pass minutes
                // of silence around one second of speech.
                if pinnedLanguage == nil {
                    let detected = results.first?.language
                    pinnedLanguage = Self.languagePin(
                        detected: detected,
                        matching: previousDetection,
                        speechSeconds: decodedSpeechSeconds + Self.speechSeconds(of: mapped)
                    )
                    previousDetection = detected
                }
                let split = Self.splitForConfirmation(mapped, keepingLast: 2)
                if let lastConfirmed = split.confirmed.last, lastConfirmed.end > lastConfirmedEnd {
                    lastConfirmedEnd = lastConfirmed.end
                    segments.append(contentsOf: split.confirmed)
                    decodedSpeechSeconds += Self.speechSeconds(of: split.confirmed)
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

    /// Speech — not recorded audio — the pin waits for. Recorded time counts
    /// silence and the model-load backlog, so a meeting that starts quiet
    /// crossed the old threshold on its very first decoded second.
    static let languagePinMinimumSpeechSeconds: TimeInterval = 5
    /// The most unconfirmed audio the live feed retains (5 minutes ≈ 19 MB).
    private static let maximumTailSamples = 5 * 60 * WhisperKit.sampleRate

    /// Seconds of speech in a pass's segments — the measure the language pin
    /// waits on.
    static func speechSeconds(of segments: [TranscriptSegment]) -> TimeInterval {
        segments.reduce(0) { $0 + max(0, $1.end - $1.start) }
    }

    /// The language to fix for the rest of the meeting, or nil to keep
    /// detecting. It takes the same detection on two consecutive passes AND
    /// at least languagePinMinimumSpeechSeconds of decoded speech: WhisperKit
    /// always fills in a language (defaulting to English when detection
    /// fails), one second of speech is not enough to tell zh from en, and a
    /// wrong pin transliterates every later pass of the meeting.
    static func languagePin(
        detected: String?,
        matching previous: String?,
        speechSeconds: TimeInterval
    ) -> String? {
        guard let detected,
              detected == previous,
              speechSeconds >= languagePinMinimumSpeechSeconds else { return nil }
        return detected
    }

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
            // loadedWhisperKit() has just written the actionable text into
            // availability when the load failed; prepare() wrote it when the
            // model was missing. Either way, throw that, not a bare code.
            if case .unavailable(let message) = availability {
                throw TranscriptionUnavailableError(message: message)
            }
            throw TranscriptionUnavailableError(
                message: "Whisper transcription isn't ready. Check Settings → Transcription Model, or switch back to Apple Speech."
            )
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
