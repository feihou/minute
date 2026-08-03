import Foundation
import OSLog
import SwiftData
import UIKit

/// Mirrors meetings into the app's iCloud Drive folder ("Minute" in the
/// Files app) as one browsable folder per meeting holding notes.md and the
/// audio file. iOS syncs the files; the app itself never opens a network
/// connection. The mirror is self-healing: every sync rewrites changed
/// notes, copies missing or half-copied audio, and removes the folders of
/// meetings that no longer exist.
enum ICloudDriveBackup {
    private static let logger = Logger(subsystem: "com.minuteapp.Minute", category: "ICloudDriveBackup")

    static let notesFileName = "notes.md"

    /// APFS caps a single path component at 255 UTF-8 bytes, and a folder
    /// name that exceeds it fails to create on every sync, forever.
    private static let maxNameBytes = 255
    /// Room left for a " 12"-style de-duplication suffix.
    private static let suffixReserveBytes = 4
    /// "yyyy-MM-dd HH.mm " — the fixed prefix every generated name carries.
    private static let namePrefixLength = 17

    /// Everything the mirror needs from one meeting, captured on the main
    /// actor so the file work can run in the background.
    struct Item: Sendable {
        let folderName: String
        let notes: String
        let audioSourceURL: URL?
    }

    // MARK: - Names

