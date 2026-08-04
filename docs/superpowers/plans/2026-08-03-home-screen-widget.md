# Home Screen Widget Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a small and medium iPhone Home Screen widget that opens Minute's new-recording flow and displays recent meetings.

**Architecture:** Keep SwiftData private to the app. The app projects at most three meetings into a versioned JSON snapshot in an App Group, while the widget extension reads that snapshot and uses deep links to hand actions back to the app. WidgetKit reloads are event-driven after meaningful snapshot changes.

**Tech Stack:** Swift 5, SwiftUI, SwiftData, WidgetKit, Swift Testing, iOS 26.0+

## Global Constraints

- Support iOS 26.0 and later on iPhone only.
- Add no third-party dependency, server, analytics, telemetry, or app-owned network call.
- Share only meeting ID, title, creation date, and duration; never share audio, transcripts, summaries, speaker names, paths, or settings.
- The widget extension must not capture microphone input; recording begins only after the app opens its existing title-and-consent sheet.
- Preserve the current Live Activity, iCloud capabilities, background audio, recording flow, deletion guarantees, light/dark behavior, Dynamic Type, and VoiceOver support.
- Use App Group `group.com.minuteapp.Minute`, widget kind `MinuteHomeWidget`, and custom URL scheme `minute`.

## File structure

- Create `Shared/MinuteDeepLink.swift`: construct and parse app/widget URLs.
- Create `Shared/WidgetSnapshot.swift`: shared constants, metadata DTOs, and fault-tolerant App Group persistence.
- Create `Minute/Services/WidgetSnapshotPublisher.swift`: project SwiftData models and request WidgetKit reloads.
- Create `MinuteWidgets/MinuteHomeWidget.swift`: timeline provider and small/medium widget views.
- Create `MinuteWidgets/MinuteWidgets.entitlements`: widget App Group capability.
- Create `MinuteTests/MinuteDeepLinkTests.swift`: URL contract tests.
- Create `MinuteTests/WidgetSnapshotTests.swift`: persistence, version, corruption, and deduplication tests.
- Create `MinuteTests/WidgetSnapshotPublisherTests.swift`: ordering, truncation, projection, and reload tests.
- Modify `MinuteWidgets/MinuteWidgetsBundle.swift`: register the new standard widget without changing the Live Activity.
- Modify `Minute/Views/MeetingListView.swift`: publish visible metadata and route incoming widget URLs.
- Modify `Minute/Info.plist`: register the `minute` URL scheme.
- Modify `Minute/Minute.entitlements`: add the shared App Group while retaining iCloud entitlements.
- Modify `Minute.xcodeproj/project.pbxproj`: connect the widget entitlements file to Debug and Release.
- Modify `README.md` and `CONTRIBUTING.md`: document the widget, privacy boundary, and signing requirement.

---

### Task 1: Shared snapshot and deep-link contracts

**Files:**
- Create: `Shared/MinuteDeepLink.swift`
- Create: `Shared/WidgetSnapshot.swift`
- Test: `MinuteTests/MinuteDeepLinkTests.swift`
- Test: `MinuteTests/WidgetSnapshotTests.swift`

**Interfaces:**
- Produces: `enum MinuteDeepLink: Equatable { case newMeeting; case meeting(UUID); init?(url: URL); var url: URL }`
- Produces: `enum WidgetConstants { static let appGroupIdentifier: String; static let widgetKind: String }`
- Produces: `struct WidgetMeeting: Codable, Equatable, Identifiable, Sendable`
- Produces: `struct WidgetSnapshot: Codable, Equatable, Sendable { static let currentVersion: Int; static let empty: WidgetSnapshot }`
- Produces: `struct WidgetSnapshotStore { init(defaults: UserDefaults?); func load() -> WidgetSnapshot; @discardableResult func save(_:) -> Bool }`

- [ ] **Step 1: Write failing deep-link tests**

Create `MinuteTests/MinuteDeepLinkTests.swift`:

