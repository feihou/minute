import Foundation
import Testing
@testable import Minute

struct WidgetSnapshotTests {
    private func defaults() -> (UserDefaults, String) {
        let suite = "com.minuteapp.MinuteTests.WidgetSnapshot.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    @Test func snapshotRoundTripsAndDuplicateWriteIsSkipped() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WidgetSnapshotStore(defaults: defaults)
        let meeting = WidgetMeeting(
            id: UUID(uuidString: "D2495702-022C-4E72-A955-CB2968EA8B82")!,
            title: "Design review",
            createdAt: Date(timeIntervalSince1970: 1_786_000_000),
            duration: 1_245
        )
        let snapshot = WidgetSnapshot(meetings: [meeting])

        #expect(store.load() == .empty)
        #expect(store.save(snapshot))
        #expect(store.load() == snapshot)
        #expect(!store.save(snapshot))
    }

    @Test func corruptDataReadsEmptyAndIsRepairedByTheNextSave() throws {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("corrupt".utf8), forKey: WidgetSnapshotStore.storageKey)
        let store = WidgetSnapshotStore(defaults: defaults)

        #expect(store.load() == .empty)
        #expect(store.save(.empty))
        let data = try #require(defaults.data(forKey: WidgetSnapshotStore.storageKey))
        #expect(try JSONDecoder().decode(WidgetSnapshot.self, from: data) == .empty)
    }

    @Test func unknownVersionReadsEmpty() throws {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let data = try JSONEncoder().encode(WidgetSnapshot(version: 999, meetings: []))
        defaults.set(data, forKey: WidgetSnapshotStore.storageKey)

        #expect(WidgetSnapshotStore(defaults: defaults).load() == .empty)
    }

    @Test func unavailableDefaultsReadsEmptyAndCannotSave() {
        let store = WidgetSnapshotStore(defaults: nil)
        #expect(store.load() == .empty)
        #expect(!store.save(.empty))
    }
}
