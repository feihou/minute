# Home Screen Widget Design

## Goal

Add a standard, user-addable iPhone Home Screen widget to Minute. The widget gives users a fast path into a new recording and shows recent meetings without weakening Minute's on-device privacy model.

## Product decisions

- Support the small and medium system widget families.
- The small widget shows a prominent **New Meeting** action and read-only context for the latest meeting. Its single tap target opens the new-meeting flow.
- The medium widget shows a distinct **New Meeting** action and up to three recent meetings. Each recent meeting is independently tappable.
- Starting from the widget opens Minute's existing title-and-recording-consent sheet. The widget extension never starts microphone capture itself.
- Recent meeting rows show only title, creation date/time, and duration.
- The widget uses system fonts, semantic colors, Dynamic Type-compatible layouts, and the app's waveform/accent visual language.

## Approaches considered

### Selected: compact App Group snapshot

The app serializes a small, versioned JSON snapshot to an App Group `UserDefaults` suite. The widget reads that snapshot and renders it using a static WidgetKit timeline. This keeps the extension independent from SwiftData and minimizes the amount of meeting data exposed outside the app sandbox.

### Rejected: launcher-only widget

A static recording launcher would require no shared data, but it would not satisfy the requirement to show recent meetings.

### Rejected: shared SwiftData store

Moving or duplicating the full database into an App Group would broaden the migration, concurrency, deletion, and corruption surface. The widget needs only a few metadata fields, so sharing the database provides no corresponding user benefit.

## Architecture

### Shared widget contract

Code compiled into both the app and `MinuteWidgets` defines:

- the App Group identifier and widget kind;
- `WidgetMeeting`, containing `id`, `title`, `createdAt`, and `duration`;
- a versioned `WidgetSnapshot` containing recent meetings;
- `WidgetSnapshotStore`, which reads and writes the encoded snapshot through an injected `UserDefaults` instance;
- `MinuteDeepLink`, which creates and parses `minute://new-meeting` and `minute://meeting/<uuid>` URLs.

The store has no network behavior. Decode failure, unavailable shared defaults, or a schema it cannot understand produces an empty snapshot.

### App-side publishing

An app-only publisher maps the newest meetings from SwiftData into `WidgetMeeting` values, sorts them newest-first, limits the snapshot to the widget's maximum needs, and writes only when the value changed. After a successful change it calls `WidgetCenter.shared.reloadTimelines(ofKind:)`.

`MeetingListView` publishes on initial load and whenever the widget-visible meeting metadata changes. This covers creation, import, title edits, duration changes, and deletion. If the app falls back to its ephemeral store, it publishes an empty snapshot so the widget does not advertise inaccessible meetings.

### Widget extension

The existing `MinuteWidgets` extension adds a `MinuteHomeWidget` beside `RecordingLiveActivity`.

Its timeline provider reads the current shared snapshot and returns one entry with a `.never` reload policy. App-side `WidgetCenter` reload requests are the refresh trigger; the widget does not poll.

The small family uses a single `widgetURL` for `minute://new-meeting`. The latest meeting metadata is informative but not independently tappable. The medium family uses SwiftUI `Link` views for the new-meeting action and each recent meeting row.

### App routing

The app registers the `minute` custom URL scheme and handles incoming URLs at the root scene.

- `minute://new-meeting` asks `MeetingListView` to populate the default title and present its existing new-meeting sheet.
- `minute://meeting/<uuid>` selects the matching `Meeting` and opens `MeetingDetailView`.
- Unsupported URLs and malformed identifiers are ignored.
- If a valid meeting link refers to a meeting that was deleted after the widget rendered, the app remains on the meeting list and republishes current widget data.

Routing is represented as a small value type so parsing can be tested without SwiftUI.

## Entitlements and configuration

- Add `group.com.minuteapp.Minute` to the app's existing entitlements.
- Add a widget-extension entitlements file containing the same App Group and connect it to both Debug and Release widget configurations.
- Register `minute` in the app's `CFBundleURLTypes`.
- Keep all existing iCloud, background-audio, and Live Activity capabilities unchanged.

App Group availability is a signing capability. Builds without the provisioned group must still compile; at runtime, snapshot access degrades to the empty state rather than affecting recording or meeting storage.

## Privacy and deletion

- Shared widget data stays on device and is readable only by Minute and its widget extension.
- The snapshot contains no audio path, audio bytes, transcript text, summary text, speaker names, or settings.
- The widget never reads or migrates the SwiftData database.
- Deleting a meeting republishes the complete bounded snapshot, removing that meeting's metadata from the shared container.
- No server, analytics, telemetry, or new dependency is introduced.

## Error handling

- Missing or corrupt snapshot: render the widget empty state and recover on the next app publish.
- App Group unavailable: preserve all app behavior and render the widget empty state.
- Stale meeting deep link: remain on the list without presenting an unrelated meeting.
- Widget reload delayed by the system: display the last valid snapshot; correctness is restored at the next granted reload.

## Accessibility and visual behavior

- Use semantic labels such as **New Meeting**, **Recent meetings**, and the full meeting title/date/duration for VoiceOver.
- Respect light, dark, tinted, and accented widget rendering modes through semantic foreground styles and WidgetKit container backgrounds.
- Truncate long titles visually while keeping their complete accessibility label.
- Empty state explains that recent meetings will appear after the user records one and keeps the new-meeting action available.

## Verification

Automated coverage will include:

- deep-link construction and parsing, including malformed URLs;
- snapshot encoding/decoding, empty and corrupt data, and write deduplication;
- newest-first mapping, truncation, and metadata-only projection;
- existing unit and UI tests to guard app behavior;
- explicit builds of the main app and widget extension.

Manual simulator verification should confirm that:

- the widget appears in the gallery in small and medium sizes;
- the small widget opens the title/consent sheet;
- medium-widget meeting links open the correct detail screen;
- creating, renaming, and deleting a meeting updates the widget when WidgetKit grants the reload;
- empty, dark, light, tinted, large-text, and VoiceOver states remain legible.

## Non-goals

- Starting microphone capture inside the widget extension.
- Pause, resume, or stop controls for an active recording; the existing Live Activity owns that presentation.
- Displaying transcript or summary content on the Home Screen.
- Configurable filtering, multiple widget kinds, Lock Screen accessory widgets, or StandBy-specific layouts.

## Official platform references

- [Linking to specific app scenes from a widget or Live Activity](https://developer.apple.com/documentation/widgetkit/linking-to-specific-app-scenes-from-your-widget-or-live-activity)
- [Configuring App Groups](https://developer.apple.com/documentation/xcode/configuring-app-groups)
- [Keeping a widget up to date](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date)
- [App extension limitations](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionOverview.html)
