import Foundation
import OSLog
import SwiftData

/// Creates, locates, and deletes the on-disk artifacts that belong to a meeting.
/// Everything lives in Application Support — it stays on the device unless the
/// user opts into iCloud Backup in Settings.
enum MeetingStore {
    private static let logger = Logger(subsystem: "com.minuteapp.Minute", category: "MeetingStore")

    /// True when the persistent SwiftData store failed and meetings live only
    /// in memory. Audio then goes to a session-only directory that gets wiped
    /// at the next launch, instead of accumulating invisibly in the persistent
    /// Recordings directory. Set once at app startup, before any recording.
    nonisolated(unsafe) static var useEphemeralStorage = false

    /// Applies the user's backup choice to the app's Application Support tree
    /// (recordings + SwiftData store). Meeting data is excluded from
    /// iCloud/computer backups unless the user turned on the iCloud Backup
    /// toggle in Settings. Covers any corrupt store and older recordings still
    /// sitting there while the in-memory fallback is active, so this runs at
    /// launch independently of where new audio routes — and again whenever the
    /// toggle changes. Returns false when the flag couldn't be applied so the
    /// Settings toggle can tell the user instead of failing silently; the
    /// policy is re-applied at every launch and recordings-directory access,
    /// so a transient failure heals itself.
    @discardableResult
    static func applyBackupPolicy() -> Bool {
        do {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            try setExcludedFromBackup(!AppSettings.iCloudBackupEnabled, at: base)
            return true
        } catch {
            logger.error("Applying the backup policy failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Sets the backup-exclusion flag on one directory. Split out so tests can
    /// exercise the flip on a scratch directory instead of racing concurrent
    /// tests over the shared Application Support tree.
    static func setExcludedFromBackup(_ excluded: Bool, at url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = excluded
        try url.setResourceValues(values)
    }

    /// A local-only SwiftData configuration. The iCloud Documents
    /// entitlement makes SwiftData's `.automatic` mode assume CloudKit
    /// mirroring and reject the schema — Minute copies files to iCloud,
    /// it never syncs the database.
    static func modelConfiguration(inMemory: Bool = false) -> ModelConfiguration {
        ModelConfiguration(isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none)
    }

    #if DEBUG
    /// Throw-free in-memory container for SwiftUI previews, which can't
    /// handle a throwing initializer. An in-memory store has nothing to
    /// fail on, so the fallback only fires if SwiftData itself is broken.
    @MainActor
    static func previewContainer() -> ModelContainer {
        do {
            return try ModelContainer(for: Meeting.self, configurations: modelConfiguration(inMemory: true))
        } catch {
            fatalError("Unable to create the in-memory preview container: \(error)")
        }
    }
    #endif

    static func recordingsDirectory() throws -> URL {
        applyBackupPolicy()
        if useEphemeralStorage {
            let directory = ephemeralRecordingsDirectory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
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

    /// Audio containers the app accepts for import; recordings are always m4a.
    static let audioFileExtensions: Set<String> = ["m4a", "mp3", "wav", "aac", "aiff", "aif", "caf", "flac"]

    /// File name for imported audio, keeping the source container so playback
    /// and re-reads never depend on a misleading extension.
    static func importedAudioFileName(originalExtension: String) -> String {
        let ext = originalExtension.lowercased()
        return UUID().uuidString + "." + (audioFileExtensions.contains(ext) ? ext : "m4a")
    }

    private static func isAudioFile(_ name: String) -> Bool {
        audioFileExtensions.contains(URL(fileURLWithPath: name).pathExtension.lowercased())
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
    /// Returns false when the deletion couldn't be committed, so bulk actions
    /// can tell the user instead of silently claiming success.
    @discardableResult
    static func delete(_ meeting: Meeting, context: ModelContext) -> Bool {
        let audioFileName = meeting.audioFileName
        context.delete(meeting)
        do {
            try context.save()
        } catch {
            logger.error("Failed to save after deleting meeting: \(error.localizedDescription)")
            // The delete stays pending in the context; if a later save
            // commits it, the audio becomes an orphan and the launch sweep
            // removes it. Never delete audio for an uncommitted row-delete.
            return false
        }
        if let audioFileName {
            deleteAudioFile(named: audioFileName)
        }
        return true
    }

    /// Removes audio files that no meeting references (e.g. left behind by a
    /// crash mid-recording), so no recording lingers on disk invisibly.
    static func removeOrphanedAudio(referencedFileNames: Set<String>) {
        guard let directory = try? recordingsDirectory(),
              let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return }
        for name in files where isAudioFile(name) && !referencedFileNames.contains(name) {
            deleteAudioFile(named: name)
        }
    }

    /// Number of recording files on disk and their combined size, for the
    /// storage row in Settings.
    static func recordingsUsage() -> (fileCount: Int, totalBytes: Int64) {
        guard let directory = try? recordingsDirectory(),
              let files = try? FileManager.default.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: [.fileSizeKey]
              )
        else { return (0, 0) }
        var count = 0
        var bytes: Int64 = 0
        for url in files where isAudioFile(url.lastPathComponent) {
            count += 1
            bytes += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return (count, bytes)
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