```swift
import Foundation
import Testing
@testable import Minute

struct MinuteDeepLinkTests {
    @Test func newMeetingRoundTrips() {
        let link = MinuteDeepLink.newMeeting
        #expect(link.url.absoluteString == "minute://new-meeting")
        #expect(MinuteDeepLink(url: link.url) == link)
    }

    @Test func meetingRoundTrips() {
        let id = UUID(uuidString: "D2495702-022C-4E72-A955-CB2968EA8B82")!
        let link = MinuteDeepLink.meeting(id)
        #expect(link.url.absoluteString == "minute://meeting/d2495702-022c-4e72-a955-cb2968ea8b82")
        #expect(MinuteDeepLink(url: link.url) == link)
    }

    @Test func malformedAndForeignURLsAreRejected() {
        #expect(MinuteDeepLink(url: URL(string: "other://new-meeting")!) == nil)
        #expect(MinuteDeepLink(url: URL(string: "minute://meeting/not-a-uuid")!) == nil)
        #expect(MinuteDeepLink(url: URL(string: "minute://unknown")!) == nil)
    }
}
```

- [ ] **Step 2: Write failing snapshot-store tests**

Create `MinuteTests/WidgetSnapshotTests.swift` with isolated defaults per test:

```swift
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
```

- [ ] **Step 3: Run the focused tests and confirm the red state**

Run:

```bash
xcodebuild -project Minute.xcodeproj -scheme Minute -derivedDataPath DerivedData \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:MinuteTests/MinuteDeepLinkTests \
  -only-testing:MinuteTests/WidgetSnapshotTests test
```

Expected: build failure because `MinuteDeepLink`, `WidgetSnapshot`, and related types do not exist.

- [ ] **Step 4: Implement the shared contracts**

Create `Shared/MinuteDeepLink.swift` with strict scheme/host/path parsing:

```swift
import Foundation

enum MinuteDeepLink: Equatable {
    private static let scheme = "minute"

    case newMeeting
    case meeting(UUID)

    var url: URL {
        switch self {
        case .newMeeting:
            URL(string: "\(Self.scheme)://new-meeting")!
        case .meeting(let id):
            URL(string: "\(Self.scheme)://meeting/\(id.uuidString.lowercased())")!
        }
    }

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme else { return nil }
        switch url.host?.lowercased() {
        case "new-meeting" where url.path.isEmpty:
            self = .newMeeting
        case "meeting":
            let components = url.pathComponents.filter { $0 != "/" }
            guard components.count == 1, let id = UUID(uuidString: components[0]) else { return nil }
            self = .meeting(id)
        default:
            return nil
        }
    }
}
```

Create `Shared/WidgetSnapshot.swift`:

```swift
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
    static let currentVersion = 1
    static let empty = WidgetSnapshot(meetings: [])

    let version: Int
    let meetings: [WidgetMeeting]

    init(version: Int = currentVersion, meetings: [WidgetMeeting]) {
        self.version = version
        self.meetings = meetings
    }
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
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data),
              snapshot.version == WidgetSnapshot.currentVersion else { return nil }
        return snapshot
    }
}
```

- [ ] **Step 5: Run the focused tests and confirm the green state**

Run the Step 3 command again. Expected: all `MinuteDeepLinkTests` and `WidgetSnapshotTests` pass.

- [ ] **Step 6: Commit the shared contracts**

```bash
git add Shared/MinuteDeepLink.swift Shared/WidgetSnapshot.swift MinuteTests/MinuteDeepLinkTests.swift MinuteTests/WidgetSnapshotTests.swift
git commit -m "feat: keep widget navigation and metadata bounded" \
  -m "Define the shared URL and snapshot contracts before either target consumes them." \
  -m "Constraint: Only ID, title, date, and duration may cross the App Group boundary." \
  -m "Confidence: high" -m "Scope-risk: narrow" \
  -m "Tested: MinuteDeepLinkTests and WidgetSnapshotTests" \
  -m "Co-authored-by: OmX <omx@oh-my-codex.dev>"
```

### Task 2: App-side snapshot projection and refresh

**Files:**
- Create: `Minute/Services/WidgetSnapshotPublisher.swift`
- Test: `MinuteTests/WidgetSnapshotPublisherTests.swift`

**Interfaces:**
- Consumes: `Meeting`, `WidgetSnapshot`, `WidgetSnapshotStore`, `WidgetConstants.widgetKind`
- Produces: `WidgetSnapshotPublisher.snapshot(from:limit:) -> WidgetSnapshot`
- Produces: `WidgetSnapshotPublisher.publish(_:store:reload:)`

- [ ] **Step 1: Write failing projection and reload tests**

