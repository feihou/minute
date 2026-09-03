import SwiftData
import SwiftUI

@main
struct MinuteApp: App {
    private enum AppTab: Hashable {
        case meetings, brain
    }

    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: AppTab = .meetings
    /// Lives at app level so summaries, re-transcriptions, and speaker
    /// identification keep running while the user navigates anywhere else in
    /// the app — and so their mutual-exclusion guard survives navigation.
    @State private var meetingJobs: MeetingJobs
    @State private var knowledgeCatchUp: KnowledgeCatchUp
    @State private var backgroundMirror: BackgroundMirrorTask?
    private let container: ModelContainer
    private let storeIsEphemeral: Bool

    init() {
        var persistent: ModelContainer?
        var failure: String?
        do {
            persistent = try ModelContainer(
                for: Meeting.self, KnowledgeEntity.self, KnowledgeFact.self,
                configurations: MeetingStore.modelConfiguration()
            )
        } catch {
            // Recorded, not swallowed. This is the one failure the user can
            // neither see nor act on, and the same open is retried identically
            // at every launch — so a deterministic cause (a lightweight
            // migration that cannot run, the case KnowledgeFact documents)
            // strands the store and every recording forever. Settings reads
            // this to say what went wrong and to offer the reset.
            failure = error.localizedDescription
        }
        if let persistent {
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
        // Written on every launch, success included, so a store that recovers
        // retires the message and the reset button with it.
        AppSettings.persistentStoreFailure = failure
        // In fallback mode, route new audio to a session-only directory; wipe
        // whatever a previous fallback session left there — no meeting can
        // reference those files anymore.
        MeetingStore.useEphemeralStorage = storeIsEphemeral
        MeetingStore.removeEphemeralRecordings()
        // Even in fallback mode, a (possibly corrupt) store and existing
        // recordings may still sit in Application Support — apply the user's
        // backup choice to it regardless of which directory receives new audio.
        MeetingStore.applyBackupPolicy()
        // After the container above, not before: the store files exist only
        // once ModelContainer has created them, and a class set on the
        // directory never reaches a file that already exists.
        MeetingStore.applyDataProtection()
        // A crash or force-quit mid-recording leaves its Live Activity on the
        // lock screen; no recording survives process death, so clear them.
        RecordingLiveActivityController.endOrphans()
        #if DEBUG
        DemoSeed.seedIfRequested(container: container)
        #endif
        // Before anything reads a fact: rows written before `sources` existed
        // carry their support in the old columns, and every read downstream
        // looks only at `sources`. Idempotent, so this is a no-op thereafter.
        KnowledgeMigration.backfillSources(context: container.mainContext)
        let jobs = MeetingJobs()
        let catchUp = KnowledgeCatchUp()
        let mainContext = container.mainContext
        jobs.onContentChanged = { catchUp.nudge(context: mainContext) }
        _meetingJobs = State(initialValue: jobs)
        _knowledgeCatchUp = State(initialValue: catchUp)
    }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $selectedTab) {
                Tab("Meetings", systemImage: "mic.fill", value: AppTab.meetings) {
                    MeetingListView(storeIsEphemeral: storeIsEphemeral)
                }
                Tab("Brain", systemImage: "brain.head.profile", value: AppTab.brain) {
                    BrainView()
                }
            }
            .environment(meetingJobs)
            .environment(knowledgeCatchUp)
            // App-wide, not per-tab: knowledge lives in the same fallback
            // store as meetings, so the warning must be visible from the
            // Brain tab too.
            .safeAreaInset(edge: .bottom) {
                if storeIsEphemeral {
                    Label("Storage is unavailable — anything from this session won't be kept after the app closes.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .padding(10)
                        .frame(maxWidth: .infinity)
                        .glassEffect(.regular.tint(.yellow.opacity(0.35)), in: .rect(cornerRadius: 16))
                        .padding(.horizontal)
                }
            }
            // Deep links (widget, Shortcuts) are meeting-scoped: land on the
            // Meetings tab. MeetingListView keeps its own onOpenURL handler —
            // it loads with the initial tab, so the handler stays registered
            // even while Brain is frontmost; this one only flips the tab.
            .onOpenURL { url in
                if MinuteDeepLink(url: url) != nil {
                    selectedTab = .meetings
                }
            }
        }
        .modelContainer(container)
        // Leaving the app is the one moment meeting data is settled and
        // there is still time to copy it — mirror to iCloud Drive then.
        .onChange(of: scenePhase) {
            backgroundMirror?.cancel()
            backgroundMirror = nil
            if scenePhase == .active {
                knowledgeCatchUp.nudge(context: container.mainContext)
            } else {
                // Foreground-only: FM rate-limits background apps anyway.
                knowledgeCatchUp.pause()
            }
            if scenePhase == .background {
                backgroundMirror = ICloudDriveBackup.syncIfEnabled(context: container.mainContext)
            }
        }
    }
}
