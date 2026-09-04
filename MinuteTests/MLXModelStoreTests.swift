import Foundation
import Testing
@testable import Minute

/// The completion marker certifies a finished download AND, so that loading a
/// summary model never has to ask Hugging Face which commit "main" points at,
/// records where that download landed.
struct MLXModelStoreTests {
    private func makeModel() -> MLXSummaryModel {
        MLXSummaryModel(
            repoID: "test-org/fake-\(UUID().uuidString)",
            label: "Fake",
            detail: "Test fixture.",
            approximateMegabytes: 1,
            minimumMemoryGigabytes: 1
        )
    }

    @Test("The marker records the snapshot directory relative to the store")
    func markerRecordsTheSnapshotDirectory() throws {
        let model = makeModel()
        defer { MLXModelStore.delete(model) }

        let snapshot = MLXModelStore.repoDirectory(for: model)
            .appending(path: "snapshots/abc123", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)

        #expect(MLXModelStore.writeCompletionMarker(for: model, snapshotDirectory: snapshot))
        #expect(MLXModelStore.snapshotDirectory(for: model)?.standardizedFileURL == snapshot.standardizedFileURL)

        // Relative, not absolute: the app's container path changes between
        // installs, and an absolute path would rot into a load failure.
        let contents = try String(contentsOf: MLXModelStore.completionMarker(for: model), encoding: .utf8)
        let expected = "models--" + model.repoID.replacingOccurrences(of: "/", with: "--") + "/snapshots/abc123"
        #expect(contents == expected)
    }

    @Test("A marker from an older build still counts as downloaded, with no directory")
    func olderMarkerHasNoRecordedDirectory() throws {
        let model = makeModel()
        defer { MLXModelStore.delete(model) }

        let directory = MLXModelStore.repoDirectory(for: model)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(count: 1).write(to: directory.appending(path: "model.safetensors"))
        // The old format: an empty marker file.
        #expect(FileManager.default.createFile(atPath: MLXModelStore.completionMarker(for: model).path, contents: nil))

        #expect(MLXModelStore.isDownloaded(model))
        #expect(MLXModelStore.snapshotDirectory(for: model) == nil)
    }

    @Test("A recorded directory that no longer exists is ignored")
    func missingRecordedDirectoryIsIgnored() throws {
        let model = makeModel()
        defer { MLXModelStore.delete(model) }

        let snapshot = MLXModelStore.repoDirectory(for: model)
            .appending(path: "snapshots/gone", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        #expect(MLXModelStore.writeCompletionMarker(for: model, snapshotDirectory: snapshot))
        try FileManager.default.removeItem(at: snapshot)

        // Falling back beats loading from a directory that isn't there.
        #expect(MLXModelStore.snapshotDirectory(for: model) == nil)
    }

    /// A recorded directory is opened by every later load on nothing but an
    /// existence check, so the only protection against wedging a model on a
    /// partial snapshot is refusing to record one. The download proves the
    /// snapshot with holdsCompleteSnapshot; the load path proves it by
    /// loading before it writes. This pins the assumption both rest on.
    @Test("A recorded directory is trusted on sight, however little it holds")
    func recordedDirectoryIsTrustedOnSight() throws {
        let model = makeModel()
        defer { MLXModelStore.delete(model) }

        let partial = MLXModelStore.repoDirectory(for: model)
            .appending(path: "snapshots/partial", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        #expect(MLXModelStore.writeCompletionMarker(for: model, snapshotDirectory: partial))

        #expect(!MLXModelStore.holdsCompleteSnapshot(at: partial))
        #expect(MLXModelStore.snapshotDirectory(for: model)?.standardizedFileURL == partial.standardizedFileURL)
    }

    @Test("A snapshot needs weights and a config to count as complete")
    func completeSnapshotNeedsWeightsAndConfig() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // An interrupted download leaves one flushed shard behind. Certifying
        // that would strand the model: the load fails and never re-resolves.
        try Data(count: 1).write(to: directory.appending(path: "model.safetensors"))
        #expect(!MLXModelStore.holdsCompleteSnapshot(at: directory))

        try Data(count: 1).write(to: directory.appending(path: "config.json"))
        #expect(MLXModelStore.holdsCompleteSnapshot(at: directory))
    }

    @Test("A config alone, and a directory that isn't there, are incomplete")
    func configAloneAndMissingDirectoryAreIncomplete() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try Data(count: 1).write(to: directory.appending(path: "config.json"))
        #expect(!MLXModelStore.holdsCompleteSnapshot(at: directory))

        #expect(!MLXModelStore.holdsCompleteSnapshot(at: directory.appending(path: "nope", directoryHint: .isDirectory)))
    }

    @Test("A snapshot outside the store records nothing")
    func snapshotOutsideTheStoreRecordsNothing() throws {
        let model = makeModel()
        defer { MLXModelStore.delete(model) }
        try FileManager.default.createDirectory(
            at: MLXModelStore.repoDirectory(for: model), withIntermediateDirectories: true
        )

        #expect(MLXModelStore.writeCompletionMarker(for: model, snapshotDirectory: FileManager.default.temporaryDirectory))
        #expect(MLXModelStore.relativeSnapshotPath(for: FileManager.default.temporaryDirectory).isEmpty)
        #expect(MLXModelStore.snapshotDirectory(for: model) == nil)
    }
}