Create `MinuteTests/WidgetSnapshotPublisherTests.swift`:

```swift
import Foundation
import Testing
@testable import Minute

@MainActor
struct WidgetSnapshotPublisherTests {
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
```

- [ ] **Step 2: Run the focused test and confirm the red state**

Run:

```bash
xcodebuild -project Minute.xcodeproj -scheme Minute -derivedDataPath DerivedData \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:MinuteTests/WidgetSnapshotPublisherTests test
```

Expected: build failure because `WidgetSnapshotPublisher` does not exist.

- [ ] **Step 3: Implement the publisher**

Create `Minute/Services/WidgetSnapshotPublisher.swift`:

```swift
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
```

- [ ] **Step 4: Run focused shared and publisher tests**

Run:

```bash
xcodebuild -project Minute.xcodeproj -scheme Minute -derivedDataPath DerivedData \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:MinuteTests/MinuteDeepLinkTests \
  -only-testing:MinuteTests/WidgetSnapshotTests \
  -only-testing:MinuteTests/WidgetSnapshotPublisherTests test
```

Expected: all focused tests pass.

- [ ] **Step 5: Commit the publisher**

```bash
git add Minute/Services/WidgetSnapshotPublisher.swift MinuteTests/WidgetSnapshotPublisherTests.swift
git commit -m "feat: refresh widgets from bounded meeting metadata" \
  -m "Project the newest meetings into the shared contract and skip redundant WidgetKit reload requests." \
  -m "Constraint: SwiftData remains private to the main app." \
  -m "Confidence: high" -m "Scope-risk: narrow" \
  -m "Tested: WidgetSnapshotPublisherTests and shared widget contract tests" \
  -m "Co-authored-by: OmX <omx@oh-my-codex.dev>"
```

### Task 3: Standard Home Screen widget

**Files:**
- Create: `MinuteWidgets/MinuteHomeWidget.swift`
- Modify: `MinuteWidgets/MinuteWidgetsBundle.swift`

**Interfaces:**
- Consumes: `WidgetSnapshotStore.load()`, `WidgetConstants.widgetKind`, and `MinuteDeepLink.url`
- Produces: `MinuteHomeWidget`, `MinuteWidgetEntry`, and `MinuteWidgetProvider`

- [ ] **Step 1: Add the timeline provider and sample states**

Create `MinuteWidgets/MinuteHomeWidget.swift` with:

```swift
import SwiftUI
import WidgetKit

struct MinuteWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct MinuteWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> MinuteWidgetEntry {
        MinuteWidgetEntry(date: .now, snapshot: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (MinuteWidgetEntry) -> Void) {
        completion(MinuteWidgetEntry(date: .now, snapshot: context.isPreview ? .sample : WidgetSnapshotStore().load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MinuteWidgetEntry>) -> Void) {
        let entry = MinuteWidgetEntry(date: .now, snapshot: WidgetSnapshotStore().load())
        completion(Timeline(entries: [entry], policy: .never))
    }
}

private extension WidgetSnapshot {
    static let sample = WidgetSnapshot(meetings: [
        WidgetMeeting(id: UUID(), title: "Product review", createdAt: .now.addingTimeInterval(-900), duration: 2_145),
        WidgetMeeting(id: UUID(), title: "Weekly sync", createdAt: .now.addingTimeInterval(-86_400), duration: 1_820),
    ])
}
```

- [ ] **Step 2: Implement the small and medium layouts**

In the same file, add `MinuteHomeWidget`, an entry view that switches on `@Environment(\.widgetFamily)`, and focused small/medium subviews:

