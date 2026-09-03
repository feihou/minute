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

    /// The Application Support subdirectories the model caches live in.
    /// `WhisperModelStore.baseDirectory` and `MLXModelStore.baseDirectory`
    /// build these paths inline, so the names are duplicated here rather than
    /// shared — rename one there and this needs the same edit.
    private static let modelDirectoryNames = ["WhisperKitModels", "MLXModels"]

    /// Pins the data protection class on Minute's Application Support tree and
    /// the App Group container: the Application Support directory itself (so
    /// new files inherit it), the Recordings directory *and every file already
    /// inside it*, whichever of the two model-cache directories exist, the
    /// SwiftData store files, which `ModelContainer` creates before any policy
    /// runs, and the group container's root and Preferences directory. Call
    /// once at launch, after the container is open. Returns false when
    /// something could not be set.
    ///
    /// `setAttributes` on a directory is not recursive and only governs what is
    /// created inside it afterwards, which is why each of these is named. That
    /// is the whole point for audio: an install upgraded from the build that
    /// set class B carries a library of recordings a stamp on the directory
    /// would never reach, and those are exactly the files the iCloud Drive
    /// mirror copies from the background with the phone locked. Stamping only
    /// the directory would fix new recordings and leave the reported failure
    /// in place for everybody who already has meetings.
    ///
    /// The model directories are the same trap one level up. Both stores create
    /// their directory lazily, so on an install upgraded from the class-B build
    /// a model directory created afterwards inherited class B — and every file
    /// downloaded into it inherits class B in turn, for as long as that
    /// directory lives, not just once. Re-stamping the two roots closes that
    /// forward path, which is the half `dataProtectionClass` names when it says
    /// re-transcription opens the model files after a wait spent with the phone
    /// locked. What it does not do is reach the model files already inside:
    /// walking a downloaded weight tree on the launch path would cost more than
    /// it buys, and unlike a recording a model is re-downloadable — deleting
    /// and re-downloading it from Settings rewrites those files under the
    /// current class. The directories are stamped only if they are there; this
    /// pass does not materialise a cache for someone who downloaded no model.
    ///
    /// The App Group container gets the same treatment: its root, and
    /// `<group>/Library/Preferences` when it is there — the directory
    /// `UserDefaults` writes the widget snapshot plist into. The reader that
    /// decides this is the widget extension's timeline provider, which runs
    /// while the device is locked; a snapshot it cannot open is a blank widget
    /// on the lock screen, the same symptom class as the recordings above. And
    /// the group root is the same upgrade trap once more: an install upgraded
    /// from the shipped build carries class B there — `setExcludedFromBackup`
    /// used to stamp it — and keeps it until something re-stamps it, so naming
    /// the root is what closes the forward path for a plist written later.
    /// Both are stamped only if they are there; this pass creates nothing in
    /// the container, and the container itself is nil wherever the entitlement
    /// is not in force, which is the case the `appGroup` default resolves.
    ///
    /// `apply` is injected so tests can assert what gets which class: the
    /// simulator accepts `.protectionKey` and then reports it back as nil, so
    /// reading the attribute afterwards would assert nothing.
    @discardableResult
    static func applyDataProtection(
        base: URL? = nil,
        appGroup: URL? = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: WidgetConstants.appGroupIdentifier
        ),
        apply: (URL, FileProtectionType) throws -> Void = { url, protection in
            try FileManager.default.setAttributes([.protectionKey: protection], ofItemAtPath: url.path)
        }
    ) -> Bool {
        let root: URL
        do {
            root = try base ?? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            logger.error("Applying data protection failed: \(error.localizedDescription)")
            return false
        }
        var succeeded = true
        var targets = [root]
        // Scoped so a failure reaching the audio — a stray file where the
        // directory should be, a full disk — costs only the audio and still
        // leaves the store files stamped, which is the other half of the fix.
        do {
            let recordings = root.appendingPathComponent(recordingsDirectoryName, isDirectory: true)
            try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
            targets.append(recordings)
            // The directory is flat by construction — one file per recording —
            // so a shallow listing is the whole library, and this runs once per
            // launch. Sorted only to make the order deterministic: the file
            // system's is not, and a test that asserts what gets stamped needs
            // one.
            let existing = try FileManager.default.contentsOfDirectory(
                at: recordings,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            targets.append(contentsOf: existing.sorted { $0.lastPathComponent < $1.lastPathComponent })
        } catch {
            logger.error("Reaching the recordings for the data protection pass failed: \(error.localizedDescription)")
            succeeded = false
        }
        // Not created when absent, unlike Recordings: a model directory that is
        // not there means nothing has been downloaded, and whatever creates it
        // later will inherit the class from the root stamped above.
        for name in modelDirectoryNames {
            let url = root.appendingPathComponent(name, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) {
                targets.append(url)
            }
        }
        for name in storeFileNames {
            let url = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                targets.append(url)
            }
        }
        // Stamped, never created: `UserDefaults` owns the layout inside the
        // container, and a Preferences directory conjured here would be one it
        // never asked for.
        if let appGroup {
            targets.append(appGroup)
            let preferences = appGroup.appendingPathComponent("Library/Preferences", isDirectory: true)
            if FileManager.default.fileExists(atPath: preferences.path) {
                targets.append(preferences)
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

    /// Deletes the persistent store and every recording under it, so the next
    /// launch starts from an empty library.
    ///
    /// The only exit from fallback mode. When the persistent container cannot
    /// open, nothing else in the app can reach these files: Settings' Delete
    /// All Meetings iterates the empty in-memory library, and `delete` resolves
    /// audio through `recordingsDirectory()`, which points at the session-only
    /// temporary directory there. So the audio and transcripts on disk would
    /// otherwise sit at rest with no delete path at all — exactly what the
    /// "no data at rest without a delete path" invariant forbids — while the
    /// same failing open repeats at every launch. Removing the files is the
    /// whole operation: SwiftData recreates the store at the next launch, and
    /// this process keeps the in-memory container it already opened, which is
    /// why the caller tells the user to quit and reopen.
    ///
    /// Everything else in Application Support is left alone: downloaded
    /// Whisper and summary models are not meeting data and cost gigabytes to
    /// fetch again. Returns false when something could not be removed, so the
    /// caller can say so rather than promise a clean slate. `base` is a
    /// parameter so tests run against a scratch tree instead of the real
    /// Application Support directory.
    @discardableResult
    static func resetPersistentStore(base: URL? = nil) -> Bool {
        var succeeded = true
        do {
            let root = try base ?? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            var targets = storeFileNames.map { root.appendingPathComponent($0) }
            targets.append(root.appendingPathComponent(recordingsDirectoryName, isDirectory: true))
            for url in targets {
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    logger.error("Resetting the store could not remove \(url.lastPathComponent): \(error.localizedDescription)")
                    succeeded = false
                }
            }
        } catch {
            logger.error("Resetting the store failed: \(error.localizedDescription)")
            succeeded = false
        }
        return succeeded
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
