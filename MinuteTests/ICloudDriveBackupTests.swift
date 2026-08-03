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

    @Test func mirrorFolderNamesAreRecognizedByPattern() {
        #expect(ICloudDriveBackup.isMirrorFolderName("2026-08-03 09.30 Standup"))
        #expect(!ICloudDriveBackup.isMirrorFolderName("My Own Notes"))
        #expect(!ICloudDriveBackup.isMirrorFolderName("2026-08-03 Standup"))
        #expect(!ICloudDriveBackup.isMirrorFolderName("2026-08-03 09.30 "))
    }

    // MARK: - Snapshots

    @Test func itemsUniquifyDuplicateFolderNames() {
        let date = fixedDate()
        let first = Meeting(title: "Standup", createdAt: date)
        let second = Meeting(title: "Standup", createdAt: date)
        let items = ICloudDriveBackup.items(for: [first, second])
        #expect(items[0].folderName != items[1].folderName)
    }

    /// The suffixed name must not land on another meeting's real name.
    @Test func itemsUniquifyWhenASuffixedNameIsAlreadyTaken() {
        let date = fixedDate()
        let meetings = [
            Meeting(title: "Standup", createdAt: date, audioFileName: "a.m4a"),
            Meeting(title: "Standup 2", createdAt: date, audioFileName: "b.m4a"),
            Meeting(title: "Standup", createdAt: date, audioFileName: "c.m4a"),
        ]
        let names = ICloudDriveBackup.items(for: meetings).map(\.folderName)
        #expect(Set(names).count == 3)
    }

    /// The file system is case-insensitive, so names that differ only in
    /// case would land in one folder.
    @Test func itemsTreatNamesDifferingOnlyInCaseAsDuplicates() {
        let date = fixedDate()
        let meetings = [
            Meeting(title: "Standup", createdAt: date, audioFileName: "a.m4a"),
            Meeting(title: "standup", createdAt: date, audioFileName: "b.m4a"),
        ]
        let names = ICloudDriveBackup.items(for: meetings).map(\.folderName)
        #expect(names[0].lowercased() != names[1].lowercased())
    }

    /// Input order must not change which meeting gets the suffix, or two
    /// meetings swap folders on every sync.
    @Test func itemsAssignTheSameNamesRegardlessOfInputOrder() {
        let date = fixedDate()
        let first = Meeting(title: "Standup", createdAt: date, audioFileName: "a.m4a")
        let second = Meeting(title: "Standup", createdAt: date, audioFileName: "b.m4a")
        let forward = ICloudDriveBackup.items(for: [first, second]).map(\.folderName)
        let reversed = ICloudDriveBackup.items(for: [second, first]).map(\.folderName)
        #expect(forward == reversed)
    }

    // MARK: - Mirror

    @Test func mirrorCreatesNotesAndCopiesAudio() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }
        let source = documents.appendingPathComponent("source.m4a")
        try Data("audio-bytes".utf8).write(to: source)

        let item = ICloudDriveBackup.Item(
            folderName: "2026-08-03 09.30 Standup",
            notes: "# Standup",
            audioSourceURL: source
        )
        try ICloudDriveBackup.mirror([item], into: documents)

        let folder = documents.appendingPathComponent(item.folderName, isDirectory: true)
        let notes = try String(contentsOf: folder.appendingPathComponent("notes.md"), encoding: .utf8)
        #expect(notes == "# Standup")
        let audio = try Data(contentsOf: folder.appendingPathComponent("source.m4a"))
        #expect(audio == Data("audio-bytes".utf8))
    }

    @Test func mirrorRemovesDeletedMeetingsButKeepsUserFolders() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }

        let item = ICloudDriveBackup.Item(folderName: "2026-08-03 09.30 Gone", notes: "x", audioSourceURL: nil)
        try ICloudDriveBackup.mirror([item], into: documents)

        // A user folder is kept even when it holds a file called notes.md —
        // deletion keys on the app's own naming, not on file contents.
        let userFolder = documents.appendingPathComponent("My Own Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: userFolder, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: userFolder.appendingPathComponent("notes.md"))

        try ICloudDriveBackup.mirror([], into: documents)

        let itemFolder = documents.appendingPathComponent(item.folderName)
        #expect(!FileManager.default.fileExists(atPath: itemFolder.path))
        #expect(FileManager.default.fileExists(atPath: userFolder.appendingPathComponent("notes.md").path))
    }

    @Test func mirrorSkipsUnchangedAudioAndRewritesChangedNotes() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }
        let source = documents.appendingPathComponent("source.m4a")
        try Data("12345".utf8).write(to: source)

        let folderName = "2026-08-03 09.30 Standup"
        try ICloudDriveBackup.mirror(
            [.init(folderName: folderName, notes: "v1", audioSourceURL: source)],
            into: documents
        )

        // Same-size garbage in the destination survives a re-mirror,
        // proving the copy is skipped when sizes match.
        let destination = documents
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent("source.m4a")
        try Data("54321".utf8).write(to: destination)

        try ICloudDriveBackup.mirror(
            [.init(folderName: folderName, notes: "v2", audioSourceURL: source)],
            into: documents
        )

        #expect(try Data(contentsOf: destination) == Data("54321".utf8))
        let notesURL = documents
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent("notes.md")
        #expect(try String(contentsOf: notesURL, encoding: .utf8) == "v2")

        // A size change is copied over.
        try Data("1234567890".utf8).write(to: source)
        try ICloudDriveBackup.mirror(
            [.init(folderName: folderName, notes: "v2", audioSourceURL: source)],
            into: documents
        )
        #expect(try Data(contentsOf: destination) == Data("1234567890".utf8))
    }

    /// One unmirrorable meeting must not stop every meeting after it.
    @Test func mirrorContinuesAfterAnItemFails() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }

        let blockedName = "2026-08-03 09.30 Blocked"
        // A plain file where the folder should go: creating it always fails.
        try Data("not a folder".utf8).write(to: documents.appendingPathComponent(blockedName))

        let goodName = "2026-08-03 10.00 Fine"
        try ICloudDriveBackup.mirror(
            [
                .init(folderName: blockedName, notes: "blocked", audioSourceURL: nil),
                .init(folderName: goodName, notes: "fine", audioSourceURL: nil),
            ],
            into: documents
        )

        let notesURL = documents
            .appendingPathComponent(goodName, isDirectory: true)
            .appendingPathComponent("notes.md")
        #expect(try String(contentsOf: notesURL, encoding: .utf8) == "fine")
    }

    /// iCloud evicts local copies under storage pressure, leaving a
    /// ".name.icloud" placeholder — the audio is still in iCloud Drive, so
    /// re-copying it is pure churn.
    @Test func mirrorLeavesEvictedAudioAlone() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }
        let source = documents.appendingPathComponent("source.m4a")
        try Data("audio".utf8).write(to: source)

        let folderName = "2026-08-03 09.30 Standup"
        let folder = documents.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent(".source.m4a.icloud"))

        try ICloudDriveBackup.mirror(
            [.init(folderName: folderName, notes: "n", audioSourceURL: source)],
            into: documents
        )

        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("source.m4a").path))
    }
}
