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

/// File transcription on a user-downloaded Whisper model (WhisperKit).
/// Covers the import, re-transcribe, and after-save paths; the spoken
/// language is auto-detected, so a meeting in Chinese transcribes correctly
/// on an English-language iPhone.
@MainActor
@Observable
final class WhisperTranscriptionService: TranscriptionEngine {
    private static let logger = Logger(subsystem: "com.minuteapp.Minute", category: "WhisperTranscription")

    private(set) var availability: TranscriptionAvailability = .unknown

    private let variant = AppSettings.whisperModel
    private var whisperKit: WhisperKit?

    /// Loads the selected model. Never downloads — the user downloads models
    /// explicitly in Settings, so a big Hugging Face fetch can't start as a
    /// surprise side effect of an import.
    func prepare() async {
        if whisperKit != nil {
            availability = .available
            return
        }
        guard WhisperModelStore.isDownloaded(variant) else {
            availability = .unavailable(
                "The Whisper model isn't downloaded yet. Get it in Settings → Transcription Model, or switch back to Apple Speech."
            )
            return
        }
        do {
            let config = WhisperKitConfig(
                modelFolder: WhisperModelStore.folder(for: variant).path,
                verbose: false,
                logLevel: .error,
                load: true,
                download: false
            )
            whisperKit = try await WhisperKit(config)
            availability = .available
        } catch {
            Self.logger.error("WhisperKit load failed: \(error.localizedDescription)")
            availability = .unavailable(
                "The Whisper model couldn't be loaded. Re-download it in Settings → Transcription Model, or switch back to Apple Speech."
            )
        }
    }

    func transcribe(file: AVAudioFile) async throws -> [TranscriptSegment] {
        guard availability == .available, let whisperKit else {
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

        return results
            .flatMap(\.segments)
            .compactMap { segment in
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return TranscriptSegment(
                    text: text,
                    start: TimeInterval(segment.start),
                    end: TimeInterval(segment.end)
                )
            }
            .sorted { $0.start < $1.start }
    }
}
