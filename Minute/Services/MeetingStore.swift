import Foundation
import OSLog
import SwiftData

/// Creates, locates, and deletes the on-disk artifacts that belong to a meeting.
/// Everything lives in Application Support — never leaves the device.
enum MeetingStore {
    private static let logger = Logger(subsystem: "com.minuteapp.Minute", category: "MeetingStore")

    /// True when the persistent SwiftData store failed and meetings live only
    /// in memory. Audio then goes to a session-only directory that gets wiped
    /// at the next launch, instead of accumulating invisibly in the persistent
    /// Recordings directory. Set once at app startup, before any recording.
    nonisolated(unsafe) static var useEphemeralStorage = false

    static func recordingsDirectory() throws -> URL {
        if useEphemeralStorage {
            let directory = ephemeralRecordingsDirectory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }
        var base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        // Meeting data must never leave the device — not even inside an
        // iCloud/computer device backup. Excluding the whole app-support tree
        // covers the recordings and the SwiftData store.
        do {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try base.setResourceValues(values)
        } catch {
            logger.error("Excluding meeting data from backups failed: \(error.localizedDescription)")
        }
        let directory = base.appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static var ephemeralRecordingsDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("EphemeralRecordings", isDirectory: true)
    }

    /// Wipes audio recorded during a previous fallback (in-memory store)
    /// session — nothing can reference those files anymore. Call at launch.
    static func removeEphemeralRecordings() {
        let directory = ephemeralRecordingsDirectory
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            logger.error("Removing ephemeral recordings failed: \(error.localizedDescription)")
        }
    }

    static func newAudioFileName() -> String {
        UUID().uuidString + ".m4a"
    }

    static func audioURL(fileName: String) throws -> URL {
        try recordingsDirectory().appendingPathComponent(fileName)
    }

    /// Resolves a meeting's audio file, or nil when it has none / it is missing.
    static func audioURL(for meeting: Meeting) -> URL? {
        guard let name = meeting.audioFileName,
              let url = try? audioURL(fileName: name),
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    /// Deleting a meeting also removes its audio file so no orphaned data
    /// remains. The database deletion commits FIRST: if it fails, the audio is
    /// untouched (a meeting must never reappear pointing at deleted audio),
    /// and a crash in between leaves an orphan the launch sweep cleans up.
    static func delete(_ meeting: Meeting, context: ModelContext) {
        let audioFileName = meeting.audioFileName
        context.delete(meeting)
        do {
            try context.save()
        } catch {
            logger.error("Failed to save after deleting meeting: \(error.localizedDescription)")
            // The delete stays pending in the context; if a later save
            // commits it, the audio becomes an orphan and the launch sweep
            // removes it. Never delete audio for an uncommitted row-delete.
            return
        }
        if let audioFileName {
            deleteAudioFile(named: audioFileName)
        }
    }

    /// Removes audio files that no meeting references (e.g. left behind by a
    /// crash mid-recording), so no recording lingers on disk invisibly.
    static func removeOrphanedAudio(referencedFileNames: Set<String>) {
        guard let directory = try? recordingsDirectory(),
              let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return }
        for name in files where name.hasSuffix(".m4a") && !referencedFileNames.contains(name) {
            deleteAudioFile(named: name)
        }
    }

    static func deleteAudioFile(named name: String) {
        do {
            let url = try audioURL(fileName: name)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            logger.error("Failed to delete audio file \(name): \(error.localizedDescription)")
        }
    }
}
