import Foundation
import SwiftData
import Testing
@testable import Minute

@MainActor
struct ICloudDriveBackupTests {
    private func scratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fixedDate() -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 3
        components.hour = 9
        components.minute = 30
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    private func item(
        id: String = UUID().uuidString,
        folderName: String,
        notes: String = "notes",
        audio: URL? = nil
    ) -> ICloudDriveBackup.Item {
        .init(meetingID: id, folderName: folderName, notes: notes, audioSourceURL: audio)
    }

    // MARK: - Names

    @Test func folderNameIsDatePrefixedAndSanitized() {
        let name = ICloudDriveBackup.folderName(title: "Q3: Plans / Review", createdAt: fixedDate())
        #expect(name == "2026-08-03 09.30 Q3 Plans Review")
    }

    @Test func folderNameFallsBackForEmptyTitles() {
        let name = ICloudDriveBackup.folderName(title: "///", createdAt: fixedDate())
        #expect(name == "2026-08-03 09.30 Meeting")
    }

    /// A file system name is capped in bytes, not characters — 200 CJK
    /// characters are 600 bytes and would fail to create on every sync.
    @Test func folderNameStaysWithinTheFileSystemByteLimit() {
        let name = ICloudDriveBackup.folderName(
            title: String(repeating: "会議", count: 100),
            createdAt: fixedDate()
        )
        #expect(name.utf8.count <= 255)
        #expect(name.hasPrefix("2026-08-03 09.30 会議"))
    }

    // MARK: - Snapshots

    @Test func itemsUniquifyDuplicateFolderNames() {
        let date = fixedDate()
        let items = ICloudDriveBackup.items(for: [
            Meeting(title: "Standup", createdAt: date),
            Meeting(title: "Standup", createdAt: date),
        ])
        #expect(items[0].folderName != items[1].folderName)
    }

    /// The suffixed name must not land on another meeting's real name.
    @Test func itemsUniquifyWhenASuffixedNameIsAlreadyTaken() {
        let date = fixedDate()
        let names = ICloudDriveBackup.items(for: [
            Meeting(title: "Standup", createdAt: date),
            Meeting(title: "Standup 2", createdAt: date),
            Meeting(title: "Standup", createdAt: date),
        ]).map(\.folderName)
        #expect(Set(names).count == 3)
    }

    /// The file system is case-insensitive, so names that differ only in
    /// case would land in one folder.
    @Test func itemsTreatNamesDifferingOnlyInCaseAsDuplicates() {
        let date = fixedDate()
        let names = ICloudDriveBackup.items(for: [
            Meeting(title: "Standup", createdAt: date),
            Meeting(title: "standup", createdAt: date),
        ]).map(\.folderName)
        #expect(names[0].lowercased() != names[1].lowercased())
    }

    /// Input order must not change which meeting gets the suffix, or two
    /// meetings swap folders on every sync.
    @Test func itemsAssignTheSameNamesRegardlessOfInputOrder() {
        let date = fixedDate()
        let first = Meeting(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                            title: "Standup", createdAt: date)
        let second = Meeting(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                             title: "Standup", createdAt: date)
        let forward = ICloudDriveBackup.items(for: [first, second])
        let reversed = ICloudDriveBackup.items(for: [second, first])
        #expect(forward.map(\.folderName) == reversed.map(\.folderName))
        #expect(forward.map(\.meetingID) == reversed.map(\.meetingID))
    }

    // MARK: - Identity

