import SwiftData
import SwiftUI

@main
struct MinuteApp: App {
    @Environment(\.scenePhase) private var scenePhase
    /// Lives at app level so summaries, re-transcriptions, and speaker
    /// identification keep running while the user navigates anywhere else in
    /// the app — and so their mutual-exclusion guard survives navigation.
    @State private var meetingJobs = MeetingJobs()
    @State private var backgroundMirror: BackgroundMirrorTask?
    private let container: ModelContainer
    private let storeIsEphemeral: Bool

    init() {
        if let persistent = try? ModelContainer(
            for: Meeting.self, KnowledgeEntity.self, KnowledgeFact.self,
            configurations: MeetingStore.modelConfiguration()
        ) {
            container = persistent
            storeIsEphemeral = false
        } else if let inMemory = try? ModelContainer(
            for: Meeting.self, KnowledgeEntity.self, KnowledgeFact.self,
            configurations: MeetingStore.modelConfiguration(inMemory: true)
        ) {
            // ponytail: corrupt store falls back to a session-only container so
            // recording still works; the list view shows a warning banner.
            container = inMemory
            storeIsEphemeral = true
        } else {
            fatalError("Unable to create a SwiftData container")
        }
        // In fallback mode, route new audio to a session-only directory; wipe
        // whatever a previous fallback session left there — no meeting can
        // reference those files anymore.
        MeetingStore.useEphemeralStorage = storeIsEphemeral
        MeetingStore.removeEphemeralRecordings()
        // Even in fallback mode, a (possibly corrupt) store and existing
        // recordings may still sit in Application Support — apply the user's
        // backup choice to it regardless of which directory receives new audio.
        MeetingStore.applyBackupPolicy()
        // A crash or force-quit mid-recording leaves its Live Activity on the
        // lock screen; no recording survives process death, so clear them.
        RecordingLiveActivityController.endOrphans()
        #if DEBUG
        DemoSeed.seedIfRequested(container: container)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            MeetingListView(storeIsEphemeral: storeIsEphemeral)
                .environment(meetingJobs)
        }
        .modelContainer(container)
        // Leaving the app is the one moment meeting data is settled and
        // there is still time to copy it — mirror to iCloud Drive then.
        .onChange(of: scenePhase) {
            backgroundMirror?.cancel()
            backgroundMirror = nil
            if scenePhase == .background {
                backgroundMirror = ICloudDriveBackup.syncIfEnabled(context: container.mainContext)
            }
        }
    }
}
