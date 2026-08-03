import Foundation
import OSLog
import SwiftData
import UIKit

/// Mirrors meetings into the app's iCloud Drive folder ("Minute" in the
/// Files app) as one browsable folder per meeting holding notes.md and the
/// audio file. iOS syncs the files; the app itself never opens a network
/// connection. The mirror is self-healing: every sync renames folders whose
/// title changed, rewrites changed notes, copies missing or half-copied
/// audio, and removes the folders of meetings that no longer exist.
///
/// A folder's identity is the meeting id in its marker file name, never the
/// folder name: names change when a title is edited, when the clock shifts
/// (DST or travel), or when the iPhone is renamed, and re-deriving identity
/// from them would delete and re-upload every recording each time. The id
/// lives in the file *name* so an iCloud-evicted marker — which iOS
/// replaces with a `..minute-<id>.icloud` placeholder — still identifies
/// its folder without reading a byte.
///
/// The folder is the user's to browse and edit, so the mirror only ever
/// touches folders carrying its own marker: it never claims, overwrites, or
/// deletes a directory someone put there themselves.
enum ICloudDriveBackup {
    private static let logger = Logger(subsystem: "com.minuteapp.Minute", category: "ICloudDriveBackup")

    static let notesFileName = "notes.md"
    /// Marker file name prefix; the meeting id follows it.
    private static let markerPrefix = "minute-"
    /// Hidden name a folder is parked under while names are being swapped.
    private static let stagingPrefix = ".minute-staging-"

    /// APFS caps a single path component at 255 UTF-8 bytes, and a folder
    /// name that exceeds it fails to create on every sync, forever.
    private static let maxNameBytes = 255
    /// Room left for a " 12"-style de-duplication suffix.
    private static let suffixReserveBytes = 4
    /// Give up rather than spin if a hundred names are all taken.
    private static let maxNameAttempts = 100

    private static let deviceSuffixKey = "backup.deviceFolderSuffix"
    private static let deviceVendorKey = "backup.deviceVendorID"

    /// Everything the mirror needs from one meeting, captured on the main
    /// actor so the file work can run in the background.
    struct Item: Sendable {
        let meetingID: String
        let folderName: String
        let notes: String
        /// What the meeting says its recording is called, even when the
        /// file itself can't be read right now.
        let audioFileName: String?
        /// The readable local file, or nil when it is missing.
        let audioSourceURL: URL?
    }

    // MARK: - Names

    /// "2026-08-03 09.30 Standup" — date-prefixed so folders sort by meeting
    /// time. Characters that break file systems or the Files app are
    /// replaced, and the title is trimmed to keep the whole name inside the
    /// file system's byte limit (a CJK or emoji title reaches it in far
    /// fewer characters than an English one). Local time, matching what the
    /// app shows; when the offset shifts the folder is renamed, not rebuilt.
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

