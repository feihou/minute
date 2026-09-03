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

    /// The upgrade case F34 is actually about. A library recorded under the
    /// shipped class-B build already sits in Recordings, and `setAttributes` on
    /// a directory is not recursive — stamping the directory fixes only audio
    /// written afterwards, while every existing `.m4a` keeps class B and the
    /// background iCloud Drive mirror still fails to copy it with the phone
    /// locked. So the pass names each recording that is already there, in a
    /// deterministic order (the file system's own is not).
    @Test func dataProtectionReachesRecordingsThatAlreadyExist() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("protection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let recordings = base.appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        // Written out of order, and one is an imported container rather than a
        // recording — every byte in there needs the class, not just `.m4a`.
        try Data("second".utf8).write(to: recordings.appendingPathComponent("b-meeting.m4a"))
        try Data("first".utf8).write(to: recordings.appendingPathComponent("a-meeting.m4a"))
        try Data("third".utf8).write(to: recordings.appendingPathComponent("imported.mp3"))

        var applied: [(name: String, protection: FileProtectionType)] = []
        let succeeded = MeetingStore.applyDataProtection(base: base) { url, protection in
            applied.append((url.lastPathComponent, protection))
        }

        #expect(succeeded)
        #expect(applied.map(\.name) == [
            base.lastPathComponent,
            "Recordings",
            "a-meeting.m4a",
            "b-meeting.m4a",
            "imported.mp3",
        ])
        #expect(Set(applied.map(\.protection)) == [.completeUntilFirstUserAuthentication])
    }

    /// The other half of the failure `dataProtectionClass` names: the Whisper
    /// and MLX model trees. Both stores create their directory lazily, so on an
    /// install upgraded from the build that stamped the Application Support
    /// root class B, a model directory created afterwards inherited class B —
    /// and every file downloaded into it inherits class B in turn, for as long
    /// as the directory lives. Stamping the two roots closes that forward path.
    ///
    /// Only the roots. The pass does not walk a model tree on the launch path,
    /// and it does not create a directory for a user who never downloaded a
    /// model — a missing one is skipped, exactly like an absent store file.
    @Test func dataProtectionReachesTheModelDirectoriesWithoutWalkingThem() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("protection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        // A downloaded Whisper model, in the nested hub layout WhisperKit
        // writes. MLXModels is deliberately absent: nothing has downloaded a
        // summary model on this install.
        let variant = base.appendingPathComponent("WhisperKitModels/models/argmaxinc/tiny", isDirectory: true)
        try FileManager.default.createDirectory(at: variant, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: variant.appendingPathComponent("config.json"))

        var applied: [(name: String, protection: FileProtectionType)] = []
        let succeeded = MeetingStore.applyDataProtection(base: base) { url, protection in
            applied.append((url.lastPathComponent, protection))
        }

        #expect(succeeded)
        #expect(applied.map(\.name) == [
            base.lastPathComponent,
            "Recordings",
            "WhisperKitModels",
        ])
        #expect(Set(applied.map(\.protection)) == [.completeUntilFirstUserAuthentication])
        // Not materialised for a user with no MLX model: this pass stamps what
        // is there, it does not create caches.
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("MLXModels").path))
    }

    /// The App Group container, which the earlier round left with no class at
    /// all. The reader that matters is the widget's timeline provider: it runs
    /// while the device is locked and reads the snapshot plist `UserDefaults`
    /// writes into `<group>/Library/Preferences`. A class-B plist there is a
    /// blank widget on the lock screen — the same symptom class as F34 — and an
    /// install upgraded from the shipped class-B build keeps class B on that
    /// root until something re-stamps it. So both the root and the Preferences
    /// directory are named, for the same reason every other target here is.
    @Test func dataProtectionStampsTheAppGroupTheLockedWidgetReads() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("protection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let group = FileManager.default.temporaryDirectory
            .appendingPathComponent("group-\(UUID().uuidString)", isDirectory: true)
        let preferences = group.appendingPathComponent("Library/Preferences", isDirectory: true)
        try FileManager.default.createDirectory(at: preferences, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: group) }

        var applied: [(name: String, protection: FileProtectionType)] = []
        let succeeded = MeetingStore.applyDataProtection(base: base, appGroup: group) { url, protection in
            applied.append((url.lastPathComponent, protection))
        }

        #expect(succeeded)
        #expect(applied.map(\.name) == [
            base.lastPathComponent,
            "Recordings",
            group.lastPathComponent,
            "Preferences",
        ])
        #expect(Set(applied.map(\.protection)) == [.completeUntilFirstUserAuthentication])
    }

    /// The container is nil wherever the App Group entitlement is not in force
    /// — the unsigned test host, for one. Nothing extra may be stamped then,
    /// and nothing may be created: a Preferences directory this pass conjured
    /// would be a directory `UserDefaults` never asked for.
    @Test func dataProtectionStampsNothingExtraWithoutAnAppGroup() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("protection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        var applied: [String] = []
        let succeeded = MeetingStore.applyDataProtection(base: base, appGroup: nil) { url, _ in
            applied.append(url.lastPathComponent)
        }

        #expect(succeeded)
        #expect(applied == [base.lastPathComponent, "Recordings"])
    }

    /// A group container whose `Library/Preferences` does not exist yet — the
    /// first launch, before anything has published a snapshot. The root still
    /// gets the class so what `UserDefaults` creates there inherits it, and the
    /// absent directory is skipped rather than materialised.
    @Test func dataProtectionSkipsAnAppGroupPreferencesDirectoryThatIsAbsent() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("protection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let group = FileManager.default.temporaryDirectory
            .appendingPathComponent("group-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: group) }

        var applied: [String] = []
        let succeeded = MeetingStore.applyDataProtection(base: base, appGroup: group) { url, _ in
            applied.append(url.lastPathComponent)
        }

        #expect(succeeded)
        #expect(applied == [base.lastPathComponent, "Recordings", group.lastPathComponent])
        #expect(!FileManager.default.fileExists(atPath: group.appendingPathComponent("Library").path))
    }

    /// One target the file system refuses must not cost the others their class:
    /// giving up at the first failure would leave the recordings — the files
    /// the locked-phone reads actually need — stamped or not depending on where
    /// in the list the failure happened to fall.
    @Test func dataProtectionKeepsGoingAfterOneTargetFails() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("protection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let recordings = base.appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: recordings.appendingPathComponent("meeting.m4a"))
        try Data("db".utf8).write(to: base.appendingPathComponent("default.store"))

        var applied: [String] = []
        let succeeded = MeetingStore.applyDataProtection(base: base) { url, _ in
            if url.lastPathComponent == "Recordings" {
                throw CocoaError(.fileWriteNoPermission)
            }
            applied.append(url.lastPathComponent)
        }

        #expect(!succeeded)
        #expect(applied == [base.lastPathComponent, "meeting.m4a", "default.store"])
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

    /// F68: in fallback mode nothing else can reach these files — the library
    /// the delete paths iterate is the empty in-memory one, and
    /// `recordingsDirectory()` points at the session-only tmp directory — so
    /// this is the only delete path the on-disk audio and transcripts have.
    @Test func resetPersistentStoreRemovesTheStoreFilesAndEveryRecording() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("reset-\(UUID().uuidString)", isDirectory: true)
        let recordings = base.appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = base.appendingPathComponent("default.store")
        let wal = base.appendingPathComponent("default.store-wal")
        let audio = recordings.appendingPathComponent(MeetingStore.newAudioFileName())
        let models = base.appendingPathComponent("WhisperModels", isDirectory: true)
        try Data("db".utf8).write(to: store)
        try Data("wal".utf8).write(to: wal)
        try Data("audio".utf8).write(to: audio)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)

        #expect(MeetingStore.resetPersistentStore(base: base))

        #expect(!FileManager.default.fileExists(atPath: store.path))
        #expect(!FileManager.default.fileExists(atPath: wal.path))
        #expect(!FileManager.default.fileExists(atPath: recordings.path))
        // Downloaded models are not meeting data and cost gigabytes to fetch
        // again; "start over" must not turn into that penalty.
        #expect(FileManager.default.fileExists(atPath: models.path))
    }

    @Test func resetPersistentStoreSucceedsWhenThereIsNothingToRemove() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("reset-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        // A store can fail to open because it was never written. "Nothing to
        // delete" is a successful reset, not a failure to report to the user.
        #expect(MeetingStore.resetPersistentStore(base: base))
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
