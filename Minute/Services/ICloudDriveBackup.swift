import CryptoKit
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
    /// Prefix of the marker naming the fingerprint of the last notes written.
    private static let notesMarkerPrefix = "minute-notes-"
    /// Bytes of SHA256 kept in that marker's name, rendered as lowercase hex.
    /// Long enough that two different notes colliding is not a practical
    /// concern, short enough to keep the file name unobtrusive.
    private static let fingerprintBytes = 8
    private static let hexDigits = Set("0123456789abcdef")
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

    /// Meetings deleted since some snapshot was taken. A snapshot is captured
    /// on the main actor and mirrored on a background task, so the user can
    /// delete a meeting while the run is still copying earlier ones — and each
    /// Item carries that meeting's full notes text in memory. One UUID per
    /// deletion for the life of the process is nothing beside writing a deleted
    /// transcript to iCloud, so nothing here is aged out; the only way an id
    /// leaves is `noteMeetingDeleteFailed`, when the delete did not commit.
    private nonisolated(unsafe) static var deletedMeetingIDs: Set<String> = []
    private static let deletedMeetingLock = NSLock()

    /// Tells any mirror run in flight that this meeting is gone. Safe from any
    /// thread and at any point around the delete — the mirror only reads.
    nonisolated static func noteMeetingDeleted(_ id: UUID) {
        deletedMeetingLock.lock()
        defer { deletedMeetingLock.unlock() }
        deletedMeetingIDs.insert(id.uuidString)
    }

    /// Takes that back when the delete did not commit. `MeetingStore.delete`
    /// re-inserts the meeting and returns false if the save throws, and the
    /// user is told the delete failed — so a noted deletion is a prediction,
    /// not a fact, and the caller must retract it on that rollback path.
    /// Without this the mirror would skip a meeting the user still has for the
    /// rest of the process, and the folder a run had already removed would stay
    /// gone from iCloud Drive with the backup still reported complete. The next
    /// sync re-creates it, the way it would for any meeting not mirrored yet.
    nonisolated static func noteMeetingDeleteFailed(_ id: UUID) {
        deletedMeetingLock.lock()
        defer { deletedMeetingLock.unlock() }
        deletedMeetingIDs.remove(id.uuidString)
    }

    private nonisolated static func isDeletedSinceSnapshot(_ meetingID: String) -> Bool {
        deletedMeetingLock.lock()
        defer { deletedMeetingLock.unlock() }
        return deletedMeetingIDs.contains(meetingID)
    }

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

    /// What one mirror run actually achieved. A Bool cannot carry the
    /// difference between "nothing could run", "ran but some meetings failed"
    /// and "was told to stop", and the callers treat all three differently:
    /// only `unavailable` means the feature can't work here, and only
    /// `interrupted` leaves the previous verdict standing because this run
    /// never reached a verdict of its own.
    ///
    /// Cases are declared in severity order so `max` folds many outcomes into
    /// one: the most alarming wins, and a run that both failed an item and
    /// stopped early reports the failure.
    enum SyncOutcome: Int, Sendable, Comparable {
        /// Every meeting mirrored and every stale folder swept.
        case complete
        /// Stopped early — the user opted out, the app was foregrounded, or
        /// the background assertion expired. Nothing is known to have failed.
        case interrupted
        /// Ran, but at least one meeting could not be written or removed.
        case incomplete
        /// Could not run at all: no iCloud container, or the device folder
        /// could not be prepared.
        case unavailable

        static func < (lhs: SyncOutcome, rhs: SyncOutcome) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
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
        var trimmed = Substring(text)
        while trimmed.utf8.count > limit { trimmed = trimmed.dropLast() }
        return String(trimmed)
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

    /// The payload carried in a marker file's name, whether the file is local
    /// or has been evicted to a placeholder. No validation — callers decide
    /// what a valid payload looks like for their prefix.
    private static func rawIdentity(fromMarkerName name: String, prefix: String) -> String? {
        if name.hasPrefix("." + prefix) {
            return String(name.dropFirst(prefix.count + 1))
        }
        if name.hasPrefix(".." + prefix), name.hasSuffix(placeholderSuffix) {
            // What iCloud leaves behind when it evicts the local copy.
            return String(name.dropFirst(prefix.count + 2).dropLast(placeholderSuffix.count))
        }
        return nil
    }

    private static func identity(fromMarkerName name: String, prefix: String) -> String? {
        guard let candidate = rawIdentity(fromMarkerName: name, prefix: prefix) else { return nil }
        // Every id the app writes is a UUID; anything else is not ours.
        return UUID(uuidString: candidate) != nil ? candidate : nil
    }

    /// Fingerprint of the notes last mirrored into a folder, carried in a
    /// marker file's *name* for the same reason the meeting id is: iCloud
    /// evicts file contents under storage pressure, and a fingerprint we
    /// cannot read is a fingerprint we cannot compare.
    ///
    /// This is what lets an evicted `notes.md` be told apart from a stale one.
    /// Reading the evicted file is impossible, and assuming "evicted means
    /// current" would strand every later edit — the mirror would never write
    /// the user's changed transcript, summary or title again.
    private nonisolated static func notesFingerprint(_ notes: Data) -> String {
        SHA256.hash(data: notes).prefix(fingerprintBytes).map { String(format: "%02x", $0) }.joined()
    }

    /// The fingerprint carried in a notes marker's name, or nil for anything
    /// else. Validated for exactly the reason the meeting id is checked as a
    /// UUID: a hidden file the user happens to name `.minute-notes-agenda`
    /// must not make itself app-owned and get swept with the meeting.
    private nonisolated static func notesFingerprint(fromMarkerName name: String) -> String? {
        guard let candidate = rawIdentity(fromMarkerName: name, prefix: notesMarkerPrefix),
              candidate.count == fingerprintBytes * 2,
              candidate.allSatisfy(hexDigits.contains)
        else { return nil }
        return candidate
    }

    private nonisolated static func holdsNotesMarker(_ folder: URL, fingerprint: String) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.contains { notesFingerprint(fromMarkerName: $0) == fingerprint }
    }

    /// Points the folder's notes marker at `fingerprint`, dropping any older
    /// one. Only called once the notes it describes are safely on disk.
    private nonisolated static func setNotesMarker(in folder: URL, fingerprint: String) {
        let fileManager = FileManager.default
        let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where notesFingerprint(fromMarkerName: name) != nil {
            try? fileManager.removeItem(at: folder.appendingPathComponent(name))
        }
        do {
            try Data().write(to: folder.appendingPathComponent(".\(notesMarkerPrefix)\(fingerprint)"))
        } catch {
            // Losing the marker only costs a redundant rewrite next sync.
            logger.error("Writing the notes marker failed: \(error.localizedDescription)")
        }
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
        ) throws -> SyncOutcome {
            // A newer snapshot already ran. Applying this one would undo it
            // — recreating the folder of a meeting it just deleted.
            //
            // Reported as `.interrupted`, never `.complete`: this run produced
            // no verdict of its own, and a background → foreground → background
            // cycle can land the older request here *after* the newer one
            // finished. Calling that success would clear a failure the newer
            // run had just recorded.
            guard request.sequence > applied else { return .interrupted }
            applied = request.sequence
            var outcome = SyncOutcome.complete
            for folder in try ICloudDriveBackup.deviceFolderURLs(for: request.device, in: documents) {
                let mirrored = try ICloudDriveBackup.mirror(
                    request.items,
                    into: folder,
                    shouldContinue: shouldContinue
                )
                outcome = Swift.max(outcome, mirrored)
            }
            return outcome
        }
    }

    /// Mirrors off the main thread. Returns false when the mirror can't run
    /// (iCloud Drive unavailable) **or** when any meeting failed to mirror, so
    /// the Settings toggle can tell the user rather than reporting a healthy
    /// backup that is missing half the library. Per-meeting errors are still
    /// logged and still don't stop the rest of the run — the next sync repairs
    /// whatever is missing.
    nonisolated static func syncNow(
        _ request: Request,
        shouldContinue: @escaping @Sendable () -> Bool = { true }
    ) async -> SyncOutcome {
        // Defense in depth: with the fallback store active the snapshot
        // holds only this session's meetings, so mirroring it would delete
        // every previously backed-up meeting from iCloud Drive.
        guard !MeetingStore.useEphemeralStorage else { return .unavailable }
        guard shouldContinue() else { return .interrupted }
        let resolved = Task.detached(priority: .utility) { documentsURL() }
        guard let documents = await resolved.value else { return .unavailable }
        guard shouldContinue() else { return .interrupted }
        do {
            // The preference is re-read as the mirror runs, so switching the
            // toggle off stops a sync this task doesn't own either — the
            // background one, say.
            return try await Mirrorer.shared.run(request, documents: documents) {
                shouldContinue() && !Task.isCancelled && AppSettings.iCloudDriveBackupEnabled
            }
        } catch {
            // Per-meeting problems are handled and logged inside the
            // mirror; anything reaching here means the folder itself could
            // not be prepared, so nothing was mirrored at all. Report it,
            // or the toggle claims a backup that does not exist.
            logger.error("iCloud Drive mirror failed: \(error.localizedDescription)")
            return .unavailable
        }
    }

    /// Fetches every meeting and mirrors it in the background. No-op unless
    /// the toggle is on and persistent storage is healthy. Called when the
    /// app enters the background — a copy cut short by suspension leaves a
    /// size mismatch the next sync repairs.
    @MainActor
    static func syncIfEnabled(context: ModelContext) -> BackgroundMirrorTask? {
        guard AppSettings.iCloudDriveBackupEnabled, !MeetingStore.useEphemeralStorage else { return nil }
        guard let meetings = try? context.fetch(FetchDescriptor<Meeting>()) else { return nil }
        let snapshot = request(for: meetings)
        // Copying a long meeting's audio outlasts the seconds iOS grants a
        // backgrounded app; without this the copy is cut mid-file every
        // time and never finishes.
        return BackgroundMirrorTask(name: "iCloud Drive mirror") { shouldContinue in
            let outcome = await syncNow(snapshot, shouldContinue: shouldContinue)
            // Remember the outcome. The mirror repairs itself on the next run,
            // but a permanently broken one — signed out of iCloud, or iCloud
            // Drive switched off in iOS Settings — would otherwise look exactly
            // like a working one while Settings kept promising a browsable
            // copy. Only record a verdict while the user still wants the
            // mirror: a run cut short by the toggle going off isn't a failure.
            guard AppSettings.iCloudDriveBackupEnabled else { return }
            switch outcome {
            case .complete:
                await MainActor.run { AppSettings.iCloudDriveLastSyncFailed = false }
            case .incomplete, .unavailable:
                await MainActor.run { AppSettings.iCloudDriveLastSyncFailed = true }
            case .interrupted:
                // Foregrounding the app or running out of background time says
                // nothing about whether the backup works. Claiming success
                // would clear a real warning; claiming failure would cry wolf
                // every time the user came back. Leave the last real verdict.
                break
            }
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
    /// Reports whether every meeting made it, so the caller can tell the user
    /// the backup is incomplete rather than clearing a warning over a
    /// half-written mirror. Stopping early is reported separately from
    /// failing: it leaves the previous verdict standing instead of claiming
    /// success for work that never ran.
    @discardableResult
    nonisolated static func mirror(
        _ items: [Item],
        into documents: URL,
        shouldContinue: @Sendable () -> Bool = { true }
    ) throws -> SyncOutcome {
        let fileManager = FileManager.default
        var outcome = SyncOutcome.complete
        guard shouldContinue() else { return .interrupted }
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
            guard shouldContinue() else { return Swift.max(outcome, .interrupted) }
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
            guard shouldContinue() else { return Swift.max(outcome, .interrupted) }
            // The snapshot is minutes old by the time a large library reaches
            // its last meetings, and every Item still holds that meeting's
            // whole notes text in memory: a meeting deleted since must not have
            // it written now, and must lose the folder an earlier sync gave it.
            // Everything it owns goes here rather than through the sweep below,
            // which judges by `chosen` and cannot see a folder this run parked
            // under a staging name — and which, handed URLs this loop already
            // removed, would report the run incomplete over folders that are
            // correctly gone.
            if isDeletedSinceSnapshot(item.meetingID) {
                if !takeBack(item.meetingID, owned: owned, parked: &parked, live: &live) {
                    outcome = .incomplete
                }
                continue
            }
            do {
                let placed = try place(item, existing: live[item.meetingID], in: documents)
                live[item.meetingID] = placed.url
                try write(
                    item,
                    into: placed.url,
                    created: placed.created,
                    verifyRecordingContents: (owned[item.meetingID]?.count ?? 0) > 1,
                    // A recording can be hundreds of megabytes and the copy
                    // runs to completion once started, so this is where a run
                    // spends nearly all of its time — and where a deletion is
                    // most likely to land. Let it stop the copy at the next
                    // check rather than finish writing a meeting that is
                    // already gone.
                    shouldContinue: { shouldContinue() && !isDeletedSinceSnapshot(item.meetingID) }
                )
            } catch {
                // One unmirrorable meeting still must not block the rest — but
                // the run is no longer a complete backup, and the caller has to
                // know that before it tells the user everything is safe.
                outcome = .incomplete
                logger.error("Mirroring \(item.folderName) failed: \(error.localizedDescription)")
            }
            // The check above is minutes old by the time a large recording has
            // finished copying, so ask again with the folder already written:
            // otherwise the meeting stays in `chosen`, the sweep below skips
            // it on that basis, and the run reports a complete backup with a
            // deleted transcript sitting in iCloud Drive until a later sync.
            // Failing to write it changes nothing here — a partly written
            // folder is exactly what has to go.
            if isDeletedSinceSnapshot(item.meetingID),
               !takeBack(item.meetingID, owned: owned, parked: &parked, live: &live) {
                outcome = .incomplete
            }
        }

        guard shouldContinue() else { return Swift.max(outcome, .interrupted) }

        // A meeting that is gone takes everything it left behind. A removal
        // that fails leaves a deleted meeting's notes and recording sitting in
        // iCloud Drive, which is exactly the kind of incompleteness the user
        // needs told about — silence here would clear the warning.
        for (id, urls) in owned where chosen[id] == nil {
            for url in urls where !removeMirror(at: url) {
                outcome = .incomplete
            }
        }
        // A duplicate goes only once the folder that was kept actually
        // holds a recording verified against the readable local source. If
        // the local file could not be read this round, a duplicate may hold
        // the only complete copy left.
        for item in items {
            guard let original = chosen[item.meetingID],
                  let keep = live[item.meetingID],
                  let candidates = owned[item.meetingID],
                  candidates.contains(where: { $0 != original })
            else { continue }
            guard holdsCurrentRecording(keep, for: item) else {
                logger.info("Kept duplicates of \(item.folderName): its recording is not in place yet")
                continue
            }
            // A duplicate left behind holds a copy of a meeting that still
            // exists, so it is clutter the next sync retries rather than a
            // hole in the backup — deliberately not counted against the run.
            for url in candidates where url != original {
                removeMirror(at: url)
            }
        }
        return outcome
    }

    /// Removes everything one meeting owns and forgets it, for a meeting the
    /// user deleted while this run was mirroring it. Deliberately kept out of
    /// the sweep below, which judges by `chosen`: the sweep cannot see a folder
    /// this run parked under a staging name, and — handed URLs already removed
    /// here — would report the run incomplete over folders that are correctly
    /// gone. Forgetting the meeting in `live` is what stops the duplicate prune
    /// from looking at it afterwards.
    ///
    /// Returns whether every removal succeeded; false means a deleted
    /// meeting's bytes are still in iCloud Drive, which the caller reports.
    private nonisolated static func takeBack(
        _ meetingID: String,
        owned: [String: [URL]],
        parked: inout [String: URL],
        live: inout [String: URL]
    ) -> Bool {
        let movedFrom = parked.removeValue(forKey: meetingID)
        var folders = (owned[meetingID] ?? []).filter { $0 != movedFrom }
        if let current = live.removeValue(forKey: meetingID), !folders.contains(current) {
            folders.append(current)
        }
        var removed = true
        for url in folders {
            // `owned` was read before this run renamed anything, so a folder
            // it names may since have moved to the name the item asked for —
            // and removing what is no longer there would count a folder that
            // is correctly gone as a removal that failed.
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if !removeMirror(at: url) { removed = false }
        }
        return removed
    }

    /// Whether the kept folder is safe enough for duplicate copies to go.
    /// Existence alone is not proof: a same-named file may be truncated, an
    /// iCloud placeholder has no locally verifiable bytes, and an unreadable
    /// source gives this run no trustworthy size to compare.
    private nonisolated static func holdsCurrentRecording(_ folder: URL, for item: Item) -> Bool {
        guard let name = item.audioFileName else { return true }
        guard let source = item.audioSourceURL, let sourceSize = fileSize(at: source) else { return false }
        return filesMatch(source, folder.appendingPathComponent(name), sourceSize: sourceSize)
    }

    /// Removes the artifacts the mirror wrote, and the folder itself only
    /// when nothing else is left in it. Deleting a meeting must leave zero
    /// bytes of it behind, but a file the user put in the folder is not the
    /// meeting — a recursive delete would take their work with it.
    /// Returns whether everything this app wrote is now gone. False means a
    /// deleted meeting's bytes are still sitting in iCloud Drive, which the
    /// caller reports rather than swallowing.
    @discardableResult
    private nonisolated static func removeMirror(at folder: URL) -> Bool {
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
            return false
        }
        for marker in markers {
            do {
                try fileManager.removeItem(at: folder.appendingPathComponent(marker))
            } catch {
                logger.error("Removing the marker failed: \(error.localizedDescription)")
                return false
            }
        }
        let remaining = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        guard remaining.isEmpty else {
            // Everything this app wrote is gone; what is left is the user's
            // own. That is a finished job, not a failed one.
            logger.info("Kept \(folder.lastPathComponent): it holds files this app did not write")
            return true
        }
        do {
            try fileManager.removeItem(at: folder)
            return true
        } catch {
            logger.error("Removing stale mirror failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Whether the mirror wrote this file: its marker, its notes, a
    /// UUID-named recording it copied, or a partial copy it left behind —
    /// each also in the hidden form iCloud leaves when it evicts one.
    private nonisolated static func isAppArtifact(_ name: String) -> Bool {
        if meetingID(fromMarkerName: name) != nil { return true }
        // The notes fingerprint marker is ours too — deleting a meeting has to
        // take it, or an emptied folder keeps a hidden file and never goes.
        if notesFingerprint(fromMarkerName: name) != nil { return true }
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
        verifyRecordingContents: Bool,
        shouldContinue: @Sendable () -> Bool
    ) throws {
        let fileManager = FileManager.default
        if meetingID(inFolder: folder) == nil {
            try Data().write(to: folder.appendingPathComponent(".\(markerPrefix)\(item.meetingID)"))
        }

        let notesURL = folder.appendingPathComponent(notesFileName)
        let notes = Data(item.notes.utf8)
        // Compare against the fingerprint in the marker's NAME rather than the
        // file's contents. Reading notes.md back would re-upload every meeting
        // on every sync once iCloud evicts the local copies (a nil read looks
        // like "never written"), while treating an evicted file as current
        // would strand every later edit. The name survives eviction, so it can
        // answer "did these notes change?" either way.
        // The marker alone is not enough: notes.md can be deleted out from
        // under it in Files or lost to an iCloud conflict, leaving neither the
        // file nor an eviction placeholder. Skipping then would strand the
        // folder without its transcript forever while every sync reported
        // success, so require the marker AND some form of the file.
        let fingerprint = notesFingerprint(notes)
        let notesPresent = fileManager.fileExists(atPath: notesURL.path)
            || fileManager.fileExists(
                atPath: folder.appendingPathComponent(".\(notesFileName)\(placeholderSuffix)").path
            )
        if !(notesPresent && holdsNotesMarker(folder, fingerprint: fingerprint)) {
            let previousNotes = try? Data(contentsOf: notesURL)
            try notes.write(to: notesURL, options: .atomic)
            // notes.md carries the whole transcript and lands in one
            // synchronous write. If the user opted out while it ran, take it
            // back here — with the setting off, no later sync will. The marker
            // is deliberately left untouched on this path: it still describes
            // what is on disk after the revert.
            guard shouldContinue() else {
                revert(folder: folder, created: created, notesURL: notesURL, to: previousNotes)
                return
            }
            setNotesMarker(in: folder, fingerprint: fingerprint)
        }

        // Copy first, prune second: removing the recording this one replaces
        // before the replacement has landed would leave the meeting with no
        // audio at all if the copy then fails.
        if let source = item.audioSourceURL, let sourceSize = fileSize(at: source) {
            let destination = folder.appendingPathComponent(source.lastPathComponent)
            if !isCurrent(
                destination,
                source: source,
                sourceSize: sourceSize,
                verifyContents: verifyRecordingContents
            ) {
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
    /// Mirrored recordings use UUID filenames, so stale cleanup treats any
    /// supported UUID-named audio as app-owned. A descriptive name such as
    /// `agenda.mp3` is preserved, but a user-added UUID-named file can be
    /// removed even when Minute did not copy it.
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
    private nonisolated static func isCurrent(
        _ destination: URL,
        source: URL,
        sourceSize: Int64,
        verifyContents: Bool
    ) -> Bool {
        // iCloud evicts local copies of synced files under storage
        // pressure, leaving a ".name.icloud" placeholder. The file is still
        // in iCloud Drive — re-copying it would just churn.
        let placeholder = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent)\(placeholderSuffix)")
        if FileManager.default.fileExists(atPath: placeholder.path) { return true }
        guard fileSize(at: destination) == sourceSize else { return false }
        // Recordings are immutable, so size is the efficient steady-state
        // check. Before a duplicate sweep would destroy another copy, compare
        // every byte and repair this one first if necessary.
        return !verifyContents || filesMatch(source, destination, sourceSize: sourceSize)
    }

    /// Exact comparison is reserved for destructive duplicate cleanup so
    /// ordinary background syncs do not reread every potentially large audio
    /// file merely to confirm an immutable copy is still present.
    private nonisolated static func filesMatch(_ source: URL, _ destination: URL, sourceSize: Int64) -> Bool {
        guard fileSize(at: destination) == sourceSize else { return false }
        do {
            let sourceHandle = try FileHandle(forReadingFrom: source)
            defer { try? sourceHandle.close() }
            let destinationHandle = try FileHandle(forReadingFrom: destination)
            defer { try? destinationHandle.close() }

            while true {
                let sourceChunk = try sourceHandle.read(upToCount: 1_048_576) ?? Data()
                let destinationChunk = try destinationHandle.read(upToCount: 1_048_576) ?? Data()
                guard sourceChunk == destinationChunk else { return false }
                if sourceChunk.isEmpty { return true }
            }
        } catch {
            return false
        }
    }

    private nonisolated static func fileSize(at url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
    }
}

/// Owns a lifecycle-triggered mirror so foregrounding or background-time
/// expiration can stop its immutable snapshot at the next safety boundary.
/// Cancellation rides on the Task itself: UIKit's expiration callback and
/// the lifecycle owner both funnel into `cancel()`, and the file-work
/// continuation checks observe it through `Task.isCancelled`.
@MainActor
final class BackgroundMirrorTask {
    private var token: BackgroundTaskToken?
    private var task: Task<Void, Never>?

    init(
        name: String,
        operation: @escaping @Sendable (@escaping @Sendable () -> Bool) async -> Void
    ) {
        let token = BackgroundTaskToken(name: name) { [weak self] in
            self?.cancel()
        }
        self.token = token
        task = Task { @MainActor in
            await operation { !Task.isCancelled }
            token.end()
        }
    }

    /// Returns the task so callers that need a graceful stop can await it.
    @discardableResult
    func cancel() -> Task<Void, Never>? {
        task?.cancel()
        token?.end()
        return task
    }
}

/// Keeps the app awake long enough to finish background work (mirroring,
/// summary generation). iOS suspends a backgrounded app within seconds
/// otherwise.
@MainActor
final class BackgroundTaskToken {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init(
        name: String,
        expirationHandler: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        // The expiration handler is documented to run on the main thread.
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated {
                expirationHandler()
                self?.end()
            }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
