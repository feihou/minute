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
}
