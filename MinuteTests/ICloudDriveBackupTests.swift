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
        audio: URL? = nil,
        audioFileName: String? = nil
    ) -> ICloudDriveBackup.Item {
        .init(
            meetingID: id,
            folderName: folderName,
            notes: notes,
            audioFileName: audioFileName ?? audio?.lastPathComponent,
            audioSourceURL: audio
        )
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
        let old = documents.appendingPathComponent("old.m4a")
        let new = documents.appendingPathComponent("new.m4a")
        try Data("old-audio".utf8).write(to: old)
        try Data("new-audio".utf8).write(to: new)

        let id = UUID().uuidString
        let name = "2026-08-03 09.30 Standup"
        try ICloudDriveBackup.mirror([item(id: id, folderName: name, audio: old)], into: documents)
        try ICloudDriveBackup.mirror([item(id: id, folderName: name, audio: new)], into: documents)

        let folder = documents.appendingPathComponent(name, isDirectory: true)
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

        // Longer than any file system allows, so creating it always fails.
        let impossible = item(folderName: String(repeating: "x", count: 300))
        let good = item(folderName: "2026-08-03 10.00 Fine", notes: "fine")
        try ICloudDriveBackup.mirror([impossible, good], into: documents)

        let notesURL = documents
            .appendingPathComponent(good.folderName, isDirectory: true)
            .appendingPathComponent("notes.md")
        #expect(try String(contentsOf: notesURL, encoding: .utf8) == "fine")
    }

    /// The folder is the user's to organize. A directory they already own
    /// must never be claimed, overwritten, or later swept — the mirror
    /// steps aside to the next name.
    @Test func mirrorStepsAsideForAUserFolderWithTheSameName() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }
        let source = documents.appendingPathComponent("source.m4a")
        try Data("app-audio".utf8).write(to: source)

        let name = "2026-08-03 09.30 Standup"
        let userFolder = documents.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: userFolder, withIntermediateDirectories: true)
        try Data("my notes".utf8).write(to: userFolder.appendingPathComponent("notes.md"))
        try Data("my recording".utf8).write(to: userFolder.appendingPathComponent("mine.m4a"))

        let entry = item(folderName: name, notes: "app notes", audio: source)
        try ICloudDriveBackup.mirror([entry], into: documents)

        // Untouched, marker and all.
        #expect(try String(contentsOf: userFolder.appendingPathComponent("notes.md"), encoding: .utf8) == "my notes")
        #expect(FileManager.default.fileExists(atPath: userFolder.appendingPathComponent("mine.m4a").path))
        #expect(ICloudDriveBackup.meetingID(inFolder: userFolder) == nil)

        let mirrored = documents.appendingPathComponent("\(name) 2", isDirectory: true)
        #expect(try String(contentsOf: mirrored.appendingPathComponent("notes.md"), encoding: .utf8) == "app notes")
        #expect(ICloudDriveBackup.meetingID(inFolder: mirrored) == entry.meetingID)
    }

    /// Two meetings that trade titles each sit on the other's target; the
    /// contents must follow their own marker, not land in the other's folder.
    @Test func mirrorHandlesTwoMeetingsSwappingNames() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }

        let alpha = "2026-08-03 09.30 Alpha"
        let beta = "2026-08-03 09.30 Beta"
        let first = UUID().uuidString
        let second = UUID().uuidString
        try ICloudDriveBackup.mirror(
            [
                item(id: first, folderName: alpha, notes: "first"),
                item(id: second, folderName: beta, notes: "second"),
            ],
            into: documents
        )

        try ICloudDriveBackup.mirror(
            [
                item(id: first, folderName: beta, notes: "first"),
                item(id: second, folderName: alpha, notes: "second"),
            ],
            into: documents
        )

        let betaFolder = documents.appendingPathComponent(beta, isDirectory: true)
        let alphaFolder = documents.appendingPathComponent(alpha, isDirectory: true)
        #expect(ICloudDriveBackup.meetingID(inFolder: betaFolder) == first)
        #expect(ICloudDriveBackup.meetingID(inFolder: alphaFolder) == second)
        #expect(try String(contentsOf: betaFolder.appendingPathComponent("notes.md"), encoding: .utf8) == "first")
        #expect(try String(contentsOf: alphaFolder.appendingPathComponent("notes.md"), encoding: .utf8) == "second")
    }

    /// An unreadable local recording must not take the mirrored copy —
    /// possibly the last one left — down with it.
    @Test func mirrorKeepsMirroredAudioWhenTheLocalFileIsUnreadable() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }
        let source = documents.appendingPathComponent("rec.m4a")
        try Data("recording".utf8).write(to: source)

        let id = UUID().uuidString
        let name = "2026-08-03 09.30 Standup"
        try ICloudDriveBackup.mirror([item(id: id, folderName: name, audio: source)], into: documents)

        // The meeting still names a recording; the local file just can't be
        // resolved this round.
        try ICloudDriveBackup.mirror(
            [item(id: id, folderName: name, audio: nil, audioFileName: "rec.m4a")],
            into: documents
        )

        let mirrored = documents
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("rec.m4a")
        #expect(try Data(contentsOf: mirrored) == Data("recording".utf8))
    }

    /// When the meeting itself has no recording, the mirror must not keep
    /// one — deleting has to leave zero bytes behind.
    @Test func mirrorRemovesAudioWhenTheMeetingHasNoRecording() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }

        let source = documents.appendingPathComponent("old.m4a")
        try Data("old".utf8).write(to: source)

        let id = UUID().uuidString
        let name = "2026-08-03 09.30 Standup"
        try ICloudDriveBackup.mirror([item(id: id, folderName: name, audio: source)], into: documents)

        // The meeting no longer has any recording at all.
        try ICloudDriveBackup.mirror(
            [item(id: id, folderName: name, audio: nil, audioFileName: nil)],
            into: documents
        )

        let folder = documents.appendingPathComponent(name, isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("old.m4a").path))
    }

    /// A failed write must never cost the user the backup they already had,
    /// and must never hide it under an internal name either.
    @Test func mirrorKeepsThePreviousFolderWhenTheNewOneCannotBeWritten() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }

        let id = UUID().uuidString
        let before = item(id: id, folderName: "2026-08-03 09.30 Standup", notes: "v1")
        try ICloudDriveBackup.mirror([before], into: documents)
        let folder = documents.appendingPathComponent(before.folderName, isDirectory: true)
        try Data("proof".utf8).write(to: folder.appendingPathComponent("sentinel.txt"))

        // Renaming to a name no file system can create.
        try ICloudDriveBackup.mirror(
            [item(id: id, folderName: String(repeating: "x", count: 300), notes: "v2")],
            into: documents
        )

        #expect(try String(contentsOf: folder.appendingPathComponent("notes.md"), encoding: .utf8) == "v1")
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("sentinel.txt").path))
    }

    /// iCloud evicts local copies under storage pressure, leaving a
    /// ".name.icloud" placeholder — the audio is still in iCloud Drive, so
    /// re-copying it is pure churn.
    @Test func mirrorLeavesEvictedAudioAlone() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }
        let source = documents.appendingPathComponent("source.m4a")
        try Data("audio".utf8).write(to: source)

        let id = UUID().uuidString
        let name = "2026-08-03 09.30 Standup"
        try ICloudDriveBackup.mirror([item(id: id, folderName: name, audio: source)], into: documents)

        // iCloud reclaims the space: the copy becomes a placeholder.
        let folder = documents.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("source.m4a"))
        try Data().write(to: folder.appendingPathComponent(".source.m4a.icloud"))

        try ICloudDriveBackup.mirror([item(id: id, folderName: name, audio: source)], into: documents)

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

    /// Restoring a backup onto a replacement iPhone clones the suffix, and
    /// two phones in one folder would sweep each other's meetings.
    @Test func deviceIdentityChangesOnlyWhenTheVendorIDIsKnownAndDifferent() {
        #expect(ICloudDriveBackup.deviceIdentityChanged(stored: "device-a", current: "device-b"))
        #expect(ICloudDriveBackup.deviceIdentityChanged(stored: nil, current: "device-a"))
        #expect(!ICloudDriveBackup.deviceIdentityChanged(stored: "device-a", current: "device-a"))
        // Unknown before the first unlock — never churn on a guess.
        #expect(!ICloudDriveBackup.deviceIdentityChanged(stored: "device-a", current: nil))
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
