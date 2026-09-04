import Foundation
import Testing
import WhisperKit
@testable import Minute

/// hasLocalData/isDownloaded drive the picker's Delete swipe action: a
/// variant with partial files must be deletable without ever being offered
/// as a usable model.
struct WhisperModelStoreTests {
    // MARK: Fixture variants
    //
    // A fixture that exercises the tokenizer half of the store has to name a
    // real Whisper SIZE — tokenizerVariant matches by substring, and a name
    // that maps to no size makes tokenizerFolder nil, which skips exactly the
    // code under test. But the tokenizer folder is per size, not per variant:
    // "openai_whisper-small-test-<UUID>" resolves to the very folder the
    // catalog's Small model uses, so on a machine that has Small downloaded
    // the test reads the user's real tokenizer AND its `delete` wipes it,
    // leaving the app claiming Small "needs a small one-time update". Two
    // fixtures sharing a size collide with each other the same way, because
    // this suite is not .serialized and Swift Testing runs its tests in
    // parallel. fixtureVariantsOwnTheirTokenizerFolders holds both rules.

    /// tokenizerIsRequiredForADownloadedModel
    private static let downloadedFixture = "openai_whisper-medium-test"
    /// modelWithoutItsTokenizerNeedsAnUpdate. NOT "small": that is a catalog
    /// size, and this test both reads and deletes the tokenizer folder.
    private static let tokenizerUpdateFixture = "openai_whisper-large-v2-test"
    /// tokenizerOnlyLeftoverCountsAsLocalData
    private static let leftoverFixture = "openai_whisper-tiny-test"
    /// deleteRemovesTheTokenizer. NOT "tiny": leftoverFixture owns that size,
    /// and this test deletes the folder while that one is asserting on it.
    private static let deleteFixture = "openai_whisper-base.en-test"

    private static let fixtureVariants = [
        downloadedFixture, tokenizerUpdateFixture, leftoverFixture, deleteFixture,
    ]

    /// A variant name under one of those fixtures, unique per run so two
    /// executions can never share a model folder.
    private static func fixture(_ base: String) -> String {
        "\(base)-\(UUID().uuidString)"
    }

    @Test("No fixture shares a tokenizer folder with a catalog model or another fixture")
    func fixtureVariantsOwnTheirTokenizerFolders() throws {
        let catalogFolders = Set(WhisperModelCatalog.models.compactMap {
            WhisperModelStore.tokenizerFolder(for: $0.variant)?.path
        })
        // Every catalog model maps to a size, and to a folder of its own.
        #expect(catalogFolders.count == WhisperModelCatalog.models.count)

        var fixtureFolders: Set<String> = []
        for base in Self.fixtureVariants {
            let folder = try #require(WhisperModelStore.tokenizerFolder(for: Self.fixture(base))).path
            // A fixture must never touch a folder a real download owns…
            #expect(!catalogFolders.contains(folder))
            // …nor one another fixture owns, since they run in parallel.
            #expect(fixtureFolders.insert(folder).inserted)
        }
    }

    @Test("Every Whisper size WhisperKit knows maps to its own tokenizer")
    func everyWhisperSizeMapsToItself() {
        // Derived from ModelVariant.allCases, so a size a future WhisperKit
        // release adds is in this table the day the package updates — and it
        // must resolve to itself, never to a shorter name it happens to
        // contain: "large-v3" must not answer .large, "base.en" not .base.
        let sizes = WhisperModelStore.tokenizerVariants.map(\.description)
        // Tautological as long as the table is derived from allCases, and kept
        // for exactly that reason: it is what goes red if anyone reverts
        // `tokenizerVariants` to a hand-written list, which would then quietly
        // miss whatever size the next WhisperKit update ships. It cannot catch
        // that missing size by itself — the derivation is what does — so this
        // guards the derivation, not the contents.
        #expect(sizes.count == ModelVariant.allCases.count)
        #expect(Set(sizes).count == sizes.count)
        for size in sizes {
            #expect(WhisperModelStore.tokenizerVariant(for: "openai_whisper-\(size)")?.description == size)
        }
        // A name that is not a Whisper model at all still maps to nothing.
        #expect(WhisperModelStore.tokenizerVariant(for: "nonexistent-model-variant") == nil)
    }

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
        let variant = Self.fixture(Self.downloadedFixture)
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
        let variant = Self.fixture(Self.tokenizerUpdateFixture)
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
        let variant = Self.fixture(Self.leftoverFixture)
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
        let variant = Self.fixture(Self.deleteFixture)
        defer { WhisperModelStore.delete(variant) }

        let tokenizer = try #require(WhisperModelStore.tokenizerFolder(for: variant))
        try FileManager.default.createDirectory(at: tokenizer, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: tokenizer.appending(path: "tokenizer.json"))

        WhisperModelStore.delete(variant)
        #expect(!FileManager.default.fileExists(atPath: tokenizer.path))
    }
}