```swift
struct MinuteHomeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetConstants.widgetKind, provider: MinuteWidgetProvider()) { entry in
            MinuteHomeWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color(.systemBackground) }
        }
        .configurationDisplayName("Quick Record & Recents")
        .description("Start a recording and return to recent meetings.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private let widgetAccent = Color(red: 0x4A / 255, green: 0x5C / 255, blue: 0xEC / 255)

private struct MinuteHomeWidgetView: View {
    let entry: MinuteWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemMedium:
            MediumMinuteWidgetView(meetings: entry.snapshot.meetings)
        default:
            SmallMinuteWidgetView(latest: entry.snapshot.meetings.first)
        }
    }
}

private struct WidgetIconTile: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "waveform")
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(
                    colors: [widgetAccent, widgetAccent.mix(with: .black, by: 0.18)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            )
            .widgetAccentable()
    }
}

private struct SmallMinuteWidgetView: View {
    let latest: WidgetMeeting?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                WidgetIconTile(size: 30)
                Text("Minute")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 0)
            }
            Spacer(minLength: 4)
            Label("New Meeting", systemImage: "mic.fill")
                .font(.headline)
                .foregroundStyle(widgetAccent)
                .widgetAccentable()
            Text("Open Minute to record")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Divider()
            if let latest {
                Text(latest.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(metadataText(for: latest))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("Recent meetings appear here")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .widgetURL(MinuteDeepLink.newMeeting.url)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilitySummary))
        .accessibilityHint("Opens Minute before recording begins")
    }

    private var accessibilitySummary: String {
        if let latest {
            return "New Meeting. Latest meeting: \(latest.title), \(metadataText(for: latest))"
        }
        return "New Meeting. No recent meetings"
    }
}

private struct MediumMinuteWidgetView: View {
    let meetings: [WidgetMeeting]

    var body: some View {
        HStack(spacing: 12) {
            Link(destination: MinuteDeepLink.newMeeting.url) {
                VStack(alignment: .leading, spacing: 7) {
                    WidgetIconTile(size: 40)
                    Spacer(minLength: 0)
                    Label("New Meeting", systemImage: "mic.fill")
                        .font(.headline)
                        .foregroundStyle(widgetAccent)
                        .widgetAccentable()
                    Text("Open Minute to record")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: 108)
            .accessibilityHint("Opens Minute before recording begins")

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                Text("Recent meetings")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if meetings.isEmpty {
                    Spacer(minLength: 0)
                    Text("Your recent meetings will appear here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                } else {
                    ForEach(Array(meetings.prefix(3))) { meeting in
                        Link(destination: MinuteDeepLink.meeting(meeting.id).url) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(meeting.title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(metadataText(for: meeting))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("\(meeting.title), \(metadataText(for: meeting))"))
                        .accessibilityHint("Opens this meeting in Minute")
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private func metadataText(for meeting: WidgetMeeting) -> String {
    let date = meeting.createdAt.formatted(date: .abbreviated, time: .shortened)
    guard meeting.duration > 0 else { return date }
    return "\(date) · \(durationText(meeting.duration))"
}

private func durationText(_ duration: TimeInterval) -> String {
    Duration.seconds(duration.rounded())
        .formatted(.time(pattern: duration >= 3_600 ? .hourMinuteSecond : .minuteSecond))
}
```

- [ ] **Step 3: Register the widget in the existing bundle**

Change `MinuteWidgetsBundle.body` to:

```swift
var body: some Widget {
    MinuteHomeWidget()
    RecordingLiveActivity()
}
```

- [ ] **Step 4: Build the widget target**

Run:

```bash
xcodebuild -project Minute.xcodeproj -target MinuteWidgets -configuration Debug -derivedDataPath DerivedData \
  -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build
```

Expected: `** BUILD SUCCEEDED **`. Inspect warnings and fix widget code warnings before continuing.

- [ ] **Step 5: Commit the widget UI**

```bash
git add MinuteWidgets/MinuteHomeWidget.swift MinuteWidgets/MinuteWidgetsBundle.swift
git commit -m "feat: make Minute available on the Home Screen" \
  -m "Add adaptive small and medium WidgetKit layouts for quick recording and recent meeting access." \
  -m "Constraint: The small family has one URL target; its latest meeting is read-only context." \
  -m "Confidence: high" -m "Scope-risk: narrow" \
  -m "Tested: MinuteWidgets simulator build" \
  -m "Co-authored-by: OmX <omx@oh-my-codex.dev>"
```

### Task 4: App routing, publishing, and capabilities

**Files:**
- Modify: `Minute/Views/MeetingListView.swift`
- Modify: `Minute/Info.plist`
- Modify: `Minute/Minute.entitlements`
- Create: `MinuteWidgets/MinuteWidgets.entitlements`
- Modify: `Minute.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `MinuteDeepLink`, `WidgetSnapshotPublisher`, and `WidgetSnapshot`
- Produces: URL-driven presentation of the existing new-meeting sheet and `MeetingDetailView`
- Produces: app/widget access to `group.com.minuteapp.Minute`

- [ ] **Step 1: Wire metadata publishing into `MeetingListView`**

Replace `justFinished` with `meetingDestination` everywhere so recordings, imports, and deep links share one navigation destination:

```swift
@State private var meetingDestination: Meeting?

