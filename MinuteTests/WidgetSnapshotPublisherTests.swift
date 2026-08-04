import Foundation
import Testing
@testable import Minute

@MainActor
struct WidgetSnapshotPublisherTests {
    // Catches projecting unsorted, unbounded, or transcript-bearing app models into the widget DTO.
    @Test func snapshotIsNewestFirstLimitedAndMetadataOnly() {
        let old = Meeting(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            title: "Old",
            createdAt: Date(timeIntervalSince1970: 100),
            duration: 10,
            audioFileName: "private.m4a",
            segments: [TranscriptSegment(text: "Private transcript", start: 0, end: 1)]
        )
        let middle = Meeting(title: "Middle", createdAt: Date(timeIntervalSince1970: 200), duration: 20)
        let newest = Meeting(title: "Newest", createdAt: Date(timeIntervalSince1970: 300), duration: 30)

        let snapshot = WidgetSnapshotPublisher.snapshot(from: [middle, old, newest], limit: 2)

        #expect(snapshot.meetings.map(\.title) == ["Newest", "Middle"])
        #expect(snapshot.meetings.map(\.duration) == [30, 20])
        #expect(snapshot.meetings.allSatisfy { !$0.title.contains("Private transcript") })
    }

    // Catches requesting WidgetKit refreshes when the stored shared snapshot is unchanged.
    @Test func publishReloadsOnlyWhenStoredValueChanges() {
        let suite = "com.minuteapp.MinuteTests.WidgetPublish.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WidgetSnapshotStore(defaults: defaults)
        let snapshot = WidgetSnapshot(meetings: [
            WidgetMeeting(id: UUID(), title: "Review", createdAt: .now, duration: 60),
        ])
        var reloads = 0

        WidgetSnapshotPublisher.publish(snapshot, store: store) { reloads += 1 }
        WidgetSnapshotPublisher.publish(snapshot, store: store) { reloads += 1 }

        #expect(reloads == 1)
    }
}
