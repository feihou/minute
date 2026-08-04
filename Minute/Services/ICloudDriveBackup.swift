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
/// Identity is a marker file name, never a folder name: names change when a
/// title is edited, when the clock shifts (DST or travel), or when the
/// iPhone is renamed, and re-deriving identity from them would delete and
/// re-upload every recording each time. The id lives in the file *name* so
/// an iCloud-evicted marker — which iOS replaces with a
/// `..minute-<id>.icloud` placeholder — still identifies its folder without
/// reading a byte.
///
/// These folders are the user's to browse and edit, so the mirror touches
/// only what it can prove it created: a folder carrying its marker, and a
/// recording named the way it names recordings. It never claims, overwrites,
/// or deletes anything else.
enum ICloudDriveBackup {
    private static let logger = Logger(subsystem: "com.minuteapp.Minute", category: "ICloudDriveBackup")

    static let notesFileName = "notes.md"
    /// Marker file name prefixes; a UUID follows each.
    private static let markerPrefix = "minute-"
    private static let deviceMarkerPrefix = "minute-device-"
    /// Hidden name a folder is parked under while names are being swapped.
    private static let stagingPrefix = ".minute-staging-"
    private static let placeholderSuffix = ".icloud"
    /// Hidden name a recording is copied under before it replaces the last
    /// one, so a failed copy never leaves the meeting with no audio.
    private static let partialSuffix = ".partial"

    /// APFS caps a single path component at 255 UTF-8 bytes, and a folder
    /// name that exceeds it fails to create on every sync, forever.
    private static let maxNameBytes = 255
    /// Room left for a " 12"-style de-duplication suffix.
    private static let suffixReserveBytes = 4
    /// Give up rather than spin if a hundred names are all taken.
    private static let maxNameAttempts = 100

    private static let deviceIdentityKey = "backup.deviceIdentity"
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

    /// This iPhone's mirror folder: a readable name for the Files app, and
    /// a full UUID that identifies the folder no matter what it is called.
    struct Device: Sendable {
        let displayName: String
        let identity: String
    }

    /// One snapshot of the library, numbered so a slow sync can never apply
    /// an older view after a newer one already ran — which would resurrect
    /// the folder of a meeting the newer sync had just deleted.
    struct Request: Sendable {
        let items: [Item]
        let device: Device
        let sequence: Int
    }

    // MARK: - Names