.navigationDestination(item: $meetingDestination) { meeting in
    MeetingDetailView(meeting: meeting, autoGenerateSummary: AppSettings.autoSummarizeEnabled)
}
```

Add a derived snapshot and event-driven publisher:

```swift
private var widgetSnapshot: WidgetSnapshot {
    storeIsEphemeral ? .empty : WidgetSnapshotPublisher.snapshot(from: meetings)
}

// Attach to the root view modifiers.
.onChange(of: widgetSnapshot, initial: true) { _, snapshot in
    WidgetSnapshotPublisher.publish(snapshot)
}
```

Keep the existing `@Query` ordering and orphan sweep unchanged. Assign both completed recordings and imports to `meetingDestination`.

- [ ] **Step 2: Route incoming widget URLs**

Attach `.onOpenURL(perform: handleDeepLink)` to the root view and add:

```swift
private func handleDeepLink(_ url: URL) {
    guard let deepLink = MinuteDeepLink(url: url) else { return }
    switch deepLink {
    case .newMeeting:
        guard activeSession == nil else { return }
        beginNewMeeting()
    case .meeting(let id):
        if let meeting = meetings.first(where: { $0.id == id }) {
            meetingDestination = meeting
        } else {
            WidgetSnapshotPublisher.publish(widgetSnapshot)
        }
    }
}
```

Do not start `RecordingSession` in this handler; `beginNewMeeting()` must continue to present `NewMeetingSheet` first.

- [ ] **Step 3: Register the custom URL scheme**

Add this top-level entry to `Minute/Info.plist`:

```xml
<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleTypeRole</key>
        <string>Editor</string>
        <key>CFBundleURLName</key>
        <string>com.minuteapp.Minute</string>
        <key>CFBundleURLSchemes</key>
        <array>
            <string>minute</string>
        </array>
    </dict>
</array>
```

- [ ] **Step 4: Add the App Group capability to both targets**

Preserve every existing iCloud key in `Minute/Minute.entitlements` and add:

```xml
<key>com.apple.security.application-groups</key>
<array>
    <string>group.com.minuteapp.Minute</string>
</array>
```

Create `MinuteWidgets/MinuteWidgets.entitlements` with the same plist header and App Group entry only.

In `Minute.xcodeproj/project.pbxproj`:

- add `MinuteWidgets.entitlements` beside `Info.plist` in the MinuteWidgets synchronized-group `membershipExceptions`;
- add `CODE_SIGN_ENTITLEMENTS = MinuteWidgets/MinuteWidgets.entitlements;` to both widget build configurations;
- leave bundle identifiers, versions, iCloud settings, and app target entitlements unchanged.

- [ ] **Step 5: Run focused tests and build the integrated app**

Run:

```bash
xcodebuild -project Minute.xcodeproj -scheme Minute -derivedDataPath DerivedData \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:MinuteTests/MinuteDeepLinkTests \
  -only-testing:MinuteTests/WidgetSnapshotTests \
  -only-testing:MinuteTests/WidgetSnapshotPublisherTests test
xcodebuild -project Minute.xcodeproj -scheme Minute -derivedDataPath DerivedData \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

Expected: focused tests pass and the main scheme, including the embedded widget extension, reports `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit app integration and capabilities**

```bash
git add Minute/Views/MeetingListView.swift Minute/Info.plist Minute/Minute.entitlements \
  MinuteWidgets/MinuteWidgets.entitlements Minute.xcodeproj/project.pbxproj
git commit -m "feat: route Home Screen actions through Minute" \
  -m "Publish bounded meeting metadata and resolve widget URLs through the existing consent-first recording and detail flows." \
  -m "Constraint: Both targets require the same provisioned App Group for device builds." \
  -m "Confidence: high" -m "Scope-risk: moderate" \
  -m "Directive: Do not bypass NewMeetingSheet when handling the recording deep link." \
  -m "Tested: Focused widget contract tests and unsigned simulator scheme build" \
  -m "Co-authored-by: OmX <omx@oh-my-codex.dev>"