    /// "2026-08-03 09.30 Standup" — date-prefixed so folders sort by meeting
    /// time. Characters that break file systems or the Files app are
    /// replaced, and the title is trimmed to keep the whole name inside the
    /// file system's byte limit (a CJK or emoji title reaches it in far
    /// fewer characters than an English one).
    static func folderName(title: String, createdAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let prefix = formatter.string(from: createdAt) + " "
        let cleaned = title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.controlCharacters))
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let body = truncated(
            cleaned.isEmpty ? "Meeting" : cleaned,
            toUTF8Bytes: maxNameBytes - prefix.utf8.count - suffixReserveBytes
        )
        return prefix + body
    }

    /// Cuts on a character boundary so a multi-byte character is never
    /// split into invalid UTF-8.
    private static func truncated(_ text: String, toUTF8Bytes limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        var result = ""
        var used = 0
        for character in text {
            let size = String(character).utf8.count
            guard used + size <= limit else { break }
            result.append(character)
            used += size
        }
        return result.isEmpty ? "Meeting" : result
    }

    /// True for names this app generates. The deletion pass only ever
    /// touches these, so anything the user puts in the folder survives.
    /// A name test rather than a marker file: it needs no disk access, and
    /// it still works when iCloud has evicted the folder's contents (an
    /// evicted `notes.md` is on disk as `.notes.md.icloud`, so a
    /// marker-file check would silently stop deleting stale folders).
    static func isMirrorFolderName(_ name: String) -> Bool {
        let characters = Array(name)
        guard characters.count > namePrefixLength else { return false }
        let digitPositions = [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15]
        let separators: [(Int, Character)] = [(4, "-"), (7, "-"), (10, " "), (13, "."), (16, " ")]
        return digitPositions.allSatisfy { characters[$0].isASCII && characters[$0].isWholeNumber }
            && separators.allSatisfy { characters[$0.0] == $0.1 }
    }

    /// Snapshots meetings for mirroring in a stable order, giving meetings
    /// that would share a folder name (same minute, same title) distinct
    /// numbered names. Comparison is case-insensitive because the file
    /// system is: "Standup" and "standup" would otherwise collide on disk.
    @MainActor
    static func items(for meetings: [Meeting]) -> [Item] {
        var used: Set<String> = []
        // Sorted so suffixes land on the same meetings every sync —
        // otherwise two same-titled meetings swap folders and each sync
        // rewrites both.
        let ordered = meetings.sorted {
            ($0.createdAt, $0.title, $0.audioFileName ?? "")
                < ($1.createdAt, $1.title, $1.audioFileName ?? "")
        }
        return ordered.map { meeting in
            let base = folderName(title: meeting.title, createdAt: meeting.createdAt)
            var name = base
            var suffix = 2
            while !used.insert(name.lowercased()).inserted {
                name = "\(base) \(suffix)"
                suffix += 1
            }
            return Item(
                folderName: name,
                notes: NotesExporter.notesText(for: meeting),
                audioSourceURL: MeetingStore.audioURL(for: meeting)
            )
        }
    }

    /// "iPhone 3F2A" — the device name plus a suffix kept in UserDefaults.
    /// Each device mirrors into its own subfolder; two iPhones on one Apple
    /// ID would otherwise delete each other's meetings from a shared folder.
    @MainActor
    static func deviceFolderName() -> String {
        let key = "backup.deviceFolderSuffix"
        let defaults = UserDefaults.standard
        // Not identifierForVendor: it is nil before the first unlock, and
        // falling back to the bare (generic "iPhone") device name would put
        // two devices in one folder — exactly what this suffix prevents.
        let suffix = defaults.string(forKey: key) ?? {
            let generated = String(UUID().uuidString.prefix(4))
            defaults.set(generated, forKey: key)
            return generated
        }()
        return "\(UIDevice.current.name) \(suffix)"
    }

    // MARK: - Sync

    /// This device's folder inside the app's ubiquity Documents directory,
    /// or nil when iCloud Drive is unavailable (not signed in, iCloud Drive
    /// off, or missing entitlement). Slow on first call — never call on the
    /// main thread.
    nonisolated static func containerURL(deviceFolder: String) -> URL? {
        FileManager.default
            .url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(deviceFolder, isDirectory: true)
    }

    /// Serializes mirrors: the toggle-on sync and the background sync must
    /// never write the same folders at once.
    private actor Mirrorer {
        static let shared = Mirrorer()

        func run(_ items: [Item], into documents: URL) throws {
            try ICloudDriveBackup.mirror(items, into: documents)
        }
    }

    /// Mirrors off the main thread; returns false when the mirror can't run
    /// (iCloud Drive unavailable) so the Settings toggle can tell the user.
    /// Per-meeting errors are logged, not surfaced — the next sync repairs
    /// whatever is missing.
    nonisolated static func syncNow(items: [Item], deviceFolder: String) async -> Bool {
        // Defense in depth: with the fallback store active the snapshot
        // holds only this session's meetings, so mirroring it would delete
        // every previously backed-up meeting from iCloud Drive.
        guard !MeetingStore.useEphemeralStorage else { return false }
        let resolved = Task.detached(priority: .utility) { containerURL(deviceFolder: deviceFolder) }
        guard let documents = await resolved.value else { return false }
        do {
            try await Mirrorer.shared.run(items, into: documents)
        } catch {
            logger.error("iCloud Drive mirror failed: \(error.localizedDescription)")
        }
        return true
    }

    /// Fetches every meeting and mirrors it in the background. No-op unless
    /// the toggle is on and persistent storage is healthy. Called when the
    /// app enters the background — a copy cut short by suspension leaves a
    /// size mismatch the next sync repairs.
    @MainActor
    static func syncIfEnabled(context: ModelContext) {
        guard AppSettings.iCloudDriveBackupEnabled, !MeetingStore.useEphemeralStorage else { return }
        guard let meetings = try? context.fetch(FetchDescriptor<Meeting>()) else { return }
        let snapshot = items(for: meetings)
        let deviceFolder = deviceFolderName()
        // Copying a long meeting's audio outlasts the seconds iOS grants a
        // backgrounded app; without this the copy is cut mid-file every
        // time and never finishes.
        let token = BackgroundTaskToken(name: "iCloud Drive mirror")
        Task {
            _ = await syncNow(items: snapshot, deviceFolder: deviceFolder)
            token.end()
        }
    }

    // MARK: - Mirror

    /// Brings `documents` to exactly one folder per item. Folders the app
    /// didn't name are left alone, and one unmirrorable meeting never
    /// blocks the rest.
    nonisolated static func mirror(_ items: [Item], into documents: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: documents, withIntermediateDirectories: true)

        let expected = Set(items.map { $0.folderName.lowercased() })
        let existing = (try? fileManager.contentsOfDirectory(
            at: documents,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        for url in existing {
            let name = url.lastPathComponent
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDirectory, !expected.contains(name.lowercased()), isMirrorFolderName(name) else { continue }
            do {
                try fileManager.removeItem(at: url)
            } catch {
                logger.error("Removing stale mirror \(name) failed: \(error.localizedDescription)")
            }
        }

        for item in items {
            do {
                try write(item, into: documents)
            } catch {
                logger.error("Mirroring \(item.folderName) failed: \(error.localizedDescription)")
            }
        }
    }

    private nonisolated static func write(_ item: Item, into documents: URL) throws {
        let fileManager = FileManager.default
        let folder = documents.appendingPathComponent(item.folderName, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        let notesURL = folder.appendingPathComponent(notesFileName)
        let notes = Data(item.notes.utf8)
        if (try? Data(contentsOf: notesURL)) != notes {
            try notes.write(to: notesURL, options: .atomic)
        }

        guard let source = item.audioSourceURL, let sourceSize = fileSize(at: source) else { return }
        let destination = folder.appendingPathComponent(source.lastPathComponent)
        guard !isCurrent(destination, sourceSize: sourceSize) else { return }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
    }

    /// Whether the mirrored audio can be left alone.
    private nonisolated static func isCurrent(_ destination: URL, sourceSize: Int64) -> Bool {
        // iCloud evicts local copies of synced files under storage
        // pressure, leaving a ".name.icloud" placeholder. The file is still
        // in iCloud Drive — re-copying it would just churn.
        let placeholder = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).icloud")
        if FileManager.default.fileExists(atPath: placeholder.path) { return true }
        // ponytail: size compare, not checksums — recordings are written
        // once, so a matching size means the copy completed.
        return fileSize(at: destination) == sourceSize
    }

    private nonisolated static func fileSize(at url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
    }
}

/// Keeps the app awake long enough to finish a background mirror. iOS
/// suspends a backgrounded app within seconds otherwise.
@MainActor
private final class BackgroundTaskToken {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init(name: String) {
        // The expiration handler is documented to run on the main thread.
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
