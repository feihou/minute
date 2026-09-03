import Foundation
import SwiftData
import Testing
@testable import Minute

/// Lets a fixed number of `shouldContinue` checks pass, then refuses —
/// standing in for the user switching the toggle off mid-sync.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int

    init(allowing remaining: Int) { self.remaining = remaining }

    func check() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard remaining > 0 else { return false }
        remaining -= 1
        return true
    }
}

/// Allows every check and runs a side effect from the given check onward —
/// standing in for the user deleting a meeting while the mirror is still
/// copying an earlier one.
private final class Trip: @unchecked Sendable {
    private let lock = NSLock()
    private var checks = 0
    private let from: Int
    private let effect: @Sendable () -> Void

    init(from: Int, effect: @escaping @Sendable () -> Void) {
        self.from = from
        self.effect = effect
    }

    func check() -> Bool {
        lock.lock()
        checks += 1
        let fire = checks >= from
        lock.unlock()
        if fire { effect() }
        return true
    }
}

private actor CancellationProbe {
    private var stopped = false

    func markStopped() { stopped = true }
    func didStop() -> Bool { stopped }
}

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

    /// Recordings are always UUID-named, the way MeetingStore names them.
    private func recording(in directory: URL, bytes: String = "audio") throws -> URL {
        let url = directory.appendingPathComponent(MeetingStore.newAudioFileName())
        try Data(bytes.utf8).write(to: url)
        return url
    }

    private func device(named name: String, identity: String = UUID().uuidString) -> ICloudDriveBackup.Device {
        .init(displayName: name, identity: identity)
    }

    /// The root this device mirrors into; duplicates follow it in the list.
    private func deviceFolder(_ device: ICloudDriveBackup.Device, in documents: URL) throws -> URL {
        try ICloudDriveBackup.deviceFolderURLs(for: device, in: documents)[0]
    }

    private func visibleNames(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }

    /// Every entry, hidden ones included. A folder the mirror parks carries a
    /// dot-prefixed staging name, so "nothing of this meeting is here" is only
    /// proved by looking past what the Files app shows.
    private func allNames(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
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

    /// Only the exact marker the mirror writes may confer ownership: a file
    /// the user names "minute-agenda" must not make their folder app-owned.
    @Test func onlyTheExactMarkerNameWithAUUIDIsAMarker() {
        let id = UUID().uuidString
        #expect(ICloudDriveBackup.meetingID(fromMarkerName: ".minute-\(id)") == id)
        // iCloud evicted the marker itself.
        #expect(ICloudDriveBackup.meetingID(fromMarkerName: "..minute-\(id).icloud") == id)

        #expect(ICloudDriveBackup.meetingID(fromMarkerName: "minute-\(id)") == nil)
        #expect(ICloudDriveBackup.meetingID(fromMarkerName: ".minute-agenda") == nil)
        #expect(ICloudDriveBackup.meetingID(fromMarkerName: "minute-agenda") == nil)
        #expect(ICloudDriveBackup.meetingID(fromMarkerName: "notes.md") == nil)
    }

    @Test func folderIdentitySurvivesAnEvictedMarker() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }
        let id = UUID().uuidString
        let folder = documents.appendingPathComponent("2026-08-03 09.30 Standup", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("..minute-\(id).icloud"))

        #expect(ICloudDriveBackup.meetingID(inFolder: folder) == id)
    }

    /// Restoring a backup onto a replacement iPhone clones the identity, and
    /// two phones in one folder would sweep each other's meetings.
    @Test func deviceIdentityChangesOnlyWhenTheVendorIDIsKnownAndDifferent() {
        #expect(ICloudDriveBackup.deviceIdentityChanged(stored: "device-a", current: "device-b"))
        #expect(ICloudDriveBackup.deviceIdentityChanged(stored: nil, current: "device-a"))
        #expect(!ICloudDriveBackup.deviceIdentityChanged(stored: "device-a", current: "device-a"))
        // Unknown before the first unlock — never churn on a guess.
        #expect(!ICloudDriveBackup.deviceIdentityChanged(stored: "device-a", current: nil))
    }

    // MARK: - Mirror

    @Test func mirrorCreatesNotesAndCopiesAudio() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }
        let source = try recording(in: documents, bytes: "audio-bytes")

        let entry = item(folderName: "2026-08-03 09.30 Standup", notes: "# Standup", audio: source)
        try ICloudDriveBackup.mirror([entry], into: documents)

        let folder = documents.appendingPathComponent(entry.folderName, isDirectory: true)
        #expect(try String(contentsOf: folder.appendingPathComponent("notes.md"), encoding: .utf8) == "# Standup")
        #expect(try Data(contentsOf: folder.appendingPathComponent(source.lastPathComponent)) == Data("audio-bytes".utf8))
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

    /// The toggle-on sync snapshots every meeting on the main actor and copies
    /// them on a Task nothing cancels, so a meeting deleted mid-run is still in
    /// the snapshot when the loop reaches it — and notes.md carries its whole
    /// transcript in memory.
    @Test func mirrorSkipsAndRemovesAMeetingDeletedSinceTheSnapshot() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }

        let deletedID = UUID()
        let deleted = item(id: deletedID.uuidString, folderName: "2026-08-03 09.30 Deleted", notes: "# secret transcript")
        let kept = item(folderName: "2026-08-03 10.00 Kept", notes: "# kept")
        try ICloudDriveBackup.mirror([deleted, kept], into: documents)
        #expect(FileManager.default.fileExists(atPath: documents.appendingPathComponent(deleted.folderName).path))

        // The user deletes that meeting while this snapshot is still being
        // mirrored.
        ICloudDriveBackup.noteMeetingDeleted(deletedID)
        try ICloudDriveBackup.mirror([deleted, kept], into: documents)

        // Its folder goes with it, and the rest of the snapshot still lands.
        #expect(!FileManager.default.fileExists(atPath: documents.appendingPathComponent(deleted.folderName).path))
        let keptFolder = documents.appendingPathComponent(kept.folderName, isDirectory: true)
        #expect(try String(contentsOf: keptFolder.appendingPathComponent("notes.md"), encoding: .utf8) == "# kept")
    }

    @Test func mirrorNeverWritesADeletedMeetingsNotesInTheFirstPlace() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }

        let deletedID = UUID()
        let entry = item(id: deletedID.uuidString, folderName: "2026-08-03 09.30 Deleted", notes: "# secret transcript")
        ICloudDriveBackup.noteMeetingDeleted(deletedID)

        try ICloudDriveBackup.mirror([entry], into: documents)

        // Nothing was ever created: a deleted meeting's transcript must not
        // reach iCloud Drive even for the seconds until the next sync, and
        // not under a hidden name either.
        #expect(try allNames(in: documents).isEmpty)
    }

    /// The case the snapshot cannot see: the delete lands after `mirror` has
    /// already started, while the loop is still on an earlier meeting.
    @Test func mirrorSkipsAMeetingDeletedWhileTheRunIsStillCopying() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }

        let deletedID = UUID()
        let first = item(folderName: "2026-08-03 09.30 Kept", notes: "# kept")
        let second = item(id: deletedID.uuidString, folderName: "2026-08-03 10.00 Deleted", notes: "# secret transcript")

        // From the second shouldContinue check on — the first is the one
        // `mirror` makes before it touches a folder, so this deletion is
        // unknowable to anything the run read on entry. On a real library
        // those checks are minutes apart.
        let trip = Trip(from: 2) { ICloudDriveBackup.noteMeetingDeleted(deletedID) }
        let outcome = try ICloudDriveBackup.mirror([first, second], into: documents, shouldContinue: { trip.check() })

        #expect(try visibleNames(in: documents) == [first.folderName])
        // Skipping a meeting the user deleted is the run doing its job, not
        // failing at it: an incomplete verdict here would warn about a backup
        // that is exactly as complete as it should be.
        #expect(outcome == .complete)
    }

    /// The window the pre-write check cannot see: the delete lands while
    /// `write` is already copying this meeting's recording, which is where a
    /// run spends nearly all of its time on a real library. The folder stays in
    /// `chosen`, and `chosen` is what the stale-folder sweep judges by — so
    /// without a recheck nothing later in the run takes it back, and the run
    /// reports success over a deleted meeting's transcript and audio.
    @Test func mirrorTakesBackAMeetingDeletedWhileItsRecordingWasCopying() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }

        let deletedID = UUID()
        // A noted deletion lives for the rest of the process, so hand it back
        // however this test ends — the way MeetingStore does when the delete
        // turns out not to have committed.
        defer { ICloudDriveBackup.noteMeetingDeleteFailed(deletedID) }

        let deletedName = "2026-08-03 09.30 Deleted"
        let keptName = "2026-08-03 10.00 Kept"
        let kept = item(folderName: keptName, notes: "# kept")
        let firstTake = try recording(in: documents, bytes: "first take")
        let deleted = item(
            id: deletedID.uuidString,
            folderName: deletedName,
            notes: "# secret transcript",
            audio: firstTake
        )
        try ICloudDriveBackup.mirror([deleted, kept], into: documents)

        // A re-recording gives the second run something to copy: unchanged
        // notes and unchanged audio are both skipped, and the run would never
        // reach the check this test trips.
        let secondTake = try recording(in: documents, bytes: "second take")
        let retaken = item(
            id: deletedID.uuidString,
            folderName: deletedName,
            notes: "# secret transcript",
            audio: secondTake
        )
        // Checks: the one before any folder is touched, one per meeting in the
        // parking pass, the item loop's own — and then the fifth, inside
        // `write`, with the recording's bytes already on disk.
        let trip = Trip(from: 5) { ICloudDriveBackup.noteMeetingDeleted(deletedID) }
        let outcome = try ICloudDriveBackup.mirror(
            [retaken, kept],
            into: documents,
            shouldContinue: { trip.check() }
        )

        // Nothing of that meeting is left: not the folder an earlier run gave
        // it, and not the recording that had just landed in it.
        #expect(!FileManager.default.fileExists(atPath: documents.appendingPathComponent(deletedName).path))
        // Taking back a meeting the user deleted is the run doing its job, not
        // failing at it.
        #expect(outcome == .complete)
        // And it carried on to the meeting after it.
        let keptFolder = documents.appendingPathComponent(keptName, isDirectory: true)
        #expect(try String(contentsOf: keptFolder.appendingPathComponent("notes.md"), encoding: .utf8) == "# kept")
    }

    /// Deleting a meeting is not a one-way door: `MeetingStore.delete` puts
    /// the row back and reports failure when the save throws, and the user is
    /// told the delete did not happen. That meeting still exists, so the note
    /// has to be revocable — otherwise the mirror goes on skipping it for the
    /// life of the process and the folder this run removed never comes back.
    @Test func mirrorBacksUpAgainAfterADeleteIsRolledBack() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }

        let meetingID = UUID()
        let entry = item(id: meetingID.uuidString, folderName: "2026-08-03 09.30 Kept", notes: "# kept")
        try ICloudDriveBackup.mirror([entry], into: documents)

        // The delete is noted, the mirror in flight takes the folder with it,
        // and only then does the save throw and the meeting come back.
        ICloudDriveBackup.noteMeetingDeleted(meetingID)
        try ICloudDriveBackup.mirror([entry], into: documents)
        #expect(try allNames(in: documents).isEmpty)

        ICloudDriveBackup.noteMeetingDeleteFailed(meetingID)
        try ICloudDriveBackup.mirror([entry], into: documents)

        let folder = documents.appendingPathComponent(entry.folderName, isDirectory: true)
        #expect(try String(contentsOf: folder.appendingPathComponent("notes.md"), encoding: .utf8) == "# kept")
    }

    /// One delete that failed says nothing about the others a long mirror run
    /// was told about: forgetting all of them would put every one of those
    /// transcripts back into iCloud Drive.
    @Test func aRolledBackDeleteClearsOnlyTheMeetingItNames() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }

        let restoredID = UUID()
        let goneID = UUID()
        let restored = item(id: restoredID.uuidString, folderName: "2026-08-03 09.30 Restored", notes: "# restored")
        let gone = item(id: goneID.uuidString, folderName: "2026-08-03 10.00 Gone", notes: "# secret transcript")

        ICloudDriveBackup.noteMeetingDeleted(restoredID)
        ICloudDriveBackup.noteMeetingDeleted(goneID)
        ICloudDriveBackup.noteMeetingDeleteFailed(restoredID)

        try ICloudDriveBackup.mirror([restored, gone], into: documents)

        #expect(try allNames(in: documents) == [restored.folderName])
    }

    /// Two meetings that trade titles make the mirror park one folder under a
    /// hidden staging name so the other can take that name. When the parked
    /// one belongs to the meeting the user just deleted, the staged folder has
    /// to go — the run's own un-park cleanup would otherwise put a deleted
    /// meeting's notes back into view under a free name.
    @Test func mirrorRemovesADeletedMeetingsFolderEvenWhileItIsParked() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }

        let deletedID = UUID()
        let keptID = UUID()
        let deletedName = "2026-08-03 09.30 One"
        let keptName = "2026-08-03 10.00 Two"
        try ICloudDriveBackup.mirror([
            item(id: deletedID.uuidString, folderName: deletedName, notes: "# secret transcript"),
            item(id: keptID.uuidString, folderName: keptName, notes: "# kept"),
        ], into: documents)

        // The user swaps the two titles, then deletes the first meeting while
        // this snapshot is still being mirrored.
        ICloudDriveBackup.noteMeetingDeleted(deletedID)
        let outcome = try ICloudDriveBackup.mirror([
            item(id: deletedID.uuidString, folderName: keptName, notes: "# secret transcript"),
            item(id: keptID.uuidString, folderName: deletedName, notes: "# kept"),
        ], into: documents)

        // Nothing staged left behind, and the meeting that survives holds the
        // name it asked for. Complete, not incomplete: the folder this run
        // moved to staging is not also a removal that failed.
        #expect(try allNames(in: documents) == [deletedName])
        #expect(outcome == .complete)
        let folder = documents.appendingPathComponent(deletedName, isDirectory: true)
        #expect(try String(contentsOf: folder.appendingPathComponent("notes.md"), encoding: .utf8) == "# kept")
    }

    /// The user owns this folder in Files. Nothing without the app's marker
    /// may be deleted — not even a folder named exactly like the app's own,
    /// nor one holding a file that merely looks like a marker.
    @Test func mirrorKeepsUnmarkedFoldersEvenWhenTheyLookLikeMirrors() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }

        let userFolder = documents.appendingPathComponent("2026-08-03 09.30 Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: userFolder, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: userFolder.appendingPathComponent("notes.md"))
        try Data("agenda".utf8).write(to: userFolder.appendingPathComponent("minute-agenda"))

        try ICloudDriveBackup.mirror([], into: documents)

        #expect(try String(contentsOf: userFolder.appendingPathComponent("notes.md"), encoding: .utf8) == "mine")
        #expect(FileManager.default.fileExists(atPath: userFolder.appendingPathComponent("minute-agenda").path))
    }

    /// The folder is the user's to organize. A directory they already own
    /// must never be claimed, overwritten, or later swept — the mirror
    /// steps aside to the next name.
    @Test func mirrorStepsAsideForAUserFolderWithTheSameName() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }
        let source = try recording(in: documents, bytes: "app-audio")

        let name = "2026-08-03 09.30 Standup"
        let userFolder = documents.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: userFolder, withIntermediateDirectories: true)
        try Data("my notes".utf8).write(to: userFolder.appendingPathComponent("notes.md"))

        let entry = item(folderName: name, notes: "app notes", audio: source)
        try ICloudDriveBackup.mirror([entry], into: documents)

        #expect(try String(contentsOf: userFolder.appendingPathComponent("notes.md"), encoding: .utf8) == "my notes")
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

    /// A retitled meeting (or a clock shift from DST or travel) must move
    /// its folder, not delete and re-upload every recording.
    @Test func mirrorRenamesInsteadOfRebuildingWhenTheFolderNameChanges() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }
        let source = try recording(in: documents)

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
        #expect(FileManager.default.fileExists(atPath: newFolder.appendingPathComponent(source.lastPathComponent).path))
    }

    /// Deleting a meeting must leave zero bytes behind, including in a
    /// folder whose recording was replaced.
    @Test func mirrorRemovesAudioThatIsNoLongerTheMeetingsRecording() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }
        let old = try recording(in: documents, bytes: "old-audio")
        let new = try recording(in: documents, bytes: "new-audio")

        let id = UUID().uuidString
        let name = "2026-08-03 09.30 Standup"
        try ICloudDriveBackup.mirror([item(id: id, folderName: name, audio: old)], into: documents)
        try ICloudDriveBackup.mirror([item(id: id, folderName: name, audio: new)], into: documents)

        let folder = documents.appendingPathComponent(name, isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(old.lastPathComponent).path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(new.lastPathComponent).path))
    }

    /// Audio the user dropped into a meeting folder is theirs. Only
    /// recordings the mirror wrote — always UUID-named — may be swept.
    @Test func mirrorKeepsAudioTheUserAddedToAMeetingFolder() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }
        let source = try recording(in: documents)

        let id = UUID().uuidString
        let name = "2026-08-03 09.30 Standup"
        try ICloudDriveBackup.mirror([item(id: id, folderName: name, audio: source)], into: documents)

        let folder = documents.appendingPathComponent(name, isDirectory: true)
        try Data("their tape".utf8).write(to: folder.appendingPathComponent("supplemental.mp3"))

        try ICloudDriveBackup.mirror([item(id: id, folderName: name, audio: source)], into: documents)

        #expect(try Data(contentsOf: folder.appendingPathComponent("supplemental.mp3")) == Data("their tape".utf8))
    }

    /// An unreadable local recording must not take the mirrored copy —
    /// possibly the last one left — down with it.
    @Test func mirrorKeepsMirroredAudioWhenTheLocalFileIsUnreadable() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }
        let source = try recording(in: documents, bytes: "recording")

        let id = UUID().uuidString
        let name = "2026-08-03 09.30 Standup"
        try ICloudDriveBackup.mirror([item(id: id, folderName: name, audio: source)], into: documents)

        // The meeting still names a recording; the local file just can't be
        // resolved this round.
        try ICloudDriveBackup.mirror(
            [item(id: id, folderName: name, audio: nil, audioFileName: source.lastPathComponent)],
            into: documents
        )

        let mirrored = documents
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent(source.lastPathComponent)
        #expect(try Data(contentsOf: mirrored) == Data("recording".utf8))
    }

    /// When the meeting itself has no recording, the mirror must not keep
    /// one — deleting has to leave zero bytes behind.
    @Test func mirrorRemovesAudioWhenTheMeetingHasNoRecording() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }
        let source = try recording(in: documents)

        let id = UUID().uuidString
        let name = "2026-08-03 09.30 Standup"
        try ICloudDriveBackup.mirror([item(id: id, folderName: name, audio: source)], into: documents)
        try ICloudDriveBackup.mirror(
            [item(id: id, folderName: name, audio: nil, audioFileName: nil)],
            into: documents
        )

        let folder = documents.appendingPathComponent(name, isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(source.lastPathComponent).path))
    }

    /// A duplicated folder carries the same marker; left alone it would be
    /// invisible to every later sync and outlive the meeting it holds.
    @Test func mirrorSweepsDuplicateFoldersForTheSameMeeting() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }

        let id = UUID().uuidString
        let name = "2026-08-03 09.30 Standup"
        try ICloudDriveBackup.mirror([item(id: id, folderName: name, notes: "v1")], into: documents)

        // As if duplicated in Files, or left by an iCloud conflict.
        let original = documents.appendingPathComponent(name, isDirectory: true)
        let duplicate = documents.appendingPathComponent("\(name) copy", isDirectory: true)
        try FileManager.default.copyItem(at: original, to: duplicate)

        try ICloudDriveBackup.mirror([item(id: id, folderName: name, notes: "v1")], into: documents)

        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(!FileManager.default.fileExists(atPath: duplicate.path))
    }

    @Test func mirrorSkipsUnchangedAudioAndRewritesChangedNotes() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }
        let source = try recording(in: documents, bytes: "12345")

        let id = UUID().uuidString
        let folderName = "2026-08-03 09.30 Standup"
        try ICloudDriveBackup.mirror([item(id: id, folderName: folderName, notes: "v1", audio: source)], into: documents)

        // Same-size garbage in the destination survives a re-mirror,
        // proving the copy is skipped when sizes match.
        let folder = documents.appendingPathComponent(folderName, isDirectory: true)
        let destination = folder.appendingPathComponent(source.lastPathComponent)
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
    /// Recordings are written once, so "evicted means current" is sound for
    /// audio. Notes are not: the user can rename a meeting or edit its summary
    /// at any time. Deciding from the evicted placeholder alone would strand
    /// every later edit, so the fingerprint lives in a marker's NAME, which
    /// eviction cannot take away.
    @Test func mirrorRewritesEditedNotesEvenWhenTheMirroredCopyIsEvicted() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }
        let id = UUID().uuidString
        let name = "2026-08-03 09.30 Standup"
        try ICloudDriveBackup.mirror([item(id: id, folderName: name, notes: "v1")], into: documents)

        // iCloud reclaims the space: notes.md becomes a placeholder.
        let folder = documents.appendingPathComponent(name, isDirectory: true)
        let notesURL = folder.appendingPathComponent("notes.md")
        try FileManager.default.removeItem(at: notesURL)
        try Data().write(to: folder.appendingPathComponent(".notes.md.icloud"))

        try ICloudDriveBackup.mirror([item(id: id, folderName: name, notes: "v2")], into: documents)

        #expect(try String(contentsOf: notesURL, encoding: .utf8) == "v2")
    }

    /// The other half of the same contract: an evicted but *unchanged*
    /// notes.md must not be rewritten, or every mirrored meeting re-uploads
    /// its whole transcript on every sync, forever.
    @Test func mirrorLeavesEvictedUnchangedNotesAlone() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }
        let id = UUID().uuidString
        let name = "2026-08-03 09.30 Standup"
        try ICloudDriveBackup.mirror([item(id: id, folderName: name, notes: "v1")], into: documents)

        let folder = documents.appendingPathComponent(name, isDirectory: true)
        let notesURL = folder.appendingPathComponent("notes.md")
        try FileManager.default.removeItem(at: notesURL)
        let placeholder = folder.appendingPathComponent(".notes.md.icloud")
        try Data().write(to: placeholder)

        try ICloudDriveBackup.mirror([item(id: id, folderName: name, notes: "v1")], into: documents)

        #expect(!FileManager.default.fileExists(atPath: notesURL.path))
        #expect(FileManager.default.fileExists(atPath: placeholder.path))
    }

    /// The fingerprint marker says "these notes are already mirrored", but it
    /// is only trustworthy while the notes it describes are actually there.
    /// Deleted in Files or lost to an iCloud conflict, the folder would
    /// otherwise keep its marker and never get its transcript back.
    @Test func mirrorRestoresNotesDeletedOutFromUnderTheirMarker() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }
        let id = UUID().uuidString
        let name = "2026-08-03 09.30 Standup"
        try ICloudDriveBackup.mirror([item(id: id, folderName: name, notes: "v1")], into: documents)

        // Gone entirely — no file, no eviction placeholder, marker intact.
        let folder = documents.appendingPathComponent(name, isDirectory: true)
        let notesURL = folder.appendingPathComponent("notes.md")
        try FileManager.default.removeItem(at: notesURL)

        try ICloudDriveBackup.mirror([item(id: id, folderName: name, notes: "v1")], into: documents)

        #expect(try String(contentsOf: notesURL, encoding: .utf8) == "v1")
    }

    @Test func mirrorLeavesEvictedAudioAlone() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }
        let source = try recording(in: documents)

        let id = UUID().uuidString
        let name = "2026-08-03 09.30 Standup"
        try ICloudDriveBackup.mirror([item(id: id, folderName: name, audio: source)], into: documents)

        // iCloud reclaims the space: the copy becomes a placeholder.
        let folder = documents.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.removeItem(at: folder.appendingPathComponent(source.lastPathComponent))
        let placeholder = folder.appendingPathComponent(".\(source.lastPathComponent).icloud")
        try Data().write(to: placeholder)

        try ICloudDriveBackup.mirror([item(id: id, folderName: name, audio: source)], into: documents)

        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(source.lastPathComponent).path))
        #expect(FileManager.default.fileExists(atPath: placeholder.path))
    }

    /// Opting out mid-sync has to mean something: a copy that finished
    /// landing after the user said stop must not stay in iCloud.
    @Test func mirrorDiscardsACopyThatFinishedAfterTheUserOptedOut() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }
        let source = try recording(in: documents)

        let name = "2026-08-03 09.30 Standup"
        // Passes the start, parking, write and notes checks, then the user
        // flips the toggle while the copy is running.
        let gate = Gate(allowing: 4)
        try ICloudDriveBackup.mirror(
            [item(folderName: name, audio: source)],
            into: documents,
            shouldContinue: { gate.check() }
        )

        let folder = documents.appendingPathComponent(name, isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(source.lastPathComponent).path))
        // The notes had already landed while the setting was still on.
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("notes.md").path))
    }

    /// notes.md holds the transcript and lands in one synchronous write; an
    /// opt-out during it must not leave the transcript in iCloud, because
    /// no later sync will clean it up.
    @Test func mirrorTakesBackNotesWrittenAfterTheUserOptedOut() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }

        let name = "2026-08-03 09.30 Standup"
        // Passes the start, parking and write checks, then the toggle is off
        // while notes.md is being written.
        let gate = Gate(allowing: 3)
        try ICloudDriveBackup.mirror(
            [item(folderName: name, notes: "the whole transcript")],
            into: documents,
            shouldContinue: { gate.check() }
        )

        #expect(!FileManager.default.fileExists(atPath: documents.appendingPathComponent(name).path))
    }

    /// Deleting a meeting removes what the mirror wrote, but a file the
    /// user added to the folder is not the meeting.
    /// The notes fingerprint marker is recognised by name, so the suffix has to
    /// be validated the way a meeting id is validated as a UUID. Otherwise a
    /// hidden file the user happens to name `.minute-notes-agenda` looks
    /// app-owned and gets swept along with the meeting.
    @Test func mirrorKeepsHiddenUserFilesThatOnlyLookLikeNotesMarkers() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }
        let name = "2026-08-03 09.30 Standup"
        try ICloudDriveBackup.mirror([item(folderName: name, notes: "v1")], into: documents)

        let folder = documents.appendingPathComponent(name, isDirectory: true)
        // Not a fingerprint: not 16 lowercase hex characters.
        let decoy = folder.appendingPathComponent(".minute-notes-agenda")
        try Data("mine".utf8).write(to: decoy)

        try ICloudDriveBackup.mirror([], into: documents)

        #expect(try Data(contentsOf: decoy) == Data("mine".utf8))
        // The app's own notes and marker still go.
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("notes.md").path))
        #expect(ICloudDriveBackup.meetingID(inFolder: folder) == nil)
    }

    @Test func mirrorKeepsUserFilesWhenTheMeetingIsDeleted() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }
        let source = try recording(in: documents)

        let name = "2026-08-03 09.30 Standup"
        try ICloudDriveBackup.mirror([item(folderName: name, audio: source)], into: documents)

        let folder = documents.appendingPathComponent(name, isDirectory: true)
        try Data("their tape".utf8).write(to: folder.appendingPathComponent("supplemental.mp3"))
        try Data("their notes".utf8).write(to: folder.appendingPathComponent("my-thoughts.txt"))

        try ICloudDriveBackup.mirror([], into: documents)

        // Everything the app wrote is gone.
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("notes.md").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(source.lastPathComponent).path))
        #expect(ICloudDriveBackup.meetingID(inFolder: folder) == nil)
        // Everything they wrote is not.
        #expect(try Data(contentsOf: folder.appendingPathComponent("supplemental.mp3")) == Data("their tape".utf8))
        #expect(try Data(contentsOf: folder.appendingPathComponent("my-thoughts.txt")) == Data("their notes".utf8))
    }

    @Test func mirrorWritesNothingWhenAlreadyStopped() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }

        let entry = item(folderName: "2026-08-03 09.30 Standup")
        try ICloudDriveBackup.mirror([entry], into: documents, shouldContinue: { false })

        #expect(!FileManager.default.fileExists(atPath: documents.appendingPathComponent(entry.folderName).path))
    }

    // MARK: - Device folder

    /// Renaming the iPhone must move the mirror, not abandon it — an
    /// abandoned folder keeps deleted meetings' recordings forever.
    @Test func deviceFolderFollowsAnIPhoneRename() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }

        let identity = UUID().uuidString
        let before = device(named: "iPhone", identity: identity)
        let folder = try deviceFolder(before, in: documents)
        try ICloudDriveBackup.mirror([item(folderName: "2026-08-03 09.30 Standup")], into: folder)

        let after = device(named: "Work iPhone", identity: identity)
        let moved = try deviceFolder(after, in: documents)

        #expect(moved.lastPathComponent == "Work iPhone")
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(FileManager.default.fileExists(atPath: moved.appendingPathComponent("2026-08-03 09.30 Standup").path))
    }

    /// Identity is the marker, not the name: a user folder that happens to
    /// share the display name is stepped around, never adopted.
    @Test func deviceFolderStepsAsideForAUserFolderOfTheSameName() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }

        let userFolder = documents.appendingPathComponent("iPhone", isDirectory: true)
        try FileManager.default.createDirectory(at: userFolder, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: userFolder.appendingPathComponent("keep.txt"))

        let resolved = try deviceFolder(device(named: "iPhone"), in: documents)

        #expect(resolved.lastPathComponent == "iPhone 2")
        #expect(FileManager.default.fileExists(atPath: userFolder.appendingPathComponent("keep.txt").path))
    }

    /// Two iPhones sharing a name (or a restored settings clone) must never
    /// share a folder — one would sweep the other's meetings.
    @Test func devicesWithDifferentIdentitiesNeverShareAFolder() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }

        let first = try deviceFolder(device(named: "iPhone"), in: documents)
        let second = try deviceFolder(device(named: "iPhone"), in: documents)

        #expect(first != second)
    }

    /// The same device resolves to the same folder every time.
    @Test func deviceFolderIsStableAcrossSyncs() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }

        let phone = device(named: "iPhone")
        let first = try deviceFolder(phone, in: documents)
        let second = try deviceFolder(phone, in: documents)

        #expect(first == second)
    }

    /// A device name is user-typed: a slash would make the marker land a
    /// level below where every later scan looks, so each sync would create
    /// another folder and deletions would only ever reach the newest.
    @Test func deviceDisplayNameCannotIntroduceANestedPath() {
        let identity = UUID().uuidString
        let tail = String(identity.prefix(4))

        let slashed = ICloudDriveBackup.displayName(forDeviceNamed: "Fei/Work iPhone", identity: identity)
        #expect(!slashed.contains("/"))
        #expect(slashed == "Fei Work iPhone \(tail)")

        let long = ICloudDriveBackup.displayName(
            forDeviceNamed: String(repeating: "名", count: 200),
            identity: identity
        )
        #expect(long.utf8.count <= 255)

        #expect(ICloudDriveBackup.displayName(forDeviceNamed: "///", identity: identity) == "iPhone \(tail)")
    }

    /// An iCloud conflict can leave a second root with the same device
    /// marker. Mirroring only one would strand its meetings there forever.
    @Test func everyRootCarryingTheDeviceIdentityIsMirrored() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }

        let phone = device(named: "iPhone")
        let root = try deviceFolder(phone, in: documents)
        let entry = item(folderName: "2026-08-03 09.30 Standup")
        try ICloudDriveBackup.mirror([entry], into: root)

        let duplicate = documents.appendingPathComponent("iPhone (conflict)", isDirectory: true)
        try FileManager.default.copyItem(at: root, to: duplicate)

        // The meeting is deleted in the app: every root must lose it.
        let roots = try ICloudDriveBackup.deviceFolderURLs(for: phone, in: documents)
        #expect(roots.count == 2)
        for folder in roots {
            try ICloudDriveBackup.mirror([], into: folder)
        }

        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(entry.folderName).path))
        #expect(!FileManager.default.fileExists(atPath: duplicate.appendingPathComponent(entry.folderName).path))
    }

    // MARK: - Failure and cancellation

    /// The replacement has to land before the recording it replaces is
    /// pruned, or a failed copy leaves the meeting with no audio at all.
    @Test func mirrorKeepsThePreviousRecordingWhenTheReplacementCannotBeCopied() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }
        let old = try recording(in: documents, bytes: "old-audio")
        let new = try recording(in: documents, bytes: "new-audio-of-another-size")

        let id = UUID().uuidString
        let name = "2026-08-03 09.30 Standup"
        try ICloudDriveBackup.mirror([item(id: id, folderName: name, audio: old)], into: documents)

        // Nothing new may be created in the folder, so the copy must fail.
        let folder = documents.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }

        try ICloudDriveBackup.mirror([item(id: id, folderName: name, audio: new)], into: documents)

        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(old.lastPathComponent).path))
    }

    /// Parking hides a folder until it is placed. A sync that starts after
    /// the toggle went off must not hide anything and then stop.
    @Test func mirrorParksNothingWhenAlreadyStopped() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }

        let alpha = "2026-08-03 09.30 Alpha"
        let beta = "2026-08-03 09.30 Beta"
        let first = UUID().uuidString
        let second = UUID().uuidString
        try ICloudDriveBackup.mirror(
            [item(id: first, folderName: alpha), item(id: second, folderName: beta)],
            into: documents
        )

        // The titles were swapped, which needs parking — but the user has
        // already opted out.
        try ICloudDriveBackup.mirror(
            [item(id: first, folderName: beta), item(id: second, folderName: alpha)],
            into: documents,
            shouldContinue: { false }
        )

        let all = try FileManager.default.contentsOfDirectory(atPath: documents.path)
        #expect(!all.contains { $0.hasPrefix(".minute-staging-") })
        #expect(try visibleNames(in: documents) == [alpha, beta])
    }

    /// A folder parked for a swap is hidden until it is placed. If the run
    /// stops in between, it must come back into view — with the setting off
    /// no later sync would rescue it.
    @Test func mirrorRestoresParkedFoldersWhenTheRunStopsMidway() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }

        let alpha = "2026-08-03 09.30 Alpha"
        let beta = "2026-08-03 09.30 Beta"
        let first = UUID().uuidString
        let second = UUID().uuidString
        try ICloudDriveBackup.mirror(
            [item(id: first, folderName: alpha), item(id: second, folderName: beta)],
            into: documents
        )

        // Swapped titles need parking; the toggle goes off after the first
        // folder has already been moved out of the way.
        let gate = Gate(allowing: 2)
        try ICloudDriveBackup.mirror(
            [item(id: first, folderName: beta), item(id: second, folderName: alpha)],
            into: documents,
            shouldContinue: { gate.check() }
        )

        let all = try FileManager.default.contentsOfDirectory(atPath: documents.path)
        #expect(!all.contains { $0.hasPrefix(".minute-staging-") })
        #expect(try visibleNames(in: documents) == [alpha, beta])
    }

    /// A duplicate may hold the only copy of a recording the kept folder is
    /// missing; sweeping it then destroys the last one.
    @Test func mirrorKeepsADuplicateUntilTheKeptFolderHoldsTheRecording() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }
        let source = try recording(in: documents, bytes: "the only copy")

        let id = UUID().uuidString
        let name = "2026-08-03 09.30 Standup"
        try ICloudDriveBackup.mirror([item(id: id, folderName: name, audio: source)], into: documents)

        let folder = documents.appendingPathComponent(name, isDirectory: true)
        let duplicate = documents.appendingPathComponent("\(name) copy", isDirectory: true)
        try FileManager.default.copyItem(at: folder, to: duplicate)
        // The kept folder loses its recording and the local file cannot be
        // read this round, so the duplicate is the last copy.
        try FileManager.default.removeItem(at: folder.appendingPathComponent(source.lastPathComponent))

        try ICloudDriveBackup.mirror(
            [item(id: id, folderName: name, audio: nil, audioFileName: source.lastPathComponent)],
            into: documents
        )

        let survivor = duplicate.appendingPathComponent(source.lastPathComponent)
        #expect(try Data(contentsOf: survivor) == Data("the only copy".utf8))
    }

    /// A same-named file is not proof that the kept duplicate is healthy.
    /// When the local source is unreadable, another folder may hold the last
    /// complete copy and must survive until a later sync can verify it.
    @Test func mirrorKeepsAHealthyDuplicateWhenTheKeptRecordingCannotBeVerified() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }
        let source = try recording(in: documents, bytes: "healthy audio")

        let id = UUID().uuidString
        let name = "2026-08-03 09.30 Standup"
        try ICloudDriveBackup.mirror([item(id: id, folderName: name, audio: source)], into: documents)

        let kept = documents.appendingPathComponent(name, isDirectory: true)
        let duplicate = documents.appendingPathComponent("\(name) copy", isDirectory: true)
        try FileManager.default.copyItem(at: kept, to: duplicate)
        try Data("bad".utf8).write(to: kept.appendingPathComponent(source.lastPathComponent))

        try ICloudDriveBackup.mirror(
            [item(id: id, folderName: name, audio: nil, audioFileName: source.lastPathComponent)],
            into: documents
        )

        let survivor = duplicate.appendingPathComponent(source.lastPathComponent)
        let survivorExists = FileManager.default.fileExists(atPath: survivor.path)
        #expect(survivorExists)
        if survivorExists {
            #expect(try Data(contentsOf: survivor) == Data("healthy audio".utf8))
        }
    }

    /// Before pruning a duplicate, equal byte counts are not enough: repair
    /// a same-sized corrupt kept copy from the readable source, then remove
    /// the now-redundant healthy duplicate.
    @Test func mirrorRepairsSameSizeCorruptionBeforePruningDuplicate() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }
        let source = try recording(in: documents, bytes: "healthy audio")

        let id = UUID().uuidString
        let name = "2026-08-03 09.30 Standup"
        let entry = item(id: id, folderName: name, audio: source)
        try ICloudDriveBackup.mirror([entry], into: documents)

        let kept = documents.appendingPathComponent(name, isDirectory: true)
        let duplicate = documents.appendingPathComponent("\(name) copy", isDirectory: true)
        try FileManager.default.copyItem(at: kept, to: duplicate)
        let destination = kept.appendingPathComponent(source.lastPathComponent)
        try Data("corrupt audio".utf8).write(to: destination)

        try ICloudDriveBackup.mirror([entry], into: documents)

        #expect(try Data(contentsOf: destination) == Data("healthy audio".utf8))
        #expect(!FileManager.default.fileExists(atPath: duplicate.path))
    }

    /// An evicted placeholder proves a cloud object exists, not that its
    /// bytes match the readable local recording. Keep a healthy duplicate
    /// until the chosen copy can be verified locally.
    @Test func mirrorKeepsAHealthyDuplicateWhenTheKeptRecordingIsEvicted() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }
        let source = try recording(in: documents, bytes: "healthy audio")

        let id = UUID().uuidString
        let name = "2026-08-03 09.30 Standup"
        try ICloudDriveBackup.mirror([item(id: id, folderName: name, audio: source)], into: documents)

        let kept = documents.appendingPathComponent(name, isDirectory: true)
        let duplicate = documents.appendingPathComponent("\(name) copy", isDirectory: true)
        try FileManager.default.copyItem(at: kept, to: duplicate)
        try FileManager.default.removeItem(at: kept.appendingPathComponent(source.lastPathComponent))
        try Data().write(to: kept.appendingPathComponent(".\(source.lastPathComponent).icloud"))

        try ICloudDriveBackup.mirror([item(id: id, folderName: name, audio: source)], into: documents)

        let survivor = duplicate.appendingPathComponent(source.lastPathComponent)
        #expect(FileManager.default.fileExists(atPath: survivor.path))
    }

    /// If an artifact cannot be removed, the marker has to stay: without it
    /// no later sync can find the folder, and the leftover recording would
    /// be orphaned in iCloud for good.
    @Test func sweepKeepsTheMarkerWhenAnArtifactCannotBeRemoved() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }
        let source = try recording(in: documents)

        let name = "2026-08-03 09.30 Standup"
        try ICloudDriveBackup.mirror([item(folderName: name, audio: source)], into: documents)

        let folder = documents.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }

        try ICloudDriveBackup.mirror([], into: documents)

        #expect(ICloudDriveBackup.meetingID(inFolder: folder) != nil)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(source.lastPathComponent).path))
    }

    /// On a case-insensitive volume the new path resolves to the existing
    /// directory, so a plain move is a no-op and Files would keep showing
    /// the old spelling forever.
    @Test func mirrorAppliesACaseOnlyTitleChange() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }

        let id = UUID().uuidString
        try ICloudDriveBackup.mirror([item(id: id, folderName: "2026-08-03 09.30 Standup")], into: documents)
        try ICloudDriveBackup.mirror([item(id: id, folderName: "2026-08-03 09.30 STANDUP")], into: documents)

        #expect(try visibleNames(in: documents) == ["2026-08-03 09.30 STANDUP"])
    }

    /// Two overlapping syncs: the older snapshot must not resurrect what
    /// the newer one deleted.
    @Test func mirrorerDropsASnapshotANewerOneSuperseded() async throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }

        let phone = device(named: "iPhone")
        let mirrorer = ICloudDriveBackup.Mirrorer()
        let entry = item(folderName: "2026-08-03 09.30 Standup")

        // The newer snapshot records the meeting as deleted.
        try await mirrorer.run(
            .init(items: [], device: phone, sequence: 2),
            documents: documents,
            shouldContinue: { true }
        )
        // The older one, arriving late, must be dropped.
        try await mirrorer.run(
            .init(items: [entry], device: phone, sequence: 1),
            documents: documents,
            shouldContinue: { true }
        )

        let root = try deviceFolder(phone, in: documents)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(entry.folderName).path))
    }

    /// Foregrounding the app or exhausting background time must stop the
    /// lifecycle-owned mirror instead of letting its stale snapshot continue.
    @Test func backgroundMirrorCancellationStopsTheOperation() async {
        let probe = CancellationProbe()
        let operation = BackgroundMirrorTask(name: "test mirror") { shouldContinue in
            while shouldContinue() { await Task.yield() }
            await probe.markStopped()
        }

        let task = operation.cancel()
        await task?.value

        let stopped = await probe.didStop()
        #expect(stopped)
    }
}