```

### Task 5: Documentation and full verification

**Files:**
- Modify: `README.md`
- Modify: `CONTRIBUTING.md`

**Interfaces:**
- Consumes: completed widget feature and exact App Group/signing behavior
- Produces: user installation guidance and contributor capability notes

- [ ] **Step 1: Update user-facing documentation**

In `README.md`:

- add a feature bullet explaining the optional small/medium Home Screen widget, quick-record handoff, and recent-meeting links;
- state that Home Screen metadata is limited to title/date/duration in the local App Group and is visible when the user installs the widget;
- add installation steps: long-press the Home Screen, choose **Edit → Add Widget**, search for **Minute**, select a size, and add it;
- add `WidgetSnapshotPublisher` plus `MinuteWidgets` to the architecture overview;
- extend the signing note to mention that App Groups, like the existing iCloud capabilities, need matching paid-team provisioning for physical-device builds.

In `CONTRIBUTING.md`, update the capability note so contributors know the app and extension must share `group.com.minuteapp.Minute`; keep the simulator guidance and no-dependency rule unchanged.

- [ ] **Step 2: Run formatting and project-integrity checks**

Run:

```bash
git diff --check
plutil -lint Minute/Info.plist Minute/Minute.entitlements MinuteWidgets/Info.plist MinuteWidgets/MinuteWidgets.entitlements
xcodebuild -project Minute.xcodeproj -list
```

Expected: no whitespace errors, all four plists report `OK`, and Xcode lists `MinuteWidgets` plus the `Minute` scheme.

- [ ] **Step 3: Run static analysis and the full test suite**

Run sequentially:

```bash
xcodebuild -project Minute.xcodeproj -scheme Minute -derivedDataPath DerivedData \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO analyze
xcodebuild -project Minute.xcodeproj -scheme Minute -derivedDataPath DerivedData \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

Expected: `** ANALYZE SUCCEEDED **` and `** TEST SUCCEEDED **`. The live Apple Intelligence integration test may skip itself when the model is unavailable; no other failure or unexpected skip is acceptable.

- [ ] **Step 4: Inspect widget and privacy diffs**

Run:

```bash
git diff -- Shared Minute MinuteWidgets MinuteTests README.md CONTRIBUTING.md Minute.xcodeproj/project.pbxproj
rg -n "audioFileName|transcript|summary|speakerNames" Shared/WidgetSnapshot.swift MinuteWidgets/MinuteHomeWidget.swift
```

Expected: the diff matches the design, and the privacy scan finds no shared/widget field or rendering reference to private meeting content.

- [ ] **Step 5: Verify the installed widget and recording deep link in Simulator**

Run these commands separately, accepting an "already booted" response from the boot command:

```bash
xcrun simctl list devices available
xcrun simctl boot "iPhone 17 Pro"
xcrun simctl install booted DerivedData/Build/Products/Debug-iphonesimulator/Minute.app
xcrun simctl launch booted com.minuteapp.Minute
xcrun simctl openurl booted minute://new-meeting
open -a Simulator
```

Confirm the URL presents **New Meeting** rather than starting the microphone. In Simulator, long-press the Home Screen, choose **Edit → Add Widget**, search for **Minute**, and verify both small and medium sizes. Confirm the small widget has one recording tap target, while the medium widget separates **New Meeting** from recent-meeting rows. Inspect empty, light, dark, tinted, large-text, and VoiceOver states and save small/medium screenshots as verification evidence outside the repository.

- [ ] **Step 6: Commit documentation**

```bash
git add README.md CONTRIBUTING.md
git commit -m "docs: make the Home Screen widget discoverable" \
  -m "Explain installation, local metadata sharing, and the device-signing capability contributors must configure." \
  -m "Confidence: high" -m "Scope-risk: narrow" \
  -m "Tested: plist lint, project listing, static analysis, and full simulator test suite" \
  -m "Not-tested: Physical-device widget gallery and App Group provisioning" \
  -m "Co-authored-by: OmX <omx@oh-my-codex.dev>"
```

- [ ] **Step 7: Perform a final clean-tree evidence check**

Run:

```bash
git status --short
git log -6 --oneline --decorate
```

Expected: no uncommitted changes and the widget implementation commits are visible above the design and plan commits.