    /// Snapshots meetings for mirroring in a stable order, giving meetings
    /// that would share a folder name (same minute, same title) distinct
    /// numbered names. Comparison is case-insensitive because the file
    /// system is: "Standup" and "standup" would otherwise collide on disk.
    @MainActor
    static func items(for meetings: [Meeting]) -> [Item] {
        var used: Set<String> = []
        // Sorted so suffixes land on the same meetings every sync —
        // otherwise two same-titled meetings swap folders and each sync
        // renames both.
        let ordered = meetings.sorted {
            ($0.createdAt, $0.title, $0.id.uuidString) < ($1.createdAt, $1.title, $1.id.uuidString)
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
                meetingID: meeting.id.uuidString,
                folderName: name,
                notes: NotesExporter.notesText(for: meeting),
                audioFileName: meeting.audioFileName,
                audioSourceURL: MeetingStore.audioURL(for: meeting)
            )
        }
    }

    /// "iPhone 3F2A" — the device name plus a suffix kept in UserDefaults.
    /// Each device mirrors into its own subfolder; two iPhones on one Apple
    /// ID would otherwise delete each other's meetings from a shared folder.
    @MainActor
    static func deviceFolderName() -> String {
        let defaults = UserDefaults.standard
        let vendorID = UIDevice.current.identifierForVendor?.uuidString
        if deviceIdentityChanged(stored: defaults.string(forKey: deviceVendorKey), current: vendorID) {
            defaults.set(vendorID, forKey: deviceVendorKey)
            defaults.removeObject(forKey: deviceSuffixKey)
        }
        // Not identifierForVendor alone: it is nil before the first unlock,
        // and falling back to the bare (generic "iPhone") device name would
        // put two devices in one folder — what this suffix prevents.
        let suffix = defaults.string(forKey: deviceSuffixKey) ?? {
            let generated = String(UUID().uuidString.prefix(4))
            defaults.set(generated, forKey: deviceSuffixKey)
            return generated
        }()
        return "\(UIDevice.current.name) \(suffix)"
    }

    /// Whether the stored suffix belongs to a different physical iPhone.
    /// Restoring a backup onto a replacement phone copies the suffix along
    /// with everything else, and two phones sharing a mirror folder would
    /// sweep each other's meetings — so the clone takes a new suffix. A nil
    /// vendor id (before first unlock) can't tell, and must not churn.
    static func deviceIdentityChanged(stored: String?, current: String?) -> Bool {
        guard let current else { return false }
        return stored != current
    }

    // MARK: - Sync

    /// This device's folder inside the app's ubiquity Documents directory,
    /// or nil when iCloud Drive is unavailable (not signed in, iCloud Drive
    /// off, or missing entitlement). Slow on first call — never call on the
    /// main thread.
    nonisolated static func containerURL(deviceFolder: String) -> URL? {
        guard let documents = FileManager.default
            .url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("Documents", isDirectory: true)
        else { return nil }
        return deviceFolderURL(named: deviceFolder, in: documents)
    }

    /// Where this device mirrors, following a renamed iPhone. The trailing
    /// suffix is this device's identity, so a folder carrying it is moved to
    /// the new name instead of being abandoned — an abandoned folder would
    /// keep deleted meetings' recordings in iCloud with nothing left to
    /// sweep them.
    nonisolated static func deviceFolderURL(named name: String, in documents: URL) -> URL {
        let fileManager = FileManager.default
        let target = documents.appendingPathComponent(name, isDirectory: true)
        guard !fileManager.fileExists(atPath: target.path),
              let suffix = name.split(separator: " ").last.map({ " " + $0 })
        else { return target }

        let candidates = (try? fileManager.contentsOfDirectory(
            at: documents,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        let previous = candidates.first { url in
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            // Only ever move a folder this app filled with meeting folders,
            // so a user folder that happens to end the same way is safe.
            return isDirectory && url.lastPathComponent.hasSuffix(suffix) && holdsMirrorFolders(url)
        }
        guard let previous else { return target }
        do {
            try fileManager.moveItem(at: previous, to: target)
        } catch {
            logger.error("Following the device rename failed: \(error.localizedDescription)")
            return previous
        }
        return target
    }

    private nonisolated static func holdsMirrorFolders(_ url: URL) -> Bool {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil
        )) ?? []
        return children.contains { meetingID(inFolder: $0) != nil }
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

    /// Brings `documents` to one folder per item: parks folders whose name
    /// must change, places each item, and only then removes the folders of
    /// meetings that are really gone. A write that fails therefore never
    /// costs the user the backup it was replacing, and one unmirrorable
    /// meeting never blocks the rest.
    nonisolated static func mirror(_ items: [Item], into documents: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: documents, withIntermediateDirectories: true)

        var owned = ownedFolders(in: documents)

        // Park only a folder whose target another mirror folder is sitting
        // on — two meetings that swap titles each hold the other's name, and
        // renaming in place would write one meeting's notes into the folder
        // carrying the other's marker. Everything else moves straight
        // across, so a move that fails leaves the backup visible where it
        // was instead of stranded under a hidden staging name.
        let holders = Dictionary(
            owned.map { ($1.lastPathComponent.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for item in items {
            guard let current = owned[item.meetingID],
                  current.lastPathComponent != item.folderName,
                  let holder = holders[item.folderName.lowercased()],
                  holder != item.meetingID
            else { continue }
            let staging = documents.appendingPathComponent(stagingPrefix + item.meetingID, isDirectory: true)
            guard !fileManager.fileExists(atPath: staging.path) else { continue }
            do {
                try fileManager.moveItem(at: current, to: staging)
                owned[item.meetingID] = staging
            } catch {
                logger.error("Parking \(current.lastPathComponent) failed: \(error.localizedDescription)")
            }
        }

        for item in items {
            guard !Task.isCancelled else { return }
            do {
                let folder = try place(item, existing: owned[item.meetingID], in: documents)
                owned[item.meetingID] = folder
                try write(item, into: folder)
            } catch {
                logger.error("Mirroring \(item.folderName) failed: \(error.localizedDescription)")
            }
        }

        guard !Task.isCancelled else { return }
        let expected = Set(items.map(\.meetingID))
        for (id, url) in owned where !expected.contains(id) {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                logger.error("Removing stale mirror failed: \(error.localizedDescription)")
            }
        }
    }

    /// The folder an item owns — moved to its current name when it already
    /// exists, created when it doesn't. A directory the app didn't mark is
    /// someone else's: the mirror steps aside to the next numbered name
    /// rather than claiming, overwriting, and eventually deleting it.
    private nonisolated static func place(_ item: Item, existing: URL?, in documents: URL) throws -> URL {
        let fileManager = FileManager.default
        var candidate = item.folderName
        for attempt in 1...maxNameAttempts {
            let target = documents.appendingPathComponent(candidate, isDirectory: true)
            if target == existing { return target }
            if !fileManager.fileExists(atPath: target.path) {
                if let existing {
                    try fileManager.moveItem(at: existing, to: target)
                } else {
                    try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                }
                return target
            }
            // Ours already — a parking move that failed earlier, say.
            if meetingID(inFolder: target) == item.meetingID { return target }
            candidate = "\(item.folderName) \(attempt + 1)"
        }
        throw CocoaError(.fileWriteInvalidFileName)
    }

    /// Folders this app wrote, keyed by meeting id. Anything the user put in
    /// the folder has no marker and is invisible here — so it is never
    /// renamed and never deleted, however its name looks.
    private nonisolated static func ownedFolders(in documents: URL) -> [String: URL] {
        let existing = (try? FileManager.default.contentsOfDirectory(
            at: documents,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        var owned: [String: URL] = [:]
        for url in existing {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDirectory, let id = meetingID(inFolder: url) else { continue }
            owned[id] = url
        }
        return owned
    }

    /// The meeting a folder belongs to, taken from its marker file's *name*
    /// so an evicted (`..minute-<id>.icloud`) marker still identifies it.
    static func meetingID(inFolder url: URL) -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        for name in names {
            var trimmed = name
            if trimmed.hasSuffix(".icloud") { trimmed.removeLast(".icloud".count) }
            while trimmed.hasPrefix(".") { trimmed.removeFirst() }
            guard trimmed.hasPrefix(markerPrefix) else { continue }
            return String(trimmed.dropFirst(markerPrefix.count))
        }
        return nil
    }

    private nonisolated static func write(_ item: Item, into folder: URL) throws {
        let fileManager = FileManager.default
        if meetingID(inFolder: folder) == nil {
            try Data().write(to: folder.appendingPathComponent(".\(markerPrefix)\(item.meetingID)"))
        }

        let notesURL = folder.appendingPathComponent(notesFileName)
        let notes = Data(item.notes.utf8)
        if (try? Data(contentsOf: notesURL)) != notes {
            try notes.write(to: notesURL, options: .atomic)
        }

        // Keyed on what the meeting *says* its recording is, not on what
        // could be read: a temporarily unreadable local file must never
        // take the mirrored copy — possibly the last one — down with it.
        removeStaleAudio(in: folder, keeping: item.audioFileName)

        guard let source = item.audioSourceURL, let sourceSize = fileSize(at: source) else { return }
        let destination = folder.appendingPathComponent(source.lastPathComponent)
        guard !isCurrent(destination, sourceSize: sourceSize) else { return }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
    }

    /// Deleting a meeting must leave zero bytes behind, and a folder whose
    /// recording was replaced would otherwise keep the old one forever.
    private nonisolated static func removeStaleAudio(in folder: URL, keeping current: String?) {
        let fileManager = FileManager.default
        let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names {
            // Match the real file and the placeholder iCloud leaves behind.
            var trimmed = name
            if trimmed.hasSuffix(".icloud") { trimmed.removeLast(".icloud".count) }
            while trimmed.hasPrefix(".") { trimmed.removeFirst() }
            let isAudio = MeetingStore.audioFileExtensions
                .contains(URL(fileURLWithPath: trimmed).pathExtension.lowercased())
            guard isAudio, trimmed != current else { continue }
            do {
                try fileManager.removeItem(at: folder.appendingPathComponent(name))
            } catch {
                logger.error("Removing stale audio failed: \(error.localizedDescription)")
            }
        }
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
