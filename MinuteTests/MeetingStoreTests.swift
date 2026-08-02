import Foundation
import SwiftData
import Testing
@testable import Minute

@MainActor
struct MeetingStoreTests {
    @Test func deleteRemovesMeetingAndAudioFile() throws {
        let container = try ModelContainer(
            for: Meeting.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
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

    @Test func recordingsDirectoryIsExcludedFromBackups() throws {
        let directory = try MeetingStore.recordingsDirectory()
        let base = directory.deletingLastPathComponent()
        let values = try base.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
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

    @Test func removeOrphanedAudioSweepsImportedFormats() throws {
        let orphanName = MeetingStore.importedAudioFileName(originalExtension: "mp3")
        let orphanURL = try MeetingStore.audioURL(fileName: orphanName)
        try Data("orphan mp3".utf8).write(to: orphanURL)

        // Reference every other file on disk so concurrently running tests
        // keep their fixtures; only our orphan is sweepable.
        let directory = try MeetingStore.recordingsDirectory()
        let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
        MeetingStore.removeOrphanedAudio(referencedFileNames: existing.subtracting([orphanName]))

        #expect(!FileManager.default.fileExists(atPath: orphanURL.path))
    }

    @Test func removeOrphanedAudioDeletesOnlyUnreferencedFiles() throws {
        let keptName = MeetingStore.newAudioFileName()
        let orphanName = MeetingStore.newAudioFileName()
        let keptURL = try MeetingStore.audioURL(fileName: keptName)
        let orphanURL = try MeetingStore.audioURL(fileName: orphanName)
        try Data("kept".utf8).write(to: keptURL)
        try Data("orphan".utf8).write(to: orphanURL)

        MeetingStore.removeOrphanedAudio(referencedFileNames: [keptName])

        #expect(FileManager.default.fileExists(atPath: keptURL.path))
        #expect(!FileManager.default.fileExists(atPath: orphanURL.path))

        MeetingStore.deleteAudioFile(named: keptName)
    }
}
