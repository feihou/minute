import WidgetKit

enum WidgetSnapshotPublisher {
    static let maximumMeetingCount = 3

    /// How long a burst of snapshot changes is collected before one write.
    /// A meeting's title and duration change while the user is still working
    /// — a rename, a job landing — and the list view is the NavigationStack
    /// root, so it re-evaluates for every one of them; each change was
    /// otherwise its own App Group write and its own WidgetKit reload
    /// request. Short enough that nothing waits on it, and leaving the app
    /// flushes whatever is pending anyway.
    static let coalescingWindow = Duration.milliseconds(500)

    static func snapshot(from meetings: [Meeting], limit: Int = maximumMeetingCount) -> WidgetSnapshot {
        let recent = meetings
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(max(0, limit))
            .map {
                WidgetMeeting(
                    id: $0.id,
                    title: $0.title,
                    createdAt: $0.createdAt,
                    duration: $0.duration
                )
            }
        return WidgetSnapshot(meetings: Array(recent))
    }

    @MainActor
    static func publish(
        _ snapshot: WidgetSnapshot,
        store: WidgetSnapshotStore = WidgetSnapshotStore(),
        reload: () -> Void = { WidgetCenter.shared.reloadTimelines(ofKind: WidgetConstants.widgetKind) }
    ) {
        if store.save(snapshot) {
            reload()
        }
    }
}
