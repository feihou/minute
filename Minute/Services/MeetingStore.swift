import Foundation
import OSLog
import SwiftData

/// Creates, locates, and deletes the on-disk artifacts that belong to a meeting.
/// Everything lives in Application Support — never leaves the device.
enum MeetingStore {
    private static let logger = Logger(subsystem: "com.minuteapp.Minute", category: "MeetingStore")

    static func recordingsDirectory() throws -> URL {
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

    /// Deleting a meeting also removes its audio file so no orphaned data remains.
    static func delete(_ meeting: Meeting, context: ModelContext) {
        if let name = meeting.audioFileName {
            deleteAudioFile(named: name)
        }
        context.delete(meeting)
        do {
            try context.save()
        } catch {
            logger.error("Failed to save after deleting meeting: \(error.localizedDescription)")
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
