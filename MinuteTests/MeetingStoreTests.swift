import Foundation
import SwiftData
import Testing
@testable import Minute

@MainActor
struct MeetingStoreTests {
    /// The failure path of `delete` restores the meeting by re-inserting it,
    /// which only works because SwiftData treats an insert of a pending-deleted
    /// object as an undo. If that ever stops holding, a failed delete would
    /// silently commit on the next unrelated save.
    @Test func reinsertingUndoesAnUncommittedDelete() throws {
        let container = try ModelContainer(
            for: Meeting.self,
            configurations: MeetingStore.modelConfiguration(inMemory: true)
        )
        let context = container.mainContext
        let meeting = Meeting(title: "Survivor")
        context.insert(meeting)
        try context.save()

        context.delete(meeting)
        context.insert(meeting)
        try context.save()

        #expect(!meeting.isDeleted)
        #expect(try context.fetch(FetchDescriptor<Meeting>()).count == 1)
    }

    @Test func deleteRemovesMeetingAndAudioFile() throws {
        let container = try ModelContainer(
            for: Meeting.self,
            configurations: MeetingStore.modelConfiguration(inMemory: true)
        )
        let context = container.mainContext

        let fileName = MeetingStore.newAudioFileName()
        let url = try MeetingStore.audioURL(fileName: fileName)
        try Data("fake audio".utf8).write(to: url)
        #expect(FileManager.default.fileExists(atPath: url.path))

        let meeting = Meeting(title: "To Delete", audioFileName: fileName)
        context.insert(meeting)
        try context.save()

        MeetingStore.delete(meeting, context: context)

        #expect(!FileManager.default.fileExists(atPath: url.path))
        let remaining = try context.fetch(FetchDescriptor<Meeting>())
        #expect(remaining.isEmpty)
    }

    @Test func audioURLIsNilForMeetingWithoutRecording() {
        let meeting = Meeting(title: "No Audio")
        #expect(MeetingStore.audioURL(for: meeting) == nil)
    }

    @Test func audioURLIsNilWhenFileIsMissing() {
        let meeting = Meeting(title: "Missing Audio", audioFileName: "does-not-exist.m4a")
        #expect(MeetingStore.audioURL(for: meeting) == nil)
    }

    @Test func recordingsDirectoryIsExcludedFromBackupsByDefault() throws {
        // Pin the precondition: UserDefaults persist on the simulator, so a
        // toggle flipped in the host app would otherwise leak into this test.
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: AppSettings.iCloudBackupKey)
        defaults.removeObject(forKey: AppSettings.iCloudBackupKey)
        defer { previous.map { defaults.set($0, forKey: AppSettings.iCloudBackupKey) } }