    /// Strips what a path component cannot hold and squeezes the rest, so a
    /// title (or a device name) can never introduce a nested path.
    private static func sanitized(_ text: String) -> String {
        text
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.controlCharacters))
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
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
        return result
    }

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
        let body = truncated(
            sanitized(title),
            toUTF8Bytes: maxNameBytes - prefix.utf8.count - suffixReserveBytes
        )
        return prefix + (body.isEmpty ? "Meeting" : body)
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

    // MARK: - Device identity

    /// The folder name shown in Files. A device name is user-typed and can
    /// hold a slash, which `appendingPathComponent` would read as a nested
    /// path — the marker would then land one level below where every later
    /// scan looks, and each sync would create another folder.
    static func displayName(forDeviceNamed name: String, identity: String) -> String {
        let tail = String(identity.prefix(4))
        let base = truncated(
            sanitized(name),
            toUTF8Bytes: maxNameBytes - suffixReserveBytes - tail.utf8.count - 1
        )
        return "\(base.isEmpty ? "iPhone" : base) \(tail)"
    }

    /// This device's folder identity. The name is for humans — only the
    /// UUID decides which folder belongs to this iPhone, so two devices can
    /// share a name (or a display tail) without ever sharing a folder.
    @MainActor
    static func currentDevice() -> Device {
        let defaults = UserDefaults.standard
        let vendorID = UIDevice.current.identifierForVendor?.uuidString
        if deviceIdentityChanged(stored: defaults.string(forKey: deviceVendorKey), current: vendorID) {
            defaults.set(vendorID, forKey: deviceVendorKey)
            defaults.removeObject(forKey: deviceIdentityKey)
        }
        let identity = defaults.string(forKey: deviceIdentityKey) ?? {
            let generated = UUID().uuidString
            defaults.set(generated, forKey: deviceIdentityKey)
            return generated
        }()
        return Device(
            displayName: displayName(forDeviceNamed: UIDevice.current.name, identity: identity),
            identity: identity
        )
    }

    /// Whether the stored identity belongs to a different physical iPhone.
    /// Restoring a backup onto a replacement phone copies it along with
    /// everything else, and two phones sharing a mirror folder would sweep
    /// each other's meetings — so the clone takes a new one. A nil vendor id
    /// (before first unlock) can't tell, and must not churn.
    static func deviceIdentityChanged(stored: String?, current: String?) -> Bool {
        guard let current else { return false }
        return stored != current
    }

    /// The next snapshot to mirror. Taking the number here, on the main
    /// actor, is what lets the mirror drop a snapshot that a newer one has
    /// already superseded.
    @MainActor private static var lastSequence = 0

    @MainActor
    static func request(for meetings: [Meeting]) -> Request {
        lastSequence += 1
        return Request(items: items(for: meetings), device: currentDevice(), sequence: lastSequence)
    }

    // MARK: - Markers

    /// The meeting id in a marker file name, or nil for anything else.
    /// Only the exact name the mirror writes counts — a file the user
    /// happens to call "minute-agenda" must never make their folder look
    /// app-owned and get swept.
    static func meetingID(fromMarkerName name: String) -> String? {
        identity(fromMarkerName: name, prefix: markerPrefix)
    }

    private static func identity(fromMarkerName name: String, prefix: String) -> String? {
        let candidate: String
        if name.hasPrefix("." + prefix) {
            candidate = String(name.dropFirst(prefix.count + 1))
        } else if name.hasPrefix(".." + prefix), name.hasSuffix(placeholderSuffix) {
            // What iCloud leaves behind when it evicts the local copy.
            candidate = String(name.dropFirst(prefix.count + 2).dropLast(placeholderSuffix.count))
        } else {
            return nil
        }
        // Every id the app writes is a UUID; anything else is not ours.
        return UUID(uuidString: candidate) != nil ? candidate : nil
    }

    /// The meeting a folder belongs to, taken from its marker file's *name*
    /// so an evicted marker still identifies it.
    static func meetingID(inFolder url: URL) -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        for name in names {
            if let id = meetingID(fromMarkerName: name) { return id }
        }
        return nil
    }

    private nonisolated static func holdsDeviceMarker(_ url: URL, identity wanted: String) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.contains { identity(fromMarkerName: $0, prefix: deviceMarkerPrefix) == wanted }
    }

    private nonisolated static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    // MARK: - Sync

    /// The app's ubiquity Documents directory, or nil when iCloud Drive is
    /// unavailable (not signed in, iCloud Drive off, or missing
    /// entitlement). Slow on first call — never call on the main thread.
    nonisolated static func documentsURL() -> URL? {
        FileManager.default
            .url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("Documents", isDirectory: true)
    }

    /// Every root carrying this device's marker, the first one renamed to
    /// the current display name. Identity is the marker, not the name, so a
    /// renamed iPhone keeps the folder it already filled instead of
    /// abandoning it — an abandoned folder would keep deleted meetings'
    /// recordings with nothing left to sweep them.
    ///
    /// An iCloud conflict or a copy made in Files can leave a second root
    /// with the same marker. Every one of them is mirrored, so a meeting
    /// deleted in the app disappears from all of them; picking one and
    /// ignoring the rest would strand recordings there forever.
    ///
    /// Only ever called from `Mirrorer`, so two overlapping syncs can't both
    /// try to migrate the same folder.
    nonisolated static func deviceFolderURLs(for device: Device, in documents: URL) throws -> [URL] {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: documents, withIntermediateDirectories: true)

        let marked = ((try? fileManager.contentsOfDirectory(
            at: documents,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? [])
            .filter { isDirectory($0) && holdsDeviceMarker($0, identity: device.identity) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard let first = marked.first(where: { $0.lastPathComponent == device.displayName }) ?? marked.first else {
            let folder = try freeName(startingAt: device.displayName, in: documents)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data().write(to: folder.appendingPathComponent(".\(deviceMarkerPrefix)\(device.identity)"))
            return [folder]
        }
        return [renamed(first, to: device.displayName, in: documents)] + marked.filter { $0 != first }
    }

    /// Moves a folder to `name` when that name is free, and otherwise leaves
    /// it where it is. Never returns a URL that does not exist: another sync
    /// may have moved it already, and mirroring into a vanished path would
    /// recreate a folder every later sync ignores.
    private nonisolated static func renamed(_ folder: URL, to name: String, in documents: URL) -> URL {
        let fileManager = FileManager.default
        guard folder.lastPathComponent != name else { return folder }
        let target = documents.appendingPathComponent(name, isDirectory: true)
        guard !fileManager.fileExists(atPath: target.path) else { return folder }
        do {
            try fileManager.moveItem(at: folder, to: target)
            return target
        } catch {
            logger.error("Following the device rename failed: \(error.localizedDescription)")
            return fileManager.fileExists(atPath: folder.path) ? folder : target
        }
    }

    /// The first unused name in `documents`, so the mirror never claims a
    /// directory someone else put there.
    private nonisolated static func freeName(startingAt base: String, in documents: URL) throws -> URL {
        for attempt in 1...maxNameAttempts {
            let candidate = attempt == 1 ? base : "\(base) \(attempt)"
            let url = documents.appendingPathComponent(candidate, isDirectory: true)
            if !FileManager.default.fileExists(atPath: url.path) { return url }
        }
        throw CocoaError(.fileWriteInvalidFileName)
    }

    /// Serializes mirrors: the toggle-on sync and the background sync must
    /// never migrate the device folder or write meeting folders at once.
    /// Instantiable so tests get their own; production uses `shared`.
    actor Mirrorer {
        static let shared = Mirrorer()

        private var applied = 0

        func run(
            _ request: Request,
            documents: URL,
            shouldContinue: @Sendable () -> Bool
        ) throws {
            // A newer snapshot already ran. Applying this one would undo it
            // — recreating the folder of a meeting it just deleted.
            guard request.sequence > applied else { return }
            applied = request.sequence
            for folder in try ICloudDriveBackup.deviceFolderURLs(for: request.device, in: documents) {
                try ICloudDriveBackup.mirror(request.items, into: folder, shouldContinue: shouldContinue)
            }
        }
    }

    /// Mirrors off the main thread; returns false when the mirror can't run
    /// (iCloud Drive unavailable) so the Settings toggle can tell the user.
    /// Per-meeting errors are logged, not surfaced — the next sync repairs
    /// whatever is missing.
    nonisolated static func syncNow(_ request: Request) async -> Bool {
        // Defense in depth: with the fallback store active the snapshot
        // holds only this session's meetings, so mirroring it would delete
        // every previously backed-up meeting from iCloud Drive.
        guard !MeetingStore.useEphemeralStorage else { return false }
        let resolved = Task.detached(priority: .utility) { documentsURL() }
        guard let documents = await resolved.value else { return false }
        do {
            // The preference is re-read as the mirror runs, so switching the
            // toggle off stops a sync this task doesn't own either — the
            // background one, say.
            try await Mirrorer.shared.run(request, documents: documents) {
                !Task.isCancelled && AppSettings.iCloudDriveBackupEnabled
            }
        } catch {
            // Per-meeting problems are handled and logged inside the
            // mirror; anything reaching here means the folder itself could
            // not be prepared, so nothing was mirrored at all. Report it,
            // or the toggle claims a backup that does not exist.
            logger.error("iCloud Drive mirror failed: \(error.localizedDescription)")
            return false
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
        let snapshot = request(for: meetings)
        // Copying a long meeting's audio outlasts the seconds iOS grants a
        // backgrounded app; without this the copy is cut mid-file every
        // time and never finishes.
        let token = BackgroundTaskToken(name: "iCloud Drive mirror")
        Task {
            _ = await syncNow(snapshot)
            token.end()
        }
    }

    // MARK: - Mirror

    /// Brings `documents` to one folder per item: parks folders whose name
    /// another one holds, places each item, and only then removes folders
    /// that belong to no meeting. A write that fails therefore never costs
    /// the user the backup it was replacing, and one unmirrorable meeting
    /// never blocks the rest.
    ///
    /// `shouldContinue` is checked before any folder is touched, between
    /// meetings, and after each copy, so turning the setting off stops the
    /// mirror mid-run and discards a recording that finished landing after
    /// the user said stop.
    nonisolated static func mirror(
        _ items: [Item],
        into documents: URL,
        shouldContinue: @Sendable () -> Bool = { true }
    ) throws {
        let fileManager = FileManager.default
        guard shouldContinue() else { return }
        try fileManager.createDirectory(at: documents, withIntermediateDirectories: true)

        let owned = ownedFolders(in: documents)
        // One meeting can end up with several folders — an iCloud conflict,
        // or a folder duplicated in Files. Keep one and let the rest be
        // swept, or they stay invisible to every later sync and outlive the
        // meeting they hold.
        var chosen: [String: URL] = [:]
        for item in items {
            guard let candidates = owned[item.meetingID], !candidates.isEmpty else { continue }
            chosen[item.meetingID] = candidates.first { $0.lastPathComponent == item.folderName } ?? candidates[0]
        }
        var live = chosen

        // Parking hides a folder until it is placed, so nothing may leave
        // this function with one still parked: the setting may be off by
        // then, and no later sync would bring it back into view.
        var parked: [String: URL] = [:]
        defer {
            for (id, original) in parked {
                guard let current = live[id], current.lastPathComponent.hasPrefix(stagingPrefix) else { continue }
                let destination = (try? freeName(startingAt: original.lastPathComponent, in: documents)) ?? original
                try? fileManager.moveItem(at: current, to: destination)
            }
        }

        // Park only a folder whose target another mirror folder is sitting
        // on — two meetings that swap titles each hold the other's name, and
        // renaming in place would write one meeting's notes into the folder
        // carrying the other's marker. Everything else moves straight
        // across, so a move that fails leaves the backup visible where it
        // was instead of stranded under a hidden staging name.
        let holders = Dictionary(
            live.map { ($1.lastPathComponent.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for item in items {
            // Parking hides a folder until it is placed; never start that
            // when the run is already stopping.
            guard shouldContinue() else { return }
            guard let current = live[item.meetingID],
                  current.lastPathComponent != item.folderName,
                  let holder = holders[item.folderName.lowercased()],
                  holder != item.meetingID
            else { continue }
            let staging = documents.appendingPathComponent(stagingPrefix + item.meetingID, isDirectory: true)
            guard !fileManager.fileExists(atPath: staging.path) else { continue }
            do {
                try fileManager.moveItem(at: current, to: staging)
                live[item.meetingID] = staging
                parked[item.meetingID] = current
            } catch {
                logger.error("Parking \(current.lastPathComponent) failed: \(error.localizedDescription)")
            }
        }

        for item in items {
            guard shouldContinue() else { return }
            do {
                let placed = try place(item, existing: live[item.meetingID], in: documents)
                live[item.meetingID] = placed.url
                try write(item, into: placed.url, created: placed.created, shouldContinue: shouldContinue)
            } catch {
                logger.error("Mirroring \(item.folderName) failed: \(error.localizedDescription)")
            }
        }

        guard shouldContinue() else { return }

        // A meeting that is gone takes everything it left behind.
        for (id, urls) in owned where chosen[id] == nil {
            for url in urls {
                removeMirror(at: url)
            }
        }
        // A duplicate goes only once the folder that was kept actually
        // holds the recording. If the local file could not be read this
        // round, the duplicate may be the only copy of it left.
        for item in items {
            guard let original = chosen[item.meetingID], let keep = live[item.meetingID] else { continue }
            guard holdsRecording(keep, named: item.audioFileName) else {
                logger.info("Kept duplicates of \(item.folderName): its recording is not in place yet")
                continue
            }
            for url in owned[item.meetingID] ?? [] where url != original {
                removeMirror(at: url)
            }
        }
    }

    /// Whether a folder holds the meeting's recording — either the file or
    /// the placeholder iCloud leaves when it evicts one.
    private nonisolated static func holdsRecording(_ folder: URL, named name: String?) -> Bool {
        guard let name else { return true }
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: folder.appendingPathComponent(name).path)
            || fileManager.fileExists(atPath: folder.appendingPathComponent(".\(name)\(placeholderSuffix)").path)
    }

    /// Removes the artifacts the mirror wrote, and the folder itself only
    /// when nothing else is left in it. Deleting a meeting must leave zero
    /// bytes of it behind, but a file the user put in the folder is not the
    /// meeting — a recursive delete would take their work with it.
    private nonisolated static func removeMirror(at folder: URL) {
        let fileManager = FileManager.default
        let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        var markers: [String] = []
        var incomplete = false
        for name in names {
            // The marker is what makes this folder findable at all; drop it
            // last, and only if everything else went, or a recording left
            // behind by a failed removal would be orphaned for good.
            if meetingID(fromMarkerName: name) != nil {
                markers.append(name)
                continue
            }
            guard isAppArtifact(name) else { continue }
            do {
                try fileManager.removeItem(at: folder.appendingPathComponent(name))
            } catch {
                incomplete = true
                logger.error("Removing \(name) failed: \(error.localizedDescription)")
            }
        }
        guard !incomplete else {
            logger.info("Kept the marker on \(folder.lastPathComponent) so a later sync finishes the job")
            return
        }
        for marker in markers {
            do {
                try fileManager.removeItem(at: folder.appendingPathComponent(marker))
            } catch {
                logger.error("Removing the marker failed: \(error.localizedDescription)")
                return
            }
        }
        let remaining = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        guard remaining.isEmpty else {
            logger.info("Kept \(folder.lastPathComponent): it holds files this app did not write")
            return
        }
        do {
            try fileManager.removeItem(at: folder)
        } catch {
            logger.error("Removing stale mirror failed: \(error.localizedDescription)")
        }
    }

    /// Whether the mirror wrote this file: its marker, its notes, a
    /// UUID-named recording it copied, or a partial copy it left behind —
    /// each also in the hidden form iCloud leaves when it evicts one.
    private nonisolated static func isAppArtifact(_ name: String) -> Bool {
        if meetingID(fromMarkerName: name) != nil { return true }
        var trimmed = localName(of: name)
        if trimmed.hasSuffix(partialSuffix) {
            trimmed.removeLast(partialSuffix.count)
            if trimmed.hasPrefix(".") { trimmed.removeFirst() }
        }
        if trimmed == notesFileName { return true }
        let path = URL(fileURLWithPath: trimmed)
        return MeetingStore.audioFileExtensions.contains(path.pathExtension.lowercased())
            && UUID(uuidString: path.deletingPathExtension().lastPathComponent) != nil
    }

    /// The folder an item owns — moved to its current name when it already
    /// exists, created when it doesn't. A directory the app didn't mark is
    /// someone else's: the mirror steps aside to the next numbered name
    /// rather than claiming, overwriting, and eventually deleting it.
    private nonisolated static func place(
        _ item: Item,
        existing: URL?,
        in documents: URL
    ) throws -> (url: URL, created: Bool) {
        let fileManager = FileManager.default
        for attempt in 1...maxNameAttempts {
            let candidate = attempt == 1 ? item.folderName : "\(item.folderName) \(attempt)"
            let target = documents.appendingPathComponent(candidate, isDirectory: true)
            if target == existing { return (target, false) }
            if !fileManager.fileExists(atPath: target.path) {
                if let existing {
                    try fileManager.moveItem(at: existing, to: target)
                    return (target, false)
                }
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                return (target, true)
            }
            guard meetingID(inFolder: target) == item.meetingID else { continue }
            // Ours already. On a case-insensitive volume a title edit that
            // only changed capitalization resolves to this same directory,
            // and a direct move would be a no-op that leaves Files showing
            // the old spelling forever — go around through a temporary name.
            if let existing, existing.lastPathComponent != candidate {
                try recase(existing, to: target, in: documents, meetingID: item.meetingID)
            }
            return (target, false)
        }
        throw CocoaError(.fileWriteInvalidFileName)
    }

    private nonisolated static func recase(
        _ folder: URL,
        to target: URL,
        in documents: URL,
        meetingID: String
    ) throws {
        let fileManager = FileManager.default
        let staging = documents.appendingPathComponent(stagingPrefix + meetingID, isDirectory: true)
        guard !fileManager.fileExists(atPath: staging.path) else { return }
        try fileManager.moveItem(at: folder, to: staging)
        try fileManager.moveItem(at: staging, to: target)
    }

    /// Folders this app wrote, keyed by meeting id. Anything the user put in
    /// the folder has no marker and is invisible here — so it is never
    /// renamed and never deleted, however its name looks.
    private nonisolated static func ownedFolders(in documents: URL) -> [String: [URL]] {
        let existing = (try? FileManager.default.contentsOfDirectory(
            at: documents,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        var owned: [String: [URL]] = [:]
        for url in existing.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard isDirectory(url), let id = meetingID(inFolder: url) else { continue }
            owned[id, default: []].append(url)
        }
        return owned
    }

    private nonisolated static func write(
        _ item: Item,
        into folder: URL,
        created: Bool,
        shouldContinue: @Sendable () -> Bool
    ) throws {
        let fileManager = FileManager.default
        if meetingID(inFolder: folder) == nil {
            try Data().write(to: folder.appendingPathComponent(".\(markerPrefix)\(item.meetingID)"))
        }

        let notesURL = folder.appendingPathComponent(notesFileName)
        let notes = Data(item.notes.utf8)
        let previousNotes = try? Data(contentsOf: notesURL)
        if previousNotes != notes {
            try notes.write(to: notesURL, options: .atomic)
            // notes.md carries the whole transcript and lands in one
            // synchronous write. If the user opted out while it ran, take it
            // back here — with the setting off, no later sync will.
            guard shouldContinue() else {
                revert(folder: folder, created: created, notesURL: notesURL, to: previousNotes)
                return
            }
        }

        // Copy first, prune second: removing the recording this one replaces
        // before the replacement has landed would leave the meeting with no
        // audio at all if the copy then fails.
        if let source = item.audioSourceURL, let sourceSize = fileSize(at: source) {
            let destination = folder.appendingPathComponent(source.lastPathComponent)
            if !isCurrent(destination, sourceSize: sourceSize) {
                // Land the bytes under a hidden name so the previous copy
                // survives a failure part-way through.
                let partial = folder.appendingPathComponent(".\(source.lastPathComponent)\(partialSuffix)")
                try? fileManager.removeItem(at: partial)
                try fileManager.copyItem(at: source, to: partial)
                // The copy runs to completion whatever happens around it, so
                // a recording can land after the user opted out.
                guard shouldContinue() else {
                    try? fileManager.removeItem(at: partial)
                    return
                }
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.moveItem(at: partial, to: destination)
            }
        }

        // Keyed on what the meeting *says* its recording is, not on what
        // could be read: a temporarily unreadable local file must never
        // take the mirrored copy — possibly the last one — down with it.
        removeStaleAudio(in: folder, keeping: item.audioFileName)
    }

    /// Undoes a notes write the user opted out of mid-flight: a folder this
    /// run created goes entirely, and an existing one keeps the notes it
    /// already had.
    private nonisolated static func revert(folder: URL, created: Bool, notesURL: URL, to previous: Data?) {
        let fileManager = FileManager.default
        guard !created else {
            try? fileManager.removeItem(at: folder)
            return
        }
        if let previous {
            try? previous.write(to: notesURL, options: .atomic)
        } else {
            try? fileManager.removeItem(at: notesURL)
        }
    }

    /// Deleting a meeting must leave zero bytes behind, and a folder whose
    /// recording was replaced would otherwise keep the old one forever.
    /// Only recordings the mirror itself copied are ever removed — every one
    /// is named with a UUID, so an `agenda.mp3` the user dropped in the
    /// folder is left exactly where they put it.
    private nonisolated static func removeStaleAudio(in folder: URL, keeping current: String?) {
        let fileManager = FileManager.default
        let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names {
            let trimmed = localName(of: name)
            let path = URL(fileURLWithPath: trimmed)
            let isAudio = MeetingStore.audioFileExtensions.contains(path.pathExtension.lowercased())
            let isMirrored = UUID(uuidString: path.deletingPathExtension().lastPathComponent) != nil
            guard isAudio, isMirrored, trimmed != current else { continue }
            do {
                try fileManager.removeItem(at: folder.appendingPathComponent(name))
            } catch {
                logger.error("Removing stale audio failed: \(error.localizedDescription)")
            }
        }
    }

    /// The name a file has when its contents are local — evicted files are
    /// on disk as a hidden ".name.icloud" placeholder.
    private nonisolated static func localName(of name: String) -> String {
        guard name.hasPrefix("."), name.hasSuffix(placeholderSuffix) else { return name }
        return String(name.dropFirst().dropLast(placeholderSuffix.count))
    }

    /// Whether the mirrored audio can be left alone.
    private nonisolated static func isCurrent(_ destination: URL, sourceSize: Int64) -> Bool {
        // iCloud evicts local copies of synced files under storage
        // pressure, leaving a ".name.icloud" placeholder. The file is still
        // in iCloud Drive — re-copying it would just churn.
        let placeholder = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent)\(placeholderSuffix)")
        if FileManager.default.fileExists(atPath: placeholder.path) { return true }
        // ponytail: size compare, not checksums — recordings are written
        // once, so a matching size means the copy completed.
        return fileSize(at: destination) == sourceSize
    }

    private nonisolated static func fileSize(at url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
    }
}

/// Keeps the app awake long enough to finish background work (mirroring,
/// summary generation). iOS suspends a backgrounded app within seconds
/// otherwise.
@MainActor
final class BackgroundTaskToken {
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
