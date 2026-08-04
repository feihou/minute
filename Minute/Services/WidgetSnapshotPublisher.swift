import WidgetKit

enum WidgetSnapshotPublisher {
    static let maximumMeetingCount = 3

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