        // Apply the policy here rather than trusting the launch-time pass:
        // `backupPolicyApplied` sticks once per process, so this test otherwise
        // asserts whatever ambient state the host launch and earlier tests left
        // on the real Application Support directory — which made it flake under
        // parallel scheduling. Applying with the default (off) setting and
        // asserting the result tests the same promise deterministically.
        #expect(MeetingStore.applyBackupPolicy())
        let directory = try MeetingStore.recordingsDirectory()
        let base = directory.deletingLastPathComponent()
        let values = try base.resourceValues(forKeys: [.isExcludedFromBackupKey])
        // The message names the directory read and the ephemeral flag because
        // this test's one historic failure mode is the host app silently
        // falling back to in-memory storage at launch (a failed store
        // migration), which routes recordingsDirectory() to tmp.
        #expect(values.isExcludedFromBackup == true,
                "base=\(base.path) ephemeral=\(MeetingStore.useEphemeralStorage)")
    }

    // On a scratch directory, not the real Application Support tree, so tests
    // running concurrently never observe a flipped flag there.
    @Test func backupExclusionFlagFollowsTheRequestedValue() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try MeetingStore.setExcludedFromBackup(true, at: directory)
        // Fresh URL each read — URL caches resource values per instance.
        var values = try URL(fileURLWithPath: directory.path)
            .resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)

        try MeetingStore.setExcludedFromBackup(false, at: directory)
        values = try URL(fileURLWithPath: directory.path)
            .resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == false)
    }

    /// F34/F35: the class was pinned on Application Support only, which does
    /// not reach the SwiftData store (ModelContainer creates it before any
    /// policy runs) nor a Recordings directory that already existed. And the
    /// class itself was wrong: `completeUnlessOpen` files cannot be reopened
    /// after the phone locks, which is exactly when the iCloud Drive mirror
    /// and the job engines read them.
    ///
    /// The applier is injected because the simulator accepts `.protectionKey`
    /// and reports it back as nil — reading the attribute would assert
    /// nothing about what was requested.
    @Test func dataProtectionCoversTheStoreFilesAndTheRecordingsDirectory() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("protection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        // The store files exist before any policy runs. The -shm sibling
        // deliberately does not, so the pass is shown to skip what is absent
        // rather than throw on it.
        try Data("db".utf8).write(to: base.appendingPathComponent("default.store"))
        try Data("wal".utf8).write(to: base.appendingPathComponent("default.store-wal"))

        var applied: [(name: String, protection: FileProtectionType)] = []
        let succeeded = MeetingStore.applyDataProtection(base: base) { url, protection in
            applied.append((url.lastPathComponent, protection))
        }

        #expect(succeeded)
        #expect(applied.map(\.name) == [
            base.lastPathComponent,
            "Recordings",
            "default.store",
            "default.store-wal",
        ])
        #expect(Set(applied.map(\.protection)) == [.completeUntilFirstUserAuthentication])
        // Created if missing, so a fresh install's audio inherits the class.
        #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("Recordings").path))
    }

    @Test func ephemeralModeRoutesAudioToTemporaryDirectoryAndWipesIt() throws {
        MeetingStore.useEphemeralStorage = true
        defer { MeetingStore.useEphemeralStorage = false }

        let directory = try MeetingStore.recordingsDirectory()
        #expect(directory.path.hasPrefix(FileManager.default.temporaryDirectory.path))

        let fileName = MeetingStore.newAudioFileName()
        let url = try MeetingStore.audioURL(fileName: fileName)
        try Data("session audio".utf8).write(to: url)
        #expect(FileManager.default.fileExists(atPath: url.path))

        MeetingStore.removeEphemeralRecordings()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func importedAudioFileNameKeepsKnownExtensionsAndDefaultsUnknownToM4a() {
        #expect(MeetingStore.importedAudioFileName(originalExtension: "MP3").hasSuffix(".mp3"))
        #expect(MeetingStore.importedAudioFileName(originalExtension: "wav").hasSuffix(".wav"))
        #expect(MeetingStore.importedAudioFileName(originalExtension: "xyz").hasSuffix(".m4a"))
        #expect(MeetingStore.importedAudioFileName(originalExtension: "").hasSuffix(".m4a"))
    }

    /// A directory only this test writes into. The sweep used to run against
    /// the live Recordings directory and "protect" concurrent tests' fixtures
    /// by listing the directory first — which still lost anything that landed
    /// between the listing and the sweep.
    private func makeScratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("orphan-sweep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func removeOrphanedAudioSweepsImportedFormats() throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let orphanName = MeetingStore.importedAudioFileName(originalExtension: "mp3")
        let orphanURL = directory.appendingPathComponent(orphanName)
        try Data("orphan mp3".utf8).write(to: orphanURL)

        MeetingStore.removeOrphanedAudio(referencedFileNames: [], in: directory)

        #expect(!FileManager.default.fileExists(atPath: orphanURL.path))
    }

    @Test func removeOrphanedAudioDeletesOnlyUnreferencedFiles() throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keptName = MeetingStore.newAudioFileName()
        let orphanName = MeetingStore.newAudioFileName()
        let keptURL = directory.appendingPathComponent(keptName)
        let orphanURL = directory.appendingPathComponent(orphanName)
        try Data("kept".utf8).write(to: keptURL)
        try Data("orphan".utf8).write(to: orphanURL)

        MeetingStore.removeOrphanedAudio(referencedFileNames: [keptName], in: directory)

        #expect(FileManager.default.fileExists(atPath: keptURL.path))
        #expect(!FileManager.default.fileExists(atPath: orphanURL.path))
    }

    @Test func removeOrphanedAudioLeavesNonAudioFilesAlone() throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let notes = directory.appendingPathComponent("notes.txt")
        try Data("not audio".utf8).write(to: notes)

        MeetingStore.removeOrphanedAudio(referencedFileNames: [], in: directory)

        // The sweep is keyed on audio extensions; anything else in the
        // directory belongs to someone else and must survive.
        #expect(FileManager.default.fileExists(atPath: notes.path))
    }

    @Test func referencedAudioFileNamesListsEveryStoredMeetingsFile() throws {
        let container = try ModelContainer(
            for: Meeting.self,
            configurations: MeetingStore.modelConfiguration(inMemory: true)
        )
        let context = container.mainContext
        context.insert(Meeting(title: "A", audioFileName: "a.m4a"))
        context.insert(Meeting(title: "B", audioFileName: "b.wav"))
        context.insert(Meeting(title: "No audio"))
        try context.save()

        // The launch sweep deletes every recording NOT in this set, so it
        // must come from a fetch that can say "I failed" — never from a view
        // query whose failure reads as an empty library.
        #expect(MeetingStore.referencedAudioFileNames(context: context) == ["a.m4a", "b.wav"])
    }
}
