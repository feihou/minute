import SwiftData
import SwiftUI

@main
struct MinuteApp: App {
    private let container: ModelContainer
    private let storeIsEphemeral: Bool

    init() {
        if let persistent = try? ModelContainer(for: Meeting.self) {
            container = persistent
            storeIsEphemeral = false
        } else if let inMemory = try? ModelContainer(
            for: Meeting.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        ) {
            // ponytail: corrupt store falls back to a session-only container so
            // recording still works; the list view shows a warning banner.
            container = inMemory
            storeIsEphemeral = true
        } else {
            fatalError("Unable to create a SwiftData container for Meeting")
        }
        // In fallback mode, route new audio to a session-only directory; wipe
        // whatever a previous fallback session left there — no meeting can
        // reference those files anymore.
        MeetingStore.useEphemeralStorage = storeIsEphemeral
        MeetingStore.removeEphemeralRecordings()
    }

    var body: some Scene {
        WindowGroup {
            MeetingListView(storeIsEphemeral: storeIsEphemeral)
        }
        .modelContainer(container)
    }
}