    /// iCloud replaces an evicted file with a ".name.icloud" placeholder;
    /// identity must survive that, or the mirror loses track of its folders.
    @Test func folderIdentitySurvivesAnEvictedMarker() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }
        let folder = documents.appendingPathComponent("2026-08-03 09.30 Standup", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("..minute-THE-ID.icloud"))

        #expect(ICloudDriveBackup.meetingID(inFolder: folder) == "THE-ID")
    }

    // MARK: - Mirror

    @Test func mirrorCreatesNotesAndCopiesAudio() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }
        let source = documents.appendingPathComponent("source.m4a")
        try Data("audio-bytes".utf8).write(to: source)

        let entry = item(folderName: "2026-08-03 09.30 Standup", notes: "# Standup", audio: source)
        try ICloudDriveBackup.mirror([entry], into: documents)

        let folder = documents.appendingPathComponent(entry.folderName, isDirectory: true)
        #expect(try String(contentsOf: folder.appendingPathComponent("notes.md"), encoding: .utf8) == "# Standup")
        #expect(try Data(contentsOf: folder.appendingPathComponent("source.m4a")) == Data("audio-bytes".utf8))
        #expect(ICloudDriveBackup.meetingID(inFolder: folder) == entry.meetingID)
    }

    @Test func mirrorRemovesDeletedMeetings() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }

        let entry = item(folderName: "2026-08-03 09.30 Gone")
        try ICloudDriveBackup.mirror([entry], into: documents)
        try ICloudDriveBackup.mirror([], into: documents)

        #expect(!FileManager.default.fileExists(atPath: documents.appendingPathComponent(entry.folderName).path))
    }

    /// The user owns this folder in Files. Nothing without the app's marker
    /// may be deleted — not even a folder named exactly like the app's own.
    @Test func mirrorKeepsUnmarkedFoldersEvenWhenTheyLookLikeMirrors() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }

        let userFolder = documents.appendingPathComponent("2026-08-03 09.30 Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: userFolder, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: userFolder.appendingPathComponent("notes.md"))

        try ICloudDriveBackup.mirror([], into: documents)

        #expect(FileManager.default.fileExists(atPath: userFolder.appendingPathComponent("notes.md").path))
    }

    /// A retitled meeting (or a clock shift from DST or travel) must move
    /// its folder, not delete and re-upload every recording.
    @Test func mirrorRenamesInsteadOfRebuildingWhenTheFolderNameChanges() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }
        let source = documents.appendingPathComponent("source.m4a")
        try Data("audio-bytes".utf8).write(to: source)

        let id = UUID().uuidString
        let before = item(id: id, folderName: "2026-08-03 09.30 Standup", audio: source)
        try ICloudDriveBackup.mirror([before], into: documents)

        // A file only a move preserves — a delete-and-recreate loses it.
        let oldFolder = documents.appendingPathComponent(before.folderName, isDirectory: true)
        try Data("proof".utf8).write(to: oldFolder.appendingPathComponent("moved-with-me.txt"))

        let after = item(id: id, folderName: "2026-08-03 09.30 Sprint Review", audio: source)
        try ICloudDriveBackup.mirror([after], into: documents)

        let newFolder = documents.appendingPathComponent(after.folderName, isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: oldFolder.path))
        #expect(try Data(contentsOf: newFolder.appendingPathComponent("moved-with-me.txt")) == Data("proof".utf8))
        #expect(FileManager.default.fileExists(atPath: newFolder.appendingPathComponent("source.m4a").path))
    }

    /// Deleting a meeting must leave zero bytes behind, including in a
    /// folder another meeting has since taken over.
    @Test func mirrorRemovesAudioThatIsNoLongerTheMeetingsRecording() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }
        let source = documents.appendingPathComponent("new.m4a")
        try Data("new-audio".utf8).write(to: source)

        let entry = item(folderName: "2026-08-03 09.30 Standup", audio: source)
        let folder = documents.appendingPathComponent(entry.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("old-audio".utf8).write(to: folder.appendingPathComponent("old.m4a"))

        try ICloudDriveBackup.mirror([entry], into: documents)

        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("old.m4a").path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("new.m4a").path))
    }

    @Test func mirrorSkipsUnchangedAudioAndRewritesChangedNotes() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }
        let source = documents.appendingPathComponent("source.m4a")
        try Data("12345".utf8).write(to: source)

        let id = UUID().uuidString
        let folderName = "2026-08-03 09.30 Standup"
        try ICloudDriveBackup.mirror([item(id: id, folderName: folderName, notes: "v1", audio: source)], into: documents)

        // Same-size garbage in the destination survives a re-mirror,
        // proving the copy is skipped when sizes match.
        let folder = documents.appendingPathComponent(folderName, isDirectory: true)
        let destination = folder.appendingPathComponent("source.m4a")
        try Data("54321".utf8).write(to: destination)

        try ICloudDriveBackup.mirror([item(id: id, folderName: folderName, notes: "v2", audio: source)], into: documents)

        #expect(try Data(contentsOf: destination) == Data("54321".utf8))
        #expect(try String(contentsOf: folder.appendingPathComponent("notes.md"), encoding: .utf8) == "v2")

        // A size change is copied over.
        try Data("1234567890".utf8).write(to: source)
        try ICloudDriveBackup.mirror([item(id: id, folderName: folderName, notes: "v2", audio: source)], into: documents)
        #expect(try Data(contentsOf: destination) == Data("1234567890".utf8))
    }

    /// One unmirrorable meeting must not stop every meeting after it.
    @Test func mirrorContinuesAfterAnItemFails() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }

        let blockedName = "2026-08-03 09.30 Blocked"
        // A plain file where the folder should go: creating it always fails.
        try Data("not a folder".utf8).write(to: documents.appendingPathComponent(blockedName))

        let good = item(folderName: "2026-08-03 10.00 Fine", notes: "fine")
        try ICloudDriveBackup.mirror([item(folderName: blockedName), good], into: documents)

        let notesURL = documents
            .appendingPathComponent(good.folderName, isDirectory: true)
            .appendingPathComponent("notes.md")
        #expect(try String(contentsOf: notesURL, encoding: .utf8) == "fine")
    }

    /// A failed write must never cost the user the backup they already had.
    @Test func mirrorKeepsThePreviousFolderWhenTheNewOneCannotBeWritten() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }

        let id = UUID().uuidString
        let before = item(id: id, folderName: "2026-08-03 09.30 Standup", notes: "v1")
        try ICloudDriveBackup.mirror([before], into: documents)

        // Block the renamed destination with a plain file.
        let blockedName = "2026-08-03 09.30 Renamed"
        try Data("not a folder".utf8).write(to: documents.appendingPathComponent(blockedName))

        try ICloudDriveBackup.mirror([item(id: id, folderName: blockedName, notes: "v2")], into: documents)

        let previous = documents
            .appendingPathComponent(before.folderName, isDirectory: true)
            .appendingPathComponent("notes.md")
        #expect(try String(contentsOf: previous, encoding: .utf8) == "v1")
    }

    /// iCloud evicts local copies under storage pressure, leaving a
    /// ".name.icloud" placeholder — the audio is still in iCloud Drive, so
    /// re-copying it is pure churn.
    @Test func mirrorLeavesEvictedAudioAlone() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }
        let source = documents.appendingPathComponent("source.m4a")
        try Data("audio".utf8).write(to: source)

        let entry = item(folderName: "2026-08-03 09.30 Standup", audio: source)
        let folder = documents.appendingPathComponent(entry.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent(".source.m4a.icloud"))

        try ICloudDriveBackup.mirror([entry], into: documents)

        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("source.m4a").path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".source.m4a.icloud").path))
    }

    // MARK: - Device folder

    /// Renaming the iPhone must move the mirror, not abandon it — an
    /// abandoned folder keeps deleted meetings' recordings forever.
    @Test func deviceFolderFollowsAnIPhoneRename() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }

        let old = documents.appendingPathComponent("iPhone 3F2A", isDirectory: true)
        try ICloudDriveBackup.mirror([item(folderName: "2026-08-03 09.30 Standup")], into: old)

        let resolved = ICloudDriveBackup.deviceFolderURL(named: "Work iPhone 3F2A", in: documents)

        #expect(resolved.lastPathComponent == "Work iPhone 3F2A")
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: resolved.appendingPathComponent("2026-08-03 09.30 Standup").path))
    }

    /// A user folder that happens to end the same way is not the mirror.
    @Test func deviceFolderLeavesUnrelatedFoldersAlone() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }

        let userFolder = documents.appendingPathComponent("Scans 3F2A", isDirectory: true)
        try FileManager.default.createDirectory(at: userFolder, withIntermediateDirectories: true)

        let resolved = ICloudDriveBackup.deviceFolderURL(named: "iPhone 3F2A", in: documents)

        #expect(resolved.lastPathComponent == "iPhone 3F2A")
        #expect(FileManager.default.fileExists(atPath: userFolder.path))
    }
}
