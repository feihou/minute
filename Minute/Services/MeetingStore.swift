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

    /// Whether the last attempt stuck. A transient failure (storage briefly
    /// unavailable at launch) would otherwise leave new recordings under the
    /// wrong backup policy for the rest of the process, so
    /// `recordingsDirectory()` retries while this is false — once it sticks,
    /// not on every call.
    private nonisolated(unsafe) static var backupPolicyApplied = false

    /// Applies the user's backup choice to the app's Application Support tree
    /// (recordings + SwiftData store) and to the App Group container (the
    /// widget snapshot, which carries meeting titles). Meeting data is
    /// excluded from iCloud/computer backups unless the user turned on the
    /// iCloud Backup toggle in Settings. Covers any corrupt store and older
    /// recordings still sitting there while the in-memory fallback is active,
    /// so this runs at launch independently of where new audio routes — and
    /// again whenever the toggle changes. Returns false when the policy
    /// couldn't be applied so the Settings toggle can tell the user instead of
    /// failing silently; a failed attempt is retried on the next
    /// recordings-directory access, so a transient failure heals itself.
    @discardableResult
    static func applyBackupPolicy() -> Bool {
        let excluded = !AppSettings.iCloudBackupEnabled
        var applied = true
        do {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            try setExcludedFromBackup(excluded, at: base)
        } catch {
            logger.error("Applying the backup policy failed: \(error.localizedDescription)")
            applied = false
        }
        // The widget snapshot lives outside the app container and carries
        // meeting titles and times. Application Support alone would leave those
        // in the device backup while the toggle promised nothing left the
        // phone. It is a derived cache the app republishes at every launch, so
        // excluding it costs the user nothing on restore.
        if let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: WidgetConstants.appGroupIdentifier
        ) {
            do {
                try setExcludedFromBackup(excluded, at: group)
            } catch {
                logger.error("Applying the backup policy to the App Group failed: \(error.localizedDescription)")
                applied = false
            }
        }
        backupPolicyApplied = applied
        return applied
    }

    /// Sets the backup-exclusion flag on one directory. Split out so tests can
    /// exercise the flip on a scratch directory instead of racing concurrent
    /// tests over the shared Application Support tree. The data protection
    /// class is applied separately — see `applyDataProtection`, which has to
    /// run after the SwiftData container exists.
    static func setExcludedFromBackup(_ excluded: Bool, at url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = excluded
        try url.setResourceValues(values)
    }

    /// The subdirectory of Application Support that holds meeting audio.
    private static let recordingsDirectoryName = "Recordings"

    /// SwiftData's on-disk files for the default configuration: the database
    /// plus its write-ahead log and shared-memory siblings. Named explicitly
    /// because both the data-protection pass and the fallback reset have to
    /// address them one by one — a directory attribute never reaches a file
    /// that already exists, and deleting only `default.store` leaves a -wal a
    /// later open replays.
    static let storeFileNames = ["default.store", "default.store-wal", "default.store-shm"]

    /// The data protection class Minute pins on its own files.
    ///
    /// Not `completeUnlessOpen` (class B), which is what this used to set.
    /// A class-B file that is closed cannot be reopened once the device locks,
    /// and Minute reads its own files precisely then: the iCloud Drive mirror
    /// starts on `scenePhase == .background`, which is exactly what locking the
    /// phone produces, and it copies each recording with `FileManager.copyItem`
    /// after the class key has been discarded; re-transcription and speaker
    /// identification open the audio (and the Whisper/MLX model files) after a
    /// model-preparation wait the user may well spend with the phone locked.
    /// The failures surfaced as "the last backup to iCloud Drive didn't
    /// finish — check that you're signed in to iCloud" while iCloud was fine.
    /// `completeUntilFirstUserAuthentication` still leaves everything
    /// unreadable until the first unlock after a reboot — the state a stolen
    /// powered-off phone is in — without breaking those reads.
    static let dataProtectionClass = FileProtectionType.completeUntilFirstUserAuthentication

    /// Pins the data protection class on everything Minute writes: the
    /// Application Support directory (so new files inherit it), the Recordings
    /// directory (which on an install upgraded from before the policy shipped
    /// already exists and keeps whatever class it was created with, so new
    /// audio inherits the wrong one), and the SwiftData store files, which
    /// `ModelContainer` creates before any policy runs and which a directory
    /// attribute therefore never reaches. `setAttributes` on a directory is not
    /// recursive and only governs what is created inside it afterwards, which
    /// is why each of these is named. Call once at launch, after the container
    /// is open. Returns false when something could not be set.
    ///
    /// `apply` is injected so tests can assert what gets which class: the
    /// simulator accepts `.protectionKey` and then reports it back as nil, so
    /// reading the attribute afterwards would assert nothing.
    @discardableResult
    static func applyDataProtection(
        base: URL? = nil,
        apply: (URL, FileProtectionType) throws -> Void = { url, protection in
            try FileManager.default.setAttributes([.protectionKey: protection], ofItemAtPath: url.path)
        }
    ) -> Bool {
        var succeeded = true
        do {
            let root = try base ?? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let recordings = root.appendingPathComponent(recordingsDirectoryName, isDirectory: true)
            try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
            var targets = [root, recordings]
            for name in storeFileNames {
                let url = root.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: url.path) {
                    targets.append(url)
                }
            }
            for url in targets {
                do {
                    try apply(url, dataProtectionClass)
                } catch {
                    logger.error("Pinning the data protection class on \(url.lastPathComponent) failed: \(error.localizedDescription)")
                    succeeded = false
                }
            }
        } catch {
            logger.error("Applying data protection failed: \(error.localizedDescription)")
            succeeded = false
        }
        return succeeded
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
            return try ModelContainer(
                for: Meeting.self, KnowledgeEntity.self, KnowledgeFact.self,
                configurations: modelConfiguration(inMemory: true)
            )
        } catch {
            fatalError("Unable to create the in-memory preview container: \(error)")
        }
    }
    #endif

    static func recordingsDirectory() throws -> URL {
        // The policy is applied at launch and whenever the Settings toggle
        // flips, which covers every moment it can actually change — so this
        // used to re-apply it unconditionally and cost three syscalls on the
        // main thread per call, on a path reached from view bodies
        // (audioURL(for:)) and therefore from every redraw of a summarizing
        // meeting. Retry only while it has not yet stuck, which keeps the
        // documented self-healing for a transient failure at no steady cost.
        if !backupPolicyApplied {
            applyBackupPolicy()
        }
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
        let directory = base.appendingPathComponent(recordingsDirectoryName, isDirectory: true)
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

    /// What the user is agreeing to when they confirm a delete. Lives here
    /// rather than in either view because both the list and the detail screen
    /// ask the same question about the same operation, and a promise about
    /// what `delete` removes must not drift between the two places it is made.
    /// "learned only from this meeting" is the literal truth: a fact another
    /// meeting also states keeps that meeting as a source and survives.
    static let deleteMeetingWarning = "The recording, transcript, summary, and everything Brain learned only from this meeting will be permanently deleted from this iPhone."

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
            // Undo just this deletion. Left pending, it would be committed by
            // the next save from anywhere — the detail view's onDisappear, a
            // summary finishing — silently deleting a meeting we had just told
            // the user we could not delete, and orphaning its audio on the way
            // out. Re-inserting restores this one object without a
            // context-wide rollback(), which would also discard unrelated
            // unsaved edits in the shared main context.
            context.insert(meeting)
            return false
        }
        if let audioFileName {
            deleteAudioFile(named: audioFileName)
        }
        // A fact's sources are a codable list rather than a SwiftData
        // relationship, so nothing cascades to them — a deleted meeting would
        // keep speaking through the facts it produced. `reconcile` takes no
        // meeting on purpose: with sources a uniform list, dropping one
        // deleted meeting's support and reconciling the whole library are the
        // same pass, so this both retires the facts only this meeting
        // supported and clears anything an earlier failed pass left behind.
        // Deliberately after the meeting delete commits: a failure here must
        // not resurrect the meeting, and the launch pass in MeetingListView
        // catches whatever a failed save leaves behind.
        KnowledgeStore.reconcile(context: context)
        return true
    }

    /// The audio files the library still references, or nil when the store
    /// couldn't be read. The launch sweep deletes everything NOT in this set,
    /// so a failed read must never be mistaken for an empty library — the
    /// knowledge sweep already refuses to run on one, and the audio sweep
    /// must too.
    static func referencedAudioFileNames(context: ModelContext) -> Set<String>? {
        do {
            let meetings = try context.fetch(FetchDescriptor<Meeting>())
            return Set(meetings.compactMap(\.audioFileName))
        } catch {
            logger.error("Could not read the library before sweeping orphaned audio, so nothing was swept: \(error.localizedDescription)")
            return nil
        }
    }

    /// Removes audio files that no meeting references (e.g. left behind by a
    /// crash mid-recording), so no recording lingers on disk invisibly.
    /// `directory` defaults to the live recordings directory; tests pass a
    /// scratch one so they aren't sweeping a directory other tests are writing
    /// fixtures into at the same time.
    static func removeOrphanedAudio(referencedFileNames: Set<String>, in directory: URL? = nil) {
        guard let directory = directory ?? (try? recordingsDirectory()),
              let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return }
        for name in files where isAudioFile(name) && !referencedFileNames.contains(name) {
            let url = directory.appendingPathComponent(name)
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                logger.error("Failed to delete audio file \(name): \(error.localizedDescription)")
            }
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
