import Foundation

enum WidgetConstants {
    static let appGroupIdentifier = "group.com.minuteapp.Minute"
    static let widgetKind = "MinuteHomeWidget"
}

struct WidgetMeeting: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let title: String
    let createdAt: Date
    let duration: TimeInterval
}

struct WidgetSnapshot: Codable, Equatable, Sendable {
    static let empty = WidgetSnapshot(meetings: [])

    let meetings: [WidgetMeeting]
}

struct WidgetSnapshotStore {
    static let storageKey = "home-screen-widget.snapshot"
    private let defaults: UserDefaults?

    init(defaults: UserDefaults? = UserDefaults(suiteName: WidgetConstants.appGroupIdentifier)) {
        self.defaults = defaults
    }

    func load() -> WidgetSnapshot {
        validStoredSnapshot() ?? .empty
    }

    @discardableResult
    func save(_ snapshot: WidgetSnapshot) -> Bool {
        guard let defaults, validStoredSnapshot() != snapshot,
              let data = try? JSONEncoder().encode(snapshot) else { return false }
        defaults.set(data, forKey: Self.storageKey)
        return true
    }

    private func validStoredSnapshot() -> WidgetSnapshot? {
        guard let data = defaults?.data(forKey: Self.storageKey),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else { return nil }
        return snapshot
    }
}
