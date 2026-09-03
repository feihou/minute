import Foundation
import Testing
@testable import Minute

/// hasLocalData/isDownloaded drive the picker's Delete swipe action: a
/// variant with partial files must be deletable without ever being offered
/// as a usable model.
struct WhisperModelStoreTests {
    @Test("Partial downloads are deletable but never report as downloaded")
    func partialDownloadLifecycle() throws {
        let variant = "test-variant-\(UUID().uuidString)"
        defer { WhisperModelStore.delete(variant) }

        #expect(!WhisperModelStore.hasLocalData(variant))
        #expect(!WhisperModelStore.isDownloaded(variant))

        // A folder with a stray file mimics a cancelled download.
        let folder = WhisperModelStore.folder(for: variant)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appending(path: "config.json"))

        #expect(WhisperModelStore.hasLocalData(variant))
        #expect(!WhisperModelStore.isDownloaded(variant))

        WhisperModelStore.delete(variant)
        #expect(!WhisperModelStore.hasLocalData(variant))
    }

    @Test("In-flight bytes in WhisperKit's hidden download cache are seen and deleted")
    func downloadCacheLifecycle() throws {
        let variant = "test-variant-\(UUID().uuidString)"
        defer { WhisperModelStore.delete(variant) }

        // A cancel before the first file completes leaves bytes ONLY in the
        // .cache download folder — they must still be visible and deletable.
        let cache = WhisperModelStore.downloadCache(for: variant)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data(count: 1).write(to: cache.appending(path: "AudioEncoder.mlmodelc.abc123.incomplete"))

        #expect(WhisperModelStore.hasLocalData(variant))
        #expect(!WhisperModelStore.isDownloaded(variant))

        WhisperModelStore.delete(variant)
        #expect(!WhisperModelStore.hasLocalData(variant))
        #expect(!FileManager.default.fileExists(atPath: cache.path))
    }

    @Test("Tokenizer folders live inside the store, one per Whisper size")
    func tokenizerFolderMatchesTheHubLayout() throws {
        let large = try #require(WhisperModelStore.tokenizerFolder(for: "openai_whisper-large-v3-v20240930_626MB"))
        #expect(large.path.hasSuffix("WhisperKitModels/tokenizers/models/openai/whisper-large-v3"))
        let base = try #require(WhisperModelStore.tokenizerFolder(for: "openai_whisper-base"))
        #expect(base.path.hasSuffix("WhisperKitModels/tokenizers/models/openai/whisper-base"))
        // A name that isn't a Whisper size has no tokenizer repo, and must
        // not be able to make an otherwise complete model look missing.
        #expect(WhisperModelStore.tokenizerFolder(for: "nonexistent-model-variant") == nil)
    }

    @Test("A model without its tokenizer is not downloaded")
    func tokenizerIsRequiredForADownloadedModel() throws {
        // A variant name that maps to a size the catalog never offers, so a
        // real download on this machine can't collide with the fixture.
        let variant = "openai_whisper-medium-test-\(UUID().uuidString)"
        defer { WhisperModelStore.delete(variant) }

        let folder = WhisperModelStore.folder(for: variant)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc", "config.json"] {
            try Data("{}".utf8).write(to: folder.appending(path: name))
        }
        // Every Core ML file is there, but the first transcription would
        // still have to reach Hugging Face for the tokenizer.
        #expect(!WhisperModelStore.isDownloaded(variant))

        let tokenizer = try #require(WhisperModelStore.tokenizerFolder(for: variant))
        try FileManager.default.createDirectory(at: tokenizer, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: tokenizer.appending(path: "tokenizer.json"))
        #expect(!WhisperModelStore.isDownloaded(variant))   // tokenizer_config.json still missing
        try Data("{}".utf8).write(to: tokenizer.appending(path: "tokenizer_config.json"))
        #expect(WhisperModelStore.isDownloaded(variant))
    }

    @Test("A model from before the tokenizer counted needs an update, not a download")
    func modelWithoutItsTokenizerNeedsAnUpdate() throws {
        let variant = "openai_whisper-small-test-\(UUID().uuidString)"
        defer { WhisperModelStore.delete(variant) }

        // Nothing on disk: this is a plain "not downloaded", and offering a
        // few-megabyte update for a model the user doesn't have would be a lie.
        #expect(!WhisperModelStore.needsTokenizerUpdate(variant))

        let folder = WhisperModelStore.folder(for: variant)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc", "config.json"] {
            try Data("{}".utf8).write(to: folder.appending(path: name))
        }
        // Exactly the state every install from before this release is in: the
        // hundreds of megabytes are there, only the tokenizer is missing.
        #expect(WhisperModelStore.needsTokenizerUpdate(variant))
        #expect(!WhisperModelStore.isDownloaded(variant))

        let tokenizer = try #require(WhisperModelStore.tokenizerFolder(for: variant))
        try FileManager.default.createDirectory(at: tokenizer, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: tokenizer.appending(path: "tokenizer.json"))
        try Data("{}".utf8).write(to: tokenizer.appending(path: "tokenizer_config.json"))
        // Complete: nothing left to update.
        #expect(!WhisperModelStore.needsTokenizerUpdate(variant))
        #expect(WhisperModelStore.isDownloaded(variant))
    }

    @Test("A leftover tokenizer folder keeps the model deletable")
    func tokenizerOnlyLeftoverCountsAsLocalData() throws {
        let variant = "openai_whisper-tiny-test-\(UUID().uuidString)"
        defer { WhisperModelStore.delete(variant) }

        let tokenizer = try #require(WhisperModelStore.tokenizerFolder(for: variant))
        try FileManager.default.createDirectory(at: tokenizer, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: tokenizer.appending(path: "tokenizer.json"))

        // A delete that half-succeeded, or a tokenizer fetched for a model
        // whose own download then failed: the bytes are real, so the row has
        // to keep offering Delete.
        #expect(WhisperModelStore.hasLocalData(variant))
        #expect(!WhisperModelStore.isDownloaded(variant))
    }

    @Test("Deleting a model removes its tokenizer too")
    func deleteRemovesTheTokenizer() throws {
        let variant = "openai_whisper-tiny-test-\(UUID().uuidString)"
        defer { WhisperModelStore.delete(variant) }

        let tokenizer = try #require(WhisperModelStore.tokenizerFolder(for: variant))
        try FileManager.default.createDirectory(at: tokenizer, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: tokenizer.appending(path: "tokenizer.json"))

        WhisperModelStore.delete(variant)
        #expect(!FileManager.default.fileExists(atPath: tokenizer.path))
    }
}
