# Review Fixes, Batch 2 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the remaining confirmed findings of the 2026-09-02 functional review (report: https://claude.ai/code/artifact/5c878fef-8f93-41eb-823c-de180d128bf3) that batch 1 (PR #51) deferred, plus the follow-ups its whole-branch review raised.

**Architecture:** Four file-disjoint tracks (C engines and downloads; D recording and playback; F1 views, app entry, meeting store; F2 summaries, backup, knowledge, docs) run in separate worktrees off `main` at 8c443be and merge back; a short sequential Track E then wires the cross-track hand-offs. Every task is a failing-test-first change where the code is testable; pure SwiftUI wiring and hardware paths are verified by build plus the full unit suite.

**Tech Stack:** Swift 5 language mode, SwiftUI, SwiftData, Swift Testing, FoundationModels, WhisperKit 1.0.0, mlx-swift-lm 3.31.4, swift-huggingface 0.9.0. Xcode 26.6, iOS 26.5 simulators.

## Global Constraints

- Privacy invariants from CONTRIBUTING.md hold: no meeting content on the wire; every byte written has a delete path (MeetingStore.delete or the launch sweeps); AI output stays grounded ("Not specified" literal); recording never depends on optional capabilities and any handled failure still offers to save captured audio.
- No new third-party dependencies. Do not edit Minute.xcodeproj/project.pbxproj.
- Unit tests use Swift Testing, never XCTest. SwiftData-touching test structs are `@MainActor` with an in-memory container via `MeetingStore.modelConfiguration(inMemory: true)`; containers holding KnowledgeEntity/KnowledgeFact are retained for the process lifetime (retainedContainers pattern in MinuteTests/KnowledgeCatchUpTests.swift).
- Swift 5 language mode: an actor-isolated expression cannot be a default argument (use the nil-defaulted injection pattern).
- Baseline at the branch point (8c443be): **292 tests in 43 suites pass**. Every task leaves that green plus its own new tests.
- SwiftLint is strict in CI (.swiftlint.yml): match the codebase style; no `for … where` around side effects; `line_length` is disabled. swiftlint is not installed locally.
- Commit messages: Conventional Commits, ending with the trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Explicit paths; never `git add -A`; never commit anything under `.superpowers/`.
- A task edits only files its track owns (each track section lists them); cross-track needs are Track E hand-offs.
- After a committed delete a SwiftData object has `isDeleted == false` and `modelContext == nil`; guard stale reads with `isGone` (Minute/Models/PersistentModel+IsGone.swift).
- Simulators: Track C "iPhone 17 Pro", Track D "iPhone 17", Track F1 "iPhone 17 Pro Max", Track F2 "iPhone Air", Track E "iPhone 17 Pro". Substitute the track's device in every test command.

---

## Track C — Engines and downloads

Findings closed here: F71 (engine side), F08, F07, F45, F12, F13, F05, F11.

**Files this track owns** (a task must not edit anything else):
`Minute/Services/WhisperTranscriptionService.swift`, `Minute/Services/WhisperDownloadCenter.swift`,
`Minute/Services/MLXSummarizationService.swift`, `Minute/Services/MLXDownloadCenter.swift`,
`Minute/Services/SummarizationEngine.swift`, `Minute/Services/TranscriptionEngine.swift`,
`Minute/Services/AudioImporter.swift`, `Minute/Views/TranscriptionModelView.swift`,
`Minute/Views/SummaryModelView.swift`, plus `MinuteTests/WhisperModelStoreTests.swift`,
`MinuteTests/TranscriptionEngineSettingsTests.swift`, `MinuteTests/SummarizationEngineSettingsTests.swift`,
`MinuteTests/TranscriptionUnavailableErrorTests.swift`, `MinuteTests/AudioImporterTests.swift`,
and new test files for these types.

### Global Constraints

- Privacy invariants from CONTRIBUTING.md hold: no meeting content on the wire; every byte written has a delete path (MeetingStore.delete or the launch sweeps); AI output stays grounded ("Not specified" literal); recording never depends on optional capabilities and any handled failure still offers to save captured audio.
- No new third-party dependencies. Do not edit `Minute.xcodeproj/project.pbxproj` (new files under `Minute/`, `MinuteTests/`, `Shared/`, `MinuteWidgets/` are picked up automatically).
- Unit tests use Swift Testing (`import Testing`, `@Test`, `#expect`, `#require`), never XCTest. SwiftData-touching test structs are `@MainActor` with an in-memory container via `MeetingStore.modelConfiguration(inMemory: true)`; containers holding `KnowledgeEntity`/`KnowledgeFact` are retained for the process lifetime (`retainedContainers` pattern in `MinuteTests/KnowledgeCatchUpTests.swift`).
- The project builds in Swift 5 language mode: an actor-isolated expression cannot be a default argument (use the nil-defaulted injection pattern: `engine: (any Engine)? = nil` then `let engine = engine ?? Engines.current()`).
- Baseline at the branch point (commit `8c443be` on main): **292 tests in 43 suites pass**. Every task leaves that green plus its own new tests.
- SwiftLint is strict in CI (`.swiftlint.yml` disables line_length, function/type/file length, cyclomatic_complexity, identifier_name, todo, redundant_optional_initialization, trailing_comma, for_where): match the codebase style — 4-space indent, doc comments that explain WHY, no `for … where` wrapping side effects. `swiftlint` is not installed locally.
- Commit messages: Conventional Commits (`fix:`/`test:`/`docs:`), ending with the trailer line `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Commit with explicit paths; never `git add -A`; never commit anything under `.superpowers/`.
- A task edits only files its track owns (listed above). If a fix genuinely needs a file another track owns, the task ends at the owned side (e.g. adds a hook/property) and the plan section's "Hand-offs to Track E" list names the one-line wiring the post-merge track must do.
- SwiftData fact established in batch 1: after a committed delete an object has `isDeleted == false` and `modelContext == nil`; guard stale reads with the `PersistentModel` `isGone` extension (`Minute/Models/PersistentModel+IsGone.swift`), never `isDeleted`.

**Test commands** (from the worktree root `/Users/feihou/workplace/minute/.claude/worktrees/app-code-review-e76404`; this track uses simulator "iPhone 17 Pro"):

One suite while iterating:
```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MinuteTests/<SuiteName> CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Full unit suite, once before each commit:
```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```

**Line numbers** in this section are as of commit `8c443be` and shift as earlier tasks in this track land. Every replacement quotes the exact current text; **the quoted old snippet is the authoritative anchor** — find it, don't count lines.

**Package sources cited in this section** (read-only; the exact APIs were verified there):
- WhisperKit 1.0.0 (rev 25c6299): `/Users/feihou/Library/Developer/Xcode/DerivedData/Minute-aniwhiyqmtxllnfdgshpvtisjlok/SourcePackages/checkouts/WhisperKit`
- mlx-swift-lm: `/Users/feihou/Library/Developer/Xcode/DerivedData/Minute-aniwhiyqmtxllnfdgshpvtisjlok/SourcePackages/checkouts/mlx-swift-lm`
- swift-huggingface: `/Users/feihou/Library/Developer/Xcode/DerivedData/Minute-aniwhiyqmtxllnfdgshpvtisjlok/SourcePackages/checkouts/swift-huggingface`

---

### Task 1: Whisper reports that it is loading its model (F71, engine side)

**Files:**
- Modify: `Minute/Services/TranscriptionEngine.swift:6-11` (the `TranscriptionAvailability` enum)
- Modify: `Minute/Services/AudioImporter.swift:115-117` (the `.unknown, .downloadingModel` case)
- Modify: `Minute/Services/WhisperTranscriptionService.swift:266-276` (top of `runLiveLoop`)
- Test: `MinuteTests/AudioImporterTests.swift` (add at the end of the struct, after `importWithNoRecognizedSpeechExplainsItself`)

**Interfaces:**
- Consumes: `TranscriptionAvailability` (`case unknown, available, downloadingModel, unavailable(String)`), `AudioImporter.importAudio(from:context:transcription:) async throws -> Result`, `WhisperTranscriptionService.loadedWhisperKit() async -> WhisperKit?`.
- Produces: `TranscriptionAvailability.loadingModel` — a new case every switch over the enum must handle; `RecordingView`'s `default:` branch keeps compiling but renders "Listening…" (Track E hand-off).

- [ ] **Step 1: Write the failing test**

Add to `MinuteTests/AudioImporterTests.swift`, inside `struct AudioImporterTests`, after `importWithNoRecognizedSpeechExplainsItself`:

```swift
    /// An engine whose model is still loading when the import starts —
    /// Whisper reports this while Core ML specializes the weights.
    @MainActor
    private final class LoadingTranscriptionEngine: TranscriptionEngine {
        var availability: TranscriptionAvailability = .loadingModel
        var volatileText = ""
        var segments: [TranscriptSegment] = []
        var timestampOffset: TimeInterval = 0
        func prepare() async {}
        func start(inputFormat: AVAudioFormat) async -> (@Sendable (AVAudioPCMBuffer) -> Void)? { nil }
        func finish() async -> [TranscriptSegment] { [] }
        func cancel() async {}
        func transcribe(file: AVAudioFile) async throws -> [TranscriptSegment] { [] }
    }

    @Test func importWhileTheModelIsStillLoadingSaysTheModelWasntReady() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let source = try makeWavFixture()
        defer { try? FileManager.default.removeItem(at: source) }

        let result = try await AudioImporter.importAudio(
            from: source, context: context, transcription: LoadingTranscriptionEngine()
        )

        // A loading model is a not-ready model, exactly like a downloading
        // one: the audio is kept and the note says why there's no transcript.
        #expect(result.meeting.segments.isEmpty)
        #expect(result.transcriptionNote == "The audio was imported without a transcript because the speech model wasn't ready.")

        MeetingStore.delete(result.meeting, context: context)
    }
```

- [ ] **Step 2: Run the suite to verify it fails**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MinuteTests/AudioImporterTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: a compile error, `error: type 'TranscriptionAvailability' has no member 'loadingModel'`.

- [ ] **Step 3: Add the case to the availability enum**

In `Minute/Services/TranscriptionEngine.swift`, replace lines 6-11:

```swift
enum TranscriptionAvailability: Equatable {
    case unknown
    case available
    case downloadingModel
    case unavailable(String)
}
```

with:

```swift
enum TranscriptionAvailability: Equatable {
    case unknown
    case available
    case downloadingModel
    /// Model files are on disk but not loaded yet. Whisper's first load
    /// compiles the Core ML weights for this device, which takes tens of
    /// seconds to minutes; the recorder is already capturing, so the UI must
    /// be able to say "loading" instead of an empty "Listening…".
    case loadingModel
    case unavailable(String)
}
```

- [ ] **Step 4: Handle the new case in the import path**

In `Minute/Services/AudioImporter.swift`, replace lines 115-117:

```swift
        case .unknown, .downloadingModel:
            transcriptionNote = "The audio was imported without a transcript because the speech model wasn't ready."
        }
```

with:

```swift
        case .unknown, .downloadingModel, .loadingModel:
            transcriptionNote = "The audio was imported without a transcript because the speech model wasn't ready."
        }
```

- [ ] **Step 5: Set the state around the live model load**

In `Minute/Services/WhisperTranscriptionService.swift`, replace lines 266-276 (the head of `runLiveLoop`):

```swift
    private func runLiveLoop(feed: WhisperLiveFeed) async {
        // The model loads HERE, not in prepare(), so the feed is already
        // capturing while Core ML compiles — the backlog decodes on the
        // first pass and the meeting's opening words aren't lost.
        guard let whisperKit = await loadedWhisperKit() else {
            // Retire the feed: its only consumer is gone, and the recorder's
            // handler would otherwise keep piling audio into it for the rest
            // of the recording (~230 MB/hour) for nothing.
            feed.stop()
            return
        }
```

with:

```swift
    private func runLiveLoop(feed: WhisperLiveFeed) async {
        // The model loads HERE, not in prepare(), so the feed is already
        // capturing while Core ML compiles — the backlog decodes on the
        // first pass and the meeting's opening words aren't lost. Say so:
        // prepare() reported .available without loading, and the load can
        // run for minutes on first use with nothing to show for it.
        availability = .loadingModel
        guard let whisperKit = await loadedWhisperKit() else {
            // loadedWhisperKit() has already written the actionable
            // .unavailable text; leave it there rather than claiming ready.
            // Retire the feed: its only consumer is gone, and the recorder's
            // handler would otherwise keep piling audio into it for the rest
            // of the recording (~230 MB/hour) for nothing.
            feed.stop()
            return
        }
        availability = .available
```

- [ ] **Step 6: Run the suite to verify it passes**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MinuteTests/AudioImporterTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: 4 tests pass, including `importWhileTheModelIsStillLoadingSaysTheModelWasntReady`.

- [ ] **Step 7: Run the full unit suite**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 293 tests.

- [ ] **Step 8: Commit**

```bash
git add Minute/Services/TranscriptionEngine.swift Minute/Services/AudioImporter.swift Minute/Services/WhisperTranscriptionService.swift MinuteTests/AudioImporterTests.swift
git commit -m "$(cat <<'EOF'
fix: report the Whisper model load as its own availability state

prepare() deliberately doesn't load the model, so the whole Core ML
specialization — tens of seconds to minutes on first use — was invisible:
the recorder showed the generic "Listening…" empty state and the user
couldn't tell starting from broken. TranscriptionAvailability gains
.loadingModel, set in runLiveLoop around loadedWhisperKit(), and the import
path treats it like .downloadingModel.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Deleting the selected Whisper model moves the selection (F08)

**Files:**
- Modify: `Minute/Services/WhisperDownloadCenter.swift:26-67` (add a static helper above `download`)
- Modify: `Minute/Views/TranscriptionModelView.swift:42-47` (the delete confirmation button)
- Create: `MinuteTests/WhisperDownloadSelectionTests.swift`

**Interfaces:**
- Consumes: `WhisperModelStore.delete(_ variant: String)`, `WhisperModelStore.isDownloaded(_ variant: String) -> Bool`, `WhisperModelCatalog.models: [WhisperModel]`, `AppSettings.whisperModel: String`, `TranscriptionModelView.refreshDownloaded()`, the view's `@AppStorage(AppSettings.whisperModelKey) selectedVariant`.
- Produces: `WhisperDownloadCenter.replacementSelection(after deleted: String, selected: String, downloaded: [String]) -> String?` — pure, takes the still-downloaded catalog variants in catalog order.

- [ ] **Step 1: Write the failing test**

Create `MinuteTests/WhisperDownloadSelectionTests.swift`:

```swift
import Foundation
import Testing
@testable import Minute

/// Deleting the selected model must not leave the selection pointing at bytes
/// that are gone: the next recording would report "the model isn't downloaded"
/// while a downloaded model sits one row below with no checkmark.
@MainActor
struct WhisperDownloadSelectionTests {
    @Test("The most accurate model still downloaded takes the selection")
    func picksTheMostAccurateSurvivor() {
        // The list arrives in catalog order (smallest → most accurate).
        #expect(WhisperDownloadCenter.replacementSelection(
            after: "openai_whisper-large-v3",
            selected: "openai_whisper-large-v3",
            downloaded: ["openai_whisper-base", "openai_whisper-small"]
        ) == "openai_whisper-small")
    }

    @Test("Deleting a model that isn't selected changes nothing")
    func leavesAnUnrelatedDeletionAlone() {
        #expect(WhisperDownloadCenter.replacementSelection(
            after: "openai_whisper-base",
            selected: "openai_whisper-large-v3",
            downloaded: ["openai_whisper-small", "openai_whisper-large-v3"]
        ) == nil)
    }

    @Test("With nothing else downloaded the stored selection is left alone")
    func keepsTheSelectionWhenNothingElseIsDownloaded() {
        #expect(WhisperDownloadCenter.replacementSelection(
            after: "openai_whisper-large-v3",
            selected: "openai_whisper-large-v3",
            downloaded: []
        ) == nil)
        // The deleted model is never its own replacement, even if a stale
        // caller still lists it.
        #expect(WhisperDownloadCenter.replacementSelection(
            after: "openai_whisper-large-v3",
            selected: "openai_whisper-large-v3",
            downloaded: ["openai_whisper-large-v3"]
        ) == nil)
    }
}
```

- [ ] **Step 2: Run the suite to verify it fails**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MinuteTests/WhisperDownloadSelectionTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: a compile error, `error: type 'WhisperDownloadCenter' has no member 'replacementSelection'`.

- [ ] **Step 3: Implement the helper**

In `Minute/Services/WhisperDownloadCenter.swift`, insert directly above `func download(_ model: WhisperModel) {` (line 26):

```swift
    /// The variant to select once `deleted` is removed, or nil to leave the
    /// stored selection alone. `downloaded` is the still-downloaded catalog
    /// variants in catalog order (smallest → most accurate), so the most
    /// accurate survivor wins — the same reasoning as
    /// WhisperModelCatalog.defaultModel: accuracy is why someone opts into
    /// Whisper in the first place.
    static func replacementSelection(after deleted: String, selected: String, downloaded: [String]) -> String? {
        guard deleted == selected else { return nil }
        return downloaded.last { $0 != deleted }
    }

```

- [ ] **Step 4: Run the suite to verify it passes**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MinuteTests/WhisperDownloadSelectionTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: 3 tests pass.

- [ ] **Step 5: Wire the delete action to it**

In `Minute/Views/TranscriptionModelView.swift`, inside the `.confirmationDialog` (lines 34-50), replace:

```swift
            Button("Delete \(model.label)", role: .destructive) {
                WhisperModelStore.delete(model.variant)
                refreshDownloaded()
            }
```

with:

```swift
            Button("Delete \(model.label)", role: .destructive) {
                WhisperModelStore.delete(model.variant)
                // The deleted model may have been the selected one. Leaving
                // the selection there makes the next recording report "the
                // model isn't downloaded" while a downloaded model sits one
                // row below with no checkmark. selectedVariant is the
                // @AppStorage on AppSettings.whisperModelKey, so writing it
                // stores the new selection.
                if let replacement = WhisperDownloadCenter.replacementSelection(
                    after: model.variant,
                    selected: AppSettings.whisperModel,
                    downloaded: WhisperModelCatalog.models.map(\.variant).filter(WhisperModelStore.isDownloaded)
                ) {
                    selectedVariant = replacement
                }
                refreshDownloaded()
            }
```

The button wiring itself has no unit test — pressing a SwiftUI confirmation-dialog action needs a UI test, and this track's suite is unit-only. The decision it makes is `replacementSelection`, covered by Step 1; the wiring is verified by the build and the full suite.

- [ ] **Step 6: Run the full unit suite**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 296 tests.

- [ ] **Step 7: Commit**

```bash
git add Minute/Services/WhisperDownloadCenter.swift Minute/Views/TranscriptionModelView.swift MinuteTests/WhisperDownloadSelectionTests.swift
git commit -m "$(cat <<'EOF'
fix: move the Whisper selection off a model the user just deleted

Deleting the selected model left AppSettings.whisperModel pointing at it, so
the picker warned "download a model" with Base sitting downloaded one row
below and the next recording saved without a transcript. Deletion now hands
the selection to the most accurate model still on disk, mirroring the
auto-select the download center already does.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Pin the live language on evidence, not on elapsed audio (F07)

**Files:**
- Modify: `Minute/Services/WhisperTranscriptionService.swift:291-293` (loop state), `:333-343` (the pin block), `:344-346` (the confirmation block), `:386-390` (the sample-count threshold)
- Test: `MinuteTests/TranscriptionEngineSettingsTests.swift` (append a new `struct WhisperLanguagePinTests` after `WhisperLiveSplitTests`, which ends at line 114)

**Interfaces:**
- Consumes: `WhisperTranscriptionService.mapSegments(_:timeBase:) -> [TranscriptSegment]` (private), `splitForConfirmation(_:keepingLast:)`, `TranscriptSegment(text:start:end:)`.
- Produces: `WhisperTranscriptionService.speechSeconds(of segments: [TranscriptSegment]) -> TimeInterval`; `WhisperTranscriptionService.languagePin(detected: String?, matching previous: String?, speechSeconds: TimeInterval) -> String?`; `WhisperTranscriptionService.languagePinMinimumSpeechSeconds: TimeInterval` (all `static`, `@MainActor` by the class's isolation). Removes `languagePinMinimumSamples`.

- [ ] **Step 1: Write the failing test**

Append to `MinuteTests/TranscriptionEngineSettingsTests.swift` (after the closing `}` of `WhisperLiveSplitTests` at line 114):

```swift

/// The live loop pins the meeting's language for every later pass, so the pin
/// must wait for evidence: one noisy second is enough for Whisper to guess
/// wrong, and a wrong pin transliterates the rest of the meeting.
struct WhisperLanguagePinTests {
    @MainActor
    @Test("Speech seconds sum segment durations, not recorded time")
    func speechSecondsSumSegments() {
        let segments = [
            TranscriptSegment(text: "one", start: 12, end: 14),
            TranscriptSegment(text: "two", start: 14, end: 17.5),
        ]
        // 12 seconds of silence before the first word count for nothing.
        #expect(WhisperTranscriptionService.speechSeconds(of: segments) == 5.5)
        #expect(WhisperTranscriptionService.speechSeconds(of: []) == 0)
    }

    @MainActor
    @Test("One detection is never enough, however much speech it heard")
    func firstDetectionDoesNotPin() {
        #expect(WhisperTranscriptionService.languagePin(detected: "zh", matching: nil, speechSeconds: 60) == nil)
    }

    @MainActor
    @Test("Two consecutive passes must agree")
    func disagreeingPassesDoNotPin() {
        #expect(WhisperTranscriptionService.languagePin(detected: "zh", matching: "en", speechSeconds: 60) == nil)
    }

    @MainActor
    @Test("Agreement on too little speech does not pin")
    func agreementNeedsEnoughSpeech() {
        #expect(WhisperTranscriptionService.languagePin(
            detected: "zh",
            matching: "zh",
            speechSeconds: WhisperTranscriptionService.languagePinMinimumSpeechSeconds - 0.1
        ) == nil)
    }

    @MainActor
    @Test("Agreement plus enough speech pins the language")
    func agreementWithEnoughSpeechPins() {
        #expect(WhisperTranscriptionService.languagePin(
            detected: "zh",
            matching: "zh",
            speechSeconds: WhisperTranscriptionService.languagePinMinimumSpeechSeconds
        ) == "zh")
    }

    @MainActor
    @Test("A pass that detected nothing never pins")
    func missingDetectionDoesNotPin() {
        #expect(WhisperTranscriptionService.languagePin(detected: nil, matching: nil, speechSeconds: 60) == nil)
    }
}
```

- [ ] **Step 2: Run the suite to verify it fails**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MinuteTests/WhisperLanguagePinTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: compile errors, `error: type 'WhisperTranscriptionService' has no member 'speechSeconds'` and `… no member 'languagePin'`.

- [ ] **Step 3: Add the pin helpers and the new threshold**

In `Minute/Services/WhisperTranscriptionService.swift`, replace lines 386-390:

```swift
    /// Language detection needs at least this much audio before its result
    /// is trusted enough to pin for the rest of the meeting.
    private static let languagePinMinimumSamples = 5 * WhisperKit.sampleRate
    /// The most unconfirmed audio the live feed retains (5 minutes ≈ 19 MB).
    private static let maximumTailSamples = 5 * 60 * WhisperKit.sampleRate
```

with:

```swift
    /// Speech — not recorded audio — the pin waits for. Recorded time counts
    /// silence and the model-load backlog, so a meeting that starts quiet
    /// crossed the old threshold on its very first decoded second.
    static let languagePinMinimumSpeechSeconds: TimeInterval = 5
    /// The most unconfirmed audio the live feed retains (5 minutes ≈ 19 MB).
    private static let maximumTailSamples = 5 * 60 * WhisperKit.sampleRate

    /// Seconds of speech in a pass's segments — the measure the language pin
    /// waits on.
    static func speechSeconds(of segments: [TranscriptSegment]) -> TimeInterval {
        segments.reduce(0) { $0 + max(0, $1.end - $1.start) }
    }

    /// The language to fix for the rest of the meeting, or nil to keep
    /// detecting. It takes the same detection on two consecutive passes AND
    /// at least languagePinMinimumSpeechSeconds of decoded speech: WhisperKit
    /// always fills in a language (defaulting to English when detection
    /// fails), one second of speech is not enough to tell zh from en, and a
    /// wrong pin transliterates every later pass of the meeting.
    static func languagePin(
        detected: String?,
        matching previous: String?,
        speechSeconds: TimeInterval
    ) -> String? {
        guard let detected,
              detected == previous,
              speechSeconds >= languagePinMinimumSpeechSeconds else { return nil }
        return detected
    }
```

- [ ] **Step 4: Use the helpers in the live loop**

Step 3 removed `languagePinMinimumSamples`, which the loop still references, so the app does not compile until this step is done — do it before running anything.

In `Minute/Services/WhisperTranscriptionService.swift`, replace lines 291-293:

```swift
        // Pinned after the first pass so live text stops flickering between
        // per-window detection hypotheses; nil means "detect on this pass".
        var pinnedLanguage: String?
```

with:

```swift
        // Pinned once two passes agree on enough speech, so live text stops
        // flickering between per-window detection hypotheses; nil means
        // "detect on this pass".
        var pinnedLanguage: String?
        // What the previous pass detected — a pin needs the same answer twice.
        var previousDetection: String?
        // Speech confirmed so far, summed over segment durations. Confirmed
        // audio is purged from the tail, so adding the current pass's
        // segments double-counts nothing.
        var decodedSpeechSeconds: TimeInterval = 0
```

Then replace lines 333-343:

```swift
                // Pin only once detection has heard enough audio — the very
                // first 1-second pass is too short to trust, and a wrong pin
                // would mistranscribe the rest of the meeting. Measured
                // cumulatively (totalSamples): the retained tail shrinks with
                // every purge and might never span the threshold itself.
                if pinnedLanguage == nil,
                   totalSamples >= Self.languagePinMinimumSamples {
                    pinnedLanguage = results.first?.language
                }
                let mapped = Self.mapSegments(results, timeBase: timeBase)
                let split = Self.splitForConfirmation(mapped, keepingLast: 2)
```

with:

```swift
                let mapped = Self.mapSegments(results, timeBase: timeBase)
                // Pin only on evidence: the same detection twice in a row and
                // at least five seconds of speech actually decoded. A wrong
                // pin mistranscribes the rest of the meeting, and a recording
                // that starts with a quiet room hands the first pass minutes
                // of silence around one second of speech.
                if pinnedLanguage == nil {
                    let detected = results.first?.language
                    pinnedLanguage = Self.languagePin(
                        detected: detected,
                        matching: previousDetection,
                        speechSeconds: decodedSpeechSeconds + Self.speechSeconds(of: mapped)
                    )
                    previousDetection = detected
                }
                let split = Self.splitForConfirmation(mapped, keepingLast: 2)
```

Then, in the confirmation block, replace lines 344-346:

```swift
                if let lastConfirmed = split.confirmed.last, lastConfirmed.end > lastConfirmedEnd {
                    lastConfirmedEnd = lastConfirmed.end
                    segments.append(contentsOf: split.confirmed)
```

with:

```swift
                if let lastConfirmed = split.confirmed.last, lastConfirmed.end > lastConfirmedEnd {
                    lastConfirmedEnd = lastConfirmed.end
                    segments.append(contentsOf: split.confirmed)
                    decodedSpeechSeconds += Self.speechSeconds(of: split.confirmed)
```

The loop wiring itself has no unit test — `decodedSpeechSeconds` accumulating from `split.confirmed` and `previousDetection` advancing each pass only happen inside `runLiveLoop`, which needs a loaded WhisperKit and a live audio feed. The judgement it feeds is `speechSeconds`/`languagePin`, covered by Step 1; the wiring is verified by the build, the full suite, and reading the three replacements above together.

- [ ] **Step 5: Run the suite to verify it passes**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MinuteTests/WhisperLanguagePinTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: 6 tests pass.

- [ ] **Step 6: Run the full unit suite**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 302 tests.

- [ ] **Step 7: Commit**

```bash
git add Minute/Services/WhisperTranscriptionService.swift MinuteTests/TranscriptionEngineSettingsTests.swift
git commit -m "$(cat <<'EOF'
fix: pin the live Whisper language on speech heard, not seconds recorded

The guard counted cumulative recorded samples, so a meeting that starts with
a quiet room (the common case — the model load alone buffers 5-20 s) pinned
the language from a pass holding one second of speech. Pinning now takes the
same detection on two consecutive passes and at least five seconds of decoded
speech, summed over segment durations; until then detectLanguage stays on.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Keep model downloads alive when the app is backgrounded (F45)

**Files:**
- Modify: `Minute/Services/WhisperDownloadCenter.swift:10-72` (notices property, pause notice, token around the task)
- Modify: `Minute/Services/MLXDownloadCenter.swift:10-66` (same)
- Modify: `Minute/Views/TranscriptionModelView.swift:109-120` (row detail stack)
- Modify: `Minute/Views/SummaryModelView.swift:112-123` (row detail stack)
- Test: none — see the note in Step 1.

**Interfaces:**
- Consumes: `BackgroundTaskToken(name: String, expirationHandler: @escaping @MainActor @Sendable () -> Void)` and `BackgroundTaskToken.end()` (`Minute/Services/ICloudDriveBackup.swift:1014-1035`; used the same way at `:992-998`).
- Produces: `WhisperDownloadCenter.notices: [String: String]` (variant → message) and `WhisperDownloadCenter.backgroundPauseNotice: String`; `MLXDownloadCenter.notices: [String: String]` (repoID → message) and `MLXDownloadCenter.backgroundPauseNotice: String`.

- [ ] **Step 1: Note why there is no unit test**

This task is not unit-testable: it depends on UIKit's background-task expiration and on real multi-hundred-megabyte URLSession transfers, neither of which a unit test can drive. It is verified by the build and the full suite staying green, and by the code review of the token wiring below.

- [ ] **Step 2: Add the notice state and the token to the Whisper center**

In `Minute/Services/WhisperDownloadCenter.swift`, insert after line 20 (`private(set) var finishedCount = 0`) and its blank line, before `private var tasks`:

```swift
    /// variant → a non-failure explanation for a stopped download. iOS ending
    /// the app's background window is not a failure: the partial files stay
    /// on disk and Get resumes, so this renders in secondary text while
    /// `errors` stays red.
    private(set) var notices: [String: String] = [:]

    /// Shown when iOS ended the background window mid-download.
    static let backgroundPauseNotice = "Paused when Minute went to the background. Tap Get to resume."

```

Then replace lines 30-33:

```swift
        errors[variant] = nil
        progress[variant] = 0
        tasks[variant] = Task {
            do {
```

with:

```swift
        errors[variant] = nil
        notices[variant] = nil
        progress[variant] = 0
        tasks[variant] = Task {
            // A 150-630 MB transfer over an ordinary URLSession dies the
            // moment iOS suspends the app, which happens seconds after the
            // user switches away. The token buys the OS-granted window; when
            // it expires we cancel the transfer ourselves so it ends as a
            // resumable pause with the partial files kept, instead of a
            // "the network connection was lost" error the user reads as a
            // failure of the download itself.
            let token = BackgroundTaskToken(name: "Whisper model download") { [weak self] in
                guard let self else { return }
                self.notices[variant] = Self.backgroundPauseNotice
                self.tasks[variant]?.cancel()
            }
            defer { token.end() }
            do {
```

- [ ] **Step 3: Add the notice state and the token to the MLX center**

In `Minute/Services/MLXDownloadCenter.swift`, insert after line 20 (`private(set) var finishedCount = 0`) and its blank line, before `private var tasks`:

```swift
    /// repoID → a non-failure explanation for a stopped download. iOS ending
    /// the app's background window is not a failure: the partial files stay
    /// on disk and Get resumes, so this renders in secondary text while
    /// `errors` stays red.
    private(set) var notices: [String: String] = [:]

    /// Shown when iOS ended the background window mid-download.
    static let backgroundPauseNotice = "Paused when Minute went to the background. Tap Get to resume."

```

Then replace lines 30-33:

```swift
        errors[repoID] = nil
        progress[repoID] = 0
        tasks[repoID] = Task {
            do {
```

with:

```swift
        errors[repoID] = nil
        notices[repoID] = nil
        progress[repoID] = 0
        tasks[repoID] = Task {
            // A 1-2.3 GB transfer over an ordinary URLSession dies the moment
            // iOS suspends the app, which happens seconds after the user
            // switches away. The token buys the OS-granted window; when it
            // expires we cancel the transfer ourselves so it ends as a
            // resumable pause with the partial files kept, instead of a
            // "the network connection was lost" error the user reads as a
            // failure of the download itself.
            let token = BackgroundTaskToken(name: "Summary model download") { [weak self] in
                guard let self else { return }
                self.notices[repoID] = Self.backgroundPauseNotice
                self.tasks[repoID]?.cancel()
            }
            defer { token.end() }
            do {
```

- [ ] **Step 4: Show the notice in the transcription model rows**

In `Minute/Views/TranscriptionModelView.swift`, replace lines 115-119:

```swift
                    if let error = downloads.errors[model.variant] {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
```

with:

```swift
                    if let error = downloads.errors[model.variant] {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    if let notice = downloads.notices[model.variant] {
                        Text(notice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
```

- [ ] **Step 5: Show the notice in the summary model rows**

In `Minute/Views/SummaryModelView.swift`, replace lines 118-122:

```swift
                    if let error = downloads.errors[model.repoID] {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
```

with:

```swift
                    if let error = downloads.errors[model.repoID] {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    if let notice = downloads.notices[model.repoID] {
                        Text(notice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
```

- [ ] **Step 6: Run the full unit suite**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 302 tests, no new warnings.

- [ ] **Step 7: Commit**

```bash
git add Minute/Services/WhisperDownloadCenter.swift Minute/Services/MLXDownloadCenter.swift Minute/Views/TranscriptionModelView.swift Minute/Views/SummaryModelView.swift
git commit -m "$(cat <<'EOF'
fix: keep model downloads alive across a short backgrounding

Both download centers ran their fetch in a plain Task, so switching apps for
a few seconds suspended the process, tore down the transfer and greeted the
user with "The download failed: the network connection was lost" on a 10-20
minute download. Each task now holds a BackgroundTaskToken; when the window
expires the token cancels the download itself, so the row shows a resumable
"Paused when Minute went to the background. Tap Get to resume." instead.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Fold chunk notes in code when the local merge is unreadable (F12)

**Files:**
- Modify: `Minute/Services/MLXSummarizationService.swift:294-300` (the merge call in `summarize`), and add the fold helpers before `// MARK: JSON handling` (line 577)
- Test: `MinuteTests/SummarizationEngineSettingsTests.swift` (append a new `struct MLXMechanicalFallbackTests` after `MLXJSONExtractionTests`, which ends at line 141)

**Interfaces:**
- Consumes: `SummarizationService.cleaned(_ items: [String]) -> [String]`, `SummarizationService.normalizedField(_ value: String) -> String`, `ActionItem.notSpecified`, `LocalChunkNotes`, `LocalActionItem`, `LocalPerspective`, `[LocalActionItem].normalized() -> [ActionItem]`, `[LocalPerspective].normalized() -> [SpeakerPerspective]?`, `MeetingSummary(overview:keyPoints:decisions:actionItems:openQuestions:generatedAt:suggestedTitle:speakerPerspectives:)`.
- Produces: `MLXSummarizationService.mechanicallyCombined(_ notes: [LocalChunkNotes]) -> LocalChunkNotes` and `MLXSummarizationService.mechanicalSummary(from notes: [LocalChunkNotes]) -> MeetingSummary` (both `static`, `@MainActor`).

- [ ] **Step 1: Write the failing test**

Append to `MinuteTests/SummarizationEngineSettingsTests.swift` (after the closing `}` of `MLXJSONExtractionTests` at line 141):

```swift

/// When the merge (or a condense inside it) comes back unreadable, minutes of
/// on-device generation must not be thrown away: the chunk notes fold together
/// in code, exactly as the Apple engine degrades on a refusal.
struct MLXMechanicalFallbackTests {
    private func notes(
        keyPoints: [String]? = nil,
        decisions: [String]? = nil,
        actionItems: [LocalActionItem]? = nil,
        openQuestions: [String]? = nil,
        speakerPerspectives: [LocalPerspective]? = nil
    ) -> LocalChunkNotes {
        LocalChunkNotes(
            keyPoints: keyPoints,
            decisions: decisions,
            actionItems: actionItems,
            openQuestions: openQuestions,
            speakerPerspectives: speakerPerspectives
        )
    }

    @MainActor
    @Test("Overlapping parts fold into one set of notes")
    func combinesAndDedupes() {
        let combined = MLXSummarizationService.mechanicallyCombined([
            notes(
                keyPoints: ["Pricing is behind", "Pricing is behind"],
                decisions: ["Ship on Friday"],
                actionItems: [LocalActionItem(task: "Update the pricing page", owner: nil, deadline: nil)],
                openQuestions: ["Who owns the migration?"],
                speakerPerspectives: [LocalPerspective(speaker: "Ana", points: ["Wants a staged rollout"])]
            ),
            notes(
                keyPoints: ["pricing is behind", "Docs are stale"],
                actionItems: [LocalActionItem(task: "update the pricing page", owner: "Ana", deadline: "Friday")],
                speakerPerspectives: [LocalPerspective(speaker: "ana", points: ["Wants a staged rollout", "Needs the docs first"])]
            ),
        ])

        #expect(combined.keyPoints == ["Pricing is behind", "Docs are stale"])
        #expect(combined.decisions == ["Ship on Friday"])
        #expect(combined.openQuestions == ["Who owns the migration?"])
        // The repeat carries the owner and deadline the first copy lacked.
        #expect(combined.actionItems?.count == 1)
        #expect(combined.actionItems?.first?.task == "Update the pricing page")
        #expect(combined.actionItems?.first?.owner == "Ana")
        #expect(combined.actionItems?.first?.deadline == "Friday")
        #expect(combined.speakerPerspectives?.count == 1)
        #expect(combined.speakerPerspectives?.first?.points == ["Wants a staged rollout", "Needs the docs first"])
    }

    @MainActor
    @Test("The same task owned by two people stays two commitments")
    func conflictingOwnersAreNotMerged() {
        let combined = MLXSummarizationService.mechanicallyCombined([
            notes(actionItems: [LocalActionItem(task: "Send the deck", owner: "Ana", deadline: nil)]),
            notes(actionItems: [LocalActionItem(task: "Send the deck", owner: "Bo", deadline: nil)]),
        ])
        #expect(combined.actionItems?.count == 2)
    }

    @MainActor
    @Test("The fallback summary keeps every fact and claims nothing extra")
    func fallbackSummaryHasNoOverviewOrTitle() {
        let summary = MLXSummarizationService.mechanicalSummary(from: [
            notes(
                keyPoints: ["Pricing is behind"],
                decisions: ["Ship on Friday"],
                actionItems: [LocalActionItem(task: "Update the pricing page", owner: nil, deadline: nil)],
                openQuestions: ["Who owns the migration?"]
            ),
        ])

        // No model wrote these, so the summary must not pretend otherwise.
        #expect(summary.overview.isEmpty)
        #expect(summary.suggestedTitle == nil)
        #expect(summary.keyPoints == ["Pricing is behind"])
        #expect(summary.decisions == ["Ship on Friday"])
        #expect(summary.openQuestions == ["Who owns the migration?"])
        // A missing owner is the literal placeholder, never a blank.
        #expect(summary.actionItems == [
            ActionItem(task: "Update the pricing page", owner: ActionItem.notSpecified, deadline: ActionItem.notSpecified)
        ])
        #expect(summary.speakerPerspectives == nil)
    }
}
```

- [ ] **Step 2: Run the suite to verify it fails**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MinuteTests/MLXMechanicalFallbackTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: a compile error, `error: type 'MLXSummarizationService' has no member 'mechanicallyCombined'`.

- [ ] **Step 3: Implement the code-level fold**

In `Minute/Services/MLXSummarizationService.swift`, insert directly above `    // MARK: JSON handling` (line 577):

```swift
    // MARK: Code-level fallback

    /// Folds chunk notes together in code — concatenate, dedupe, group
    /// speakers — for when the model garbles the one request it is already
    /// too late to retry. Loses the rephrasing, keeps every fact. The Apple
    /// engine degrades exactly this way on a refusal
    /// (SummarizationService.mechanicallyCombined).
    static func mechanicallyCombined(_ notes: [LocalChunkNotes]) -> LocalChunkNotes {
        var actionItems: [LocalActionItem] = []
        for item in notes.flatMap({ $0.actionItems ?? [] }) {
            let task = (item.task ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !task.isEmpty else { continue }
            // Same wording with a conflicting specified owner or deadline is
            // two commitments, not overlap — keep both.
            if let index = actionItems.firstIndex(where: {
                ($0.task ?? "").caseInsensitiveCompare(task) == .orderedSame
                    && !fieldsConflict($0.owner, item.owner)
                    && !fieldsConflict($0.deadline, item.deadline)
            }) {
                // Overlapping parts repeat tasks; keep the copy that names an
                // owner or deadline.
                if SummarizationService.normalizedField(actionItems[index].owner ?? "") == ActionItem.notSpecified {
                    actionItems[index].owner = item.owner
                }
                if SummarizationService.normalizedField(actionItems[index].deadline ?? "") == ActionItem.notSpecified {
                    actionItems[index].deadline = item.deadline
                }
            } else {
                actionItems.append(LocalActionItem(task: task, owner: item.owner, deadline: item.deadline))
            }
        }

        var perspectives: [LocalPerspective] = []
        for perspective in notes.flatMap({ $0.speakerPerspectives ?? [] }) {
            let speaker = (perspective.speaker ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !speaker.isEmpty else { continue }
            if let index = perspectives.firstIndex(where: { ($0.speaker ?? "").caseInsensitiveCompare(speaker) == .orderedSame }) {
                perspectives[index].points = SummarizationService.cleaned((perspectives[index].points ?? []) + (perspective.points ?? []))
            } else {
                perspectives.append(LocalPerspective(speaker: speaker, points: SummarizationService.cleaned(perspective.points ?? [])))
            }
        }

        return LocalChunkNotes(
            keyPoints: SummarizationService.cleaned(notes.flatMap { $0.keyPoints ?? [] }),
            decisions: SummarizationService.cleaned(notes.flatMap { $0.decisions ?? [] }),
            actionItems: actionItems,
            openQuestions: SummarizationService.cleaned(notes.flatMap { $0.openQuestions ?? [] }),
            speakerPerspectives: perspectives
        )
    }

    /// True when both values are specified and disagree — e.g. the same task
    /// wording owned by two different people.
    private static func fieldsConflict(_ first: String?, _ second: String?) -> Bool {
        let lhs = SummarizationService.normalizedField(first ?? "")
        let rhs = SummarizationService.normalizedField(second ?? "")
        return lhs != ActionItem.notSpecified && rhs != ActionItem.notSpecified
            && lhs.caseInsensitiveCompare(rhs) != .orderedSame
    }

    /// The no-model fallback summary: combined notes with an empty overview
    /// and no suggested title — the detail view hides both when empty, so the
    /// notes never claim a model wrote something it didn't.
    static func mechanicalSummary(from notes: [LocalChunkNotes]) -> MeetingSummary {
        let combined = mechanicallyCombined(notes)
        return MeetingSummary(
            overview: "",
            keyPoints: combined.keyPoints ?? [],
            decisions: combined.decisions ?? [],
            actionItems: (combined.actionItems ?? []).normalized(),
            openQuestions: combined.openQuestions ?? [],
            generatedAt: .now,
            suggestedTitle: nil,
            speakerPerspectives: (combined.speakerPerspectives ?? []).normalized()
        )
    }

```

- [ ] **Step 4: Run the suite to verify it passes**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MinuteTests/MLXMechanicalFallbackTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: 3 tests pass.

- [ ] **Step 5: Degrade instead of throwing when the merge fails**

In `Minute/Services/MLXSummarizationService.swift`, replace lines 294-300:

```swift
                try Task.checkCancellation()
                await onProgress?("Combining notes…")
                var summary = try await merge(notes, template: template, contextBlock: contextBlock, container: container)
                if skipped > 0 {
                    summary.skippedParts = skipped
                }
                return summary
```

with:

```swift
                try Task.checkCancellation()
                await onProgress?("Combining notes…")
                var summary: MeetingSummary
                do {
                    summary = try await merge(notes, template: template, contextBlock: contextBlock, container: container)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Every part already succeeded, at minutes of on-device
                    // generation apiece. A garbled merge or condense reply —
                    // the largest prompt of the run, and the one a small
                    // model misformats most — degrades the summary (no
                    // overview, title, or template sections) instead of
                    // destroying it, the same finish line the Apple engine
                    // protects.
                    Self.logger.error("Local merge failed, combining notes in code: \(error.localizedDescription)")
                    summary = Self.mechanicalSummary(from: notes)
                }
                if skipped > 0 {
                    summary.skippedParts = skipped
                }
                return summary
```

The degraded path itself only runs inside a real generation (the MLX engine refuses to run in the Simulator), so it has no unit test; the fold it falls back to is covered by Step 1's tests and the wiring is verified by the build and the full suite.

- [ ] **Step 6: Run the full unit suite**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 305 tests.

- [ ] **Step 7: Commit**

```bash
git add Minute/Services/MLXSummarizationService.swift MinuteTests/SummarizationEngineSettingsTests.swift
git commit -m "$(cat <<'EOF'
fix: keep the local model's chunk notes when the merge comes back unreadable

A malformed or truncated merge reply threw away every chunk the local model
had already extracted — ten parts of a 60-minute meeting, minutes of
generation each — and the user got an error with nothing saved. The MLX
engine now folds the notes together in code on any non-cancellation merge or
condense failure, exactly as the Apple engine degrades on a refusal: combined
key points, decisions, action items and open questions, empty overview.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: One local-model job at a time, app-wide (F13)

**Files:**
- Modify: `Minute/Services/MLXSummarizationService.swift` — insert `MLXJobGate` before `// MARK: - Service` (line 198); replace `func summarize(...)` (lines 241-310, as amended by Task 5 — the body now runs to about line 320)
- Create: `MinuteTests/MLXJobGateTests.swift`
- `Minute/Services/SummarizationEngine.swift` is deliberately untouched: `SummarizationEngines.current(language:)` keeps building one service per call (each job still loads its own container; the gate makes sure only one exists at a time).

**Interfaces:**
- Consumes: `SummarizerError.unavailable(String)`, `SummarizerError.emptyTranscript`, `TranscriptChunker.chunks(from:maxChars:) -> [String]`, `TranscriptChunker.defaultMaxChars`, `SummaryTemplate`, `MeetingSummary` (Sendable).
- Produces: `actor MLXJobGate` with `static let shared`, `static let waitingStatus: String`, and `nonisolated func run<T>(onWaiting: @escaping @MainActor @Sendable () -> Void, body: @MainActor () async throws -> T) async throws -> T`; `MLXSummarizationService.generate(chunks:template:context:onProgress:) async throws -> MeetingSummary` (private).

  Both parameters are labelled and **every call site passes both non-trailing**: a labelled closure plus a trailing closure in the same call is what SwiftLint's default-on `multiple_closures_with_trailing_closure` flags, `.swiftlint.yml` does not disable it, `MinuteTests` is inside `included:`, and the CI gate is strict while `swiftlint` isn't installed locally. The codebase already avoids the form (`WhisperTranscriptionService.swift:99-102` passes `progressCallback:` non-trailing).

- [ ] **Step 1: Write the failing test**

Create `MinuteTests/MLXJobGateTests.swift`:

```swift
import Foundation
import Testing
@testable import Minute

/// Two local-model jobs must never hold two model containers at once: 1-2.3 GB
/// of weights twice over is what gets the app killed on the very devices the
/// catalog's memory floors admit, and a killed app loses both in-memory jobs
/// with no failure recorded anywhere.
@MainActor
struct MLXJobGateTests {
    /// Counts how many jobs are inside the gate at the same moment.
    @MainActor
    final class Tracker {
        var active = 0
        var peak = 0
        var finished = 0
        var waitingReports = 0

        func begin() {
            active += 1
            peak = max(peak, active)
        }

        func end() {
            active -= 1
            finished += 1
        }
    }

    @Test func aSecondJobWaitsForTheFirstAndIsToldWhy() async throws {
        let gate = MLXJobGate()
        let tracker = Tracker()
        // Event-driven, not timed: signals make this deterministic on any
        // host speed (the KnowledgeCatchUpTests pattern).
        let (firstJobStarted, startedContinuation) = AsyncStream.makeStream(of: Void.self)
        let (firstJobMayFinish, finishContinuation) = AsyncStream.makeStream(of: Void.self)
        let (secondJobWaited, waitedContinuation) = AsyncStream.makeStream(of: Void.self)

        let first = Task {
            // Both closures are labelled arguments, never trailing: one
            // labelled plus one trailing closure in the same call trips
            // SwiftLint's multiple_closures_with_trailing_closure, which CI
            // enforces and this machine can't run.
            try await gate.run(onWaiting: {}, body: {
                tracker.begin()
                startedContinuation.yield(())
                var mayFinish = firstJobMayFinish.makeAsyncIterator()
                _ = await mayFinish.next()
                tracker.end()
            })
        }
        var started = firstJobStarted.makeAsyncIterator()
        _ = await started.next()   // the first job definitely holds the gate

        let second = Task {
            // Finishing the stream on exit keeps a broken gate a failing test
            // rather than a hung one.
            defer { waitedContinuation.finish() }
            try await gate.run(
                onWaiting: {
                    tracker.waitingReports += 1
                    waitedContinuation.yield(())
                },
                body: {
                    tracker.begin()
                    tracker.end()
                }
            )
        }
        var waited = secondJobWaited.makeAsyncIterator()
        _ = await waited.next()   // the second job is queued, not running

        #expect(tracker.finished == 0)
        finishContinuation.yield(())
        try await first.value
        try await second.value

        #expect(tracker.peak == 1)
        #expect(tracker.finished == 2)
        #expect(tracker.waitingReports == 1)
        #expect(MLXJobGate.waitingStatus == "Waiting for another local-model job to finish…")
    }

    @Test func aFailedJobStillOpensTheGate() async throws {
        struct Boom: Error {}
        let gate = MLXJobGate()

        await #expect(throws: Boom.self) {
            try await gate.run(onWaiting: {}, body: { () async throws -> Void in throw Boom() })
        }

        // A wedged gate would hang every later summary forever.
        var ran = false
        try await gate.run(onWaiting: {}, body: { ran = true })
        #expect(ran)
    }
}
```

- [ ] **Step 2: Run the suite to verify it fails**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MinuteTests/MLXJobGateTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: a compile error, `error: cannot find 'MLXJobGate' in scope`.

- [ ] **Step 3: Implement the gate**

In `Minute/Services/MLXSummarizationService.swift`, insert directly above `// MARK: - Service` (line 198):

```swift
// MARK: - Job gate

/// Serializes local-model work across the whole app.
///
/// Each summarize job builds its own service instance and loads its own
/// 1-2.3 GB container (deliberately: keeping the weights resident between
/// occasional summaries is worse for memory pressure). Nothing else stops two
/// meetings from summarizing at once — MeetingJobs gates per meeting, and
/// Auto-Summarize plus a manual Generate on another meeting is two clicks
/// away — and two containers resident together is what pushes the app past
/// the foreground memory limit on the very devices the catalog's floors
/// admit, killing it with both jobs lost and no failure recorded.
actor MLXJobGate {
    static let shared = MLXJobGate()

    /// Progress text a queued job reports, so the summary section explains
    /// the wait instead of sitting on "Loading the summary model…".
    static let waitingStatus = "Waiting for another local-model job to finish…"

    private var isRunning = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// Runs `body` once no other local-model job is running, calling
    /// `onWaiting` first when this job has to queue. The gate reopens as soon
    /// as `body` returns OR throws — a failed job must never wedge the queue.
    ///
    /// `body` is a labelled parameter, not a trailing one: callers pass two
    /// closures, and a labelled-plus-trailing pair is what SwiftLint's
    /// multiple_closures_with_trailing_closure rejects.
    nonisolated func run<T>(
        onWaiting: @escaping @MainActor @Sendable () -> Void,
        body: @MainActor () async throws -> T
    ) async throws -> T {
        await acquire(onWaiting: onWaiting)
        do {
            let value = try await body()
            await release()
            return value
        } catch {
            await release()
            throw error
        }
    }

    private func acquire(onWaiting: @escaping @MainActor @Sendable () -> Void) async {
        if isRunning {
            await onWaiting()
        }
        // A loop, not a single suspension: release() wakes one waiter, but a
        // job arriving in between can take the gate first.
        while isRunning {
            await withCheckedContinuation { waiting.append($0) }
        }
        isRunning = true
    }

    private func release() {
        isRunning = false
        guard !waiting.isEmpty else { return }
        waiting.removeFirst().resume()
    }
}

```

- [ ] **Step 4: Run the suite to verify it passes**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MinuteTests/MLXJobGateTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: 2 tests pass.

- [ ] **Step 5: Run every summary through the gate**

In `Minute/Services/MLXSummarizationService.swift`, cut the whole `summarize` method and paste the block below in its place. The cut starts at this exact line:

```swift
    func summarize(
```

and ends at the closing `    }` of these exact last six lines of the method (unchanged by Task 5, which edited only the middle of the body):

```swift
        } catch {
            throw SummarizerError.generationFailed(
                "The local model couldn't summarize this meeting: \(error.localizedDescription)"
            )
        }
    }
```

The next line after the cut is the blank line before `    // MARK: Model loading`. The new `generate` body is the code you just cut moved verbatim, so diff it against what you cut to be sure nothing was dropped:

```swift
    func summarize(
        transcript: String,
        template: SummaryTemplate,
        context: String,
        onProgress: (@MainActor @Sendable (String) -> Void)?
    ) async throws -> MeetingSummary {
        if let message = availabilityMessage {
            throw SummarizerError.unavailable(message)
        }
        let chunks = TranscriptChunker.chunks(from: transcript, maxChars: TranscriptChunker.defaultMaxChars)
        guard !chunks.isEmpty else { throw SummarizerError.emptyTranscript }

        // One local-model job at a time, app-wide: see MLXJobGate. Both
        // closures are labelled arguments — a labelled closure plus a
        // trailing one trips SwiftLint's
        // multiple_closures_with_trailing_closure, which CI enforces.
        return try await MLXJobGate.shared.run(
            onWaiting: { onProgress?(MLXJobGate.waitingStatus) },
            body: {
                try await self.generate(chunks: chunks, template: template, context: context, onProgress: onProgress)
            }
        )
    }

    /// The whole generation, from model load to finished notes, run while
    /// holding MLXJobGate.
    private func generate(
        chunks: [String],
        template: SummaryTemplate,
        context: String,
        onProgress: (@MainActor @Sendable (String) -> Void)?
    ) async throws -> MeetingSummary {
        // The weights go the moment this job ends: the gate opens for the
        // next job immediately afterwards, and two resident containers is the
        // failure the gate exists to prevent. Spelled `self.` because a local
        // `let container` is declared below and this defer clears the
        // instance property, not that local.
        defer { self.container = nil }
        // A job cancelled while it queued behind another must not start a
        // full generation now that its turn came.
        try Task.checkCancellation()

        onProgress?("Loading the summary model…")
        // Outside the do/catch below, which only wraps generation: a corrupt
        // or half-downloaded snapshot would otherwise reach the summary
        // section as a raw MLX or URL error.
        let container: ModelContainer
        do {
            container = try await loadedContainer()
        } catch let error as SummarizerError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Self.logger.error("Local summary model load failed: \(error.localizedDescription)")
            throw SummarizerError.generationFailed(
                "The local summary model couldn't be loaded. Delete and re-download it in Settings → Summary Model, or switch to Apple Intelligence."
            )
        }
        let contextBlock = SummarizationService.contextBlock(from: context).map { "\n\($0)\n" } ?? ""

        do {
            if chunks.count == 1 {
                return try await summarizeWhole(chunks[0], template: template, contextBlock: contextBlock, container: container)
            }
            var notes: [LocalChunkNotes] = []
            var skipped = 0
            for (index, chunk) in chunks.enumerated() {
                try Task.checkCancellation()
                await onProgress?("Reading part \(index + 1) of \(chunks.count)…")
                do {
                    notes.append(try await extractNotes(from: chunk, part: index + 1, of: chunks.count, contextBlock: contextBlock, container: container))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // One bad stretch must not sink the whole meeting.
                    Self.logger.error("Chunk summarization failed: \(error.localizedDescription)")
                    skipped += 1
                }
            }
            guard !notes.isEmpty else {
                throw SummarizerError.generationFailed(Self.unreadableMessage)
            }
            try Task.checkCancellation()
            await onProgress?("Combining notes…")
            var summary: MeetingSummary
            do {
                summary = try await merge(notes, template: template, contextBlock: contextBlock, container: container)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Every part already succeeded, at minutes of on-device
                // generation apiece. A garbled merge or condense reply — the
                // largest prompt of the run, and the one a small model
                // misformats most — degrades the summary (no overview, title,
                // or template sections) instead of destroying it, the same
                // finish line the Apple engine protects.
                Self.logger.error("Local merge failed, combining notes in code: \(error.localizedDescription)")
                summary = Self.mechanicalSummary(from: notes)
            }
            if skipped > 0 {
                summary.skippedParts = skipped
            }
            return summary
        } catch let error as SummarizerError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SummarizerError.generationFailed(
                "The local model couldn't summarize this meeting: \(error.localizedDescription)"
            )
        }
    }
```

The wiring itself has no unit test: `MLXSummarizationService.availabilityMessage` refuses to run in the Simulator, so `summarize` throws before it reaches the gate. The gate's own behavior is covered by Step 1's tests, and the wiring is verified by the build and the full suite.

- [ ] **Step 6: Run the full unit suite**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 307 tests.

- [ ] **Step 7: Commit**

```bash
git add Minute/Services/MLXSummarizationService.swift MinuteTests/MLXJobGateTests.swift
git commit -m "$(cat <<'EOF'
fix: serialize local-model summaries so two containers never load at once

MeetingJobs only gates per meeting, so Auto-Summarize on a just-saved meeting
plus a manual Generate on another loaded two copies of 1-2.3 GB of weights —
on an 8 GB iPhone, the catalog's own floor, that is a jetsam kill with both
in-memory jobs lost and no error shown. Local jobs now queue through an
app-wide MLXJobGate; a queued job reports "Waiting for another local-model
job to finish…", and each job drops its container as it ends.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Give the Whisper store a tokenizer folder (F05, part 1)

**Files:**
- Modify: `Minute/Services/WhisperTranscriptionService.swift:52-130` (`WhisperModelStore`: new tokenizer members, `isDownloaded` at 78-87, `delete` at 117-120)
- Test: `MinuteTests/WhisperModelStoreTests.swift` (append inside the struct, after `downloadCacheLifecycle`, which ends at line 46)

**Interfaces:**
- Consumes (verified in the pinned WhisperKit checkout):
  - The Hub layout the tokenizer load looks in: `HubApi.localRepoLocation(_ repo: Repo) -> URL` is `downloadBase.appending(component: "models").appending(component: repo.id)` — `Sources/ArgmaxCore/External/Hub/HubApi.swift:350-352` — so a download base of `<store>/tokenizers` puts repo `openai/whisper-<size>` at `<store>/tokenizers/models/openai/whisper-<size>`. Step 3 **builds** that path instead of calling `HubApiWrapper.localRepoLocation`: `HubApiWrapper.init` constructs its `HubApi` eagerly (`Sources/ArgmaxCore/HubWrapper.swift:26-37`), and `HubApi.init` creates an `NWPathMonitor`-backed `NetworkMonitor` on a fresh `DispatchQueue` and starts the shared one (`Sources/ArgmaxCore/External/Hub/HubApi.swift:75, 114, 810-830`) — while `hasTokenizer` → `isDownloaded` runs once per catalog row on every Settings refresh and again in `prepare()` at record time. A pure path computation must not spin up a path monitor.
  - `public enum ModelVariant` with `description` values `tiny`, `tiny.en`, `base`, `base.en`, `small`, `small.en`, `medium`, `medium.en`, `large`, `large-v2`, `large-v3` — `Sources/WhisperKit/Core/Models.swift:39-88`. WhisperKit's own tokenizer repo name is `"openai/whisper-" + description` (`Sources/WhisperKit/Utilities/ModelUtilities.swift:175-202`, which is `internal`, hence the local copy of the rule).
  - The tokenizer files a local load needs: `tokenizer.json` is required and `tokenizer_config.json` is what picks the tokenizer class — `Sources/ArgmaxCore/External/Hub/Hub.swift:230, 267-279` and `Sources/ArgmaxCore/External/Tokenizers/Tokenizer.swift:628-638`.
- Produces: `WhisperModelStore.tokenizerBaseDirectory: URL`; `WhisperModelStore.tokenizerVariant(for variant: String) -> ModelVariant?`; `WhisperModelStore.tokenizerFolder(for variant: String) -> URL?`; `WhisperModelStore.hasTokenizer(_ variant: String) -> Bool`; `isDownloaded` now also requires the tokenizer, and `delete` removes it.

- [ ] **Step 1: Write the failing test**

Append inside `struct WhisperModelStoreTests` in `MinuteTests/WhisperModelStoreTests.swift`, after `downloadCacheLifecycle` (before the struct's closing `}` at line 47):

```swift

    @Test("Tokenizer folders live inside the store, one per Whisper size")
    func tokenizerFolderMatchesTheHubLayout() throws {
        let large = try #require(WhisperModelStore.tokenizerFolder(for: "openai_whisper-large-v3-v20240930_626MB"))
        #expect(large.path.hasSuffix("WhisperKitModels/tokenizers/models/openai/whisper-large-v3"))
        let base = try #require(WhisperModelStore.tokenizerFolder(for: "openai_whisper-base"))
        #expect(base.path.hasSuffix("WhisperKitModels/tokenizers/models/openai/whisper-base"))
        // A name that isn't a Whisper size has no tokenizer repo, and must
        // not be able to make an otherwise complete model look missing.
        #expect(WhisperModelStore.tokenizerFolder(for: "nonexistent-model-variant") == nil)
    }

    @Test("A model without its tokenizer is not downloaded")
    func tokenizerIsRequiredForADownloadedModel() throws {
        // A variant name that maps to a size the catalog never offers, so a
        // real download on this machine can't collide with the fixture.
        let variant = "openai_whisper-medium-test-\(UUID().uuidString)"
        defer { WhisperModelStore.delete(variant) }

        let folder = WhisperModelStore.folder(for: variant)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc", "config.json"] {
            try Data("{}".utf8).write(to: folder.appending(path: name))
        }
        // Every Core ML file is there, but the first transcription would
        // still have to reach Hugging Face for the tokenizer.
        #expect(!WhisperModelStore.isDownloaded(variant))

        let tokenizer = try #require(WhisperModelStore.tokenizerFolder(for: variant))
        try FileManager.default.createDirectory(at: tokenizer, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: tokenizer.appending(path: "tokenizer.json"))
        #expect(!WhisperModelStore.isDownloaded(variant))   // tokenizer_config.json still missing
        try Data("{}".utf8).write(to: tokenizer.appending(path: "tokenizer_config.json"))
        #expect(WhisperModelStore.isDownloaded(variant))
    }

    @Test("Deleting a model removes its tokenizer too")
    func deleteRemovesTheTokenizer() throws {
        let variant = "openai_whisper-tiny-test-\(UUID().uuidString)"
        defer { WhisperModelStore.delete(variant) }

        let tokenizer = try #require(WhisperModelStore.tokenizerFolder(for: variant))
        try FileManager.default.createDirectory(at: tokenizer, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: tokenizer.appending(path: "tokenizer.json"))

        WhisperModelStore.delete(variant)
        #expect(!FileManager.default.fileExists(atPath: tokenizer.path))
    }
```

- [ ] **Step 2: Run the suite to verify it fails**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MinuteTests/WhisperModelStoreTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: a compile error, `error: type 'WhisperModelStore' has no member 'tokenizerFolder'`.

- [ ] **Step 3: Add the tokenizer location to the store**

In `Minute/Services/WhisperTranscriptionService.swift`, insert directly below `folder(for:)` (after line 76, before the `/// True when the pieces WhisperKit needs to load are all present.` comment on line 78):

```swift
    /// Where the tokenizers live: a sibling of the model folders inside the
    /// store, so baseDirectory's backup exclusion covers them and delete can
    /// reclaim them. WhisperKit treats this URL as a Hub download base and
    /// resolves each tokenizer to <base>/models/openai/whisper-<size>
    /// (HubApiWrapper.localRepoLocation → HubApi.swift:350-352).
    static var tokenizerBaseDirectory: URL {
        baseDirectory.appending(path: "tokenizers", directoryHint: .isDirectory)
    }

    /// Whisper sizes, most specific name first: "large-v3" must win over
    /// "large", and "base.en" over "base".
    private static let tokenizerVariants: [ModelVariant] = [
        .largev3, .largev2, .large, .mediumEn, .medium, .smallEn, .small, .baseEn, .base, .tinyEn, .tiny,
    ]

    /// The Whisper size a catalog folder name belongs to
    /// ("openai_whisper-large-v3-v20240930_626MB" → .largev3), or nil when
    /// the name is not a Whisper model at all.
    static func tokenizerVariant(for variant: String) -> ModelVariant? {
        tokenizerVariants.first { variant.contains($0.description) }
    }

    /// The folder holding one size's tokenizer files, or nil when the variant
    /// name maps to no Whisper size. The path is built, not asked for:
    /// HubApiWrapper's initializer starts an NWPathMonitor on a fresh queue
    /// (HubApi.swift:75, 114, 810-830), and isDownloaded calls this once per
    /// catalog row on every Settings refresh.
    /// ponytail: mirrors the hub layout (<base>/models/<repo>) and rebuilds
    /// the repo name ("openai/whisper-" + size) because WhisperKit's
    /// tokenizerNameForVariant is internal — the same bet folder(for:)
    /// already makes; revisit both if WhisperKit changes its layout.
    static func tokenizerFolder(for variant: String) -> URL? {
        guard let size = tokenizerVariant(for: variant) else { return nil }
        return tokenizerBaseDirectory.appending(
            path: "models/openai/whisper-\(size.description)",
            directoryHint: .isDirectory
        )
    }

    /// True when the tokenizer WhisperKit loads is in the store. Both files
    /// are needed: tokenizer.json is the vocabulary and tokenizer_config.json
    /// picks the tokenizer class, and a folder holding only one of them sends
    /// the load back to Hugging Face. A variant with no mapped size reports
    /// true so an off-catalog model never looks missing over a tokenizer that
    /// was never meant to exist.
    static func hasTokenizer(_ variant: String) -> Bool {
        guard let folder = tokenizerFolder(for: variant) else { return true }
        return ["tokenizer.json", "tokenizer_config.json"].allSatisfy {
            FileManager.default.fileExists(atPath: folder.appending(path: $0).path)
        }
    }

```

- [ ] **Step 4: Require the tokenizer, and delete it with the model**

In the same file, replace lines 78-87:

```swift
    /// True when the pieces WhisperKit needs to load are all present.
    /// ponytail: presence checks, no checksums — a corrupted model fails at
    /// load time and the fix is delete + re-download.
    static func isDownloaded(_ variant: String) -> Bool {
        let folder = folder(for: variant)
        let required = ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc", "config.json"]
        return required.allSatisfy {
            FileManager.default.fileExists(atPath: folder.appending(path: $0).path)
        }
    }
```

with:

```swift
    /// True when the pieces WhisperKit needs to load are all present — Core
    /// ML files AND the tokenizer, because a model without its tokenizer
    /// still needs the network on its first transcription, which is exactly
    /// what "downloaded" is supposed to rule out.
    /// ponytail: presence checks, no checksums — a corrupted model fails at
    /// load time and the fix is delete + re-download.
    static func isDownloaded(_ variant: String) -> Bool {
        let folder = folder(for: variant)
        let required = ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc", "config.json"]
        let hasModel = required.allSatisfy {
            FileManager.default.fileExists(atPath: folder.appending(path: $0).path)
        }
        return hasModel && hasTokenizer(variant)
    }
```

and replace lines 117-120:

```swift
    static func delete(_ variant: String) {
        try? FileManager.default.removeItem(at: folder(for: variant))
        try? FileManager.default.removeItem(at: downloadCache(for: variant))
    }
```

with:

```swift
    static func delete(_ variant: String) {
        try? FileManager.default.removeItem(at: folder(for: variant))
        try? FileManager.default.removeItem(at: downloadCache(for: variant))
        // Safe to take the whole tokenizer folder: no two catalog models
        // share a Whisper size, so this can't strand another model.
        if let tokenizer = tokenizerFolder(for: variant) {
            try? FileManager.default.removeItem(at: tokenizer)
        }
    }
```

- [ ] **Step 5: Run the suite to verify it passes**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MinuteTests/WhisperModelStoreTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: 5 tests pass.

- [ ] **Step 6: Run the full unit suite**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 310 tests.

- [ ] **Step 7: Commit**

```bash
git add Minute/Services/WhisperTranscriptionService.swift MinuteTests/WhisperModelStoreTests.swift
git commit -m "$(cat <<'EOF'
fix: count the tokenizer as part of a downloaded Whisper model

The store tracked only the Core ML files, so the tokenizer WhisperKit needs
to load a model lived outside it (HubApi's default Documents/huggingface),
survived Delete, and escaped the store's backup exclusion. The store now owns
a tokenizers/ folder beside the models, isDownloaded requires tokenizer.json
and tokenizer_config.json, and delete reclaims them. Task 8 makes Get fetch
them.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Fetch the tokenizer as part of "Get", and load it from the store (F05, part 2)

**Files:**
- Modify: `Minute/Services/WhisperTranscriptionService.swift` — `WhisperModelStore.download` (89-104 at `8c443be`) and `loadedWhisperKit` (171-195), both pushed down by Task 7's insert; anchor on the snippets
- Test: none — see Step 1.

**Interfaces:**
- Consumes (verified in the pinned WhisperKit checkout):
  - `ModelUtilities.loadTokenizer(for pretrained: ModelVariant, tokenizerFolder: URL? = nil, additionalSearchPaths: [URL] = [], useBackgroundSession: Bool = false) async throws -> WhisperTokenizer` — `Sources/WhisperKit/Utilities/ModelUtilities.swift:17-77`. It looks for `tokenizer.json` under `tokenizerFolder/models/openai/whisper-<size>` (`:24-25, 28-54`) and, when it isn't there, downloads the repo's config files into exactly that folder (`:68-76`, via `Sources/ArgmaxCore/External/Hub/Hub.swift:225-236`). `ModelUtilities` is public in ArgmaxCore, which WhisperKit re-exports (`Sources/WhisperKit/Core/WhisperKit.swift:4`).
  - `WhisperKitConfig(… tokenizerFolder: URL? = nil …)` — `Sources/WhisperKit/Core/Configurations.swift:21, 75-104`; `WhisperKit.init` keeps it as `tokenizerFolder` (`Sources/WhisperKit/Core/WhisperKit.swift:69`) and hands it to `ModelUtilities.loadTokenizer` at load time (`:475-480`), so a folder we pre-populated is a purely local hit.
  - `WhisperModelStore.tokenizerBaseDirectory`, `tokenizerVariant(for:)` (Task 7).
- Produces: `WhisperModelStore.downloadTokenizer(_ variant: String) async throws` (private); `download(_:onProgress:)` now completes the tokenizer too, and reports the model's own progress scaled to 0.99 so the last percent of the bar covers the tokenizer fetch.

- [ ] **Step 1: Note why there is no unit test**

This task is not unit-testable: both halves are live Hugging Face and Core ML work (`WhisperKit.download`, `ModelUtilities.loadTokenizer`, `WhisperKit(config)`), and a unit test that hit them would download hundreds of megabytes. Task 7's tests already pin the on-disk contract this code has to satisfy; this task is verified by the build and the full suite, and by the manual check in Step 5.

- [ ] **Step 2: Fetch the tokenizer as part of the download**

In `Minute/Services/WhisperTranscriptionService.swift`, replace `WhisperModelStore.download`:

```swift
    /// Streams the model from Hugging Face; partially downloaded files are
    /// kept so a retry resumes instead of starting over.
    static func download(
        _ variant: String,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws {
        _ = try await WhisperKit.download(
            variant: variant,
            downloadBase: baseDirectory,
            from: repo,
            progressCallback: { progress in
                let fraction = progress.fractionCompleted
                Task { @MainActor in onProgress(fraction) }
            }
        )
    }
```

with:

```swift
    /// Streams the model and its tokenizer from Hugging Face; partially
    /// downloaded files are kept so a retry resumes instead of starting over.
    static func download(
        _ variant: String,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws {
        _ = try await WhisperKit.download(
            variant: variant,
            downloadBase: baseDirectory,
            from: repo,
            progressCallback: { progress in
                // The bar's last percent belongs to the tokenizer fetched
                // below. Without it a re-Get of an already-complete model —
                // which every existing install needs once now that the
                // tokenizer counts — would sit at a full bar for the seconds
                // that fetch takes and read as a hang.
                let fraction = progress.fractionCompleted * 0.99
                Task { @MainActor in onProgress(fraction) }
            }
        )
        // Don't start a fresh fetch on a cancel that landed at a file
        // boundary (WhisperKit returns normally from those).
        try Task.checkCancellation()
        try await downloadTokenizer(variant)
        await MainActor.run { onProgress(1) }
    }

    /// Fetches the variant's tokenizer into the store. WhisperKit would
    /// otherwise fetch it during the FIRST TRANSCRIPTION — which fails
    /// offline and reports "the model couldn't be loaded, re-download it",
    /// sending the user after 630 MB that were never the problem. A few
    /// megabytes of JSON here makes Get the only network step.
    /// ponytail: loadTokenizer also builds the tokenizer in memory (there is
    /// no download-only entry point); that is JSON parsing, no Core ML.
    private static func downloadTokenizer(_ variant: String) async throws {
        // An off-catalog variant maps to no Whisper size; hasTokenizer treats
        // those as satisfied, so there is nothing to fetch.
        guard let size = tokenizerVariant(for: variant) else { return }
        _ = try await ModelUtilities.loadTokenizer(for: size, tokenizerFolder: tokenizerBaseDirectory)
    }
```

- [ ] **Step 3: Point the loader at the store's tokenizer folder**

In the same file, inside `loadedWhisperKit()`, replace the config construction:

```swift
        do {
            let config = WhisperKitConfig(
                modelFolder: WhisperModelStore.folder(for: variant).path,
                verbose: false,
                logLevel: .error,
                load: true,
                download: false
            )
```

with:

```swift
        do {
            let config = WhisperKitConfig(
                modelFolder: WhisperModelStore.folder(for: variant).path,
                // Without this the tokenizer is looked up in HubApi's default
                // location (Documents/huggingface) and fetched from Hugging
                // Face on first use — outside the store, outside Delete, and
                // impossible offline. The download put it here.
                tokenizerFolder: WhisperModelStore.tokenizerBaseDirectory,
                verbose: false,
                logLevel: .error,
                load: true,
                download: false
            )
```

- [ ] **Step 4: Run the full unit suite**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 310 tests, no new warnings.

- [ ] **Step 5: Check the store layout by hand (device or simulator, needs network)**

Run the app, open Settings → Transcription → pick Whisper → tap Get on "Base", watch the bar stop just short of full while the tokenizer arrives and then complete, and confirm the app container holds
`Application Support/WhisperKitModels/tokenizers/models/openai/whisper-base/tokenizer.json` and `…/tokenizer_config.json` alongside
`Application Support/WhisperKitModels/models/argmaxinc/whisperkit-coreml/openai_whisper-base/`. Note in the commit if the layout differs.
Existing installs that already had a model see it as "not downloaded" until they tap Get again; that download resumes the Core ML files and adds the tokenizer.

- [ ] **Step 6: Commit**

```bash
git add Minute/Services/WhisperTranscriptionService.swift
git commit -m "$(cat <<'EOF'
fix: download the Whisper tokenizer with the model, and load it locally

The first transcription after Get fetched the tokenizer from Hugging Face,
so a meeting started in airplane mode failed with "the model couldn't be
loaded, re-download it" for a model that was fine — and the bytes landed
outside the store, where Delete and the backup exclusion never reached them.
Get now fetches the tokenizer into the store's tokenizers/ folder and the
load config points there, so a downloaded model really does run offline. The
progress bar's last percent covers that fetch, so the re-Get every existing
install needs doesn't sit at a full bar while the tokenizer arrives.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: Record the downloaded snapshot directory in the completion marker (F11, part 1)

**Files:**
- Modify: `Minute/Services/MLXSummarizationService.swift:95-104` (marker doc + name, plus a `logger` for the store), add `snapshotDirectory(for:)`, `writeCompletionMarker(for:snapshotDirectory:)`, `relativeSnapshotPath(for:)` after `completionMarker(for:)`; `:176-182` (the marker write in `download`)
- Create: `MinuteTests/MLXModelStoreTests.swift`

**Interfaces:**
- Consumes: `MLXModelStore.baseDirectory`, `MLXModelStore.repoDirectory(for:)`, `MLXModelStore.completionMarker(for:)`, `MLXModelStore.isDownloaded(_:)`, `ResolvedModelConfiguration.modelDirectory` (`mlx-swift-lm/Libraries/MLXLMCommon/Downloader.swift:69-77`), which for this store is the Hub cache snapshot directory `<baseDirectory>/models--org--name/snapshots/<commit>` (`swift-huggingface/Sources/HuggingFace/Hub/HubClient+Files.swift:1193-1213`, reached from `mlx-swift-lm/Libraries/MLXHuggingFaceMacros/HuggingFaceIntegrationMacros.swift:38-58`).
- Produces: `MLXModelStore.snapshotDirectory(for model: MLXSummaryModel) -> URL?`; `MLXModelStore.writeCompletionMarker(for model: MLXSummaryModel, snapshotDirectory: URL) -> Bool`; `MLXModelStore.relativeSnapshotPath(for directory: URL) -> String`.

- [ ] **Step 1: Write the failing test**

Create `MinuteTests/MLXModelStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import Minute

/// The completion marker certifies a finished download AND, so that loading a
/// summary model never has to ask Hugging Face which commit "main" points at,
/// records where that download landed.
struct MLXModelStoreTests {
    private func makeModel() -> MLXSummaryModel {
        MLXSummaryModel(
            repoID: "test-org/fake-\(UUID().uuidString)",
            label: "Fake",
            detail: "Test fixture.",
            approximateMegabytes: 1,
            minimumMemoryGigabytes: 1
        )
    }

    @Test("The marker records the snapshot directory relative to the store")
    func markerRecordsTheSnapshotDirectory() throws {
        let model = makeModel()
        defer { MLXModelStore.delete(model) }

        let snapshot = MLXModelStore.repoDirectory(for: model)
            .appending(path: "snapshots/abc123", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)

        #expect(MLXModelStore.writeCompletionMarker(for: model, snapshotDirectory: snapshot))
        #expect(MLXModelStore.snapshotDirectory(for: model)?.standardizedFileURL == snapshot.standardizedFileURL)

        // Relative, not absolute: the app's container path changes between
        // installs, and an absolute path would rot into a load failure.
        let contents = try String(contentsOf: MLXModelStore.completionMarker(for: model), encoding: .utf8)
        let expected = "models--" + model.repoID.replacingOccurrences(of: "/", with: "--") + "/snapshots/abc123"
        #expect(contents == expected)
    }

    @Test("A marker from an older build still counts as downloaded, with no directory")
    func olderMarkerHasNoRecordedDirectory() throws {
        let model = makeModel()
        defer { MLXModelStore.delete(model) }

        let directory = MLXModelStore.repoDirectory(for: model)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(count: 1).write(to: directory.appending(path: "model.safetensors"))
        // The old format: an empty marker file.
        #expect(FileManager.default.createFile(atPath: MLXModelStore.completionMarker(for: model).path, contents: nil))

        #expect(MLXModelStore.isDownloaded(model))
        #expect(MLXModelStore.snapshotDirectory(for: model) == nil)
    }

    @Test("A recorded directory that no longer exists is ignored")
    func missingRecordedDirectoryIsIgnored() throws {
        let model = makeModel()
        defer { MLXModelStore.delete(model) }

        let snapshot = MLXModelStore.repoDirectory(for: model)
            .appending(path: "snapshots/gone", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        #expect(MLXModelStore.writeCompletionMarker(for: model, snapshotDirectory: snapshot))
        try FileManager.default.removeItem(at: snapshot)

        // Falling back beats loading from a directory that isn't there.
        #expect(MLXModelStore.snapshotDirectory(for: model) == nil)
    }

    @Test("A snapshot outside the store records nothing")
    func snapshotOutsideTheStoreRecordsNothing() throws {
        let model = makeModel()
        defer { MLXModelStore.delete(model) }
        try FileManager.default.createDirectory(
            at: MLXModelStore.repoDirectory(for: model), withIntermediateDirectories: true
        )

        #expect(MLXModelStore.writeCompletionMarker(for: model, snapshotDirectory: FileManager.default.temporaryDirectory))
        #expect(MLXModelStore.relativeSnapshotPath(for: FileManager.default.temporaryDirectory).isEmpty)
        #expect(MLXModelStore.snapshotDirectory(for: model) == nil)
    }
}
```

- [ ] **Step 2: Run the suite to verify it fails**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MinuteTests/MLXModelStoreTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: a compile error, `error: type 'MLXModelStore' has no member 'writeCompletionMarker'`.

- [ ] **Step 3: Teach the marker to carry the snapshot path**

In `Minute/Services/MLXSummarizationService.swift`, replace lines 95-104:

```swift
    /// Written only after download() finishes the whole snapshot. Weights
    /// alone aren't proof of completeness: an interrupted download can leave
    /// one flushed shard behind, and loading such a partial snapshot would
    /// silently fetch the rest over the network mid-generation — which the
    /// Settings copy promises never happens.
    private static let completionMarkerName = ".minute-download-complete"

    static func completionMarker(for model: MLXSummaryModel) -> URL {
        repoDirectory(for: model).appending(path: completionMarkerName)
    }
```

with:

```swift
    private static let logger = Logger(subsystem: "com.minuteapp.Minute", category: "MLXModelStore")

    /// Written only after download() finishes the whole snapshot. Weights
    /// alone aren't proof of completeness: an interrupted download can leave
    /// one flushed shard behind, and loading such a partial snapshot would
    /// silently fetch the rest over the network mid-generation — which the
    /// Settings copy promises never happens.
    ///
    /// Its contents are the snapshot directory's path relative to
    /// baseDirectory, so the load path can open that exact directory instead
    /// of asking Hugging Face what revision "main" points at today. Empty
    /// contents mean a marker written by an older build.
    private static let completionMarkerName = ".minute-download-complete"

    static func completionMarker(for model: MLXSummaryModel) -> URL {
        repoDirectory(for: model).appending(path: completionMarkerName)
    }

    /// The downloaded snapshot directory this marker recorded, or nil when
    /// the marker predates the format or the directory is gone — either way
    /// the loader falls back to resolving it once.
    static func snapshotDirectory(for model: MLXSummaryModel) -> URL? {
        guard let contents = try? String(contentsOf: completionMarker(for: model), encoding: .utf8) else {
            return nil
        }
        let relativePath = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !relativePath.isEmpty else { return nil }
        let directory = baseDirectory.appending(path: relativePath, directoryHint: .isDirectory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return directory
    }

    /// Records a finished download and where it landed. False when the file
    /// couldn't be written (a disk full at the very end), which must fail the
    /// download: the UI would otherwise report success while isDownloaded
    /// keeps rejecting the model forever.
    static func writeCompletionMarker(for model: MLXSummaryModel, snapshotDirectory: URL) -> Bool {
        FileManager.default.createFile(
            atPath: completionMarker(for: model).path,
            contents: Data(relativeSnapshotPath(for: snapshotDirectory).utf8)
        )
    }

    /// The snapshot path relative to the store root — the app's container
    /// path changes between installs, so an absolute path would rot. Empty
    /// when the directory isn't inside the store, which records nothing and
    /// leaves the loader on its fallback.
    ///
    /// Both sides are symlink-resolved before comparing: standardizedFileURL
    /// does NOT resolve symlinks, so /var and /private/var spellings of the
    /// same directory would fail a plain prefix test and silently record
    /// nothing — F11 undone with no symptom but a slow first token.
    static func relativeSnapshotPath(for directory: URL) -> String {
        let root = baseDirectory.resolvingSymlinksInPath().path
        let path = directory.resolvingSymlinksInPath().path
        guard path.hasPrefix(root + "/") else {
            // Not fatal — the loader keeps resolving once per load — but the
            // offline load is quietly gone, so leave a trace for Step 4's
            // device check (visible in the Xcode console while attached).
            Self.logger.error("Snapshot directory outside the store, recording no path: \(path)")
            return ""
        }
        return String(path.dropFirst(root.count + 1))
    }
```

- [ ] **Step 4: Write the new marker at the end of a download**

In the same file, replace lines 176-182:

```swift
        // Only a fully resolved snapshot earns the marker isDownloaded
        // needs — and a marker that can't be written (disk full at the very
        // end) must fail the download, or the UI reports success while
        // isDownloaded keeps rejecting the model forever.
        guard FileManager.default.createFile(atPath: completionMarker(for: model).path, contents: nil) else {
            throw MarkerWriteFailure()
        }
```

with:

```swift
        // Only a fully resolved snapshot earns the marker isDownloaded
        // needs — and a marker that can't be written (disk full at the very
        // end) must fail the download, or the UI reports success while
        // isDownloaded keeps rejecting the model forever. The marker also
        // records this exact snapshot directory, which is what lets loading
        // stay offline.
        guard writeCompletionMarker(for: model, snapshotDirectory: resolved.modelDirectory) else {
            throw MarkerWriteFailure()
        }
```

- [ ] **Step 5: Run the suite to verify it passes**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MinuteTests/MLXModelStoreTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: 4 tests pass.

- [ ] **Step 6: Run the full unit suite**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 314 tests.

- [ ] **Step 7: Commit**

```bash
git add Minute/Services/MLXSummarizationService.swift MinuteTests/MLXModelStoreTests.swift
git commit -m "$(cat <<'EOF'
fix: record the downloaded snapshot directory in the completion marker

The marker was an empty file, so the load path had nothing to open and asked
Hugging Face to resolve revision "main" instead. It now carries the snapshot
directory's path relative to the store; markers from older builds stay valid
and simply report no directory. Task 10 uses it.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: Load the local summary model from disk, never through the hub (F11, part 2)

**Files:**
- Modify: `Minute/Services/MLXSummarizationService.swift` — `loadedContainer()`, the whole `// MARK: Model loading` section (314-329 at `8c443be`, pushed well down by Tasks 6 and 9); anchor on the snippet
- Test: none — see Step 1.

**Interfaces:**
- Consumes (verified in the mlx-swift-lm checkout):
  - `GenericModelFactory.loadContainer(from directory: URL, using tokenizerLoader: any TokenizerLoader) async throws -> ContainerType` — `Libraries/MLXLMCommon/ModelFactory.swift:200-208`; no `Downloader` is involved, and `#huggingFaceTokenizerLoader()` loads from that directory with `Tokenizers.AutoTokenizer.from(modelFolder:)` (`Libraries/MLXHuggingFaceMacros/HuggingFaceIntegrationMacros.swift:142-149`).
  - `resolve(configuration:from:useLatest:progressHandler:) async throws -> ResolvedModelConfiguration` — `Libraries/MLXLMCommon/ModelFactory.swift:228-263` (already used by `MLXModelStore.download`); its `.id` branch is the network path that `ModelConfiguration(id:)` takes with revision defaulting to `"main"` (`Libraries/MLXLMCommon/ModelConfiguration.swift:33-38, 121-137`), which `HubClient.downloadSnapshot` cannot serve from cache without a listing request (`swift-huggingface/Sources/HuggingFace/Hub/HubClient+Files.swift:1235-1251, 1271-1288, 1529-1561`).
  - `MLXModelStore.snapshotDirectory(for:)`, `MLXModelStore.writeCompletionMarker(for:snapshotDirectory:)` (Task 9), `MLXModelStore.hubClient()`.
- Produces: `MLXSummarizationService.snapshotDirectory(for model: MLXSummaryModel) async throws -> URL` (private); `loadedContainer()` no longer takes a `Downloader`.

- [ ] **Step 1: Note why there is no unit test**

This task is not unit-testable: `MLXSummarizationService.availabilityMessage` refuses to run in the Simulator and a real load needs gigabytes of weights on a device. Task 9's tests cover the marker contract this code reads; the load path is verified by the build, the full suite, and the manual check in Step 4.

- [ ] **Step 2: Load from the recorded directory**

In `Minute/Services/MLXSummarizationService.swift`, replace `loadedContainer()`:

```swift
    /// Loads through the same downloader path as Settings' download — with
    /// the snapshot already cached this is an offline cache hit, and it
    /// avoids hardcoding HubCache's snapshot-revision layout.
    private func loadedContainer() async throws -> ModelContainer {
        if let container { return container }
        guard let model = MLXModelCatalog.model(for: AppSettings.localSummaryModel) else {
            throw SummarizerError.unavailable("The selected summary model is no longer offered. Choose another in Settings → Summary Model.")
        }
        let loaded = try await LLMModelFactory.shared.loadContainer(
            from: #hubDownloader(MLXModelStore.hubClient()),
            using: #huggingFaceTokenizerLoader(),
            configuration: ModelConfiguration(id: model.repoID)
        )
        container = loaded
        return loaded
    }
```

with:

```swift
    /// Loads the weights straight out of the directory the download recorded.
    /// Loading by repo id instead would resolve revision "main" through
    /// huggingface.co on EVERY summary — a request the user never asked for,
    /// a ~60 s stall before the first token on a network where the host is
    /// reachable but dead, and a chance of pulling newly added files
    /// mid-generation. Only the Get button may touch the network.
    private func loadedContainer() async throws -> ModelContainer {
        if let container { return container }
        guard let model = MLXModelCatalog.model(for: AppSettings.localSummaryModel) else {
            throw SummarizerError.unavailable("The selected summary model is no longer offered. Choose another in Settings → Summary Model.")
        }
        let directory = try await snapshotDirectory(for: model)
        let loaded = try await LLMModelFactory.shared.loadContainer(
            from: directory,
            using: #huggingFaceTokenizerLoader()
        )
        container = loaded
        return loaded
    }

    /// The recorded snapshot directory. A model downloaded by a build that
    /// didn't record one is resolved the old way ONCE — the same call the
    /// download makes, so a cached snapshot is found — and the marker is
    /// rewritten so every later load is local.
    private func snapshotDirectory(for model: MLXSummaryModel) async throws -> URL {
        if let recorded = MLXModelStore.snapshotDirectory(for: model) { return recorded }
        let resolved = try await resolve(
            configuration: ModelConfiguration(id: model.repoID),
            from: #hubDownloader(MLXModelStore.hubClient()),
            useLatest: false,
            progressHandler: { _ in }
        )
        // Best effort: a marker that can't be rewritten costs one resolve per
        // load, not a failed summary.
        _ = MLXModelStore.writeCompletionMarker(for: model, snapshotDirectory: resolved.modelDirectory)
        return resolved.modelDirectory
    }
```

- [ ] **Step 3: Run the full unit suite**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 314 tests, no new warnings.

- [ ] **Step 4: Check on a device (needs a downloaded local model)**

On a device with a local summary model downloaded: turn on Airplane Mode, open a meeting and tap Generate Summary. It must start generating (no "Loading the summary model…" stall and no load error). Repeat once online with Charles/Network Link Conditioner or Console.app filtered on `huggingface.co` to confirm no request is made during a summary. If the model was downloaded by an older build, the first summary after this change resolves once (which needs network or a warm cache) and then rewrites the marker — the second summary must be fully offline.

- [ ] **Step 5: Commit**

```bash
git add Minute/Services/MLXSummarizationService.swift
git commit -m "$(cat <<'EOF'
fix: load the local summary model from disk instead of through the hub

loadedContainer() resolved ModelConfiguration(id:) at revision "main", and
HubClient can only serve a commit hash from cache — so every summary began
with a GET to huggingface.co, could pull newly added repo files mid-
generation, and stalled for the URLSession timeout when the host was
reachable but dead. The download now records its snapshot directory and the
load opens that directory directly; a model from an older build resolves once
more and then rewrites its marker.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Hand-offs to Track E

- **RecordingView (`Minute/Views/RecordingView.swift:242-265`)**: `transcriptArea` switches on `session.transcription.availability` and now falls into `default:` → `liveTranscript` → "Listening…" for the new `.loadingModel` case. Add a case beside `.downloadingModel` rendering a `ProgressView("Loading the transcription model…")` with the sub-line "Recording continues while the model loads — the live transcript starts once it's ready." (F71 UI side; the engine already sets the state).
- Nothing else: Tasks 2-10 stay inside track-owned files.

### Not done in this track

- **F13's "surface a persisted failure if the app relaunches with a job that never finished"** — `MeetingJobs` is not this track's file and job state is deliberately in-memory; the decision scoped F13 to the app-wide gate.
- **F13 for Whisper re-transcription running alongside an MLX summary** — the decision names local-model (MLX) jobs only, and the shared gate would have to be acquired inside `MeetingJobs`, which this track does not own.
- **F45's background `URLSessionConfiguration`** — the decision chose the `BackgroundTaskToken` route; a background session would change how `WhisperKit.download` and the hub downloader run and is a far larger change than the finding warrants.
- **F11's "pin each catalog entry to a commit hash"** — the decision chose recording the snapshot directory instead, which needs no catalog churn on every upstream re-quantization.
- **F12's "optionally retry the merge once with a fresh session"** — YAGNI: the decision is the code-level fold, and a retry doubles the worst-case wait on a model that already failed the largest prompt of the run.
- **F05's "make the load-failure message distinguish 'needs a one-time network fetch' from 'model corrupted'"** — no longer a distinct state: a model missing its tokenizer now fails `isDownloaded`, so `prepare()` reports the accurate "The Whisper model isn't downloaded yet…" and the load-failure text only appears for a genuinely broken model.

---

## Track D — Recording and playback

Twelve fixes to the recording studio, the recorder, the live-transcription engine, the Live Activity, and playback. The two large ones (Task 21's persist-before-finalize restructure of `RecordingSession.finish(in:)` and Task 18's buffer backlog) come last, after the cheap contained fixes have already moved the files they build on.

**Files this track owns** (edit nothing else):
`Minute/Recording/RecordingSession.swift`, `Minute/Services/AudioRecorder.swift`, `Minute/Views/RecordingView.swift`, `Minute/Recording/RecordingLiveActivityController.swift`, `Minute/Services/TranscriptionService.swift`, `Minute/Services/AudioPlayerController.swift`, `Minute/Views/PlaybackBarView.swift`, `Minute/Support/AudioBufferConverter.swift`, `Shared/RecordingActivityAttributes.swift`, `MinuteWidgets/RecordingLiveActivity.swift`, `MinuteTests/RecordingSessionTitleTests.swift`, `MinuteTests/BufferHandlerBoxTests.swift`, and the new test files this section creates.

### Global Constraints

- Privacy invariants from CONTRIBUTING.md hold: no meeting content on the wire; every byte written has a delete path (MeetingStore.delete or the launch sweeps); AI output stays grounded ("Not specified" literal); recording never depends on optional capabilities and any handled failure still offers to save captured audio.
- No new third-party dependencies. Do not edit Minute.xcodeproj/project.pbxproj (new files under Minute/, MinuteTests/, Shared/, MinuteWidgets/ are picked up automatically).
- Unit tests use Swift Testing (import Testing, @Test, #expect, #require), never XCTest. SwiftData-touching test structs are @MainActor with an in-memory container via MeetingStore.modelConfiguration(inMemory: true); containers holding KnowledgeEntity/KnowledgeFact are retained for the process lifetime (retainedContainers pattern in MinuteTests/KnowledgeCatchUpTests.swift).
- The project builds in Swift 5 language mode: an actor-isolated expression cannot be a default argument (use the nil-defaulted injection pattern: `engine: (any Engine)? = nil` then `let engine = engine ?? Engines.current()`).
- Baseline at the branch point (commit 8c443be on main): 292 tests in 43 suites pass. Every task leaves that green plus its own new tests.
- SwiftLint is strict in CI (.swiftlint.yml disables line_length, function/type/file length, cyclomatic_complexity, identifier_name, todo, redundant_optional_initialization, trailing_comma, for_where): match the codebase style — 4-space indent, doc comments that explain WHY, no for…where wrapping side effects. swiftlint is not installed locally.
- Commit messages: Conventional Commits (fix:/test:/docs:), ending with the trailer line "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>". Commit with explicit paths; never git add -A; never commit anything under .superpowers/.
- A task edits only files its track owns (listed below). If a fix genuinely needs a file another track owns, the task ends at the owned side (e.g. adds a hook/property) and the plan section's "Hand-offs to Track E" list names the one-line wiring the post-merge track must do.
- SwiftData fact established in batch 1: after a committed delete an object has isDeleted == false and modelContext == nil; guard stale reads with the PersistentModel `isGone` extension (Minute/Models/PersistentModel+IsGone.swift), never isDeleted.

**Test commands** (run from the worktree root; this track uses simulator "iPhone 17"):

One suite while iterating:
```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MinuteTests/<SuiteName> CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```

Full unit suite once before each commit:
```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```

---

### Task 11: Live Activity gets the title the meeting will actually be saved with (F42)

**Files:**
- Modify: `Minute/Recording/RecordingSession.swift` (add a property next to `savedTitles`, lines 260-269; change the `.recording` branch of `syncLiveActivity`, lines 233-241)
- Test: `MinuteTests/RecordingSessionTitleTests.swift` (add two tests to the existing struct, after line 35)

**Interfaces:**
- Consumes: `static func savedTitles(draft: String, prefilledDefault: String) -> (title: String, defaultTitle: String)`; `RecordingLiveActivityController.start(title: String)`; `RecordingSession.init(title:prefilledDefaultTitle:)`.
- Produces: `var liveActivityTitle: String` on `RecordingSession` (main-actor, read by `syncLiveActivity` and by the tests).

- [ ] **Step 1: Write the failing test**

Add to `MinuteTests/RecordingSessionTitleTests.swift`, inside the struct after `sessionKeepsThePrefilledDefaultItWasCreatedWith`:

```swift

    /// ActivityAttributes are immutable for the life of the activity, so the
    /// title handed to `start` is the only one the lock screen will ever show —
    /// it has to be the same string the saved meeting gets, not the raw draft.
    @Test func liveActivityTitleFallsBackToThePrefilledDefaultWhenTheDraftIsEmpty() {
        let session = RecordingSession(title: "   ", prefilledDefaultTitle: "Meeting Sep 2, 2026 at 9:30 AM")
        #expect(session.liveActivityTitle == "Meeting Sep 2, 2026 at 9:30 AM")
    }

    @Test func liveActivityTitleTrimsTheDraftTheUserTyped() {
        let session = RecordingSession(title: "  Q3 roadmap  ", prefilledDefaultTitle: "Meeting Sep 2, 2026 at 9:30 AM")
        #expect(session.liveActivityTitle == "Q3 roadmap")
    }
```

- [ ] **Step 2: Run the suite to verify it fails**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MinuteTests/RecordingSessionTitleTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: compile error `value of type 'RecordingSession' has no member 'liveActivityTitle'`.

- [ ] **Step 3: Implement**

In `Minute/Recording/RecordingSession.swift`, add this property immediately before `nonisolated static func defaultTitle(for:)` (i.e. after the `syncLiveActivity` method, around line 251):

```swift

    /// The title the Live Activity is started with. `ActivityAttributes` are
    /// immutable for the life of the activity, so this is the only title the
    /// lock screen ever shows — take it through the same trim-and-fall-back
    /// the save uses, or clearing the title field in the New Meeting sheet
    /// leaves the card (and the expanded Dynamic Island) with a blank line
    /// while the saved meeting is named "Meeting <date>".
    var liveActivityTitle: String {
        Self.savedTitles(draft: title, prefilledDefault: prefilledDefaultTitle).title
    }
```

In the same file, in `syncLiveActivity(from:)`, replace:

```swift
                liveActivity.start(title: title)
```

with:

```swift
                liveActivity.start(title: liveActivityTitle)
```

- [ ] **Step 4: Run the suite to verify it passes**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MinuteTests/RecordingSessionTitleTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: 6 tests pass in `RecordingSessionTitleTests`.

- [ ] **Step 5: Run the full unit suite**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 294 tests (292 baseline + 2).

- [ ] **Step 6: Commit**

```bash
git add Minute/Recording/RecordingSession.swift MinuteTests/RecordingSessionTitleTests.swift
git commit -m "fix: start the Live Activity with the title the meeting will be saved with

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 12: Playback that refuses to start says so instead of showing Pause over silence (F21)

**Files:**
- Modify: `Minute/Services/AudioPlayerController.swift` (properties, lines 18-22; `load(url:)`, lines 88-96; `play()`, lines 107-121; `stop()`, lines 141-150)
- Modify: `Minute/Views/PlaybackBarView.swift` (the `else` branch of `body`, lines 21-77)
- Create: `MinuteTests/AudioPlayerControllerTests.swift`

**Interfaces:**
- Consumes: `AVAudioPlayer.play() -> Bool`; `AudioPlayerController.deactivateSessionIfNeeded()` (private, existing); `AudioPlayerController.isPlaying`, `.duration`, `.currentTime`, `.isLoaded`.
- Produces: `static let AudioPlayerController.playbackFailedMessage: String`; `private(set) var lastError: String?`; `func load(url: URL, makePlayer: (URL) throws -> AVAudioPlayer = { try AVAudioPlayer(contentsOf: $0) }) throws`.

- [ ] **Step 1: Write the failing test**

Create `MinuteTests/AudioPlayerControllerTests.swift`:

```swift
import AVFoundation
import Foundation
import Testing
@testable import Minute

/// A player that refuses to start, the way AVAudioPlayer does while another
/// app's non-mixable session (a phone call) holds the audio hardware.
private final class RefusingPlayer: AVAudioPlayer {
    override func play() -> Bool { false }
}

/// A player that starts, without depending on the test simulator actually
/// having an audio route.
private final class StartingPlayer: AVAudioPlayer {
    override func play() -> Bool { true }
}

/// `play()` used to discard AVAudioPlayer's Bool: when the player refused to
/// start, the bar showed the pause icon and "Pause playback" over silence with
/// a frozen clock, and nothing ever corrected it.
@MainActor
struct AudioPlayerControllerTests {
    /// Half a second of silence, written as a real WAV file so AVAudioPlayer
    /// can open it.
    private func makeWavFixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("playback-fixture-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000)!
        buffer.frameLength = 8_000
        try file.write(from: buffer)
        return url
    }

    @Test func aPlayerThatRefusesToStartLeavesTheBarOnPlayAndSaysWhy() throws {
        let url = try makeWavFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = AudioPlayerController()
        try controller.load(url: url) { try RefusingPlayer(contentsOf: $0) }

        controller.play()

        #expect(controller.isPlaying == false)
        #expect(controller.lastError == AudioPlayerController.playbackFailedMessage)
        controller.stop()
    }

    @Test func aPlayerThatStartsClearsTheEarlierFailure() throws {
        let url = try makeWavFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = AudioPlayerController()
        try controller.load(url: url) { try RefusingPlayer(contentsOf: $0) }
        controller.play()
        #expect(controller.lastError != nil)

        try controller.load(url: url) { try StartingPlayer(contentsOf: $0) }
        controller.play()

        #expect(controller.isPlaying)
        #expect(controller.lastError == nil)
        controller.stop()
    }
}
```

- [ ] **Step 2: Run the suite to verify it fails**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MinuteTests/AudioPlayerControllerTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: compile errors — `extra argument 'makePlayer' in call`, `type 'AudioPlayerController' has no member 'playbackFailedMessage'`, `value of type 'AudioPlayerController' has no member 'lastError'`.

- [ ] **Step 3: Add the error state and the injectable player**

In `Minute/Services/AudioPlayerController.swift`, replace:

```swift
    private(set) var isPlaying = false
    private(set) var duration: TimeInterval = 0
    var currentTime: TimeInterval = 0
```

with:

```swift
    private(set) var isPlaying = false
    private(set) var duration: TimeInterval = 0
    var currentTime: TimeInterval = 0
    /// Why playback couldn't start, for the playback bar to show. Cleared by
    /// the next successful start and by `stop()`.
    private(set) var lastError: String?

    /// Shown when AVAudioPlayer refuses to start. Named so the view and the
    /// tests agree on one string.
    static let playbackFailedMessage = "Couldn't start playback — another app may be using the audio."
```

Then replace `load(url:)`:

```swift
    func load(url: URL) throws {
        stop()
        let player = try AVAudioPlayer(contentsOf: url)
```

with:

```swift
    /// Loads the recording at `url`. `makePlayer` is injectable for tests:
    /// AVAudioPlayer's refusal to start can't be provoked from a unit test any
    /// other way, and that refusal is the case this controller has to survive.
    func load(url: URL, makePlayer: (URL) throws -> AVAudioPlayer = { try AVAudioPlayer(contentsOf: $0) }) throws {
        stop()
        let player = try makePlayer(url)
```

- [ ] **Step 4: Honor the result of `play()`**

Replace the body of `play()`:

```swift
        player.play()
        isPlaying = true
        startTicker()
    }
```

with:

```swift
        guard player.play() else {
            // The player did not start (typically a phone call or another
            // non-mixable session holds the hardware). Saying "playing" here
            // is the exact symptom this class exists to prevent: a pause icon
            // over silence with a clock that never moves.
            Self.logger.error("AVAudioPlayer refused to start playback")
            isPlaying = false
            stopTicker()
            deactivateSessionIfNeeded()
            lastError = Self.playbackFailedMessage
            return
        }
        lastError = nil
        isPlaying = true
        startTicker()
    }
```

In `stop()`, add the reset — replace:

```swift
    func stop() {
        pausedByInterruption = false
        player?.stop()
```

with:

```swift
    func stop() {
        pausedByInterruption = false
        lastError = nil
        player?.stop()
```

- [ ] **Step 5: Show the notice in the bar**

In `Minute/Views/PlaybackBarView.swift`, replace the whole `else` branch of `body` (currently `} else {` through the closing of `.task(id: url) { … }`) with:

```swift
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 14) {
                    Button {
                        player.togglePlayback()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(Color.accentColor, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(player.isPlaying ? "Pause playback" : "Play recording")

                    VStack(spacing: 2) {
                        Slider(
                            value: Binding(
                                get: { displayTime },
                                set: { scrubTime = $0 }
                            ),
                            in: 0...max(player.duration, 0.01)
                        ) { editing in
                            if editing {
                                scrubTime = player.currentTime
                                isScrubbing = true
                            } else {
                                player.seek(to: scrubTime)
                                isScrubbing = false
                            }
                        }
                        .accessibilityLabel("Playback position")

                        // Elapsed and remaining sit at the ends of the track they
                        // describe, the way a player's timeline reads.
                        HStack {
                            Text(displayTime.clockString)
                            Spacer()
                            Text(player.duration.clockString)
                        }
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                // One line, under the control that failed: a tap that produced
                // nothing has to say something, or the user taps again.
                if let lastError = player.lastError {
                    Text(lastError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .task(id: url) {
                // List rows re-run .task when scrolled back on screen; don't
                // reload (and reset) an already-loaded player.
                guard !player.isLoaded else { return }
                do {
                    try player.load(url: url)
                } catch {
                    loadError = "This recording can't be played back."
                }
            }
        }
```

- [ ] **Step 6: Run the suite to verify it passes**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MinuteTests/AudioPlayerControllerTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: 2 tests pass.

- [ ] **Step 7: Run the full unit suite**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 296 tests (292 baseline + 4).

- [ ] **Step 8: Commit**

```bash
git add Minute/Services/AudioPlayerController.swift Minute/Views/PlaybackBarView.swift MinuteTests/AudioPlayerControllerTests.swift
git commit -m "fix: report playback that never started instead of showing pause over silence

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 13: A cancelled file transcription is discarded, not applied (F10)

**Files:**
- Modify: `Minute/Services/TranscriptionService.swift` (`transcribe(file:)`, lines 184-196)

**Interfaces:**
- Consumes: `SpeechAnalyzer.analyzeSequence(from:)`, `SpeechAnalyzer.finalizeAndFinish(through:)`, `SpeechAnalyzer.cancelAndFinishNow()` (existing call sites in this method).
- Produces: no new symbols; `transcribe(file:)` now throws `CancellationError` when the caller cancelled during the analysis.

**Not unit-testable:** `transcribe(file:)` returns early unless `availability == .available`, which requires a real `SpeechTranscriber` (never available on the simulator), so the cancellation path cannot be reached from a unit test — verified by build plus the full suite.

- [ ] **Step 1: Implement**

In `Minute/Services/TranscriptionService.swift`, replace:

```swift
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        do {
            if let lastSample = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
```

with:

```swift
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        do {
            if let lastSample = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            // The caller replaces the meeting's entire transcript with what
            // comes back, so a re-transcription the user stopped must be
            // thrown away rather than applied. `collector` is an unstructured
            // Task and does not inherit this cancellation, which is why the
            // check has to be explicit.
            try Task.checkCancellation()
        } catch {
```

- [ ] **Step 2: Run the full unit suite**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 296 tests, no new warnings.

- [ ] **Step 3: Commit**

```bash
git add Minute/Services/TranscriptionService.swift
git commit -m "fix: discard a cancelled file transcription instead of applying it

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 14: Live transcription that dies mid-recording says so on screen (F49)

**Files:**
- Modify: `Minute/Services/TranscriptionService.swift` (the `resultsTask` catch, lines 124-128; add a static helper next to it)
- Create: `MinuteTests/TranscriptionLiveFailureTests.swift`

**Interfaces:**
- Consumes: `TranscriptionAvailability.unavailable(String)`; `RecordingView.transcriptArea`'s existing `.unavailable(let reason)` placeholder (`Minute/Views/RecordingView.swift:259-260`).
- Produces: `static func TranscriptionService.liveStoppedMessage(_ error: any Error) -> String`.

**Partly unit-testable:** the message is pinned by the test below, but the wiring around it — the `resultsTask` catch actually assigning `availability` — cannot be reached from a unit test: `start(inputFormat:)` returns before creating `resultsTask` unless `availability == .available`, which requires a real `SpeechTranscriber` (never available on the simulator). The catch is two statements added to an existing catch that already runs, so it is verified by build plus the full suite; do not add a test that asserts nothing.

- [ ] **Step 1: Write the failing test**

Create `MinuteTests/TranscriptionLiveFailureTests.swift`:

```swift
import Foundation
import Testing
@testable import Minute

/// When the live results stream dies mid-recording the panel used to keep
/// showing the segments it already had (or "Listening…") for the rest of the
/// meeting, and the saved transcript simply stopped mid-sentence with nothing
/// anywhere to explain it.
@MainActor
struct TranscriptionLiveFailureTests {
    private struct StreamFailure: LocalizedError {
        var errorDescription: String? { "The analyzer stopped responding" }
    }

    @Test func liveFailureMessageNamesTheCauseAndPromisesTheRecordingContinues() {
        let message = TranscriptionService.liveStoppedMessage(StreamFailure())

        #expect(message == "Live transcription stopped: The analyzer stopped responding. Recording continues; you can re-transcribe the audio after saving.")
    }
}
```

- [ ] **Step 2: Run the suite to verify it fails**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MinuteTests/TranscriptionLiveFailureTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: compile error `type 'TranscriptionService' has no member 'liveStoppedMessage'`.

- [ ] **Step 3: Implement**

In `Minute/Services/TranscriptionService.swift`, replace the `resultsTask` catch block:

```swift
            } catch {
                // Losing live results is non-fatal; the recording continues.
                Self.logger.error("Transcriber results stream failed: \(error.localizedDescription)")
                self?.volatileText = ""
            }
```

with:

```swift
            } catch {
                // Losing live results is non-fatal for the recording — but
                // silence here left the panel showing stale segments (or
                // "Listening…") for the rest of the meeting and the saved
                // transcript simply stopped mid-sentence. Say it where the
                // user is looking. Everything finalized so far stays in
                // `segments` and is still saved.
                Self.logger.error("Transcriber results stream failed: \(error.localizedDescription)")
                self?.volatileText = ""
                self?.availability = .unavailable(Self.liveStoppedMessage(error))
            }
```

Then add this static helper immediately after the `finish()` method (after line 225, before `cancel()`):

```swift

    /// What the recording screen shows once the live results stream has died.
    /// The recording itself is unaffected, so the message has to say that as
    /// well as what stopped — otherwise a user watching the panel assumes the
    /// meeting is being lost and stops it.
    static func liveStoppedMessage(_ error: any Error) -> String {
        "Live transcription stopped: \(error.localizedDescription). Recording continues; you can re-transcribe the audio after saving."
    }
```

The period after the interpolation is part of the sentence, and the test above pins the exact string.

- [ ] **Step 4: Run the suite to verify it passes**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MinuteTests/TranscriptionLiveFailureTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: 1 test passes.

- [ ] **Step 5: Run the full unit suite**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 297 tests (292 baseline + 5).

- [ ] **Step 6: Commit**

```bash
git add Minute/Services/TranscriptionService.swift MinuteTests/TranscriptionLiveFailureTests.swift
git commit -m "fix: surface a live transcription that died mid-recording instead of showing Listening

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 15: The microphone-denied failure offers Open Settings (F72)

**Files:**
- Modify: `Minute/Recording/RecordingSession.swift` (`Phase` enum, lines 14-21; the four `.failed(…)` sites at lines 71, 95, 120, 211)
- Modify: `Minute/Views/RecordingView.swift` (imports, line 1-2; the `.failed` branch of `statusHeader`, lines 95-131)

**Interfaces:**
- Consumes: `UIApplication.openSettingsURLString` and `UIApplication.shared.open(_:)` (same call shape as `Minute/Views/SettingsView.swift:407-412`).
- Produces: `RecordingSession.Phase.failed(String, canOpenSettings: Bool)` — every existing `.failed` construction and match must carry the new label.

**Not unit-testable:** reaching `.failed(…, canOpenSettings: true)` requires a denied microphone permission from `AVAudioApplication.requestRecordPermission()`, and the button's only effect is `UIApplication.shared.open` — neither can be driven from a unit test. The exhaustive `switch` in `RecordingView` means the compiler checks the wiring; verified by build plus the full suite.

- [ ] **Step 1: Widen the failure phase**

In `Minute/Recording/RecordingSession.swift`, replace:

```swift
        case failed(String)
```

with:

```swift
        /// `canOpenSettings` is true only for the microphone-permission
        /// failure: it is the one failure the user fixes in iOS Settings, and
        /// the recording screen puts an Open Settings button on screen for it
        /// instead of leaving them to navigate there by hand.
        case failed(String, canOpenSettings: Bool)
```

- [ ] **Step 2: Update the four construction sites**

In the same file:

```swift
            phase = .failed("Microphone access is off. Enable it in Settings › Privacy & Security › Microphone.")
```
becomes
```swift
            phase = .failed(
                "Microphone access is off. Enable it in Settings › Privacy & Security › Microphone.",
                canOpenSettings: true
            )
```

```swift
            self.phase = .failed(message)
```
becomes
```swift
            self.phase = .failed(message, canOpenSettings: false)
```

```swift
            phase = .failed("Recording couldn't start: \(error.localizedDescription)")
```
becomes
```swift
            phase = .failed("Recording couldn't start: \(error.localizedDescription)", canOpenSettings: false)
```

```swift
            phase = .failed("The meeting couldn't be saved — storage may be full. Free up space and tap Save Recording to try again.")
```
becomes
```swift
            phase = .failed(
                "The meeting couldn't be saved — storage may be full. Free up space and tap Save Recording to try again.",
                canOpenSettings: false
            )
```

- [ ] **Step 3: Add the button**

In `Minute/Views/RecordingView.swift`, add `import UIKit` to the imports so the file reads:

```swift
import SwiftData
import SwiftUI
import UIKit
```

Then replace the `.failed` case of `statusHeader`:

```swift
        case .failed(let message):
```

with:

```swift
        case .failed(let message, let canOpenSettings):
```

and inside that branch, insert the Open Settings button as the first item of the `HStack(spacing: 12)`, immediately before `if session.didStartRecording {`:

```swift
                    if canOpenSettings {
                        // The only failure the user can fix without leaving
                        // the meeting behind — don't make them hunt through
                        // iOS Settings by hand on every attempt.
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
```

- [ ] **Step 4: Run the full unit suite**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 297 tests. A compile error naming `.failed` anywhere else means a site was missed — the only two files that construct or match it are the two above.

- [ ] **Step 5: Commit**

```bash
git add Minute/Recording/RecordingSession.swift Minute/Views/RecordingView.swift
git commit -m "fix: offer Open Settings when recording fails on microphone permission

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 16: Recorded time comes from frames written, not from Date() deltas (F73)

**Files:**
- Modify: `Minute/Services/AudioRecorder.swift` (add a counter type after `BufferHandlerBox`, line 65; stored properties, lines 112-113; `elapsed`, lines 120-123; `handleMediaServicesReset`, lines 232-238; `start`, lines 287-294; `installTap`, lines 334-341; `pause`, lines 350-362; `resume`, line 411; `stop`, lines 415-440)
- Create: `MinuteTests/AudioRecorderTimingTests.swift`

**Interfaces:**
- Consumes: `AVAudioFile.processingFormat.sampleRate`, `AVAudioPCMBuffer.frameLength`.
- Produces: `final class RecordedFrameCounter: Sendable` with `var value: AVAudioFramePosition`, `func add(_ frames: AVAudioFrameCount)`, `func reset()`; `static func AudioRecorder.seconds(frames: AVAudioFramePosition, sampleRate: Double) -> TimeInterval`. `AudioRecorder.elapsed` and `stop()` keep their signatures and now return frame-derived time; `stop()` on an idle recorder returns 0.

- [ ] **Step 1: Write the failing test**

Create `MinuteTests/AudioRecorderTimingTests.swift`:

```swift
import AVFoundation
import Foundation
import Testing
@testable import Minute

/// Recorded time is derived from the frames actually written to the file, not
/// from Date() deltas: Date() is not monotonic, so an NTP or carrier time
/// correction mid-meeting (common right after a flight, a call, or a reboot)
/// used to move the saved duration — and every transcript timestamp derived
/// from it — by the size of the correction.
@MainActor
struct AudioRecorderTimingTests {
    @Test func framesConvertToSecondsAtTheFilesSampleRate() {
        #expect(AudioRecorder.seconds(frames: 48_000, sampleRate: 48_000) == 1)
        #expect(AudioRecorder.seconds(frames: 24_000, sampleRate: 48_000) == 0.5)
        #expect(AudioRecorder.seconds(frames: 16_000, sampleRate: 16_000) == 1)
    }

    @Test func anUnknownSampleRateReadsAsNoRecordedTime() {
        // stop() converts with the rate stored when the file was opened; before
        // any file exists that rate is 0, and dividing by it would hand
        // SwiftData an infinite (or NaN) meeting duration.
        #expect(AudioRecorder.seconds(frames: 48_000, sampleRate: 0) == 0)
        #expect(AudioRecorder.seconds(frames: 0, sampleRate: 48_000) == 0)
    }

    @Test func aRecorderThatNeverStartedReportsNoRecordedTime() {
        let recorder = AudioRecorder()
        #expect(recorder.elapsed == 0)
        #expect(recorder.stop() == 0)
    }
}
```

- [ ] **Step 2: Run the suite to verify it fails**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MinuteTests/AudioRecorderTimingTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: compile error `type 'AudioRecorder' has no member 'seconds'`.

- [ ] **Step 3: Add the frame counter**

In `Minute/Services/AudioRecorder.swift`, insert after the closing brace of `BufferHandlerBox` (line 65) and before the `/// Records microphone audio…` comment:

```swift

/// Frames written to the recording file, counted on the realtime audio tap
/// thread and read on the main actor. A class (not a stored property) so the
/// tap closure and the recorder share one counter, and a lock so the
/// cross-thread read is defined rather than a data race.
final class RecordedFrameCounter: Sendable {
    private let storage = OSAllocatedUnfairLock<AVAudioFramePosition>(initialState: 0)

    var value: AVAudioFramePosition {
        storage.withLock { $0 }
    }

    func add(_ frames: AVAudioFrameCount) {
        storage.withLock { $0 += AVAudioFramePosition(frames) }
    }

    func reset() {
        storage.withLock { $0 = 0 }
    }
}
```

- [ ] **Step 4: Replace the wall-clock bookkeeping**

Replace the two stored properties:

```swift
    private var accumulatedTime: TimeInterval = 0
    private var segmentStartedAt: Date?
```

with:

```swift
    private let frameCounter = RecordedFrameCounter()
    /// Sample rate of the file's processing format, kept in its own property
    /// so `stop()` can still convert the frame count after the file is closed.
    private var fileSampleRate: Double = 0
```

Replace `elapsed`:

```swift
    /// Total recorded time, excluding paused stretches.
    var elapsed: TimeInterval {
        accumulatedTime + (segmentStartedAt.map { Date().timeIntervalSince($0) } ?? 0)
    }
```

with:

```swift
    /// Total recorded time, excluding paused stretches — derived from the
    /// frames actually written to the file rather than a `Date()` delta.
    /// `Date()` is not monotonic: a carrier or NTP correction mid-meeting used
    /// to stretch (or shrink) the saved duration, the transcript's timestamp
    /// offset, and the Live Activity's paused clock by the size of the
    /// correction, while playback still used the file's real length. Frames
    /// only advance while the tap is running, so pauses bank themselves.
    ///
    /// Not observable: `frameCounter` is a `let` and `fileSampleRate` only
    /// changes at start/stop, so reading this no longer invalidates a SwiftUI
    /// view on every tick the way the old `Date()` delta did. The one reader
    /// (`RecordingView`'s elapsed label) is inside a
    /// `TimelineView(.periodic(from: .now, by: 0.5))` and redraws on its own
    /// schedule; a plain `Text(recorder.elapsed…)` elsewhere would sit frozen.
    var elapsed: TimeInterval {
        Self.seconds(frames: frameCounter.value, sampleRate: fileSampleRate)
    }

    /// Seconds of audio a frame count represents. Zero when nothing has been
    /// written yet (no file, so no sample rate), so a duration can never come
    /// back infinite or NaN.
    static func seconds(frames: AVAudioFramePosition, sampleRate: Double) -> TimeInterval {
        guard frames > 0, sampleRate > 0 else { return 0 }
        return Double(frames) / sampleRate
    }
```

In `handleMediaServicesReset`, delete the banking (the frame count already stopped when the tap did) — replace:

```swift
        guard state == .recording || state == .paused else { return }
        if let startedAt = segmentStartedAt {
            accumulatedTime += Date().timeIntervalSince(startedAt)
        }
        segmentStartedAt = nil
        pausedByInterruption = false
```

with:

```swift
        guard state == .recording || state == .paused else { return }
        pausedByInterruption = false
```

In `start(writingTo:quality:)`, replace:

```swift
        file = try AVAudioFile(forWriting: url, settings: settings)

        didReportWriteError = false
        try installTap()
        engine.prepare()
        try engine.start()
        segmentStartedAt = Date()
        state = .recording
```

with:

```swift
        let file = try AVAudioFile(forWriting: url, settings: settings)
        self.file = file
        // The tap counts frames in the file's processing format; keep its rate
        // so stop() can convert them after the file is closed.
        fileSampleRate = file.processingFormat.sampleRate
        frameCounter.reset()

        didReportWriteError = false
        try installTap()
        engine.prepare()
        try engine.start()
        state = .recording
```

In `installTap`, count only what actually reached the file — replace:

```swift
            do {
                try file.write(from: normalized)
            } catch {
```

with:

```swift
            do {
                try file.write(from: normalized)
                frameCounter.add(normalized.frameLength)
            } catch {
```

and capture the counter alongside the handler box by replacing:

```swift
        let handlerBox = tapHandler
```

with:

```swift
        let handlerBox = tapHandler
        let frameCounter = self.frameCounter
```

In `pause()`, delete the banking — replace:

```swift
        engine.pause()
        if let startedAt = segmentStartedAt {
            accumulatedTime += Date().timeIntervalSince(startedAt)
        }
        segmentStartedAt = nil
        level = 0
```

with:

```swift
        engine.pause()
        level = 0
```

In `resume()`, delete the segment restart — replace:

```swift
        segmentStartedAt = Date()
        state = .recording
    }
```

with:

```swift
        state = .recording
    }
```

- [ ] **Step 5: Rewrite `stop()`**

Replace:

```swift
    func stop() -> TimeInterval {
        guard state != .idle else { return accumulatedTime }
        if let startedAt = segmentStartedAt {
            accumulatedTime += Date().timeIntervalSince(startedAt)
        }
        segmentStartedAt = nil
        pausedByInterruption = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        tapHandler.handler = nil
        file = nil // Closes and flushes the file.
        level = 0
        state = .idle

        let duration = accumulatedTime
        accumulatedTime = 0
```

with:

```swift
    func stop() -> TimeInterval {
        guard state != .idle else { return 0 }
        pausedByInterruption = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        tapHandler.handler = nil
        file = nil // Closes and flushes the file.
        level = 0
        state = .idle

        // Read before resetting: this is the number the meeting is saved with.
        let duration = elapsed
        frameCounter.reset()
        fileSampleRate = 0
```

(the rest of `stop()` — the `setActive(false)` block and `return duration` — is unchanged.)

- [ ] **Step 6: Run the suite to verify it passes**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MinuteTests/AudioRecorderTimingTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: 3 tests pass.

- [ ] **Step 7: Run the full unit suite**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 300 tests (292 baseline + 8). No "unused variable" warnings — `accumulatedTime` and `segmentStartedAt` must be gone from the file (`grep -n "accumulatedTime\|segmentStartedAt" Minute/Services/AudioRecorder.swift` returns nothing).

- [ ] **Step 8: Commit**

```bash
git add Minute/Services/AudioRecorder.swift MinuteTests/AudioRecorderTimingTests.swift
git commit -m "fix: derive recorded duration from frames written instead of wall-clock deltas

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 17: A dead recording's Live Activity goes stale within minutes (F46)

**Files:**
- Modify: `Minute/Recording/RecordingLiveActivityController.swift` (`start`, lines 16-28; `update`, lines 30-38; add the stale-date helper)
- Modify: `Minute/Recording/RecordingSession.swift` (add the refresh task property near line 47; `syncLiveActivity`, lines 233-251; add start/stop helpers)
- Modify: `MinuteWidgets/RecordingLiveActivity.swift` (`DynamicIsland` regions, lines 13-39; `LockScreenView`, lines 47-81; `TimerText`, lines 83-99; `StatusBadge`, lines 101-114)
- Create: `MinuteTests/RecordingLiveActivityStaleDateTests.swift`

**Interfaces:**
- Consumes: `ActivityContent(state:staleDate:)`, `Activity.update(_:)`, `ActivityViewContext.isStale`.
- Produces: `static let RecordingLiveActivityController.staleAfter: TimeInterval`; `static func RecordingLiveActivityController.staleDate(from: Date = .now) -> Date`; `static let RecordingSession.liveActivityRefreshInterval: TimeInterval`.

- [ ] **Step 1: Write the failing test**

Create `MinuteTests/RecordingLiveActivityStaleDateTests.swift`:

```swift
import Foundation
import Testing
@testable import Minute

/// Every ActivityContent used to carry `staleDate: nil`, so a process that
/// died mid-recording left the lock screen claiming live capture — timer
/// ticking — until the next launch. A short stale date the live session keeps
/// pushing forward makes a dead session visible within minutes.
@MainActor
struct RecordingLiveActivityStaleDateTests {
    @Test func staleDateIsThreeMinutesAfterTheContentIsSent() {
        let now = Date(timeIntervalSince1970: 1_000_000)

        #expect(RecordingLiveActivityController.staleDate(from: now) == now.addingTimeInterval(180))
    }

    @Test func theStaleWindowIsSeveralRefreshesWide() {
        // The session pushes the date forward on a timer. If the window were
        // not comfortably wider than that interval, one late refresh would
        // brand a healthy recording as dead.
        #expect(RecordingLiveActivityController.staleAfter > RecordingSession.liveActivityRefreshInterval * 2)
    }
}
```

- [ ] **Step 2: Run the suite to verify it fails**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MinuteTests/RecordingLiveActivityStaleDateTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: compile errors `type 'RecordingLiveActivityController' has no member 'staleDate'` and `no member 'staleAfter'`.

- [ ] **Step 3: Stamp every content with a stale date**

In `Minute/Recording/RecordingLiveActivityController.swift`, insert after the `chain` property (line 14):

```swift

    /// How long a lock-screen card is trusted after the app last touched it.
    /// The session refreshes well inside this window while it is alive, so the
    /// date only lapses when the process is gone — the one case where the card
    /// would otherwise keep counting up over a recording that ended.
    static let staleAfter: TimeInterval = 180

    static func staleDate(from now: Date = .now) -> Date {
        now.addingTimeInterval(staleAfter)
    }
```

In `start(title:)`, replace:

```swift
                content: ActivityContent(state: state, staleDate: nil)
```

with:

```swift
                content: ActivityContent(state: state, staleDate: Self.staleDate())
```

In `update(isPaused:elapsed:)`, replace:

```swift
        enqueue { await activity.update(ActivityContent(state: state, staleDate: nil)) }
```

with:

```swift
        let staleDate = Self.staleDate()
        enqueue { await activity.update(ActivityContent(state: state, staleDate: staleDate)) }
```

- [ ] **Step 4: Refresh the activity while the session is alive**

In `Minute/Recording/RecordingSession.swift`, add after the `transcriptionTask` property (line 47):

```swift
    /// Pushes the Live Activity's stale date forward while this session is
    /// alive. Cancelled the moment recording ends, so a process that dies
    /// mid-recording simply stops refreshing and the card goes stale.
    private var activityRefreshTask: Task<Void, Never>?
```

Add these two helpers immediately after the `liveActivityTitle` property Task 11 added (which sits directly below `syncLiveActivity(from:)`, around line 260) and before `nonisolated static func defaultTitle(for:)`:

```swift

    /// How often the Live Activity's stale date is pushed forward.
    static let liveActivityRefreshInterval: TimeInterval = 60

    private func startActivityRefresh() {
        guard activityRefreshTask == nil else { return }
        activityRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.liveActivityRefreshInterval))
                guard !Task.isCancelled, let self else { return }
                guard self.phase == .recording || self.phase == .paused else { return }
                self.liveActivity.update(isPaused: self.phase == .paused, elapsed: self.recorder.elapsed)
            }
        }
    }

    private func stopActivityRefresh() {
        activityRefreshTask?.cancel()
        activityRefreshTask = nil
    }
```

In `syncLiveActivity(from:)`, replace the switch body:

```swift
        switch phase {
        case .recording:
            if oldPhase == .preparing {
                liveActivity.start(title: liveActivityTitle)
            } else {
                liveActivity.update(isPaused: false, elapsed: recorder.elapsed)
            }
        case .paused:
            liveActivity.update(isPaused: true, elapsed: recorder.elapsed)
        case .idle, .saving, .failed:
            // The recorder has stopped (or never started) in all three —
            // ending is a no-op when no activity was requested.
            liveActivity.end()
        case .preparing:
            break
        }
```

with:

```swift
        switch phase {
        case .recording:
            if oldPhase == .preparing {
                liveActivity.start(title: liveActivityTitle)
            } else {
                liveActivity.update(isPaused: false, elapsed: recorder.elapsed)
            }
            startActivityRefresh()
        case .paused:
            liveActivity.update(isPaused: true, elapsed: recorder.elapsed)
            startActivityRefresh()
        case .idle, .saving, .failed:
            // The recorder has stopped (or never started) in all three —
            // ending is a no-op when no activity was requested.
            stopActivityRefresh()
            liveActivity.end()
        case .preparing:
            break
        }
```

- [ ] **Step 5: Render the stale state in the widget**

In `MinuteWidgets/RecordingLiveActivity.swift`, replace `TimerText` and `StatusBadge`:

```swift
private struct TimerText: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        if state.isPaused {
```

with:

```swift
private struct TimerText: View {
    let state: RecordingActivityAttributes.ContentState
    /// A stale card's app is gone: freeze the clock at the last value it sent
    /// rather than keep counting up over a recording that is not happening.
    var isStale = false

    var body: some View {
        if state.isPaused || isStale {
```

and:

```swift
private struct StatusBadge: View {
    let isPaused: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isPaused ? Color.orange : Color.red)
                .frame(width: 7, height: 7)
            Text(isPaused ? "Paused" : "Recording")
                .fontWeight(.semibold)
                .foregroundStyle(isPaused ? Color.orange : Color.red)
        }
    }
}
```

with:

```swift
private struct StatusBadge: View {
    let isPaused: Bool
    var isStale = false

    private var tint: Color {
        if isStale { return .secondary }
        return isPaused ? .orange : .red
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
            // The app stopped refreshing this card: it can no longer claim a
            // recording is running, and saying so is the only cue the user
            // gets to reopen Minute.
            Text(isStale ? "Minute isn't running" : (isPaused ? "Paused" : "Recording"))
                .fontWeight(.semibold)
                .foregroundStyle(tint)
        }
    }
}
```

Then pass `context.isStale` at all five call sites — the expanded leading `StatusBadge`, the expanded trailing `TimerText`, the `compactTrailing` `TimerText`, and both of `LockScreenView`'s. `StatusIcon` (`compactLeading` and `minimal`, lines 30-39) is deliberately left alone: it renders a single glyph with no room for a state that needs words, and the expanded and lock-screen presentations are where the user actually reads the card's claim.

In `body`:

```swift
                DynamicIslandExpandedRegion(.leading) {
                    StatusBadge(isPaused: context.state.isPaused, isStale: context.isStale)
                        .font(.callout)
                        .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TimerText(state: context.state, isStale: context.isStale)
                        .font(.title3.weight(.medium))
                        .padding(.trailing, 6)
                }
```

and:

```swift
            } compactTrailing: {
                TimerText(state: context.state, isStale: context.isStale)
                    .font(.caption2)
                    .foregroundStyle(context.state.isPaused ? Color.orange : Color.red)
                    .frame(maxWidth: 52)
```

and in `LockScreenView`:

```swift
                StatusBadge(isPaused: context.state.isPaused, isStale: context.isStale)
                    .font(.caption)
            }
            Spacer(minLength: 8)
            TimerText(state: context.state, isStale: context.isStale)
                .font(.system(size: 30, weight: .medium, design: .rounded))
```

- [ ] **Step 6: Run the suite to verify it passes**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MinuteTests/RecordingLiveActivityStaleDateTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: 2 tests pass. (The widget extension is built as part of the app, so a mistake in `RecordingLiveActivity.swift` fails this command with a compile error.)

- [ ] **Step 7: Run the full unit suite**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 302 tests (292 baseline + 10).

- [ ] **Step 8: Commit**

```bash
git add Minute/Recording/RecordingLiveActivityController.swift Minute/Recording/RecordingSession.swift MinuteWidgets/RecordingLiveActivity.swift MinuteTests/RecordingLiveActivityStaleDateTests.swift
git commit -m "fix: let a dead recording's Live Activity go stale instead of claiming live capture

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 18: Audio captured before the engine attaches is replayed to it (F70)

**Files:**
- Modify: `Minute/Services/AudioRecorder.swift` (`BufferHandlerBox`, lines 22-65; `setBufferHandler`, lines 266-270; `start(writingTo:quality:)`, lines 273-295 — the block Task 16 rewrote; the three `tapHandler.handler = nil` sites at lines 241, 305, and inside `stop()`; the tap closure in `installTap`, line 342)
- Modify: `Minute/Recording/RecordingSession.swift` (the `guard isTranscriptionEnabled` line 124; the `timestampOffset` assignment, line 135)
- Modify: `Minute/Support/AudioBufferConverter.swift` (the type's doc comment, lines 4-8)
- Test: `MinuteTests/BufferHandlerBoxTests.swift` (rewrite the existing test's API use, add four tests)

**Interfaces:**
- Consumes: `AVAudioPCMBuffer.floatChannelData`, `AVAudioFormat.isInterleaved`, `AVAudioFormat.sampleRate`; `AudioRecorder.elapsed` (Task 16); `TranscriptionEngine.timestampOffset`.
- Produces on `BufferHandlerBox`: `static let backlogLimit: TimeInterval`; `func offer(_ buffer: AVAudioPCMBuffer)`; `func install(_ handler: Handler?)`; `var backlogSeconds: TimeInterval` (read-only, lock-guarded); `func reset()`. The `var handler` property is removed — every caller uses `offer`/`install`.
- Produces on `AudioRecorder`: `var pendingBacklogSeconds: TimeInterval` — the lead-in the next `setBufferHandler(_:)` will replay, which `RecordingSession` subtracts from `elapsed` to place the analyzer's clock origin.

- [ ] **Step 1: Write the failing tests**

Replace the whole of `MinuteTests/BufferHandlerBoxTests.swift` with:

```swift
import AVFoundation
import os
import Testing
@testable import Minute

struct BufferHandlerBoxTests {
    /// One buffer of `seconds` of audio, marked in its first sample so the
    /// test can identify it after the box has copied it.
    private func buffer(marker: Float, seconds: Double = 0.1, sampleRate: Double = 8_000) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        buffer.floatChannelData![0][0] = marker
        return buffer
    }

    @Test func clearingHandlerAfterManyBufferDeliveriesDoesNotOverflowTheStack() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
        buffer.frameLength = 1
        let box = BufferHandlerBox()
        let deliveryCount = OSAllocatedUnfairLock(initialState: 0)
        box.install { _ in
            deliveryCount.withLock { $0 += 1 }
        }

        // A long recording reads this handler thousands of times. The old
        // lock-backed closure value accumulated a reabstraction wrapper on
        // every read, then recursively released the entire chain on stop.
        for _ in 0..<20_000 {
            box.offer(buffer)
        }

        #expect(deliveryCount.withLock { $0 } == 20_000)
        box.install(nil)
        box.offer(buffer)
        #expect(deliveryCount.withLock { $0 } == 20_000)
    }

    /// Buffers captured before the transcription engine attaches — a second or
    /// two of prepare() + start(), minutes on a first run — used to be dropped
    /// on the floor, so every transcript began mid-sentence.
    @Test func buffersOfferedBeforeAHandlerAttachesAreReplayedInOrderFirst() {
        let box = BufferHandlerBox()
        box.offer(buffer(marker: 1))
        box.offer(buffer(marker: 2))
        box.offer(buffer(marker: 3))

        let received = OSAllocatedUnfairLock(initialState: [Float]())
        box.install { buffer in
            received.withLock { $0.append(buffer.floatChannelData![0][0]) }
        }
        box.offer(buffer(marker: 4))

        #expect(received.withLock { $0 } == [1, 2, 3, 4])
    }

    @Test func theBacklogHoldsAtMostThirtySecondsOfAudioAndReportsHowMuch() {
        let box = BufferHandlerBox()
        // 35 one-second buffers: the oldest five fall off the front.
        for marker in 1...35 {
            box.offer(buffer(marker: Float(marker), seconds: 1))
        }

        // The session reads this to place the analyzer's clock origin at the
        // START of the lead-in it is about to be handed. It has to be read
        // before installing, because installing drains the queue.
        #expect(BufferHandlerBox.backlogLimit == 30)
        #expect(box.backlogSeconds == 30)

        let received = OSAllocatedUnfairLock(initialState: [Float]())
        box.install { buffer in
            received.withLock { $0.append(buffer.floatChannelData![0][0]) }
        }

        #expect(received.withLock { $0 } == (6...35).map(Float.init))
        #expect(box.backlogSeconds == 0)
    }

    @Test func clearingTheHandlerDropsTheBacklogInsteadOfReplayingItLater() {
        let box = BufferHandlerBox()
        box.offer(buffer(marker: 1))
        box.install(nil) // What stop() does.

        let received = OSAllocatedUnfairLock(initialState: [Float]())
        box.install { buffer in
            received.withLock { $0.append(buffer.floatChannelData![0][0]) }
        }
        box.offer(buffer(marker: 2))

        #expect(received.withLock { $0 } == [2])
    }

    /// `install` latches collecting off for the rest of a recording, so a box
    /// reused across a stop/start cycle would silently drop the next
    /// recording's lead-in. `AudioRecorder.start(writingTo:quality:)` re-arms
    /// it; keep that contract inside the box rather than in the one caller.
    @Test func resettingReArmsTheBoxForTheNextRecording() {
        let box = BufferHandlerBox()
        box.offer(buffer(marker: 1))
        box.install(nil) // Previous recording: no engine attached.

        box.reset() // What start() does for the next recording.
        box.offer(buffer(marker: 2))
        let received = OSAllocatedUnfairLock(initialState: [Float]())
        box.install { buffer in
            received.withLock { $0.append(buffer.floatChannelData![0][0]) }
        }

        // The new recording's lead-in is held and replayed; the old
        // recording's buffer is gone.
        #expect(received.withLock { $0 } == [2])
    }
}
```

- [ ] **Step 2: Run the suite to verify it fails**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MinuteTests/BufferHandlerBoxTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: compile errors `value of type 'BufferHandlerBox' has no member 'install'` / `no member 'offer'` / `no member 'backlogLimit'` / `no member 'backlogSeconds'` / `no member 'reset'`.

- [ ] **Step 3: Give the box a bounded backlog**

In `Minute/Services/AudioRecorder.swift`, replace the entire `BufferHandlerBox` type (from the `/// Box the audio tap reads…` comment through its closing brace) with:

```swift
/// Box the audio tap reads on every buffer, so live transcription can attach
/// after recording has already started (e.g. while the speech model downloads).
/// A lock guards the state: the main actor writes it while the realtime tap
/// thread reads it, and an unsynchronized ARC handoff would be a data race.
///
/// Buffers offered before a handler attaches are kept — bounded — and replayed
/// into the handler the moment it arrives. Without that, everything said in
/// the seconds (on a first run, minutes) between `recorder.start()` and the
/// engine attaching was written to the file but never transcribed, so every
/// transcript silently began mid-sentence.
final class BufferHandlerBox: Sendable {
    typealias Handler = @Sendable (AVAudioPCMBuffer) -> Void

    /// Longest stretch of audio held for a handler that hasn't attached yet.
    /// This is a lead-in for the transcriber, not a recording buffer — the
    /// file already has every one of these samples.
    static let backlogLimit: TimeInterval = 30

    /// Keep the closure behind a stable reference. Returning a closure stored
    /// directly as `OSAllocatedUnfairLock` state adds a reabstraction wrapper
    /// on every read; a long recording then overflows the stack when stop()
    /// clears and recursively releases that wrapper chain.
    private final class HandlerEntry: Sendable {
        let value: Handler

        init(_ value: @escaping Handler) {
            self.value = value
        }
    }

    /// A copy of one captured buffer. `@unchecked Sendable` because
    /// AVAudioPCMBuffer isn't Sendable: these are private copies the tap's
    /// buffer never aliases, handed on only under the lock below.
    private final class PendingBuffer: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        let seconds: TimeInterval

        init(_ buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
            seconds = buffer.format.sampleRate > 0
                ? Double(buffer.frameLength) / buffer.format.sampleRate
                : 0
        }
    }

    private struct State {
        var entry: HandlerEntry?
        /// Captured audio waiting for a handler, oldest first.
        var backlog: [PendingBuffer] = []
        var backlogSeconds: TimeInterval = 0
        /// Cleared by the first `install` call, whatever it installs: after
        /// the session has decided (engine attached, or engine unavailable),
        /// a buffer with no handler is dropped instead of held for one that
        /// is never coming.
        var isCollecting = true
        /// True while the backlog is being replayed. Live buffers queue behind
        /// it so nothing overtakes the lead-in mid-replay.
        var isDraining = false
    }

    private let storage = OSAllocatedUnfairLock<State>(initialState: State())

    /// Seconds of captured audio waiting for a handler. The session reads this
    /// BEFORE installing, to move the transcription engine's clock origin back
    /// to the start of the lead-in it is about to be handed: the engine stamps
    /// its first buffer as time zero plus the offset it was given, so an offset
    /// of "now" would place every replayed segment a whole lead-in too late.
    var backlogSeconds: TimeInterval {
        storage.withLock { $0.backlogSeconds }
    }

    /// Called by the audio tap for every buffer: straight to the handler when
    /// one is attached, into the backlog while none is.
    func offer(_ buffer: AVAudioPCMBuffer) {
        let handler = storage.withLock { state -> Handler? in
            if let entry = state.entry, !state.isDraining {
                return entry.value
            }
            guard state.isCollecting || state.isDraining,
                  let pending = Self.copy(buffer)
            else { return nil }
            Self.enqueue(pending, in: &state)
            return nil
        }
        handler?(buffer)
    }

    /// Attaches (or clears) the handler. A handler arriving late gets the
    /// backlog replayed into it first, in order, before any live buffer.
    func install(_ handler: Handler?) {
        let replacement = handler.map(HandlerEntry.init)
        // Hand the old handler back out and let it die at the end of this
        // scope, i.e. after unlocking. Besides shortening the critical
        // section, this avoids running arbitrary capture cleanup while the
        // non-recursive lock is held.
        let previous = storage.withLock { state -> HandlerEntry? in
            let old = state.entry
            state.entry = replacement
            state.isCollecting = false
            if replacement == nil {
                state.backlog = []
                state.backlogSeconds = 0
                state.isDraining = false
            } else {
                state.isDraining = !state.backlog.isEmpty
            }
            return old
        }
        _ = previous
        if let value = replacement?.value {
            drain(into: value)
        }
    }

    /// Re-arms the box for a new recording: no handler, no backlog, collecting
    /// again. `install` latches collecting off for the rest of a recording, so
    /// without this a recorder reused across a stop/start cycle would silently
    /// drop the next recording's lead-in. Called from
    /// `AudioRecorder.start(writingTo:quality:)` so the contract lives here
    /// rather than in the caller.
    func reset() {
        // Hand the whole old state back out so the handler and every buffered
        // copy are released after unlocking, not inside the critical section.
        let previous = storage.withLock { state -> State in
            let old = state
            state = State()
            return old
        }
        _ = previous
    }

    /// Replays the backlog one buffer at a time. Popping and the "queue is
    /// empty" verdict happen under the same lock as `offer`'s append, so a
    /// buffer arriving mid-replay is either picked up by this loop or
    /// delivered live afterwards — never both, never out of order.
    private func drain(into handler: Handler) {
        while true {
            let next = storage.withLock { state -> PendingBuffer? in
                guard !state.backlog.isEmpty else {
                    state.isDraining = false
                    state.backlogSeconds = 0
                    return nil
                }
                let first = state.backlog.removeFirst()
                state.backlogSeconds -= first.seconds
                return first
            }
            guard let next else { return }
            handler(next.buffer)
        }
    }

    private static func enqueue(_ pending: PendingBuffer, in state: inout State) {
        state.backlog.append(pending)
        state.backlogSeconds += pending.seconds
        while state.backlogSeconds > backlogLimit, let oldest = state.backlog.first {
            state.backlog.removeFirst()
            state.backlogSeconds -= oldest.seconds
        }
    }

    /// The tap's buffer is the engine's to reuse once the callback returns, so
    /// anything held past it has to be a copy.
    private static func copy(_ buffer: AVAudioPCMBuffer) -> PendingBuffer? {
        guard buffer.frameLength > 0,
              !buffer.format.isInterleaved,
              let source = buffer.floatChannelData,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
              let destination = copy.floatChannelData
        else { return nil }
        copy.frameLength = buffer.frameLength
        let frames = Int(buffer.frameLength)
        for channel in 0..<Int(buffer.format.channelCount) {
            destination[channel].update(from: source[channel], count: frames)
        }
        return PendingBuffer(copy)
    }
}
```

- [ ] **Step 4: Move the recorder onto the new API**

In the same file, replace `tapHandler.handler = nil` at all three sites (`handleMediaServicesReset`, `cleanupAfterFailedStart`, `stop`) with:

```swift
        tapHandler.install(nil)
```

Replace `setBufferHandler` — its doc comment included, so the stale "Safe to set or clear" wording doesn't survive above the new one:

```swift
    /// Streams every buffer (already in `recordingFormat`) to `handler` on the
    /// audio tap thread. Safe to set or clear mid-recording.
    func setBufferHandler(_ handler: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        tapHandler.handler = handler
    }
```

with (the new property first, so the pair reads together):

```swift
    /// Seconds of already-captured audio the next `setBufferHandler(_:)` will
    /// replay into its handler. Read it BEFORE installing: installing drains
    /// the queue, so a read afterwards always reports zero. `RecordingSession`
    /// subtracts it from `elapsed` to place the transcription engine's clock
    /// origin at the start of that lead-in.
    var pendingBacklogSeconds: TimeInterval {
        tapHandler.backlogSeconds
    }

    /// Streams every buffer (already in `recordingFormat`) to `handler` on the
    /// audio tap thread, replaying the lead-in captured before this call.
    /// Passing nil says no handler is coming and drops that lead-in. Safe to
    /// call mid-recording.
    func setBufferHandler(_ handler: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        tapHandler.install(handler)
    }
```

In `start(writingTo:quality:)`, re-arm the box for this recording — replace the two lines Task 16 added:

```swift
        fileSampleRate = file.processingFormat.sampleRate
        frameCounter.reset()
```

with:

```swift
        fileSampleRate = file.processingFormat.sampleRate
        frameCounter.reset()
        // The first `install` of a recording latches the box out of
        // collecting; re-arm it so a recorder reused after stop() holds this
        // recording's lead-in exactly like a fresh one would.
        tapHandler.reset()
```

In the tap closure inside `installTap`, replace:

```swift
            handlerBox.handler?(normalized)
```

with:

```swift
            handlerBox.offer(normalized)
```

- [ ] **Step 5: Move the engine's clock origin back to the start of the lead-in, and hold no lead-in when no engine is coming**

In `Minute/Recording/RecordingSession.swift`, replace:

```swift
        guard isTranscriptionEnabled else { return }
```

with:

```swift
        guard isTranscriptionEnabled else {
            // No engine will attach, so nothing should hold a lead-in for one.
            recorder.setBufferHandler(nil)
            return
        }
```

Then, in the same method's transcription task, replace:

```swift
            // The analyzer's clock starts at the first buffer it receives, but
            // the file already contains everything recorded while the model
            // prepared — offset segment timestamps so taps seek correctly.
            self.transcription.timestampOffset = self.recorder.elapsed
            self.recorder.setBufferHandler(handler)
```

with:

```swift
            // The analyzer's clock starts at the first buffer it receives, and
            // that first buffer is now the OLDEST one the recorder held back
            // while the model prepared — not the one arriving live. So the
            // offset is the file time where the replay begins, `elapsed`
            // minus that lead-in, and not `elapsed` itself: offsetting by
            // `elapsed` would stamp every replayed segment a full lead-in too
            // late (a second or two here, up to the 30 s cap after a first-run
            // model download) and could push the last segment past the saved
            // meeting's duration, which is exactly the wrong-seek defect the
            // frame-derived clock fixes elsewhere. Read the lead-in BEFORE
            // installing: `setBufferHandler` drains the queue, so a read
            // afterwards is always zero. `max(0,)` because a buffer whose disk
            // write failed is still replayed but was never counted in
            // `elapsed`.
            let leadIn = self.recorder.pendingBacklogSeconds
            self.transcription.timestampOffset = max(0, self.recorder.elapsed - leadIn)
            self.recorder.setBufferHandler(handler)
```

- [ ] **Step 6: Correct the converter's threading note**

`AudioBufferConverter` is no longer touched only from the tap thread: the transcription engine's converter (captured by the handler returned from `start(inputFormat:)`) is driven from the main actor first, while `install` replays the lead-in, and from the tap thread afterwards. Access stays serial — the box's lock orders the handoff and holds live buffers behind the replay — but the comment claiming a single thread is now wrong.

In `Minute/Support/AudioBufferConverter.swift`, replace:

```swift
/// Converts PCM buffers between formats (used for the recording file after a
/// route change, and for the speech analyzer's preferred format).
/// Only ever used serially on the audio tap thread.
/// ponytail: @unchecked Sendable because AVAudioConverter isn't Sendable; safe
/// while the single tap thread is the only caller.
```

with:

```swift
/// Converts PCM buffers between formats (used for the recording file after a
/// route change, and for the speech analyzer's preferred format).
/// Only ever used serially, though not always from the same thread: the
/// transcription converter runs on the main actor while `BufferHandlerBox`
/// replays the lead-in captured before the engine attached, and on the audio
/// tap thread afterwards. The box's lock orders that handoff and keeps live
/// buffers queued behind the replay, so `convert` never has two callers at
/// once.
/// ponytail: @unchecked Sendable because AVAudioConverter isn't Sendable; safe
/// only while callers stay serialized as above.
```

- [ ] **Step 7: Run the suite to verify it passes**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MinuteTests/BufferHandlerBoxTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: 5 tests pass.

- [ ] **Step 8: Run the full unit suite**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 306 tests (292 baseline + 14).

- [ ] **Step 9: Commit**

```bash
git add Minute/Services/AudioRecorder.swift Minute/Recording/RecordingSession.swift Minute/Support/AudioBufferConverter.swift MinuteTests/BufferHandlerBoxTests.swift
git commit -m "fix: replay the audio captured before the transcription engine attached

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 19: A route change restarts capture in place instead of pausing it (F04)

**Files:**
- Modify: `Minute/Services/AudioRecorder.swift` (the `pauseOnNotification` closure and the configuration-change observer, lines 132-136 and 167-174; add `onRouteChanged` next to `onWriteError`, lines 98-106)
- Modify: `Minute/Recording/RecordingSession.swift` (add the callback wiring in `start()` after the `onWriteError` block, lines 98-104; add a transient-notice helper)

**Interfaces:**
- Consumes: `AudioRecorder.installTap()` (private, existing), `AVAudioEngine.start()`, `systemPause(causedByInterruption:)` (private, existing), `RecordingSession.notice`.
- Produces: `var AudioRecorder.onRouteChanged: ((String) -> Void)?`; `private func RecordingSession.showTransientNotice(_ message: String)`.

**Not unit-testable:** `.AVAudioEngineConfigurationChange` is posted by CoreAudio when real input hardware changes, and the recovery path is `installTap()` + `engine.start()` against that new hardware — neither can be produced in a unit test. Verified by build plus the full suite, and by hand on a device (connect/disconnect AirPods mid-recording: recording continues and the notice appears for a few seconds).

- [ ] **Step 1: Add the notice callback**

In `Minute/Services/AudioRecorder.swift`, insert after the `onWriteError` property and its `didReportWriteError` companion (line 107):

```swift

    /// Called when the input route changed and capture was restarted against
    /// the new hardware, so the owner can say so briefly. Recording never
    /// stopped — this is information, not a failure.
    var onRouteChanged: ((String) -> Void)?
```

- [ ] **Step 2: Restart in place on a configuration change**

Replace the closure declared at the top of `init()`:

```swift
        let pauseOnNotification: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.systemPause(causedByInterruption: false)
            }
        }
```

with:

```swift
        let restartOnNotification: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleConfigurationChange()
            }
        }
```

and the observer registration:

```swift
        // Route/config change (e.g. AirPods connect): the engine stops itself
        // and the tap's format may no longer match the hardware.
        observerTokens.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main,
            using: pauseOnNotification
        ))
```

with:

```swift
        // Route/config change (e.g. AirPods connect): the engine stops itself
        // and the tap's format may no longer match the hardware.
        observerTokens.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main,
            using: restartOnNotification
        ))
```

Then add this method immediately before `systemPause`'s doc comment — the `/// Pauses because the system took the microphone away, not because the` block that begins at line 189, not between that comment and the `private func systemPause(causedByInterruption:)` declaration it documents:

```swift
    /// The input route or its format changed (AirPods connecting or
    /// auto-switching away, a wired headset being plugged in). Re-arm the tap
    /// against the new hardware and keep recording: pausing here left the rest
    /// of a meeting uncaptured whenever a headset switched away with the phone
    /// locked, since the only signal was the Live Activity flipping to Paused.
    ///
    /// No interruption ownership is involved, so `pausedByInterruption` is
    /// untouched and the `.ended`-pairing logic is unaffected. Only a failed
    /// restart falls back to the old pause-with-notice, which still leaves
    /// everything captured so far saveable.
    private func handleConfigurationChange() {
        guard state == .recording else { return }
        do {
            engine.inputNode.removeTap(onBus: 0)
            try installTap()
            try engine.start()
            onRouteChanged?("Microphone changed — still recording")
        } catch {
            Self.logger.error("Restarting after an audio route change failed: \(error.localizedDescription)")
            systemPause(causedByInterruption: false)
        }
    }

```

- [ ] **Step 3: Show the notice for a few seconds**

In `Minute/Recording/RecordingSession.swift`, add after the `activityRefreshTask` property:

```swift
    /// Clears a notice that explains something already resolved (a route
    /// change the recorder recovered from), so it doesn't sit on screen
    /// implying the recording still needs attention.
    private var noticeClearTask: Task<Void, Never>?
```

Add the callback wiring in `start()`, immediately after the `recorder.onWriteError = { … }` block:

```swift

        recorder.onRouteChanged = { [weak self] message in
            guard let self, self.phase == .recording else { return }
            self.showTransientNotice(message)
        }
```

And add this helper immediately after `resume()`:

```swift

    /// A notice about something the recorder already handled: shown briefly,
    /// then cleared. The pause notices stay up because they name an action the
    /// user still has to take; this one doesn't.
    private func showTransientNotice(_ message: String) {
        notice = message
        noticeClearTask?.cancel()
        noticeClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, self.notice == message else { return }
            self.notice = nil
        }
    }
```

- [ ] **Step 4: Run the full unit suite**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 306 tests, no new warnings (in particular no "unused" warning for the renamed closure).

- [ ] **Step 5: Commit**

```bash
git add Minute/Services/AudioRecorder.swift Minute/Recording/RecordingSession.swift
git commit -m "fix: restart capture in place after an input route change instead of pausing

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 20: The recording session's transcription engine is injectable (F69, F02)

**Files:**
- Modify: `Minute/Recording/RecordingSession.swift` (the `transcription` property, lines 26-28; `init`, lines 61-64)
- Create: `MinuteTests/RecordingSessionSaveTests.swift`

**Interfaces:**
- Consumes: `TranscriptionEngines.current() -> any TranscriptionEngine`; the `TranscriptionEngine` protocol (`availability`, `volatileText`, `segments`, `timestampOffset`, `prepare()`, `start(inputFormat:)`, `finish()`, `cancel()`, `transcribe(file:)`).
- Produces: `RecordingSession.init(title: String, prefilledDefaultTitle: String = RecordingSession.defaultTitle(), transcription: (any TranscriptionEngine)? = nil)`; the test-only `ParkedTranscriptionEngine` that Tasks 21 and 22 build on.
- Existing call sites in `Minute/Views/MeetingListView.swift:183,206` keep compiling unchanged — the new parameter is last and defaulted.

- [ ] **Step 1: Write the failing test**

Create `MinuteTests/RecordingSessionSaveTests.swift`:

```swift
import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import Minute

/// A live engine whose `finish()` parks until the test releases it. The real
/// engines' finish() waits on a final decode pass that can run for minutes
/// (Whisper's tail is capped at five), which is the window every test in this
/// file is about.
@MainActor
private final class ParkedTranscriptionEngine: TranscriptionEngine {
    var availability: TranscriptionAvailability = .available
    var volatileText = ""
    /// What the engine has heard so far — what "Save without transcript" keeps.
    var segments: [TranscriptSegment] = []
    var timestampOffset: TimeInterval = 0
    /// What a finish() that runs to completion returns.
    var finalSegments: [TranscriptSegment] = []
    private(set) var didCancel = false
    /// Fires as finish() is entered, so a test can inspect the store at the
    /// exact moment the real engine would begin its final pass.
    var onFinishEntered: (() -> Void)?

    private let releases: AsyncStream<Void>
    private let releaseContinuation: AsyncStream<Void>.Continuation

    init() {
        (releases, releaseContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    func prepare() async {}

    func start(inputFormat: AVAudioFormat) async -> (@Sendable (AVAudioPCMBuffer) -> Void)? { nil }

    func finish() async -> [TranscriptSegment] {
        onFinishEntered?()
        var iterator = releases.makeAsyncIterator()
        _ = await iterator.next()
        return didCancel ? [] : finalSegments
    }

    func cancel() async {
        didCancel = true
        // The real engines clear their own collection here — which is why the
        // session has to bank the segments before cancelling.
        segments = []
        release()
    }

    func transcribe(file: AVAudioFile) async throws -> [TranscriptSegment] { [] }

    /// Lets a parked finish() return, the way the final pass completing does.
    func release() {
        releaseContinuation.yield(())
    }
}

@MainActor
struct RecordingSessionSaveTests {
    /// Containers are retained for the process lifetime: ModelContainer
    /// teardown is not actor-isolated, and a container deiniting in the
    /// background while another test runs crashes the test host inside
    /// SwiftData.framework. Pattern copied from
    /// MinuteTests/KnowledgeCatchUpTests.swift.
    private static var retainedContainers: [ModelContainer] = []

    @discardableResult
    private static func retain(_ container: ModelContainer) -> ModelContainer {
        retainedContainers.append(container)
        return container
    }

    private func makeContext() throws -> ModelContext {
        try Self.retain(ModelContainer(
            for: Meeting.self, KnowledgeEntity.self, KnowledgeFact.self,
            configurations: MeetingStore.modelConfiguration(inMemory: true)
        )).mainContext
    }

    @Test func theSessionUsesTheEngineItWasGiven() {
        let engine = ParkedTranscriptionEngine()
        let session = RecordingSession(
            title: "Injected",
            prefilledDefaultTitle: "Injected",
            transcription: engine
        )

        #expect(session.transcription === engine)
    }
}
```

- [ ] **Step 2: Run the suite to verify it fails**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MinuteTests/RecordingSessionSaveTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: compile error `extra argument 'transcription' in call`.

- [ ] **Step 3: Implement**

In `Minute/Recording/RecordingSession.swift`, replace:

```swift
    /// The engine selected in Settings (Apple Speech or Whisper), captured at
    /// session creation like the settings below.
    let transcription: any TranscriptionEngine = TranscriptionEngines.current()
```

with:

```swift
    /// The engine selected in Settings (Apple Speech or Whisper), captured at
    /// session creation like the settings below — or the one injected by a
    /// test.
    let transcription: any TranscriptionEngine
```

and replace `init`:

```swift
    init(title: String, prefilledDefaultTitle: String = RecordingSession.defaultTitle()) {
        self.title = title
        self.prefilledDefaultTitle = prefilledDefaultTitle
    }
```

with:

```swift
    /// `transcription` is injectable for tests; it defaults to nil rather than
    /// to `TranscriptionEngines.current()` because a default argument is
    /// evaluated outside this type's main-actor isolation.
    init(
        title: String,
        prefilledDefaultTitle: String = RecordingSession.defaultTitle(),
        transcription: (any TranscriptionEngine)? = nil
    ) {
        self.title = title
        self.prefilledDefaultTitle = prefilledDefaultTitle
        self.transcription = transcription ?? TranscriptionEngines.current()
    }
```

- [ ] **Step 4: Run the suite to verify it passes**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MinuteTests/RecordingSessionSaveTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: 1 test passes.

- [ ] **Step 5: Run the full unit suite**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 307 tests (292 baseline + 15).

- [ ] **Step 6: Commit**

```bash
git add Minute/Recording/RecordingSession.swift MinuteTests/RecordingSessionSaveTests.swift
git commit -m "test: make the recording session's transcription engine injectable

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 21: The meeting is persisted before the transcript is finalized (F69, F02)

**Files:**
- Modify: `Minute/Recording/RecordingSession.swift` (the `finishedRecording` property, lines 49-53; `finish(in:)`, lines 161-214; `discard()`, lines 216-229)
- Modify: `Minute/Views/RecordingView.swift` (the two `await session.discard()` call sites, lines 61 and 123)
- Test: `MinuteTests/RecordingSessionSaveTests.swift` (add two tests)

**Interfaces:**
- Consumes: `MeetingStore.delete(_:context:) -> Bool`; `Meeting.init(title:defaultTitle:createdAt:duration:audioFileName:segments:)`; `PersistentModel.isGone`; `RecordingSession.savedTitles(draft:prefilledDefault:)`; `AudioRecorder.stop() -> TimeInterval` (Task 16); `Phase.failed(_:canOpenSettings:)` (Task 15); `ParkedTranscriptionEngine` (Task 20).
- Produces: `RecordingSession.finish(in:)` keeps its signature and now writes the row before awaiting the transcript; `func discard(in context: ModelContext) async` replaces `discard()`; private state `recordedDuration: TimeInterval?`, `savedMeeting: Meeting?`, `pendingSegments: [TranscriptSegment]?` replaces `finishedRecording`.

- [ ] **Step 1: Write the failing tests**

Add to `MinuteTests/RecordingSessionSaveTests.swift`, inside the struct after `theSessionUsesTheEngineItWasGiven`:

```swift

    /// The audio file is complete and playable the moment recorder.stop()
    /// returns, but nothing references it until a Meeting row exists — and the
    /// launch sweep deletes unreferenced recordings. Finalizing a Whisper tail
    /// can outlast the ~30 s background assertion, so the row has to be written
    /// first: a suspension then costs the transcript, not the meeting.
    @Test func theMeetingIsSavedBeforeTheTranscriptIsFinalized() async throws {
        let context = try makeContext()
        let engine = ParkedTranscriptionEngine()
        engine.finalSegments = [TranscriptSegment(text: "landed after the save", start: 0, end: 1)]
        let session = RecordingSession(
            title: "  Board review  ",
            prefilledDefaultTitle: "Meeting Sep 2, 2026 at 9:30 AM",
            transcription: engine
        )

        let (entered, enteredContinuation) = AsyncStream.makeStream(of: Void.self)
        engine.onFinishEntered = { enteredContinuation.yield(()) }
        let finishTask = Task { @MainActor in await session.finish(in: context)?.id }
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()

        // Mid-finalization: the meeting is already on disk, transcript pending.
        let parked = try context.fetch(FetchDescriptor<Meeting>())
        #expect(parked.count == 1)
        #expect(parked.first?.title == "Board review")
        #expect(parked.first?.segments.isEmpty == true)

        engine.release()
        let finishedID = await finishTask.value
        #expect(finishedID != nil)

        // Same row, now carrying the transcript — never a second meeting for
        // the same audio.
        let saved = try context.fetch(FetchDescriptor<Meeting>())
        #expect(saved.count == 1)
        #expect(saved.first?.id == finishedID)
        #expect(saved.first?.segments.map(\.text) == ["landed after the save"])
        #expect(session.phase == .idle)
    }

    /// Persisting first means a discard arriving mid-finalization has a row to
    /// clean up: the audio it points at is already gone, and a meeting must
    /// never survive pointing at deleted audio.
    @Test func discardingWhileTheTranscriptFinalizesRemovesTheRowItAlreadyWrote() async throws {
        let context = try makeContext()
        let engine = ParkedTranscriptionEngine()
        engine.finalSegments = [TranscriptSegment(text: "never wanted", start: 0, end: 1)]
        let session = RecordingSession(
            title: "Throwaway",
            prefilledDefaultTitle: "Throwaway",
            transcription: engine
        )

        let (entered, enteredContinuation) = AsyncStream.makeStream(of: Void.self)
        engine.onFinishEntered = { enteredContinuation.yield(()) }
        let finishTask = Task { @MainActor in await session.finish(in: context)?.id }
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()
        #expect(try context.fetch(FetchDescriptor<Meeting>()).count == 1)

        await session.discard(in: context)
        let finishedID = await finishTask.value

        #expect(finishedID == nil)
        #expect(try context.fetch(FetchDescriptor<Meeting>()).isEmpty)
        #expect(session.phase == .idle)
    }
```

- [ ] **Step 2: Run the suite to verify it fails**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MinuteTests/RecordingSessionSaveTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: a compile error, not a test failure — `discardingWhileTheTranscriptFinalizesRemovesTheRowItAlreadyWrote` calls `session.discard(in: context)` while `discard()` still takes no context, so the file does not build (`extra argument 'in' in call`) and no test in this suite runs. `theMeetingIsSavedBeforeTheTranscriptIsFinalized`'s real failure (`parked.count == 1`, actual 0, because today's `finish` inserts only after `transcription.finish()` returns) only becomes observable once Step 5 has given `discard` its context parameter; both tests then pass together at Step 7.

- [ ] **Step 3: Replace the banked-recording state**

In `Minute/Recording/RecordingSession.swift`, replace:

```swift
    /// Captured once when recording stops; kept until a save succeeds so a
    /// failed context.save() can be retried without touching the recorder.
    /// Value data (not a Meeting instance) so every save attempt inserts a
    /// fresh model object and a failed attempt can be discarded cleanly.
    private var finishedRecording: (duration: TimeInterval, segments: [TranscriptSegment])?
```

with:

```swift
    /// Recorded duration banked when capture stopped, so a retried save still
    /// has it after the recorder went idle.
    private var recordedDuration: TimeInterval?
    /// The row written as soon as capture stopped, before the transcript was
    /// finalized. Kept so a retry (the transcript save failed) updates that
    /// meeting instead of inserting a second one for the same audio.
    private var savedMeeting: Meeting?
    /// The finalized transcript, banked so a retried save doesn't wait on the
    /// engine a second time — and so `saveWithoutTranscript()` can decide what
    /// gets written.
    private var pendingSegments: [TranscriptSegment]?
```

- [ ] **Step 4: Rewrite `finish(in:)`**

Replace the whole method (its doc comment through its closing brace) with:

```swift
    /// Stops everything, saves the meeting, and returns it.
    ///
    /// The row is written BEFORE the transcript is finalized. The audio file is
    /// complete and playable the moment `recorder.stop()` returns, but nothing
    /// references it until a Meeting exists and the launch sweep deletes every
    /// unreferenced recording — while finalizing (a Whisper final pass over up
    /// to five minutes of tail) can easily outlive the ~30 s background
    /// assertion that is all we have once stop() deactivates the audio session.
    /// Persisting first means a suspension or jettison there costs the
    /// transcript, which Re-transcribe can rebuild, instead of the meeting.
    ///
    /// Returns nil when a save failed — the session enters `.failed` with the
    /// audio (and, past the first save, the meeting) intact, and calling finish
    /// again retries only the step that failed.
    func finish(in context: ModelContext) async -> Meeting? {
        // One finish at a time, never after a discard, and never again after
        // a successful save — a stale second call would otherwise build a
        // second meeting sharing the same audio file.
        guard phase != .saving, !didDiscard, !didSave else { return nil }
        phase = .saving
        // recorder.stop() below deactivates the audio session, which is the
        // only thing keeping a backgrounded app alive. Swiping Home while the
        // transcript finalizes would otherwise let iOS suspend us mid-save.
        let token = BackgroundTaskToken(name: "Save recording")
        defer { token.end() }

        if recordedDuration == nil {
            transcriptionTask?.cancel()
            recordedDuration = recorder.stop()
        }
        guard let duration = recordedDuration else { return nil }

        if savedMeeting == nil {
            let saved = Self.savedTitles(draft: title, prefilledDefault: prefilledDefaultTitle)
            let meeting = Meeting(
                title: saved.title,
                defaultTitle: saved.defaultTitle,
                createdAt: startedAt,
                duration: duration,
                audioFileName: audioFileName,
                segments: []
            )
            context.insert(meeting)
            do {
                try context.save()
                savedMeeting = meeting
            } catch {
                Self.logger.error("Saving meeting failed: \(error.localizedDescription)")
                // Cancel only THIS pending insert — a context-wide rollback()
                // would also destroy unrelated unsaved edits in the shared main
                // context. Declaring the meeting saved instead would let the next
                // orphan sweep delete its audio.
                context.delete(meeting)
                phase = .failed(
                    "The meeting couldn't be saved — storage may be full. Free up space and tap Save Recording to try again.",
                    canOpenSettings: false
                )
                return nil
            }
        }
        guard let meeting = savedMeeting else { return nil }

        if pendingSegments == nil {
            let finalized = await transcription.finish()
            if didDiscard {
                // Discarded while the transcript finalized: the row written
                // above points at audio `discard(in:)` has already deleted, so
                // it goes with it. Never resurrect a recording the user threw
                // away, and never leave a meeting pointing at nothing.
                // `discard(in:)` runs on this actor between our awaits and may
                // already have removed the row, so ask before removing it
                // again — a committed delete leaves isDeleted false.
                if !meeting.isGone {
                    MeetingStore.delete(meeting, context: context)
                }
                savedMeeting = nil
                return nil
            }
            // `saveWithoutTranscript()` may have banked the segments while we
            // waited — it cancels the engine, which clears the engine's copy.
            if pendingSegments == nil {
                pendingSegments = finalized
            }
        }
        guard let segments = pendingSegments else { return nil }

        meeting.segments = segments
        do {
            try context.save()
            didSave = true
            phase = .idle
            return meeting
        } catch {
            Self.logger.error("Saving the transcript failed: \(error.localizedDescription)")
            // The recording itself is safe — the meeting and its audio were
            // committed above. Only the transcript is unwritten, so keep the
            // meeting and let Save Recording retry just this step.
            phase = .failed(
                "The transcript couldn't be saved — storage may be full. The recording is saved; free up space and tap Save Recording to try again.",
                canOpenSettings: false
            )
            return nil
        }
    }
```

- [ ] **Step 5: Give `discard` the context it now needs**

Replace `discard()`:

```swift
    /// Stops everything and deletes the partial audio file (user discarded).
    func discard() async {
        didDiscard = true
        transcriptionTask?.cancel()
        recorder.stop()
        await transcription.cancel()
        if let audioFileName {
            MeetingStore.deleteAudioFile(named: audioFileName)
        }
        audioFileName = nil
        finishedRecording = nil
        didStartRecording = false
        phase = .idle
    }
```

with:

```swift
    /// Stops everything and deletes the partial audio file (user discarded).
    /// Takes the context because `finish(in:)` persists the meeting before the
    /// transcript is finalized: a discard arriving after that (or after a
    /// failed transcript save) has a row to remove, and leaving it would keep
    /// a meeting whose audio this method just deleted.
    func discard(in context: ModelContext) async {
        didDiscard = true
        transcriptionTask?.cancel()
        recorder.stop()
        await transcription.cancel()
        if let savedMeeting, !savedMeeting.isGone {
            MeetingStore.delete(savedMeeting, context: context)
        }
        savedMeeting = nil
        if let audioFileName {
            MeetingStore.deleteAudioFile(named: audioFileName)
        }
        audioFileName = nil
        recordedDuration = nil
        pendingSegments = nil
        didStartRecording = false
        phase = .idle
    }
```

- [ ] **Step 6: Update the two call sites**

In `Minute/Views/RecordingView.swift`, in the confirmation dialog:

```swift
                Button("Discard Recording", role: .destructive) {
                    Task {
                        await session.discard()
                        onFinish(nil)
                    }
                }
```
becomes
```swift
                Button("Discard Recording", role: .destructive) {
                    Task {
                        await session.discard(in: context)
                        onFinish(nil)
                    }
                }
```

and in the `.failed` branch's Close button:

```swift
                            Task {
                                await session.discard()
                                onFinish(nil)
                            }
```
becomes
```swift
                            Task {
                                await session.discard(in: context)
                                onFinish(nil)
                            }
```

- [ ] **Step 7: Run the suite to verify it passes**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MinuteTests/RecordingSessionSaveTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: 3 tests pass.

Note on coverage: the two `context.save()` failure branches (first save fails → `.failed` with the audio kept; second save fails → `.failed` with the meeting kept and only the transcript retried) cannot be provoked from a unit test — SwiftData's in-memory store has no way to be made to throw on demand — so they are verified by reading the code and by the fact that both leave `didSave` false so the next `finish(in:)` re-enters at exactly the step that failed. Do not add a test that asserts nothing.

- [ ] **Step 8: Run the full unit suite**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 309 tests (292 baseline + 17).

- [ ] **Step 9: Commit**

```bash
git add Minute/Recording/RecordingSession.swift Minute/Views/RecordingView.swift MinuteTests/RecordingSessionSaveTests.swift
git commit -m "fix: persist the meeting before finalizing its transcript so a suspension can't lose the recording

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 22: "Save without transcript" ends an unbounded finalization (F02)

**Files:**
- Modify: `Minute/Recording/RecordingSession.swift` (add the method after `finish(in:)`)
- Modify: `Minute/Views/RecordingView.swift` (the `.saving` case of `statusHeader`, lines 92-94)
- Test: `MinuteTests/RecordingSessionSaveTests.swift` (add one test)

**Interfaces:**
- Consumes: `TranscriptionEngine.segments`, `TranscriptionEngine.cancel()`; `RecordingSession.pendingSegments` (Task 21).
- Produces: `func RecordingSession.saveWithoutTranscript() async`.

- [ ] **Step 1: Write the failing test**

Add to `MinuteTests/RecordingSessionSaveTests.swift`, inside the struct after `discardingWhileTheTranscriptFinalizesRemovesTheRowItAlreadyWrote`:

```swift

    /// `.saving` is otherwise unbounded — a Whisper final pass over a long tail
    /// runs for minutes on an older device, with Discard disabled and both
    /// controls greyed out. The way out keeps what the engine already heard.
    @Test func saveWithoutTranscriptStopsWaitingAndKeepsWhatWasHeard() async throws {
        let context = try makeContext()
        let engine = ParkedTranscriptionEngine()
        engine.segments = [TranscriptSegment(text: "heard before the user gave up", start: 0, end: 1)]
        engine.finalSegments = [TranscriptSegment(text: "never finalized", start: 0, end: 1)]
        let session = RecordingSession(
            title: "Long tail",
            prefilledDefaultTitle: "Long tail",
            transcription: engine
        )

        let (entered, enteredContinuation) = AsyncStream.makeStream(of: Void.self)
        engine.onFinishEntered = { enteredContinuation.yield(()) }
        let finishTask = Task { @MainActor in await session.finish(in: context)?.id }
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()

        await session.saveWithoutTranscript()
        let finishedID = await finishTask.value

        #expect(finishedID != nil)
        #expect(engine.didCancel)
        let saved = try context.fetch(FetchDescriptor<Meeting>())
        #expect(saved.count == 1)
        #expect(saved.first?.segments.map(\.text) == ["heard before the user gave up"])
        #expect(session.phase == .idle)
    }
```

- [ ] **Step 2: Run the suite to verify it fails**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MinuteTests/RecordingSessionSaveTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: compile error `value of type 'RecordingSession' has no member 'saveWithoutTranscript'`.

- [ ] **Step 3: Implement the escape hatch**

In `Minute/Recording/RecordingSession.swift`, add immediately after `finish(in:)`:

```swift

    /// Stops waiting for the transcript and finishes the save with whatever the
    /// engine has already produced. Nothing bounds a finalization — Whisper's
    /// final pass covers up to five minutes of retained tail, and Apple Speech
    /// waits on its results stream — while `.saving` disables Discard and both
    /// controls, so without this the user has no way out of a recording that is
    /// already safely on disk.
    func saveWithoutTranscript() async {
        guard phase == .saving, pendingSegments == nil else { return }
        // Bank first: cancelling clears the engine's own collection, and the
        // whole point of this action is to keep what it heard.
        pendingSegments = transcription.segments
        await transcription.cancel()
    }
```

- [ ] **Step 4: Put the button on screen**

In `Minute/Views/RecordingView.swift`, replace the `.saving` case of `statusHeader`:

```swift
        case .saving:
            ProgressView("Finishing transcript…")
                .padding(.vertical, 20)
```

with:

```swift
        case .saving:
            VStack(spacing: 12) {
                ProgressView("Finishing transcript…")
                // The final pass is unbounded and everything else on this
                // screen is disabled while it runs. Never leave the user
                // without a way to finish a recording that is already saved.
                Button("Save without transcript") {
                    Task { await session.saveWithoutTranscript() }
                }
                .buttonStyle(.bordered)
                .font(.footnote)
            }
            .padding(.vertical, 20)
```

- [ ] **Step 5: Run the suite to verify it passes**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MinuteTests/RecordingSessionSaveTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: 4 tests pass.

- [ ] **Step 6: Run the full unit suite**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 310 tests (292 baseline + 18).

- [ ] **Step 7: Commit**

```bash
git add Minute/Recording/RecordingSession.swift Minute/Views/RecordingView.swift MinuteTests/RecordingSessionSaveTests.swift
git commit -m "fix: offer Save without transcript so a long finalization is never a dead end

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Hand-offs to Track E

None. Every change lands inside this track's own files: the two `RecordingSession(...)` call sites in `Minute/Views/MeetingListView.swift` (lines 183 and 206) keep compiling unchanged because the new `transcription:` parameter is last and nil-defaulted, and the only callers of `RecordingSession.discard` are the two in `Minute/Views/RecordingView.swift`, which this track owns and updates in Task 21.

## Not done in this track

- **F49's Whisper half — the live decode loop that retries a failing pass forever.** `WhisperTranscriptionService.swift:360-363` logs each failed pass, sleeps 500 ms and retries without ever touching `availability`, so a device where every pass fails shows "Listening…" for the whole meeting exactly as Apple Speech did. The decision scopes F49 to `TranscriptionService`, and `Minute/Services/WhisperTranscriptionService.swift` is not one of this track's files, so the N-consecutive-failures counter the finding suggests belongs to whichever track owns it.
- **F49's second half — a note on the saved meeting explaining a truncated transcript.** `Meeting` has no note field (`transcriptionNote` exists only as a value on `AudioImporter.Result`), so adding one means editing `Minute/Models/Meeting.swift`, which this track does not own; the decision scopes F49 to the availability message the recording screen already renders.
- **F02's suggestion to cancel the finalization from the `BackgroundTaskToken` expiration handler.** The token type lives in `Minute/Services/ICloudDriveBackup.swift`, which this track does not own, and Task 21's persist-first ordering already removes the loss the expiration handler was meant to prevent: after the first save, a suspension costs only the transcript.
- **F70's alternative fix — re-transcribing `[0, timestampOffset)` from the file in `finish()`.** The decision chose the replay backlog; doing both would transcribe the lead-in twice and duplicate those segments.
- **F73 note (not a gap):** the Live Activity's *running* clock stays wall-clock by construction — the widget renders `Text(startedAt, style: .timer)`, which the system ticks itself. Only the paused value, `Meeting.duration`, and the transcript's `timestampOffset` become frame-derived.
- **F10's other halves** — the transcript-row Stop button in `MeetingDetailView` and `DiarizationService`'s `Task.checkCancellation()` — belong to whichever track owns those files; this track does only the `TranscriptionService.transcribe(file:)` part named in the assignment.

---

## Track F1 — Views, app entry, and the meeting store

Sixteen review findings that all land in the four screens, the app entry point, and `MeetingStore`: a summary editor that silently restructures action items on Save, a title field that can write an empty title, deep links that land behind sheets, a widget snapshot rewritten per keystroke, two stale Settings rows, two missing busy-state guards, a data-protection class that reaches nothing it claims to, a fallback store with no exit, and two documentation/dead-code cleanups.

Tasks are ordered so the suite stays green after every one: the contained view fixes first, then the ones that add a testable helper (`Meeting.committedTitle`, `MeetingDeepLinkState.action`, `MeetingStore.applyDataProtection`, `MeetingStore.resetPersistentStore`), then the three tasks that build the fallback-store exit on top of each other.

### Global Constraints

- Privacy invariants from CONTRIBUTING.md hold: no meeting content on the wire; every byte written has a delete path (`MeetingStore.delete` or the launch sweeps); AI output stays grounded (`"Not specified"` literal); recording never depends on optional capabilities and any handled failure still offers to save captured audio.
- No new third-party dependencies. Do not edit `Minute.xcodeproj/project.pbxproj` (new files under `Minute/`, `MinuteTests/`, `Shared/`, `MinuteWidgets/` are picked up automatically).
- Unit tests use Swift Testing (`import Testing`, `@Test`, `#expect`, `#require`), never XCTest. SwiftData-touching test structs are `@MainActor` with an in-memory container via `MeetingStore.modelConfiguration(inMemory: true)`; containers holding `KnowledgeEntity`/`KnowledgeFact` are retained for the process lifetime (`retainedContainers` pattern in `MinuteTests/KnowledgeCatchUpTests.swift`).
- The project builds in Swift 5 language mode: an actor-isolated expression cannot be a default argument (use the nil-defaulted injection pattern: `engine: (any Engine)? = nil` then `let engine = engine ?? Engines.current()`).
- Baseline at the branch point (commit `8c443be` on main): **292 tests in 43 suites pass**. Every task leaves that green plus its own new tests.
- SwiftLint is strict in CI (`.swiftlint.yml` disables line_length, function/type/file length, cyclomatic_complexity, identifier_name, todo, redundant_optional_initialization, trailing_comma, for_where): match the codebase style — 4-space indent, doc comments that explain WHY, no `for … where` wrapping side effects. `swiftlint` is not installed locally.
- Commit messages: Conventional Commits (`fix:`/`test:`/`docs:`), ending with the trailer line `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Commit with explicit paths; never `git add -A`; never commit anything under `.superpowers/`.
- A task edits only files its track owns (listed below). If a fix genuinely needs a file another track owns, the task ends at the owned side (e.g. adds a hook/property) and the plan section's "Hand-offs to Track E" list names the one-line wiring the post-merge track must do.
- SwiftData fact established in batch 1: after a committed delete an object has `isDeleted == false` and `modelContext == nil`; guard stale reads with the `PersistentModel` `isGone` extension (`Minute/Models/PersistentModel+IsGone.swift`), never `isDeleted`.

**Files this track owns** (edit nothing else): `Minute/Views/MeetingListView.swift`, `Minute/Views/MeetingDetailView.swift`, `Minute/Views/SettingsView.swift`, `Minute/Views/SummaryEditorView.swift`, `Minute/App/MinuteApp.swift`, `Minute/Services/MeetingStore.swift`, `Minute/Services/WidgetSnapshotPublisher.swift`, `Minute/Support/MeetingDeepLinkState.swift`, `Minute/Support/AppSettings.swift`, `Minute/Models/Meeting.swift`, `Minute/Models/PersistentModel+IsGone.swift`, `MinuteTests/MeetingStoreTests.swift`, `MinuteTests/SummaryEditorParsingTests.swift`, `MinuteTests/MeetingDeepLinkStateTests.swift`, `MinuteTests/WidgetSnapshotPublisherTests.swift`, `MinuteTests/MeetingDetailIdentityTests.swift`, plus new test files for these types.

**Test commands** (run from the worktree root; this track uses the "iPhone 17 Pro Max" simulator).

One suite while iterating — this is what "the suite command with `<SuiteName>`" means everywhere below:

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:MinuteTests/<SuiteName> CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```

Full unit suite, once before each commit — this is what "the full unit suite command" means below:

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```

Line numbers below were read from the files at commit `8c443be`. Re-derive them from the file in front of you before editing — earlier tasks in this track shift later ones.

---

### Task 23: Drop the dead per-meeting id from delete and say what reconcile does (DEAD-SCAFFOLDING)

**Files:**
- Modify: `Minute/Services/MeetingStore.swift:207-238` (the `delete(_:context:)` body: `let meetingID = meeting.id` at line 210, the comment at 229-234, `_ = meetingID` at line 235)

**Interfaces:**
- Consumes: `KnowledgeStore.reconcile(context:) -> Bool` (`Minute/Services/KnowledgeStore.swift:29`, `@discardableResult`, takes no meeting on purpose).
- Produces: nothing new.

Pure dead-code removal and a comment rewrite; `MeetingStoreTests.deleteRemovesMeetingAndAudioFile` and `MeetingDetailIdentityTests.aCommittedDeleteCountsAsGone` already cover `delete`. No new test — there is no behavior to assert. Verified by build plus the full unit suite.

- [ ] **Step 1: Remove the leftover binding and rewrite the comment**

In `Minute/Services/MeetingStore.swift`, in `delete(_:context:)`, delete this line (line 210, directly under `let audioFileName = meeting.audioFileName`):

```swift
        let meetingID = meeting.id
```

Then replace this block (lines 229-236, the comment plus `_ = meetingID` plus the call):

```swift
        // A fact's sources are a codable list rather than a SwiftData
        // relationship, so nothing cascades to them — drop this meeting's
        // support explicitly, or a deleted meeting keeps speaking through the
        // facts it produced. Deliberately after the meeting delete commits: a
        // failure here must not resurrect the meeting, and the launch pass in
        // MeetingListView catches whatever a failed save leaves behind.
        _ = meetingID
        KnowledgeStore.reconcile(context: context)
```

with:

```swift
        // A fact's sources are a codable list rather than a SwiftData
        // relationship, so nothing cascades to them — a deleted meeting would
        // keep speaking through the facts it produced. `reconcile` takes no
        // meeting on purpose: with sources a uniform list, dropping one
        // deleted meeting's support and reconciling the whole library are the
        // same pass, so this both retires the facts only this meeting
        // supported and clears anything an earlier failed pass left behind.
        // Deliberately after the meeting delete commits: a failure here must
        // not resurrect the meeting, and the launch pass in MeetingListView
        // catches whatever a failed save leaves behind.
        KnowledgeStore.reconcile(context: context)
```

- [ ] **Step 2: Run the full unit suite to verify nothing regressed**

Run:

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```

Expected: `TEST SUCCEEDED`, 292 tests, no new warnings (the unused-variable warning `meetingID` produced is gone).

- [ ] **Step 3: Commit**

```bash
git add Minute/Services/MeetingStore.swift
git commit -m "refactor: drop the dead per-meeting id from MeetingStore.delete and describe what reconcile does

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 24: Document the Auto-Summarize path that never nudges the Brain (NUDGE-DOC)

**Files:**
- Modify: `Minute/Views/MeetingListView.swift:429-448` (the doc comment on `nudgeBrain(for:)`)

**Interfaces:**
- Consumes: `KnowledgeCatchUp.nudge(context:)`, `MeetingJobs.onContentChanged` (both already referenced by the existing comment).
- Produces: nothing new.

Documentation only. Verified by build plus the full unit suite.

- [ ] **Step 1: Add the fallback sentence**

In `Minute/Views/MeetingListView.swift`, replace the last paragraph of the `nudgeBrain(for:)` doc comment — the block that currently reads:

```swift
    /// Two cases skip the nudge. A meeting with no transcript (a silent save,
    /// an import whose transcription failed) has nothing to read, and the loop
    /// skip-lists it for the rest of the process — spending its one chance, so
    /// the transcript a later Re-transcribe Audio produces would never be
    /// extracted. Nothing is lost by waiting there: that job nudges the loop
    /// itself when it lands. And with Auto-Summarize on, the summary starting
    /// on the next screen already nudges when it finishes
    /// (`MeetingJobs.onContentChanged`), as does the Brain tab's own `.task`;
    /// nudging now would only make extraction and that summary contend for the
    /// single on-device model.
```

with:

```swift
    /// Two cases skip the nudge. A meeting with no transcript (a silent save,
    /// an import whose transcription failed) has nothing to read, and the loop
    /// skip-lists it for the rest of the process — spending its one chance, so
    /// the transcript a later Re-transcribe Audio produces would never be
    /// extracted. Nothing is lost by waiting there: that job nudges the loop
    /// itself when it lands. And with Auto-Summarize on, the summary starting
    /// on the next screen already nudges when it finishes
    /// (`MeetingJobs.onContentChanged`), as does the Brain tab's own `.task`;
    /// nudging now would only make extraction and that summary contend for the
    /// single on-device model.
    ///
    /// That second case leans on a fallback: when the selected summary engine
    /// is unavailable, or the summary throws, no completion nudge ever
    /// arrives, and the meeting waits for the Brain tab's own `.task` or the
    /// next scene activation to be read — later than a nudge here, but never
    /// lost.
```

- [ ] **Step 2: Run the full unit suite to verify nothing regressed**

Run:

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```

Expected: `TEST SUCCEEDED`, 292 tests.

- [ ] **Step 3: Commit**

```bash
git add Minute/Views/MeetingListView.swift
git commit -m "docs: note when an auto-summarized meeting waits for the Brain tab instead of a nudge

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 25: Auto-Summarize is settable without Live Transcription (F67)

**Files:**
- Modify: `Minute/Views/SettingsView.swift:152-156` (the Auto-Summarize toggle and its `.disabled`), `Minute/Views/SettingsView.swift:178-180` (the Recording section footer)

**Interfaces:**
- Consumes: `AppSettings.autoSummarizeKey` (`Minute/Support/AppSettings.swift:13`), read by `MeetingListView.startImport` and the post-recording destination.
- Produces: nothing new.

A `.disabled` modifier and one string; there is nothing to unit-test in a SwiftUI control's enabled state. Verified by build plus the full unit suite.

- [ ] **Step 1: Un-gate the toggle**

In `Minute/Views/SettingsView.swift`, replace:

```swift
            Toggle(isOn: $autoSummarize) {
                settingsLabel("Auto-Summarize", systemImage: "sparkles", tint: .purple)
            }
            // Without a transcript there is nothing to summarize.
            .disabled(!liveTranscription)
```

with:

```swift
            // Deliberately not gated on Live Transcription: this setting also
            // governs imported audio (MeetingListView.startImport reads it,
            // and AudioImporter transcribes regardless of the live setting)
            // and meetings the user re-transcribes. Gating it left a user who
            // records without live transcription unable to turn it on for
            // imports at all — and left it stuck ON, greyed out and looking
            // inert, while imports kept auto-summarizing.
            Toggle(isOn: $autoSummarize) {
                settingsLabel("Auto-Summarize", systemImage: "sparkles", tint: .purple)
            }
```

- [ ] **Step 2: Reword the footer**

In the same section, replace the footer `Text(...)` (line 179):

```swift
            Text("\(selectedQuality.label): \(selectedQuality.detail). Settings apply to new recordings. Auto-Summarize generates the summary on device right after a meeting is saved — it needs Live Transcription to produce the transcript it summarizes. The template controls how notes are organized (e.g. Yesterday/Today/Blockers for standups).")
```

with:

```swift
            Text("\(selectedQuality.label): \(selectedQuality.detail). Settings apply to new recordings. Auto-Summarize generates the summary on device as soon as a meeting has a transcript — after a recording made with Live Transcription on, after importing audio, and after re-transcribing a meeting. The template controls how notes are organized (e.g. Yesterday/Today/Blockers for standups).")
```

- [ ] **Step 3: Run the full unit suite to verify nothing regressed**

Run:

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```

Expected: `TEST SUCCEEDED`, 292 tests. (`liveTranscription` is still read by the Live Transcription toggle itself, so no unused-variable warning appears.)

- [ ] **Step 4: Commit**

```bash
git add Minute/Views/SettingsView.swift
git commit -m "fix: let Auto-Summarize be set without Live Transcription, since it also governs imports

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 26: Settings re-reads the iCloud Drive verdict when the scene comes back (F41)

**Files:**
- Modify: `Minute/Views/SettingsView.swift:10-13` (environment properties), `Minute/Views/SettingsView.swift:66-72` (the `.task` modifiers on the `List`)

**Interfaces:**
- Consumes: `AppSettings.iCloudDriveLastSyncFailed` (`Minute/Support/AppSettings.swift:44-47`, a computed `UserDefaults` accessor written directly by `ICloudDriveBackup`), `AppSettings.iCloudDriveLastSyncFailedKey`.
- Produces: nothing new.

SwiftUI wiring: the bug is that `@AppStorage` never observes the mirror's direct `UserDefaults.set` on a dotted key (the codebase documents this at `SettingsView.swift:66-70`), and there is no test seam for a scene transition. Verified by build plus the full unit suite.

- [ ] **Step 1: Add the scene phase environment**

In `Minute/Views/SettingsView.swift`, under `@Environment(\.dismiss) private var dismiss` (line 10), add:

```swift
    @Environment(\.scenePhase) private var scenePhase
```

- [ ] **Step 2: Re-read the flag on activation**

Directly after the `.task { usage = MeetingStore.recordingsUsage() }` line (line 72), add:

```swift
            // The background mirror records its verdict with a direct
            // UserDefaults write, which @AppStorage does not observe on these
            // dotted keys — so while this sheet stays open across a
            // background/foreground cycle the warning below is stale in both
            // directions. Most concretely: the user reads the warning, leaves
            // to sign in to iCloud (which backgrounds the app and runs a now
            // successful mirror), comes back, and the warning is still there.
            .onChange(of: scenePhase) {
                guard scenePhase == .active else { return }
                driveLastSyncFailed = AppSettings.iCloudDriveLastSyncFailed
            }
```

- [ ] **Step 3: Run the full unit suite to verify nothing regressed**

Run:

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```

Expected: `TEST SUCCEEDED`, 292 tests.

- [ ] **Step 4: Commit**

```bash
git add Minute/Views/SettingsView.swift
git commit -m "fix: re-read the iCloud Drive sync verdict when Settings comes back to the foreground

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 27: Settings refreshes the summary model rows when a local download finishes (F14)

**Files:**
- Modify: `Minute/Views/SettingsView.swift:66-71` (the `.task(id:)` comment and call), `Minute/Views/SettingsView.swift:482-484` (`transcriptionStatusKey`)

**Interfaces:**
- Consumes: `MLXDownloadCenter.shared.finishedCount` (`Minute/Services/MLXDownloadCenter.swift:11,20` — `@MainActor @Observable final class`, `private(set) var finishedCount = 0`, bumped on every terminal outcome at line 59), `WhisperDownloadCenter.shared.finishedCount` (`Minute/Services/WhisperDownloadCenter.swift:20`).
- Produces: `private var modelStatusKey: String` on `SettingsView` (renamed from `transcriptionStatusKey`).

Renaming a private computed property and adding one interpolation. Nothing here is unit-testable: the fix is a SwiftUI observation dependency created by reading an `@Observable` property during `body` evaluation. Verified by build plus the full unit suite.

- [ ] **Step 1: Rename the key and fold in the summary download center**

In `Minute/Views/SettingsView.swift`, replace `transcriptionStatusKey` (lines 482-484):

```swift
    private var transcriptionStatusKey: String {
        "\(transcriptionEngineRaw)|\(whisperModelRaw)|\(WhisperDownloadCenter.shared.finishedCount)"
    }
```

with:

```swift
    /// Everything whose change has to re-run the capability check and re-read
    /// the model rows. Both centers' `finishedCount` is in here because a
    /// download can finish — and auto-select the model it just fetched — after
    /// its picker has been popped, and @AppStorage never observes the center's
    /// direct write to the dotted selection key. Reading them during `body` is
    /// also what makes the plain computed rows (`summaryModelName`, the
    /// availability footnote, `summarizationStatus`) re-evaluate at all: the
    /// summary side had no dependency on MLXDownloadCenter, so a finished
    /// ~1 GB download kept reading "Local Model / Unavailable / not downloaded
    /// yet" until Settings was dismissed and reopened.
    private var modelStatusKey: String {
        "\(transcriptionEngineRaw)|\(whisperModelRaw)|\(WhisperDownloadCenter.shared.finishedCount)|\(MLXDownloadCenter.shared.finishedCount)"
    }
```

- [ ] **Step 2: Point the task at the renamed key**

In the same file, replace the comment and `.task(id:)` line (lines 66-71):

```swift
            // task(id:) so returning from the engine/model picker refreshes
            // the capability row without reopening Settings. finishedCount:
            // a download can finish (and auto-select) after the picker is
            // popped, and @AppStorage never observes the center's direct
            // write to the dotted key — re-check on every terminal outcome.
            .task(id: transcriptionStatusKey) { await refreshTranscriptionStatus() }
```

with:

```swift
            // task(id:) so returning from an engine/model picker refreshes the
            // capability rows without reopening Settings; see modelStatusKey
            // for why both download centers are part of the key.
            .task(id: modelStatusKey) { await refreshTranscriptionStatus() }
```

- [ ] **Step 3: Run the full unit suite to verify nothing regressed**

Run:

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```

Expected: `TEST SUCCEEDED`, 292 tests. A compile error naming `transcriptionStatusKey` means the rename missed the `.task(id:)` call site.

- [ ] **Step 4: Commit**

```bash
git add Minute/Views/SettingsView.swift
git commit -m "fix: refresh the Summary Model row and Summarization status when a local model finishes downloading

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 28: A busy meeting can't be summarized by mistake, and its transcript job can be stopped (F62, F10 view part)

**Files:**
- Modify: `Minute/Views/MeetingDetailView.swift:452-462` (the empty-state Generate Summary button), `Minute/Views/MeetingDetailView.swift:521-530` (the transcript progress row)

**Interfaces:**
- Consumes: `MeetingJobs.cancel(_ meeting: Meeting)` (`Minute/Services/MeetingJobs.swift:76`), `isBusy`/`isRetranscribing`/`isDiarizing`/`jobStatus` (private computed properties, `MeetingDetailView.swift:57-62`).
- Produces: nothing new.

View wiring; `MeetingJobs.cancel` and its mutual-exclusion guard are already covered by the jobs suite. Verified by build plus the full unit suite.

- [ ] **Step 1: Disable the empty-state Generate Summary button while a job holds the meeting**

In `Minute/Views/MeetingDetailView.swift`, inside `emptySummaryState`, replace:

```swift
                Button {
                    generateSummary()
                } label: {
                    Label("Generate Summary", systemImage: "sparkles")
                        .font(.headline)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .padding(.top, 2)
```

with:

```swift
                Button {
                    generateSummary()
                } label: {
                    Label("Generate Summary", systemImage: "sparkles")
                        .font(.headline)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                // Same gate as the menu's Generate Summary. This state is
                // reached during a re-transcription or speaker identification
                // (no summary, not generating), and MeetingJobs.start returns
                // the running job for the meeting without starting anything —
                // so the tap was a silent no-op the user could repeat forever.
                .disabled(isBusy)
                .padding(.top, 2)
```

- [ ] **Step 2: Give the transcript progress row the Stop button the summary row has**

In the same file, in `transcriptContent`, replace:

```swift
        if isRetranscribing || isDiarizing {
            HStack(spacing: 12) {
                ProgressView()
                Text(isRetranscribing ? "Re-transcribing on device…" : (jobStatus ?? "Identifying speakers on device…"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, Layout.sectionGap - 8)
        }
```

with:

```swift
        if isRetranscribing || isDiarizing {
            HStack(spacing: 12) {
                ProgressView()
                Text(isRetranscribing ? "Re-transcribing on device…" : (jobStatus ?? "Identifying speakers on device…"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                // The same escape hatch the summary row has. Both of these
                // jobs run for many minutes on a long meeting, and every menu
                // item on this screen is gated on `isBusy` while they do — so
                // without this, a re-transcription started by mistake locks
                // the meeting with no way out but force-quitting the app.
                Button("Stop") {
                    jobs.cancel(meeting)
                }
                .font(.subheadline.weight(.medium))
                .buttonStyle(.borderless)
            }
            .padding(.top, Layout.sectionGap - 8)
        }
```

- [ ] **Step 3: Run the full unit suite to verify nothing regressed**

Run:

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```

Expected: `TEST SUCCEEDED`, 292 tests.

- [ ] **Step 4: Commit**

```bash
git add Minute/Views/MeetingDetailView.swift
git commit -m "fix: gate the empty-state Generate Summary on the busy meeting and let a transcript job be stopped

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 29: The summary editor stops restructuring action items it was never asked to touch (F52)

**Files:**
- Modify: `Minute/Views/SummaryEditorView.swift:148-175` (`save()`), `Minute/Views/SummaryEditorView.swift:191-200` (`parseActionItems`)
- Test: `MinuteTests/SummaryEditorParsingTests.swift`

**Interfaces:**
- Consumes: `SummarizationService.normalizedField(_ value: String) -> String` (`Minute/Services/SummarizationService.swift:673`, static on `struct SummarizationService`, maps ""/"not specified"/"none"/"unknown" to `ActionItem.notSpecified`), `ActionItem.notSpecified` (`Minute/Models/MeetingSummary.swift:57`), the existing `hasChanges` computed property (`SummaryEditorView.swift:56`, `draft != original` where `original` is exactly what `init` serialized).
- Produces: `SummaryEditorView.actionItemSeparator: String` (`" | "`), `static func splitActionItemLine(_ line: String) -> [String]`, and a `parseActionItems` whose contract is "split on the LAST two separators".

- [ ] **Step 1: Write the failing tests**

Add to `MinuteTests/SummaryEditorParsingTests.swift`, inside the struct, after `parseActionItemsSkipsLinesWithoutTask`:

```swift
    /// F52: the editor serializes "task | owner | deadline" and used to split
    /// on every "|", so a model-written task containing one shifted every
    /// field a column left — the wrong owner, and the deadline gone. There is
    /// no undo.
    @Test func parseActionItemsKeepsAPipeInsideTheTask() {
        let parsed = SummaryEditorView.parseActionItems("Decide A | B pricing | Alice | Friday")
        #expect(parsed == [ActionItem(task: "Decide A | B pricing", owner: "Alice", deadline: "Friday")])
    }

    @Test func parseActionItemsSplitsOnTheLastTwoSeparatorsOnly() {
        #expect(SummaryEditorView.splitActionItemLine("a | b | c | d") == ["a | b", "c", "d"])
        #expect(SummaryEditorView.splitActionItemLine("only a task") == ["only a task"])
    }

    /// A user-typed line with one separator still means task + owner, as it
    /// did before — the deadline is what's missing, not the owner.
    @Test func parseActionItemsTreatsASingleSeparatorAsTheOwner() {
        let parsed = SummaryEditorView.parseActionItems("Send the deck | Priya")
        #expect(parsed == [ActionItem(task: "Send the deck", owner: "Priya", deadline: "Not specified")])
    }

    @Test func parseActionItemsNormalizesPlaceholderOwnersAndDeadlines() {
        let parsed = SummaryEditorView.parseActionItems("Book the room | none | unknown")
        #expect(parsed == [ActionItem(task: "Book the room", owner: "Not specified", deadline: "Not specified")])
    }

    /// The round trip the editor performs on every Save: whatever `init`
    /// serialized must parse back to the identical items, or saving rewrites
    /// notes the user never edited.
    @Test func actionItemsSurviveTheEditorsSerializeParseRoundTrip() {
        let items = [
            ActionItem(task: "Decide A | B pricing", owner: "Alice", deadline: "Friday"),
            ActionItem(task: "Ship the fix", owner: "Not specified", deadline: "Not specified"),
        ]
        let serialized = items
            .map { "\($0.task) | \($0.owner) | \($0.deadline)" }
            .joined(separator: "\n")

        #expect(SummaryEditorView.parseActionItems(serialized) == items)
    }
```

- [ ] **Step 2: Run the suite to verify they fail**

Run: the suite command with `SummaryEditorParsingTests`.

Expected: `parseActionItemsSplitsOnTheLastTwoSeparatorsOnly` fails to compile (`splitActionItemLine` does not exist yet). Once that method exists but `parseActionItems` is unchanged, `parseActionItemsKeepsAPipeInsideTheTask` fails with task `"Decide A"`, owner `"B pricing"`, deadline `"Alice"`; `parseActionItemsNormalizesPlaceholderOwnersAndDeadlines` fails with owner `"none"`, deadline `"unknown"`; `actionItemsSurviveTheEditorsSerializeParseRoundTrip` fails on the first item.

- [ ] **Step 3: Make the parsing delimiter-safe**

In `Minute/Views/SummaryEditorView.swift`, replace `parseActionItems` (lines 191-200):

```swift
    static func parseActionItems(_ text: String) -> [ActionItem] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard let task = parts.first, !task.isEmpty else { return nil }
            let owner = parts.count > 1 && !parts[1].isEmpty ? parts[1] : ActionItem.notSpecified
            let deadline = parts.count > 2 && !parts[2].isEmpty ? parts[2] : ActionItem.notSpecified
            return ActionItem(task: task, owner: owner, deadline: deadline)
        }
    }
```

with:

```swift
    /// The separator `init` writes between the three fields. It carries its
    /// spaces so a bare "|" inside a field is not a delimiter.
    static let actionItemSeparator = " | "

    /// Splits one line into at most three fields, on the LAST two separators.
    /// Everything left of them is the task, however many pipes it contains —
    /// splitting on every "|" turned a model-written "Compare vendor A |
    /// vendor B" into a task, an owner and a deadline that all belonged to the
    /// task, silently and with no undo. A line with a single separator still
    /// means task + owner, which is what a user typing one row expects.
    static func splitActionItemLine(_ line: String) -> [String] {
        var fields: [String] = []
        var head = Substring(line)
        while fields.count < 2, let range = head.range(of: actionItemSeparator, options: .backwards) {
            fields.insert(String(head[range.upperBound...]), at: 0)
            head = head[..<range.lowerBound]
        }
        fields.insert(String(head), at: 0)
        return fields
    }

    static func parseActionItems(_ text: String) -> [ActionItem] {
        text.split(separator: "\n").compactMap { line in
            let fields = splitActionItemLine(String(line))
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard let task = fields.first, !task.isEmpty else { return nil }
            // Same normalization generated summaries get, so a hand-typed
            // "none" reads as the placeholder everywhere instead of appearing
            // as an owner named none.
            return ActionItem(
                task: task,
                owner: SummarizationService.normalizedField(fields.count > 1 ? fields[1] : ""),
                deadline: SummarizationService.normalizedField(fields.count > 2 ? fields[2] : "")
            )
        }
    }
```

- [ ] **Step 4: Skip the rewrite when nothing was edited**

In the same file, add a guard as the first statement of `save()` (line 148, before `meeting.summary = MeetingSummary(`):

```swift
    private func save() {
        // An untouched editor must not rewrite the summary. Every field would
        // round-trip through the line parsers, and a list item the model wrote
        // with an embedded newline in it comes back as two items — for a Save
        // the user made no edit to. `original` is exactly what `init`
        // serialized, so this compares the draft against that snapshot.
        guard hasChanges else { return }
        meeting.summary = MeetingSummary(
```

- [ ] **Step 5: Run the suite to verify it passes, then the full unit suite**

Run: the suite command with `SummaryEditorParsingTests`; then the full unit suite command.

Expected: all pass, including the four pre-existing tests in the suite (`parseActionItemsFillsMissingFieldsWithNotSpecified`, `parseActionItemsReadsAllThreeFields`, `parseActionItemsSkipsLinesWithoutTask`, and the two `parseList` tests). 292 + 5 tests.

- [ ] **Step 6: Commit**

```bash
git add Minute/Views/SummaryEditorView.swift MinuteTests/SummaryEditorParsingTests.swift
git commit -m "fix: keep a pipe inside an action item's task and skip the rewrite when the editor was not edited

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 30: The detail title commits through a draft that can't be left empty (F39)

**Files:**
- Modify: `Minute/Models/Meeting.swift:80` (append an extension at the end of the file)
- Modify: `Minute/Views/MeetingDetailView.swift:28-38` (view state), `Minute/Views/MeetingDetailView.swift:110-115` (`onDisappear`), `Minute/Views/MeetingDetailView.swift:280-297` (`masthead`), `Minute/Views/MeetingDetailView.swift:665-671` (add `commitTitle()` next to `saveQuietly()`)
- Create: `MinuteTests/MeetingTitleTests.swift`

**Interfaces:**
- Consumes: `Meeting.defaultTitle: String?` (`Minute/Models/Meeting.swift:12`), `Meeting.createdAt: Date` (line 13), `RecordingSession.defaultTitle(for date: Date = .now) -> String` (`Minute/Recording/RecordingSession.swift:256`, `nonisolated static`), `PersistentModel.isGone` (`Minute/Models/PersistentModel+IsGone.swift:13`).
- Produces: `Meeting.committedTitle(draft: String, fallback: String) -> String` (static), `Meeting.titleFallback: String` (instance computed), `MeetingDetailView.commitTitle()` (private), `@State private var titleDraft: String?` on `MeetingDetailView`.

- [ ] **Step 1: Write the failing test**

Create `MinuteTests/MeetingTitleTests.swift`:

```swift
import Foundation
import Testing
@testable import Minute

/// F39: the masthead bound its TextField straight to `meeting.title`, so the
/// user could clear it or press Return into it and `saveQuietly()` persisted
/// the result. An empty or multi-line title then heads the library row, the
/// widget snapshot, the exported notes.md and the iCloud Drive folder name.
@MainActor
struct MeetingTitleTests {
    @Test func committedTitleTrimsSurroundingWhitespace() {
        #expect(Meeting.committedTitle(draft: "  Board Review  ", fallback: "Meeting Sep 2") == "Board Review")
    }

    @Test func committedTitleFallsBackWhenTheFieldIsEmptied() {
        #expect(Meeting.committedTitle(draft: "", fallback: "Meeting Sep 2") == "Meeting Sep 2")
        #expect(Meeting.committedTitle(draft: "   \n  ", fallback: "Meeting Sep 2") == "Meeting Sep 2")
    }

    @Test func committedTitleFoldsPastedNewlinesIntoOneLine() {
        #expect(Meeting.committedTitle(draft: "Board Review\nQ3 budget", fallback: "Meeting Sep 2") == "Board Review Q3 budget")
        #expect(Meeting.committedTitle(draft: "Board Review\r\nQ3 budget", fallback: "Meeting Sep 2") == "Board Review Q3 budget")
    }

    @Test func committedTitleKeepsAnOrdinaryTitleExactly() {
        #expect(Meeting.committedTitle(draft: "Q3 Board Review", fallback: "Meeting Sep 2") == "Q3 Board Review")
    }

    @Test func titleFallbackPrefersTheTitleTheMeetingWasCreatedWith() {
        let meeting = Meeting(title: "Renamed", defaultTitle: "Meeting Jan 1, 2026 at 9:00 AM")
        #expect(meeting.titleFallback == "Meeting Jan 1, 2026 at 9:00 AM")
    }

    /// Meetings stored before `defaultTitle` existed (and imports) have none,
    /// so the fallback is regenerated from the creation date — never empty.
    @Test func titleFallbackRebuildsTheDefaultWhenTheMeetingHasNone() {
        let createdAt = Date(timeIntervalSince1970: 1_767_243_600)
        let meeting = Meeting(title: "Renamed", createdAt: createdAt)

        #expect(meeting.titleFallback == RecordingSession.defaultTitle(for: createdAt))
        #expect(!meeting.titleFallback.isEmpty)
    }
}
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: the suite command with `MeetingTitleTests`.

Expected: the build fails — `type 'Meeting' has no member 'committedTitle'` and `value of type 'Meeting' has no member 'titleFallback'`.

- [ ] **Step 3: Add the pure helpers to Meeting**

Append to the end of `Minute/Models/Meeting.swift` (after the closing brace of `final class Meeting`, line 80):

```swift

extension Meeting {
    /// The title to store when the user finishes editing the detail
    /// masthead. A title is an identifier as much as a label — it heads the
    /// library row, the Home Screen widget, the exported and mirrored
    /// notes.md, and the iCloud Drive folder name — so an emptied field must
    /// not be written through: it falls back to the meeting's own default.
    /// Newlines fold into spaces rather than being trimmed off the ends,
    /// because a pasted two-line string would otherwise turn "# title" into a
    /// heading plus a stray body line in every export.
    static func committedTitle(draft: String, fallback: String) -> String {
        let flattened = draft
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flattened.isEmpty ? fallback : flattened
    }

    /// What the title reverts to when the field is emptied: the exact
    /// auto-generated title this meeting was created with, or — for meetings
    /// stored before that field existed, and for imports — the same string
    /// regenerated from the creation date, so the fallback is never empty.
    var titleFallback: String {
        defaultTitle ?? RecordingSession.defaultTitle(for: createdAt)
    }
}
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: the suite command with `MeetingTitleTests`.

Expected: all six tests pass.

- [ ] **Step 5: Edit the masthead title through a draft**

In `Minute/Views/MeetingDetailView.swift`, add under `@State private var selectedTab: Tab = .summary` (line 36):

```swift
    /// The masthead field's text while the user is editing it; nil means "not
    /// being edited", so the field shows the stored title. Edits go through
    /// this rather than straight into `meeting.title`: bound directly, every
    /// keystroke was a model mutation the whole app re-rendered on, and
    /// clearing the field wrote an empty title that then headed the library
    /// row, the widget, and every export.
    @State private var titleDraft: String?
```

Replace the `TextField` in `masthead` (line 282):

```swift
            TextField("Title", text: $meeting.title, axis: .vertical)
                .font(.largeTitle.bold())
                .textFieldStyle(.plain)
                .accessibilityLabel("Meeting title")
```

with:

```swift
            TextField("Title", text: Binding(
                get: { titleDraft ?? meeting.title },
                set: { titleDraft = $0 }
            ))
                .font(.largeTitle.bold())
                .textFieldStyle(.plain)
                // Single-line on purpose: with `axis: .vertical` the return
                // key inserted a newline into the title instead of finishing
                // the edit, and onSubmit never fired.
                .submitLabel(.done)
                .onSubmit { commitTitle() }
                .accessibilityLabel("Meeting title")
```

- [ ] **Step 6: Commit the draft on submit and on the way out**

In the same file, replace `onDisappear` (lines 110-115):

```swift
        .onDisappear {
            player.stop()
            if !meeting.isGone {
                saveQuietly()
            }
        }
```

with:

```swift
        .onDisappear {
            player.stop()
            if !meeting.isGone {
                commitTitle()
                saveQuietly()
            }
        }
```

and add `commitTitle()` directly above `saveQuietly()` (line 665):

```swift
    /// Writes the edited title back to the meeting, substituting the fallback
    /// when the user left the field empty. A no-op when nothing was typed, so
    /// merely opening and leaving this screen never touches the model — which
    /// also keeps the widget snapshot from being rewritten for a visit.
    private func commitTitle() {
        guard let draft = titleDraft else { return }
        titleDraft = nil
        guard !meeting.isGone else { return }
        let committed = Meeting.committedTitle(draft: draft, fallback: meeting.titleFallback)
        if committed != meeting.title {
            meeting.title = committed
        }
    }

```

- [ ] **Step 7: Run the full unit suite to verify nothing regressed**

Run: the full unit suite command.

Expected: `TEST SUCCEEDED`, 292 + 5 (Task 29) + 6 = 303 tests.

- [ ] **Step 8: Commit**

```bash
git add Minute/Models/Meeting.swift Minute/Views/MeetingDetailView.swift MinuteTests/MeetingTitleTests.swift
git commit -m "fix: commit detail-view title edits through a trimmed draft that falls back instead of saving an empty title

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 31: Widget snapshot publishes are coalesced, and flushed when the app leaves (F44)

**Files:**
- Modify: `Minute/Services/WidgetSnapshotPublisher.swift:3-5` (add the window constant)
- Modify: `Minute/Views/MeetingListView.swift:24-27` (environment), `Minute/Views/MeetingListView.swift:51` (state), `Minute/Views/MeetingListView.swift:167-172` (the `onChange` modifiers), and the private helpers next to `widgetSnapshot` (line 333-335)

**Interfaces:**
- Consumes: `WidgetSnapshotPublisher.publish(_:store:reload:)` (`Minute/Services/WidgetSnapshotPublisher.swift:21-30`, `@MainActor`, same-value suppressed by `WidgetSnapshotStore.save`), `WidgetSnapshotPublisher.snapshot(from:limit:)` (line 6), the view's `widgetSnapshot` computed property.
- Produces: `WidgetSnapshotPublisher.coalescingWindow: Duration`; `MeetingListView.scheduleWidgetPublish(_:)` and `publishWidgetSnapshotNow()` (private), `@State private var widgetPublishTask: Task<Void, Never>?`.

No unit test: what is added is a SwiftUI `onChange` schedule around an already-tested publisher, and asserting a 500 ms debounce from a test would be a timing race, not a behavior check. `WidgetSnapshotPublisherTests.publishReloadsOnlyWhenStoredValueChanges` still covers the write-suppression half. Verified by build plus the full unit suite.

- [ ] **Step 1: Name the coalescing window on the publisher**

In `Minute/Services/WidgetSnapshotPublisher.swift`, replace:

```swift
enum WidgetSnapshotPublisher {
    static let maximumMeetingCount = 3
```

with:

```swift
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
```

- [ ] **Step 2: Add the scene phase and the pending-publish task to the list view**

In `Minute/Views/MeetingListView.swift`, add under `@Environment(MeetingJobs.self) private var jobs` (line 26):

```swift
    @Environment(\.scenePhase) private var scenePhase
```

and add after `@State private var deepLinkState = MeetingDeepLinkState()` (line 51):

```swift
    /// The pending widget publish, cancelled and replaced by each new
    /// snapshot so a burst of changes produces one write.
    @State private var widgetPublishTask: Task<Void, Never>?
```

- [ ] **Step 3: Publish through the window, and flush when the scene leaves**

In the same file, replace:

```swift
        .onChange(of: widgetSnapshot, initial: true) { _, snapshot in
            WidgetSnapshotPublisher.publish(snapshot)
        }
```

with:

```swift
        .onChange(of: widgetSnapshot, initial: true) { _, snapshot in
            scheduleWidgetPublish(snapshot)
        }
        .onChange(of: scenePhase) {
            // Leaving the app is the last moment a coalescing window can still
            // finish — the process may be suspended before it expires — and it
            // is also the moment the Home Screen widget is about to be looked
            // at, so publish the current snapshot outright.
            guard scenePhase != .active else { return }
            publishWidgetSnapshotNow()
        }
```

- [ ] **Step 4: Add the two helpers**

In the same file, directly after the `widgetSnapshot` computed property (lines 333-335), add:

```swift

    /// Coalesces publishes into one write per window instead of one per
    /// change. Each new snapshot cancels the pending publish and starts the
    /// window again, so the last value in a burst is the one that lands.
    private func scheduleWidgetPublish(_ snapshot: WidgetSnapshot) {
        widgetPublishTask?.cancel()
        widgetPublishTask = Task {
            try? await Task.sleep(for: WidgetSnapshotPublisher.coalescingWindow)
            guard !Task.isCancelled else { return }
            WidgetSnapshotPublisher.publish(snapshot)
        }
    }

    /// Publishes the current snapshot immediately, dropping any pending
    /// window. `publish` is same-value suppressed, so calling this when
    /// nothing changed costs one comparison and no WidgetKit reload.
    private func publishWidgetSnapshotNow() {
        widgetPublishTask?.cancel()
        widgetPublishTask = nil
        WidgetSnapshotPublisher.publish(widgetSnapshot)
    }
```

- [ ] **Step 5: Run the suite to verify it passes, then the full unit suite**

Run: the suite command with `WidgetSnapshotPublisherTests`; then the full unit suite command.

Expected: both pass; 303 tests total, unchanged from Task 30.

- [ ] **Step 6: Commit**

```bash
git add Minute/Services/WidgetSnapshotPublisher.swift Minute/Views/MeetingListView.swift
git commit -m "fix: coalesce widget snapshot publishes into one write per burst and flush them when the app leaves

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 32: Deep links arbitrate against what is already on screen (F40, F64)

**Files:**
- Modify: `Minute/Support/MeetingDeepLinkState.swift:21` (append an extension at the end of the file)
- Modify: `Minute/Views/MeetingListView.swift:463-484` (`handleDeepLink` and a new `dismissPresentedSheets`)
- Test: `MinuteTests/MeetingDeepLinkStateTests.swift`

**Interfaces:**
- Consumes: `MinuteDeepLink` (`Shared/MinuteDeepLink.swift:3`, `enum MinuteDeepLink: Equatable { case newMeeting; case meeting(UUID) }`), `MeetingDeepLinkState.receive(_:)` and `resolve(availableMeetingIDs:)` (`Minute/Support/MeetingDeepLinkState.swift:6,15`), the view's `activeSession`, `showingNewMeeting`, `showingSettings`, `showingImporter` state.
- Produces: `MeetingDeepLinkState.Action` (`enum Action: Equatable { case presentNewMeeting, openMeeting, ignore }`), `static func action(for: MinuteDeepLink, isRecording: Bool, isShowingNewMeeting: Bool) -> Action`, `MeetingListView.dismissPresentedSheets()` (private).

- [ ] **Step 1: Write the failing test**

Add to `MinuteTests/MeetingDeepLinkStateTests.swift`, inside the struct, after `newerMeetingLinkReplacesPendingMeeting`:

```swift
    // MARK: - What to do with a link, given what is already on screen

    /// F40: `beginNewMeeting()` resets `draftTitle` unconditionally, so a
    /// widget tap while the sheet is up wiped the title the user had typed
    /// into it. The sheet already IS the state the link asks for.
    @Test func aNewMeetingLinkIsIgnoredWhileTheSheetIsAlreadyOpen() {
        #expect(MeetingDeepLinkState.action(
            for: .newMeeting,
            isRecording: false,
            isShowingNewMeeting: true
        ) == .ignore)
    }

    @Test func aNewMeetingLinkIsIgnoredWhileARecordingIsRunning() {
        #expect(MeetingDeepLinkState.action(
            for: .newMeeting,
            isRecording: true,
            isShowingNewMeeting: false
        ) == .ignore)
    }

    @Test func aNewMeetingLinkPresentsTheSheetWhenNothingIsInTheWay() {
        #expect(MeetingDeepLinkState.action(
            for: .newMeeting,
            isRecording: false,
            isShowingNewMeeting: false
        ) == .presentNewMeeting)
    }

    /// F64: a meeting link is always honored — the list dismisses whatever is
    /// covering the stack first, rather than pushing the detail behind it.
    @Test func aMeetingLinkAlwaysOpensTheMeeting() {
        #expect(MeetingDeepLinkState.action(
            for: .meeting(firstID),
            isRecording: true,
            isShowingNewMeeting: true
        ) == .openMeeting)
        #expect(MeetingDeepLinkState.action(
            for: .meeting(firstID),
            isRecording: false,
            isShowingNewMeeting: false
        ) == .openMeeting)
    }
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: the suite command with `MeetingDeepLinkStateTests`.

Expected: the build fails — `type 'MeetingDeepLinkState' has no member 'action'`.

- [ ] **Step 3: Add the pure decision to MeetingDeepLinkState**

Append to the end of `Minute/Support/MeetingDeepLinkState.swift` (after the closing brace of `struct MeetingDeepLinkState`, line 21):

```swift

extension MeetingDeepLinkState {
    /// What the list should do with a link that just arrived, given what is
    /// already on screen. Pure and static so the "already the requested
    /// state" rules can be tested without a view.
    enum Action: Equatable {
        /// Present the New Meeting sheet.
        case presentNewMeeting
        /// Push the meeting the link named, once the query can see it.
        case openMeeting
        /// Do nothing: the app is already in the state the link asks for.
        case ignore
    }

    static func action(
        for deepLink: MinuteDeepLink,
        isRecording: Bool,
        isShowingNewMeeting: Bool
    ) -> Action {
        switch deepLink {
        case .newMeeting:
            // A running recording already IS a new meeting. And the sheet
            // already asks for the title the link would reset — presenting it
            // again resets the draft title in place and throws away what the
            // user typed there before they were interrupted.
            if isRecording || isShowingNewMeeting { return .ignore }
            return .presentNewMeeting
        case .meeting:
            return .openMeeting
        }
    }
}
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: the suite command with `MeetingDeepLinkStateTests`.

Expected: all eight tests pass (four pre-existing plus the four new ones).

- [ ] **Step 5: Route the view's handler through it**

In `Minute/Views/MeetingListView.swift`, replace `handleDeepLink(_:)` (lines 463-474):

```swift
    private func handleDeepLink(_ url: URL) {
        guard let deepLink = MinuteDeepLink(url: url) else { return }
        switch deepLink {
        case .newMeeting:
            deepLinkState.receive(deepLink)
            guard activeSession == nil else { return }
            beginNewMeeting()
        case .meeting:
            deepLinkState.receive(deepLink)
            resolvePendingMeetingDeepLink()
        }
    }
```

with:

```swift
    private func handleDeepLink(_ url: URL) {
        guard let deepLink = MinuteDeepLink(url: url) else { return }
        deepLinkState.receive(deepLink)
        switch MeetingDeepLinkState.action(
            for: deepLink,
            isRecording: activeSession != nil,
            isShowingNewMeeting: showingNewMeeting
        ) {
        case .ignore:
            break
        case .presentNewMeeting:
            dismissPresentedSheets()
            beginNewMeeting()
        case .openMeeting:
            dismissPresentedSheets()
            resolvePendingMeetingDeepLink()
        }
    }

    /// Clears anything modal covering the navigation stack, so a deep link's
    /// destination is what the user actually sees. A meeting link used to push
    /// the detail *underneath* an open Settings sheet — the user who tapped a
    /// widget row got Settings until they found Done. Clearing
    /// `showingNewMeeting` here is safe for the new-meeting link too: that
    /// case only reaches this when the sheet is already down.
    private func dismissPresentedSheets() {
        showingSettings = false
        showingImporter = false
        showingNewMeeting = false
    }
```

- [ ] **Step 6: Run the full unit suite to verify nothing regressed**

Run: the full unit suite command.

Expected: `TEST SUCCEEDED`, 303 + 4 = 307 tests.

- [ ] **Step 7: Commit**

```bash
git add Minute/Support/MeetingDeepLinkState.swift Minute/Views/MeetingListView.swift MinuteTests/MeetingDeepLinkStateTests.swift
git commit -m "fix: ignore a new-meeting link while its sheet is open and dismiss sheets before a deep link lands

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 33: Data protection reaches the store files and the Recordings directory (F34, F35)

**Files:**
- Modify: `Minute/Services/MeetingStore.swift:70-92` (`setExcludedFromBackup`), `Minute/Services/MeetingStore.swift:119-144` (`recordingsDirectory`, to use the shared directory-name constant), and add the new members after `setExcludedFromBackup`
- Modify: `Minute/App/MinuteApp.swift:44-47` (call the new pass after the container is open)
- Test: `MinuteTests/MeetingStoreTests.swift`

**Interfaces:**
- Consumes: `FileManager.setAttributes(_:ofItemAtPath:)`, `FileProtectionType`, the existing `logger` (`MeetingStore.swift:9`).
- Produces: `MeetingStore.recordingsDirectoryName: String` (private, `"Recordings"`), `MeetingStore.storeFileNames: [String]`, `MeetingStore.dataProtectionClass: FileProtectionType`, `@discardableResult static func applyDataProtection(base: URL? = nil, apply: (URL, FileProtectionType) throws -> Void = …) -> Bool`. Task 34 consumes `storeFileNames` and `recordingsDirectoryName`.

Note on the test: the iOS Simulator accepts `.protectionKey` and then reports it back as `nil` — verified by running a probe binary under `xcrun simctl spawn` on "iPhone 17 Pro Max" (`set OK` / `dir protection: nil` / `file protection: nil`). Asserting the attribute after setting it would therefore assert nothing, which is why the applier is injected and the test asserts exactly what the app asks the file system for, path by path.

- [ ] **Step 1: Write the failing test**

Add to `MinuteTests/MeetingStoreTests.swift`, inside the struct, after `backupExclusionFlagFollowsTheRequestedValue`:

```swift
    /// F34/F35: the class was pinned on Application Support only, which does
    /// not reach the SwiftData store (ModelContainer creates it before any
    /// policy runs) nor a Recordings directory that already existed. And the
    /// class itself was wrong: `completeUnlessOpen` files cannot be reopened
    /// after the phone locks, which is exactly when the iCloud Drive mirror
    /// and the job engines read them.
    ///
    /// The applier is injected because the simulator accepts `.protectionKey`
    /// and reports it back as nil — reading the attribute would assert
    /// nothing about what was requested.
    @Test func dataProtectionCoversTheStoreFilesAndTheRecordingsDirectory() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("protection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        // The store files exist before any policy runs. The -shm sibling
        // deliberately does not, so the pass is shown to skip what is absent
        // rather than throw on it.
        try Data("db".utf8).write(to: base.appendingPathComponent("default.store"))
        try Data("wal".utf8).write(to: base.appendingPathComponent("default.store-wal"))

        var applied: [(name: String, protection: FileProtectionType)] = []
        let succeeded = MeetingStore.applyDataProtection(base: base) { url, protection in
            applied.append((url.lastPathComponent, protection))
        }

        #expect(succeeded)
        #expect(applied.map(\.name) == [
            base.lastPathComponent,
            "Recordings",
            "default.store",
            "default.store-wal",
        ])
        #expect(Set(applied.map(\.protection)) == [.completeUntilFirstUserAuthentication])
        // Created if missing, so a fresh install's audio inherits the class.
        #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("Recordings").path))
    }
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: the suite command with `MeetingStoreTests`.

Expected: the build fails — `type 'MeetingStore' has no member 'applyDataProtection'`.

- [ ] **Step 3: Replace the class-B directory attribute with an explicit pass**

In `Minute/Services/MeetingStore.swift`, replace `setExcludedFromBackup` in full (lines 70-92):

```swift
    /// Sets the backup-exclusion flag on one directory, and pins the data
    /// protection class while we are here. Split out so tests can exercise the
    /// flip on a scratch directory instead of racing concurrent tests over the
    /// shared Application Support tree.
    static func setExcludedFromBackup(_ excluded: Bool, at url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = excluded
        try url.setResourceValues(values)
        // Meeting audio and transcripts are about as sensitive as this app's
        // data gets. The default class keeps them readable once the phone has
        // been unlocked a single time since boot — i.e. essentially always,
        // which is exactly the state a stolen phone is in. `completeUnlessOpen`
        // keeps an in-progress recording writable across a lock while leaving
        // everything at rest unreadable until the next unlock.
        //
        // Set on the directory, which is what new files inherit; recordings
        // made before this shipped keep the class they were created with.
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUnlessOpen],
            ofItemAtPath: url.path
        )
    }
```

with:

```swift
    /// Sets the backup-exclusion flag on one directory. Split out so tests can
    /// exercise the flip on a scratch directory instead of racing concurrent
    /// tests over the shared Application Support tree. The data protection
    /// class is applied separately — see `applyDataProtection`, which has to
    /// run after the SwiftData container exists.
    static func setExcludedFromBackup(_ excluded: Bool, at url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = excluded
        try url.setResourceValues(values)
    }

    /// The subdirectory of Application Support that holds meeting audio.
    private static let recordingsDirectoryName = "Recordings"

    /// SwiftData's on-disk files for the default configuration: the database
    /// plus its write-ahead log and shared-memory siblings. Named explicitly
    /// because both the data-protection pass and the fallback reset have to
    /// address them one by one — a directory attribute never reaches a file
    /// that already exists, and deleting only `default.store` leaves a -wal a
    /// later open replays.
    static let storeFileNames = ["default.store", "default.store-wal", "default.store-shm"]

    /// The data protection class Minute pins on its own files.
    ///
    /// Not `completeUnlessOpen` (class B), which is what this used to set.
    /// A class-B file that is closed cannot be reopened once the device locks,
    /// and Minute reads its own files precisely then: the iCloud Drive mirror
    /// starts on `scenePhase == .background`, which is exactly what locking the
    /// phone produces, and it copies each recording with `FileManager.copyItem`
    /// after the class key has been discarded; re-transcription and speaker
    /// identification open the audio (and the Whisper/MLX model files) after a
    /// model-preparation wait the user may well spend with the phone locked.
    /// The failures surfaced as "the last backup to iCloud Drive didn't
    /// finish — check that you're signed in to iCloud" while iCloud was fine.
    /// `completeUntilFirstUserAuthentication` still leaves everything
    /// unreadable until the first unlock after a reboot — the state a stolen
    /// powered-off phone is in — without breaking those reads.
    static let dataProtectionClass = FileProtectionType.completeUntilFirstUserAuthentication

    /// Pins the data protection class on everything Minute writes: the
    /// Application Support directory (so new files inherit it), the Recordings
    /// directory (which on an install upgraded from before the policy shipped
    /// already exists and keeps whatever class it was created with, so new
    /// audio inherits the wrong one), and the SwiftData store files, which
    /// `ModelContainer` creates before any policy runs and which a directory
    /// attribute therefore never reaches. `setAttributes` on a directory is not
    /// recursive and only governs what is created inside it afterwards, which
    /// is why each of these is named. Call once at launch, after the container
    /// is open. Returns false when something could not be set.
    ///
    /// `apply` is injected so tests can assert what gets which class: the
    /// simulator accepts `.protectionKey` and then reports it back as nil, so
    /// reading the attribute afterwards would assert nothing.
    @discardableResult
    static func applyDataProtection(
        base: URL? = nil,
        apply: (URL, FileProtectionType) throws -> Void = { url, protection in
            try FileManager.default.setAttributes([.protectionKey: protection], ofItemAtPath: url.path)
        }
    ) -> Bool {
        var succeeded = true
        do {
            let root = try base ?? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let recordings = root.appendingPathComponent(recordingsDirectoryName, isDirectory: true)
            try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
            var targets = [root, recordings]
            for name in storeFileNames {
                let url = root.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: url.path) {
                    targets.append(url)
                }
            }
            for url in targets {
                do {
                    try apply(url, dataProtectionClass)
                } catch {
                    logger.error("Pinning the data protection class on \(url.lastPathComponent) failed: \(error.localizedDescription)")
                    succeeded = false
                }
            }
        } catch {
            logger.error("Applying data protection failed: \(error.localizedDescription)")
            succeeded = false
        }
        return succeeded
    }
```

Then, in `recordingsDirectory()`, replace the literal with the constant:

```swift
        let directory = base.appendingPathComponent("Recordings", isDirectory: true)
```

becomes:

```swift
        let directory = base.appendingPathComponent(recordingsDirectoryName, isDirectory: true)
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: the suite command with `MeetingStoreTests`.

Expected: all pass — the new test plus the twelve pre-existing ones, including `recordingsDirectoryIsExcludedFromBackupsByDefault` and `backupExclusionFlagFollowsTheRequestedValue`, which only assert the backup flag.

- [ ] **Step 5: Run the pass at launch, once the container is open**

In `Minute/App/MinuteApp.swift`, replace lines 44-47:

```swift
        // Even in fallback mode, a (possibly corrupt) store and existing
        // recordings may still sit in Application Support — apply the user's
        // backup choice to it regardless of which directory receives new audio.
        MeetingStore.applyBackupPolicy()
```

with:

```swift
        // Even in fallback mode, a (possibly corrupt) store and existing
        // recordings may still sit in Application Support — apply the user's
        // backup choice to it regardless of which directory receives new audio.
        MeetingStore.applyBackupPolicy()
        // After the container above, not before: the store files exist only
        // once ModelContainer has created them, and a class set on the
        // directory never reaches a file that already exists.
        MeetingStore.applyDataProtection()
```

- [ ] **Step 6: Run the full unit suite to verify nothing regressed**

Run: the full unit suite command.

Expected: `TEST SUCCEEDED`, 307 + 1 = 308 tests.

- [ ] **Step 7: Commit**

```bash
git add Minute/Services/MeetingStore.swift Minute/App/MinuteApp.swift MinuteTests/MeetingStoreTests.swift
git commit -m "fix: pin data protection on the store files and Recordings, with a class the locked-phone reads survive

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 34: MeetingStore can delete the stranded store and recordings (F68, part 1)

**Files:**
- Modify: `Minute/Services/MeetingStore.swift` (add `resetPersistentStore` after `removeEphemeralRecordings`, currently lines 150-160)
- Test: `MinuteTests/MeetingStoreTests.swift`

**Interfaces:**
- Consumes: `MeetingStore.storeFileNames` and `MeetingStore.recordingsDirectoryName` (both produced by Task 33), the existing `logger`.
- Produces: `@discardableResult static func resetPersistentStore(base: URL? = nil) -> Bool`. Task 36 calls it.

- [ ] **Step 1: Write the failing test**

Add to `MinuteTests/MeetingStoreTests.swift`, inside the struct, after `ephemeralModeRoutesAudioToTemporaryDirectoryAndWipesIt`:

```swift
    /// F68: in fallback mode nothing else can reach these files — the library
    /// the delete paths iterate is the empty in-memory one, and
    /// `recordingsDirectory()` points at the session-only tmp directory — so
    /// this is the only delete path the on-disk audio and transcripts have.
    @Test func resetPersistentStoreRemovesTheStoreFilesAndEveryRecording() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("reset-\(UUID().uuidString)", isDirectory: true)
        let recordings = base.appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = base.appendingPathComponent("default.store")
        let wal = base.appendingPathComponent("default.store-wal")
        let audio = recordings.appendingPathComponent(MeetingStore.newAudioFileName())
        let models = base.appendingPathComponent("WhisperModels", isDirectory: true)
        try Data("db".utf8).write(to: store)
        try Data("wal".utf8).write(to: wal)
        try Data("audio".utf8).write(to: audio)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)

        #expect(MeetingStore.resetPersistentStore(base: base))

        #expect(!FileManager.default.fileExists(atPath: store.path))
        #expect(!FileManager.default.fileExists(atPath: wal.path))
        #expect(!FileManager.default.fileExists(atPath: recordings.path))
        // Downloaded models are not meeting data and cost gigabytes to fetch
        // again; "start over" must not turn into that penalty.
        #expect(FileManager.default.fileExists(atPath: models.path))
    }

    @Test func resetPersistentStoreSucceedsWhenThereIsNothingToRemove() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("reset-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        // A store can fail to open because it was never written. "Nothing to
        // delete" is a successful reset, not a failure to report to the user.
        #expect(MeetingStore.resetPersistentStore(base: base))
    }
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: the suite command with `MeetingStoreTests`.

Expected: the build fails — `type 'MeetingStore' has no member 'resetPersistentStore'`.

- [ ] **Step 3: Implement the reset**

In `Minute/Services/MeetingStore.swift`, directly after `removeEphemeralRecordings()` (which ends at line 160), add:

```swift

    /// Deletes the persistent store and every recording under it, so the next
    /// launch starts from an empty library.
    ///
    /// The only exit from fallback mode. When the persistent container cannot
    /// open, nothing else in the app can reach these files: Settings' Delete
    /// All Meetings iterates the empty in-memory library, and `delete` resolves
    /// audio through `recordingsDirectory()`, which points at the session-only
    /// temporary directory there. So the audio and transcripts on disk would
    /// otherwise sit at rest with no delete path at all — exactly what the
    /// "no data at rest without a delete path" invariant forbids — while the
    /// same failing open repeats at every launch. Removing the files is the
    /// whole operation: SwiftData recreates the store at the next launch, and
    /// this process keeps the in-memory container it already opened, which is
    /// why the caller tells the user to quit and reopen.
    ///
    /// Everything else in Application Support is left alone: downloaded
    /// Whisper and summary models are not meeting data and cost gigabytes to
    /// fetch again. Returns false when something could not be removed, so the
    /// caller can say so rather than promise a clean slate. `base` is a
    /// parameter so tests run against a scratch tree instead of the real
    /// Application Support directory.
    @discardableResult
    static func resetPersistentStore(base: URL? = nil) -> Bool {
        var succeeded = true
        do {
            let root = try base ?? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            var targets = storeFileNames.map { root.appendingPathComponent($0) }
            targets.append(root.appendingPathComponent(recordingsDirectoryName, isDirectory: true))
            for url in targets {
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    logger.error("Resetting the store could not remove \(url.lastPathComponent): \(error.localizedDescription)")
                    succeeded = false
                }
            }
        } catch {
            logger.error("Resetting the store failed: \(error.localizedDescription)")
            succeeded = false
        }
        return succeeded
    }
```

- [ ] **Step 4: Run the suite to verify it passes, then the full unit suite**

Run: the suite command with `MeetingStoreTests`; then the full unit suite command.

Expected: all pass; 308 + 2 = 310 tests.

- [ ] **Step 5: Commit**

```bash
git add Minute/Services/MeetingStore.swift MinuteTests/MeetingStoreTests.swift
git commit -m "feat: add a store reset that deletes the stranded database and recordings

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 35: The launch records why the persistent store could not open (F68, part 2)

**Files:**
- Modify: `Minute/Support/AppSettings.swift:27` (add the key next to `iCloudDriveLastSyncFailedKey`), `Minute/Support/AppSettings.swift:47` (add the accessor after `iCloudDriveLastSyncFailed`)
- Modify: `Minute/App/MinuteApp.swift:21-42` (the container creation in `init`)
- Create: `MinuteTests/AppSettingsStorageFailureTests.swift`

**Interfaces:**
- Consumes: `MeetingStore.modelConfiguration(inMemory:)` (`Minute/Services/MeetingStore.swift:98`), `ModelContainer(for:configurations:)`.
- Produces: `AppSettings.persistentStoreFailureKey: String` (`"storage.persistentStoreFailure"`), `AppSettings.persistentStoreFailure: String?` (get/set, `nil` removes the key). Task 36 reads it.

- [ ] **Step 1: Write the failing test**

Create `MinuteTests/AppSettingsStorageFailureTests.swift`:

```swift
import Foundation
import Testing
@testable import Minute

/// F68: the persistent container's error was discarded by `try?`, so a
/// migration failure that strands the store at every launch was invisible and
/// undiagnosable. It is recorded here, and Settings is the only place the user
/// can act on it.
struct AppSettingsStorageFailureTests {
    @Test func persistentStoreFailureRoundTripsAndClearsOnASuccessfulLaunch() {
        // UserDefaults persist across runs on the simulator; a message left
        // behind here would make Settings offer a destructive reset in a
        // perfectly healthy app.
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: AppSettings.persistentStoreFailureKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: AppSettings.persistentStoreFailureKey)
            } else {
                defaults.removeObject(forKey: AppSettings.persistentStoreFailureKey)
            }
        }

        AppSettings.persistentStoreFailure = "The model configuration is incompatible with the store."
        #expect(AppSettings.persistentStoreFailure == "The model configuration is incompatible with the store.")

        // Every launch writes the outcome, so a store that opens again has to
        // retire the message rather than leave the reset button on screen.
        AppSettings.persistentStoreFailure = nil
        #expect(AppSettings.persistentStoreFailure == nil)
        #expect(defaults.object(forKey: AppSettings.persistentStoreFailureKey) == nil)
    }
}
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: the suite command with `AppSettingsStorageFailureTests`.

Expected: the build fails — `type 'AppSettings' has no member 'persistentStoreFailureKey'`.

- [ ] **Step 3: Add the key and accessor**

In `Minute/Support/AppSettings.swift`, after `iCloudDriveLastSyncFailedKey` (line 27), add:

```swift
    /// Why the persistent meeting store could not be opened at the last
    /// launch, or absent when it opened. Written at every launch — including
    /// the successful one that clears it — because the fallback repeats
    /// identically until the user does something about it, and Settings is
    /// where they can.
    static let persistentStoreFailureKey = "storage.persistentStoreFailure"
```

and after the `iCloudDriveLastSyncFailed` accessor (line 47), add:

```swift

    /// The last launch's persistent-store error, or nil when it opened.
    /// Setting nil removes the key rather than storing an empty string, so
    /// "healthy" and "failed with no message" can't be confused.
    static var persistentStoreFailure: String? {
        get { UserDefaults.standard.string(forKey: persistentStoreFailureKey) }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: persistentStoreFailureKey)
            } else {
                UserDefaults.standard.removeObject(forKey: persistentStoreFailureKey)
            }
        }
    }
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: the suite command with `AppSettingsStorageFailureTests`.

Expected: the one test passes.

- [ ] **Step 5: Record the failure at launch instead of discarding it**

In `Minute/App/MinuteApp.swift`, replace the container creation (lines 21-42):

```swift
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
```

with:

```swift
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
```

- [ ] **Step 6: Run the full unit suite to verify nothing regressed**

Run: the full unit suite command.

Expected: `TEST SUCCEEDED`, 310 + 1 = 311 tests.

- [ ] **Step 7: Commit**

```bash
git add Minute/Support/AppSettings.swift Minute/App/MinuteApp.swift MinuteTests/AppSettingsStorageFailureTests.swift
git commit -m "fix: record why the persistent meeting store failed to open instead of discarding the error

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 36: Fallback mode gets a Storage section that explains and resets (F68, part 3)

**Files:**
- Modify: `Minute/Views/SettingsView.swift:33-38` (view state), `Minute/Views/SettingsView.swift:47-53` (the section gate in `body`), `Minute/Views/SettingsView.swift:104-108` (add the new dialog and alert after the existing ones), `Minute/Views/SettingsView.swift:252-272` (add `fallbackStorageSection` after `storageSection`), `Minute/Views/SettingsView.swift:468-480` (add the action after `deleteAllMeetings`)

**Interfaces:**
- Consumes: `MeetingStore.useEphemeralStorage` (`Minute/Services/MeetingStore.swift:15`), `MeetingStore.resetPersistentStore(base:)` (Task 34), `AppSettings.persistentStoreFailure` (Task 35), the private `settingsLabel(_:systemImage:tint:)` helper (`SettingsView.swift:424`).
- Produces: `SettingsView.fallbackStorageSection` and `resetStoredMeetings()` (both private).

View wiring on top of two already-tested helpers: `resetPersistentStore` is covered by `MeetingStoreTests` (Task 34) and the failure message by `AppSettingsStorageFailureTests` (Task 35). Reaching this section in a test would require a `ModelContainer` that refuses to open. Verified by build plus the full unit suite.

- [ ] **Step 1: Add the view state**

In `Minute/Views/SettingsView.swift`, add after `@State private var mirrorTask: Task<Void, Never>?` (line 38):

```swift
    @State private var confirmingStoreReset = false
    @State private var storeResetFailed = false
    /// Set once the reset has run. The process keeps the in-memory container
    /// it opened at launch, so the library only comes back empty-and-working
    /// after a relaunch — the row says so instead of leaving the user to
    /// wonder why nothing changed.
    @State private var didResetStore = false
```

- [ ] **Step 2: Show the fallback section instead of hiding Storage**

In the same file, replace the section gate (lines 47-53):

```swift
                // In fallback mode the usage figure and local deletion promise
                // would be wrong. Backup controls stay visible because the
                // device-backup choice still governs old persistent data, and
                // the user must be able to turn either privacy setting off.
                if !MeetingStore.useEphemeralStorage {
                    storageSection
                }
```

with:

```swift
                // In fallback mode the usage figure and the local deletion
                // promise would both be wrong — the usage row counts the
                // session-only tmp directory, and Delete All Meetings iterates
                // an empty in-memory library — so that mode gets its own
                // section, which is also the only way out of it. Backup
                // controls stay visible in both: the device-backup choice
                // still governs old persistent data, and the user must be able
                // to turn either privacy setting off.
                if MeetingStore.useEphemeralStorage {
                    fallbackStorageSection
                } else {
                    storageSection
                }
```

- [ ] **Step 3: Add the section**

In the same file, directly after `storageSection` (which ends at line 272), add:

```swift

    /// The way out of fallback mode, and the only delete path the on-disk
    /// audio and transcripts have while it lasts.
    private var fallbackStorageSection: some View {
        Section {
            if let message = AppSettings.persistentStoreFailure {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if didResetStore {
                Label("Quit and reopen Minute to finish.", systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
            } else {
                Button(role: .destructive) {
                    confirmingStoreReset = true
                } label: {
                    settingsLabel("Delete stored meetings and start over", systemImage: "trash", tint: .red)
                        .foregroundStyle(.red)
                }
            }
        } header: {
            Text("Storage")
        } footer: {
            Text("Minute couldn't open its meeting database, so nothing from this session is being saved. Deleting removes that database and every recording still on this iPhone, and the next launch starts with an empty library. This can't be undone.")
        }
    }
```

- [ ] **Step 4: Add the confirmation and the failure alert**

In the same file, directly after the `.alert("Some meetings couldn't be deleted", …)` modifier (which ends at line 108, before the closing `}` of the `NavigationStack`), add:

```swift
            .confirmationDialog(
                "Delete stored meetings and start over?",
                isPresented: $confirmingStoreReset,
                titleVisibility: .visible
            ) {
                Button("Delete and Start Over", role: .destructive) {
                    resetStoredMeetings()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The unreadable meeting database and every recording still on this iPhone will be permanently deleted. This can't be undone.")
            }
            .alert("Couldn't delete the stored meetings", isPresented: $storeResetFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Some files couldn't be removed. Storage may be unavailable — try again later.")
            }
```

- [ ] **Step 5: Add the action**

In the same file, directly after `deleteAllMeetings()` (which ends at line 480), add:

```swift

    /// Fallback mode only. Deletes the unreadable store and the recordings it
    /// stranded; the persistent container is only re-created at the next
    /// launch, so success asks for a relaunch rather than claiming the library
    /// is back.
    private func resetStoredMeetings() {
        if MeetingStore.resetPersistentStore() {
            didResetStore = true
        } else {
            storeResetFailed = true
        }
    }
```

- [ ] **Step 6: Run the full unit suite to verify nothing regressed**

Run: the full unit suite command.

Expected: `TEST SUCCEEDED`, 311 tests (this task adds no test).

- [ ] **Step 7: Commit**

```bash
git add Minute/Views/SettingsView.swift
git commit -m "feat: give the fallback store an exit — show why it failed and offer to delete and start over

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Hand-offs to Track E

None. Every file the fixes in this track touch is owned by this track; no task ends mid-wiring.

### Not done in this track

- **F10 service side.** `TranscriptionService` and `DiarizationService` need `try Task.checkCancellation()` after their awaits so a cancelled job is discarded rather than applied. Those files belong to the engine track, and this track was scoped to the view half (the Stop button, Task 28), so the check is a one-line addition that track must make for the button to be fully honest on the Apple-Speech path — Whisper already honors cancellation.
- **F34's error-classification half.** The finding also suggests `ICloudDriveBackup` treat a data-protection `EPERM` distinctly, so a lock-time failure never sets `iCloudDriveLastSyncFailed` or tells the user to check their iCloud sign-in. That is another track's file and outside the decision this track was given; Task 33 removes the cause, so the misleading banner should stop appearing regardless.
- **Asserting the OS-level protection class in a test.** Verified empirically on "iPhone 17 Pro Max": `setAttributes([.protectionKey: …])` succeeds and `attributesOfItem` then returns `nil` for that key, so a read-back assertion would pass whatever the code did. Task 33 injects the applier and asserts the exact (path, class) pairs the app requests instead.
- **A unit test for the widget debounce (F44).** No helper worth extracting exists — the change is an `onChange` schedule around an already-tested publisher, and asserting a 500 ms window from a test is a timing race. Task 31 states this and is verified by build plus the full suite.

---

## Track F2 — Summaries, backup, knowledge, docs

Fixes F15, F57, F59, F60, F54, F36, F23, F55, F10 (DiarizationService part), F47 (design half), plus the batch-1 follow-ups REPAIR-SPEAKER-ENTITIES and RETRANSCRIBE-INJECTABLE. Tasks 39-49. Simulator: **iPhone Air**.

**Files this track owns** (edit nothing else): `Minute/Services/SummarizationService.swift`, `Minute/Services/ICloudDriveBackup.swift`, `Minute/Services/KnowledgeExtractionService.swift`, `Minute/Services/KnowledgeCatchUp.swift`, `Minute/Services/KnowledgeStore.swift`, `Minute/Services/KnowledgeIngest.swift`, `Minute/Services/MeetingJobs.swift`, `Minute/Services/DiarizationService.swift`, `Minute/Support/KnowledgeText.swift`, `Minute/Support/SpeakerAssignment.swift`, `README.md`, `CONTRIBUTING.md`, `docs/app-store/metadata.md`, `MinuteTests/Summary*Tests.swift`, `MinuteTests/ICloudDriveBackupTests.swift`, `MinuteTests/Knowledge*Tests.swift`, `MinuteTests/SpeakerAssignmentTests.swift`, `MinuteTests/NotesExporterTests.swift`, and new test files for these types.

### Global Constraints

- Privacy invariants from CONTRIBUTING.md hold: no meeting content on the wire; every byte written has a delete path (MeetingStore.delete or the launch sweeps); AI output stays grounded ("Not specified" literal); recording never depends on optional capabilities and any handled failure still offers to save captured audio.
- No new third-party dependencies. Do not edit Minute.xcodeproj/project.pbxproj (new files under Minute/, MinuteTests/, Shared/, MinuteWidgets/ are picked up automatically).
- Unit tests use Swift Testing (import Testing, @Test, #expect, #require), never XCTest. SwiftData-touching test structs are @MainActor with an in-memory container via MeetingStore.modelConfiguration(inMemory: true); containers holding KnowledgeEntity/KnowledgeFact are retained for the process lifetime (retainedContainers pattern in MinuteTests/KnowledgeCatchUpTests.swift).
- The project builds in Swift 5 language mode: an actor-isolated expression cannot be a default argument (use the nil-defaulted injection pattern: `engine: (any Engine)? = nil` then `let engine = engine ?? Engines.current()`).
- Baseline at the branch point (commit 8c443be on main): 292 tests in 43 suites pass. Every task leaves that green plus its own new tests.
- SwiftLint is strict in CI (.swiftlint.yml disables line_length, function/type/file length, cyclomatic_complexity, identifier_name, todo, redundant_optional_initialization, trailing_comma, for_where): match the codebase style — 4-space indent, doc comments that explain WHY, no for…where wrapping side effects. swiftlint is not installed locally.
- Commit messages: Conventional Commits (fix:/test:/docs:), ending with the trailer line "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>". Commit with explicit paths; never git add -A; never commit anything under .superpowers/.
- A task edits only files its track owns (listed below). If a fix genuinely needs a file another track owns, the task ends at the owned side (e.g. adds a hook/property) and the plan section's "Hand-offs to Track E" list names the one-line wiring the post-merge track must do.
- SwiftData fact established in batch 1: after a committed delete an object has isDeleted == false and modelContext == nil; guard stale reads with the PersistentModel `isGone` extension (Minute/Models/PersistentModel+IsGone.swift), never isDeleted.

**Test commands** (from the worktree root `/Users/feihou/workplace/minute/.claude/worktrees/app-code-review-e76404`).

One suite while iterating:

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:MinuteTests/<SuiteName> CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```

Full unit suite once before each commit:

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```

Line numbers below were read from the files at commit `8c443be`. Prefix every shell command with `cd /Users/feihou/workplace/minute/.claude/worktrees/app-code-review-e76404 &&`.

---

### Task 39: Docs — name the hidden markers and the real device-folder name (F54, F36)

Documentation only: nothing here is compiled or unit-testable, so this task is verified by re-reading the edited lines and by the full unit suite staying green.

**Files:**
- Modify: `README.md:42` (privacy table row), `README.md:56-57` (backup comparison table)
- Modify: `docs/app-store/metadata.md:84-95` (Release checks list)

**Interfaces:**
- Consumes: `ICloudDriveBackup` marker prefixes as written today — `minute-` (ICloudDriveBackup.swift:31), `minute-device-` (:32), `minute-notes-` (:34), each written as a dot-prefixed hidden file; `displayName(forDeviceNamed:identity:)` (:189-196) which always renders `"<name-or-iPhone> <4 chars of identity>"`, and `currentDevice()` (:202-218) which feeds it `UIDevice.current.name` — plain `"iPhone"` without the `com.apple.developer.device-information.user-assigned-device-name` entitlement, which `Minute/Minute.entitlements` does not declare.
- Produces: nothing in code.

- [ ] **Step 1: Fix the README backup-table "Where it lands" row**

In `README.md` line 56, replace:

```markdown
| Where it lands | Inside the iPhone's device backup blob — not browsable | `Files → iCloud Drive → Minute → <your iPhone>/<date> <title>/` |
```

with:

```markdown
| Where it lands | Inside the iPhone's device backup blob — not browsable | `Files → iCloud Drive → Minute → iPhone 3F1A/<date> <title>/` — the device folder is always named `iPhone` plus four characters. Showing the name you gave the iPhone needs an Apple entitlement Minute does not hold, so two iPhones appear as two four-character folders |
```

- [ ] **Step 2: Fix the README backup-table "What you see" row**

In `README.md` line 57, replace:

```markdown
| What you see | Nothing in Files; the app appears in Settings → iCloud → iCloud Backup with its size | One folder per meeting containing `notes.md` and the audio file (plus a hidden `.minute-<id>` marker the sync uses to recognize its own folders) |
```

with:

```markdown
| What you see | Nothing in Files; the app appears in Settings → iCloud → iCloud Backup with its size | One folder per meeting containing `notes.md` and the audio file, plus three hidden marker files the sync uses to recognize its own folders: `.minute-<meeting id>` and `.minute-notes-<fingerprint>` in each meeting folder, and `.minute-device-<uuid>` in the device folder. None of them contains meeting content — the fingerprint is a truncated SHA-256 of the notes and the others are identifiers |
```

- [ ] **Step 3: Fix the README privacy-table device-folder path**

In `README.md` line 42, replace the fragment:

```markdown
mirror a browsable per-meeting folder into iCloud Drive (**iCloud Drive Folder**, under `Minute/<this device>/`)
```

with:

```markdown
mirror a browsable per-meeting folder into iCloud Drive (**iCloud Drive Folder**, under `Minute/iPhone <4 characters>/`)
```

- [ ] **Step 4: Record the naming constraint in the App Store release checks**

In `docs/app-store/metadata.md`, after line 88 (`- Confirm the archived app still contains FluidAudio 0.15.5 …`), add this bullet:

```markdown
- The iCloud Drive device folder is named `iPhone` plus four characters (e.g. `iPhone 3F1A`), never the name the user gave the iPhone: that needs the `com.apple.developer.device-information.user-assigned-device-name` entitlement, which Minute does not hold. Support copy, screenshots, and answers to reviewers must not promise a device name.
```

- [ ] **Step 5: Verify the edits read correctly**

Run:

```bash
cd /Users/feihou/workplace/minute/.claude/worktrees/app-code-review-e76404 && sed -n '42p;56,57p' README.md && grep -n "user-assigned-device-name" docs/app-store/metadata.md
```

Expected: the three README lines carry the new text, and the metadata grep prints exactly one line (the new bullet).

- [ ] **Step 6: Run the full unit suite**

Run the full-suite command. Expected: `TEST SUCCEEDED`, 292 tests (docs are not compiled — this is a regression check, not a new-test check).

- [ ] **Step 7: Commit**

```bash
cd /Users/feihou/workplace/minute/.claude/worktrees/app-code-review-e76404 && git add README.md docs/app-store/metadata.md && git commit -m "$(cat <<'EOF'
docs: disclose every hidden mirror marker and the real device-folder name

The README's backup table listed only the .minute-<id> marker, but each
meeting folder also gets .minute-notes-<fingerprint> and the device folder
gets .minute-device-<uuid>. For an app whose README enumerates exactly what
lands in the user's iCloud, that disclosure has to be complete — none of the
three holds meeting content.

The same table promised "<your iPhone>" as the folder name. UIDevice.name
returns a generic "iPhone" without the user-assigned-device-name entitlement,
which Minute does not hold, so the folder is always "iPhone <4 characters>".
Say so, and record the constraint where release copy is written.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 40: Diarization honors cancellation between its stages (F10, DiarizationService part)

`DiarizationService.diarize` needs FluidAudio's CoreML models (downloaded from Hugging Face on first use) and a real audio file, so there is no way to unit-test it here; this task is verified by the build and by the full suite staying green.

**Files:**
- Modify: `Minute/Services/DiarizationService.swift:28-70`

**Interfaces:**
- Consumes: `MeetingJobs.cancel(_:)` (MeetingJobs.swift:76-78) which cancels the job task, and `MeetingJobs.start`'s `catch is CancellationError` (MeetingJobs.swift:188-189) which stays silent for a user-tapped Stop.
- Produces: no new symbols — `diarize(audioAt:onProgress:)` keeps its signature and now throws `CancellationError` when the job was cancelled.

- [ ] **Step 1: Check cancellation after the model-preparation stage**

In `Minute/Services/DiarizationService.swift`, after the first `do/catch` block (currently lines 34-40, ending with the closing `}` of `catch`), insert:

```swift

        // A cancelled job must be discarded rather than applied: MeetingJobs
        // stays silent for a CancellationError and turns anything else into a
        // message. Checked outside the catch above so a Stop tapped during the
        // download is never reported as "the speaker model couldn't be
        // downloaded".
        try Task.checkCancellation()
```

- [ ] **Step 2: Check cancellation after the processing stage**

In the same file, after the second `do/catch` block (currently lines 44-55, ending with the closing `}` of `catch`) and before `var indices: [String: Int] = [:]`, insert:

```swift

        // Same again after the long pass: applying speaker ranges to a meeting
        // the user stopped working on would renumber its transcript behind them.
        try Task.checkCancellation()
```

- [ ] **Step 3: Run the full unit suite**

Run the full-suite command. Expected: `TEST SUCCEEDED`, 292 tests — the file compiles and nothing regressed.

- [ ] **Step 4: Commit**

```bash
cd /Users/feihou/workplace/minute/.claude/worktrees/app-code-review-e76404 && git add Minute/Services/DiarizationService.swift && git commit -m "$(cat <<'EOF'
fix: discard a cancelled diarization instead of applying it

diarize() awaited model preparation and the processing pass without ever
asking whether the job was still wanted, so a Stop tapped mid-run still
renumbered the meeting's speakers when the pass returned. Check cancellation
after each stage, outside the catch blocks, so a cancellation is never
reported as a model-download or processing failure.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 41: normalizedField recognizes the placeholders models actually write (F15)

**Files:**
- Modify: `Minute/Services/SummarizationService.swift:672-679` (the `normalizedField` helper; the run of "shared with the local-model engine" statics around it starts at :664 with `cleaned`)
- Create: `MinuteTests/SummaryPlaceholderTests.swift`

**Interfaces:**
- Consumes: `ActionItem.notSpecified` (`Minute/Models/MeetingSummary.swift:57`, the literal `"Not specified"`); `AppSettings.summaryLanguageOptions` (`Minute/Support/AppSettings.swift:108-111`) = `["English", "Spanish", "French", "German", "Italian", "Portuguese", "Japanese", "Korean", "Chinese"]`. Existing callers that must keep working: `SummarizationService.mechanicallyCombined` (:499, :502), `fieldsConflict` (:533-534), `normalized()` on generated items (:627-628), and `MLXSummarizationService.swift:741-742` (not owned here — read-only dependency on the same static).
- Produces: `SummarizationService.normalizedField(_:) -> String` (unchanged signature, widened behavior); private `SummarizationService.isPlaceholder(_:) -> Bool`, private `placeholders: Set<String>`, private `placeholderTrimming: CharacterSet`.

- [ ] **Step 1: Write the failing test**

Create `MinuteTests/SummaryPlaceholderTests.swift`:

```swift
import Foundation
import Testing
@testable import Minute

/// The "Not specified" contract. Both engines funnel owner/deadline through
/// SummarizationService.normalizedField, and it is the only thing standing
/// between a model that paraphrased the literal it was told to write and a
/// detail caption (or an exported notes.md) that reads as if someone named
/// "TBD" owned the task.
struct SummaryPlaceholderTests {
    @Test func realValuesSurviveNormalization() {
        #expect(SummarizationService.normalizedField("  Maria  ") == "Maria")
        #expect(SummarizationService.normalizedField("Friday") == "Friday")
        // A real name that merely contains a placeholder word is a real name.
        #expect(SummarizationService.normalizedField("Nobody Jones") == "Nobody Jones")
        #expect(SummarizationService.normalizedField("None of the above team") == "None of the above team")
    }

    @Test func englishPlaceholdersBecomeTheLiteral() {
        let values = [
            "", "   ", "Not specified", "not specified.", "NONE", "unknown",
            "N/A", "n/a.", "na", "TBD", "tba", "Unspecified", "Not stated",
            "not mentioned", "Not given", "not assigned", "Nobody", "no one",
            "No owner", "no deadline", "not applicable", "to be determined",
            "-", "—", "…", "\"Not specified\"",
        ]
        for value in values {
            #expect(SummarizationService.normalizedField(value) == ActionItem.notSpecified, "\(value)")
        }
    }

    @Test func localizedPlaceholdersBecomeTheLiteral() {
        // One per Summary Language option, in the order the picker lists them:
        // a language override makes the model answer in that language, and its
        // placeholder comes along.
        let values = [
            "Not specified",     // English
            "No especificado",   // Spanish
            "Non spécifié",      // French
            "Nicht angegeben",   // German
            "Non specificato",   // Italian
            "Não especificado",  // Portuguese
            "未定",               // Japanese
            "미정",               // Korean
            "待定",               // Chinese
        ]
        #expect(values.count == AppSettings.summaryLanguageOptions.count)
        for value in values {
            #expect(SummarizationService.normalizedField(value) == ActionItem.notSpecified, "\(value)")
        }
        // Wrapped in the punctuation a model likes to add.
        #expect(SummarizationService.normalizedField("「未定」") == ActionItem.notSpecified)
        #expect(SummarizationService.normalizedField("Sin asignar.") == ActionItem.notSpecified)
    }
}
```

- [ ] **Step 2: Run the suite to verify it fails**

Run the one-suite command with `SummaryPlaceholderTests`.
Expected: `realValuesSurviveNormalization` passes; `englishPlaceholdersBecomeTheLiteral` fails on the first widened spelling (`"not specified."` — the trailing period is not stripped today, so the value comes back verbatim); `localizedPlaceholdersBecomeTheLiteral` fails on `"No especificado"`.

- [ ] **Step 3: Widen the normalizer**

In `Minute/Services/SummarizationService.swift`, replace the whole `normalizedField` helper (lines 672-679):

```swift
    /// Shared with the local-model engine so both honor one output contract.
    static func normalizedField(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.lowercased() == "not specified" || trimmed.lowercased() == "none" || trimmed.lowercased() == "unknown" {
            return ActionItem.notSpecified
        }
        return trimmed
    }
```

with:

```swift
    /// Shared with the local-model engine so both honor one output contract.
    ///
    /// The model is told to write the exact literal when an owner or deadline
    /// was never stated (groundingRules, the @Guide text, and the same rules
    /// reused by the MLX engine), so anything else is the model disobeying —
    /// which the free-form-JSON local engine does, and which a Summary Language
    /// makes more likely still because the placeholder gets translated too.
    /// Whatever only means "nobody said" has to land on the literal, or the
    /// detail caption and the exported notes present it as a real owner.
    static func normalizedField(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return isPlaceholder(trimmed) ? ActionItem.notSpecified : trimmed
    }

    /// Punctuation and quote marks a model wraps a placeholder in, trimmed off
    /// both ends before matching so "Not specified.", "「未定」" and "-" all
    /// reduce to something the set below can answer.
    private static let placeholderTrimming = CharacterSet(
        charactersIn: " \t.。!?！？,、;:；：\"'“”‘’「」『』()（）[]{}-–—_…"
    )

    /// Spellings of "we don't know" this normalizer maps to the literal. The
    /// non-English entries cover every AppSettings.summaryLanguageOptions
    /// value; matching is on the lowercased, punctuation-stripped form, so
    /// only one casing of each needs listing.
    private static let placeholders: Set<String> = [
        // English
        "not specified", "none", "unknown", "n/a", "na", "tbd", "tba",
        "unspecified", "not stated", "not mentioned", "not given",
        "not assigned", "not applicable", "nobody", "no one", "no owner",
        "no deadline", "to be determined",
        // Spanish
        "no especificado", "no especificada", "sin especificar", "ninguno",
        "ninguna", "desconocido", "nadie", "sin asignar", "sin responsable",
        "sin fecha", "por determinar",
        // French
        "non spécifié", "non spécifiée", "non précisé", "aucun", "aucune",
        "inconnu", "personne", "non attribué", "sans responsable",
        "sans échéance", "à déterminer",
        // German
        "nicht angegeben", "nicht spezifiziert", "kein", "keine", "keiner",
        "unbekannt", "niemand", "nicht zugewiesen", "ohne frist",
        // Italian
        "non specificato", "non specificata", "nessuno", "nessuna",
        "sconosciuto", "non assegnato", "da definire", "senza scadenza",
        // Portuguese
        "não especificado", "não especificada", "nenhum", "nenhuma",
        "desconhecido", "ninguém", "não atribuído", "a definir", "sem prazo",
        // Japanese and Chinese share these spellings
        "未指定", "未定", "不明",
        // Japanese
        "なし", "指定なし", "未割り当て", "担当者なし", "期限なし",
        // Korean
        "지정되지 않음", "미지정", "미정", "알 수 없음", "없음", "담당자 없음", "기한 없음",
        // Chinese
        "待定", "未知", "无", "無", "暂无", "暫無", "未指明", "无负责人", "无截止日期",
    ]

    private static func isPlaceholder(_ value: String) -> Bool {
        let stripped = value.lowercased().trimmingCharacters(in: placeholderTrimming)
        // Empty, or nothing but punctuation ("-", "—", "…"): no answer either way.
        guard !stripped.isEmpty else { return true }
        return placeholders.contains(stripped)
    }
```

- [ ] **Step 4: Run the suite to verify it passes**

Run the one-suite command with `SummaryPlaceholderTests`. Expected: 3 tests pass.

- [ ] **Step 5: Run the full unit suite**

Run the full-suite command. Expected: `TEST SUCCEEDED`, 295 tests (292 + 3). `SummaryFallbackTests.combinePrefersActionItemCopyWithOwnerAndDeadline` still passes — it feeds the literal `"Not specified"`, which was already normalized before this change.

- [ ] **Step 6: Commit**

```bash
cd /Users/feihou/workplace/minute/.claude/worktrees/app-code-review-e76404 && git add Minute/Services/SummarizationService.swift MinuteTests/SummaryPlaceholderTests.swift && git commit -m "$(cat <<'EOF'
fix: treat every "we don't know" spelling as the Not specified literal

normalizedField is the only post-generation guard on the grounding contract
for both engines, but it recognized four spellings. A local model that writes
"TBD", "N/A", "Not specified." or — with a Summary Language set — the
translated placeholder therefore reached the detail caption and notes.md as a
real owner or deadline.

Strip trailing punctuation and quotes, then match a placeholder set that
covers the common English variants and one for every Summary Language option.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 42: hintNames ranks whole names above token matches (F60)

**Files:**
- Modify: `Minute/Support/KnowledgeText.swift:12-14` (add `inOrder` next to `normalized`)
- Modify: `Minute/Services/KnowledgeExtractionService.swift:138-152` (`hintCap`, `hintNames`)
- Test: `MinuteTests/KnowledgeTextTests.swift`, `MinuteTests/KnowledgeExtractionServiceTests.swift`

**Interfaces:**
- Consumes: `KnowledgeText.normalized(_:) -> String` (KnowledgeText.swift:12-14, token-**sorted**) and the private order-preserving `tokens(_:)` (:75-80); `KnowledgeExtractionService.hintCap = 20` (:140); the only caller, `extractChunk` (:121).
- Produces: `KnowledgeText.inOrder(_ text: String) -> String`; `KnowledgeExtractionService.minimumHintTokenLength = 3`; `hintNames(for:from:)` keeps its signature `(String, [String]) -> [String]` and now returns full-phrase matches first.

`KnowledgeText.inOrder` lands first, in its own red-green pair: it is referenced by the extraction tests, and a missing member fails the whole MinuteTests build, so the hintNames assertions could not be observed failing while it is absent.

- [ ] **Step 1: Write the failing KnowledgeText test**

In `MinuteTests/KnowledgeTextTests.swift`, add after `normalizedFoldsCaseDiacriticsAndTokenOrder` (ends line 9):

```swift

    @Test func inOrderKeepsWritingOrderWhileNormalizedSorts() {
        // Hint matching needs adjacency: after sorting, the two words of a
        // name sit next to each other only by accident of the alphabet.
        #expect(KnowledgeText.inOrder("Zhang, Wei") == "zhang wei")
        #expect(KnowledgeText.normalized("Zhang, Wei") == "wei zhang")
        #expect(KnowledgeText.inOrder("  Atlas   Redesign! ") == "atlas redesign")
    }
```

- [ ] **Step 2: Run the suite to verify it fails**

Run the one-suite command with `KnowledgeTextTests`.
Expected: a build failure — `type 'KnowledgeText' has no member 'inOrder'`.

- [ ] **Step 3: Add the order-preserving normalizer**

In `Minute/Support/KnowledgeText.swift`, directly after `normalized(_:)` (ends line 14), insert:

```swift

    /// The same normalization with the tokens left in the order they were
    /// written. `normalized` sorts, which is what dedup wants and what a
    /// phrase match cannot use: after sorting, the two words of a name are
    /// adjacent only by accident of the alphabet.
    static func inOrder(_ text: String) -> String {
        tokens(text).joined(separator: " ")
    }
```

- [ ] **Step 4: Run the suite to verify it passes**

Run the one-suite command with `KnowledgeTextTests`. Expected: 6 tests pass.

- [ ] **Step 5: Write the failing hintNames tests**

In `MinuteTests/KnowledgeExtractionServiceTests.swift`, replace `hintNamesKeepsOnlyNamesAppearingInChunkCappedAt20` (lines 6-18) with:

```swift
    @Test func hintNamesKeepsOnlyNamesAppearingInChunkCappedAt20() {
        let chunk = "[00:01] Sarah: Atlas is on track. Bob is out this week."
        let names = ["Sarah Chen", "Atlas", "Mercury", "Bob"]
        let hints = KnowledgeExtractionService.hintNames(for: chunk, from: names)
        #expect(hints.contains("Atlas"))
        #expect(hints.contains("Bob"))
        // "Chen" is nowhere in this chunk, so "Sarah Chen" is a different name
        // that happens to share a token. Offering it invites the model to
        // relabel this meeting's Sarah as someone else.
        #expect(!hints.contains("Sarah Chen"))
        #expect(!hints.contains("Mercury"))

        let many = (0..<50).map { "Sarah \($0)" }
        #expect(KnowledgeExtractionService.hintNames(for: "Sarah spoke", from: many).count == 20)
    }

    @Test func namesSpokenInFullOutrankPartialMatchesWithinTheCap() {
        let chunk = "[00:03] Sarah Chen: the Atlas Program ships at the end of Q3."
        // 25 roster entries whose every long token is in the chunk, and the one
        // name actually spoken sorted last: truncation alone would drop it and
        // the model would write "Sarah", which resolution cannot match.
        let names = (0..<25).map { "Atlas Program \($0)" } + ["Sarah Chen"]
        let hints = KnowledgeExtractionService.hintNames(for: chunk, from: names)

        #expect(hints.first == "Sarah Chen")
        #expect(hints.count == 20)
    }

    @Test func aNameSharingOneCommonTokenIsNotAHint() {
        let chunk = "[00:03] Sarah Chen: the Atlas Program ships at the end of Q3."
        // "the" is in every chunk ever spoken; matching on it is what let
        // common-word entity names crowd out the names actually present.
        // "state" and "union" are absent, so every-long-token fails too.
        #expect(KnowledgeExtractionService.hintNames(for: chunk, from: ["State of the Union"]).isEmpty)
        // Every long token present, in any order: still the same entity.
        #expect(KnowledgeExtractionService.hintNames(for: "Chen, Sarah joined", from: ["Sarah Chen"]) == ["Sarah Chen"])
        // "A/B Testing" normalizes to "a b testing", which this chunk does not
        // contain as a phrase. It is hinted through the token path, where the
        // one-character "a" and "b" are below the floor and "testing" — its
        // only token that carries meaning on its own — is present.
        #expect(KnowledgeExtractionService.hintNames(for: "we ran a testing pass", from: ["A/B Testing"]) == ["A/B Testing"])
    }
```

- [ ] **Step 6: Run the suite to verify it fails**

Run the one-suite command with `KnowledgeExtractionServiceTests`.
Expected: three failures — `#expect(!hints.contains("Sarah Chen"))` (today any single token matches), `hints.first == "Sarah Chen"` (no ranking today, so the fetch order wins and the cap drops it), and `State of the Union` coming back on the token "the".

- [ ] **Step 7: Rank the hints instead of truncating them**

In `Minute/Services/KnowledgeExtractionService.swift`, replace lines 138-152:

```swift
    /// Only names that lexically appear in this chunk ride in the prompt —
    /// the roster lives in the app, never in the context window (spec §2).
    static let hintCap = 20

    static func hintNames(for chunk: String, from names: [String]) -> [String] {
        let haystack = " " + KnowledgeText.normalized(chunk) + " "
        return Array(
            names.filter { name in
                KnowledgeText.normalized(name)
                    .split(separator: " ")
                    .contains { haystack.contains(" \($0) ") }
            }
            .prefix(hintCap)
        )
    }
```

with:

```swift
    /// Only names that lexically appear in this chunk ride in the prompt —
    /// the roster lives in the app, never in the context window (spec §2).
    static let hintCap = 20

    /// Tokens shorter than this ("the" is three, but "of", "a", "b", "q3" are
    /// not) prove nothing on their own: a roster name is offered only when the
    /// chunk holds the whole phrase, or every token of it long enough to mean
    /// something.
    static let minimumHintTokenLength = 3

    /// Hints in match-strength order — the name spoken in full first, then
    /// names whose every long token appears — so `hintCap` cuts the weakest
    /// matches rather than whichever names the fetch happened to return last.
    /// Without this, twenty roster names sharing an ordinary word with the
    /// chunk could push out the one name actually said, and the model would
    /// invent a second spelling that resolution cannot match.
    static func hintNames(for chunk: String, from names: [String]) -> [String] {
        let haystack = " " + KnowledgeText.inOrder(chunk) + " "
        var phrases: [String] = []
        var partials: [String] = []
        for name in names {
            let normalized = KnowledgeText.inOrder(name)
            guard !normalized.isEmpty else { continue }
            if haystack.contains(" \(normalized) ") {
                phrases.append(name)
                continue
            }
            let tokens = normalized
                .split(separator: " ")
                .filter { $0.count >= minimumHintTokenLength }
            guard !tokens.isEmpty else { continue }
            if tokens.allSatisfy({ haystack.contains(" \($0) ") }) {
                partials.append(name)
            }
        }
        return Array((phrases + partials).prefix(hintCap))
    }
```

- [ ] **Step 8: Run the suite to verify it passes**

Run the one-suite command with `KnowledgeExtractionServiceTests`. Expected: 6 tests pass.

- [ ] **Step 9: Run the full unit suite**

Run the full-suite command. Expected: `TEST SUCCEEDED`, 298 tests (295 + 3).

- [ ] **Step 10: Commit**

```bash
cd /Users/feihou/workplace/minute/.claude/worktrees/app-code-review-e76404 && git add Minute/Support/KnowledgeText.swift Minute/Services/KnowledgeExtractionService.swift MinuteTests/KnowledgeTextTests.swift MinuteTests/KnowledgeExtractionServiceTests.swift && git commit -m "$(cat <<'EOF'
fix: offer entity hints by match strength instead of fetch order

A roster name was hinted when ANY token of it appeared in the chunk, so
entities named after ordinary words ("The Atlas Program", "State of the
Union") matched every chunk and the 20-slot cap dropped the name actually
spoken — leaving the model to write "Sarah" where the store holds "Sarah
Chen", which resolution cannot match, and a duplicate entity to review.

Require the whole phrase or every token of at least three characters, and
rank whole-phrase matches first so the cap trims the weakest hints. Adds
KnowledgeText.inOrder because the existing normalizer sorts tokens and so
cannot answer a phrase question.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 43: Launch reconcile removes entities named after a diarization placeholder (REPAIR-SPEAKER-ENTITIES)

**Files:**
- Modify: `Minute/Services/KnowledgeStore.swift:109-139` (the doomed-entity pass in `reconcileStore`)
- Test: `MinuteTests/KnowledgeDeletionTests.swift`

**Interfaces:**
- Consumes: `KnowledgeExtractionService.isSpeakerPlaceholder(_ name: String) -> Bool` (KnowledgeExtractionService.swift:162-164, anchored case-insensitive regex `^\s*speaker\s+\d+\s*$`); `KnowledgeStore.reconcile(context:) -> Bool` (:28-31); `KnowledgeEntity.facts` with `@Relationship(deleteRule: .cascade)` (Minute/Models/KnowledgeEntity.swift:26-27), which takes a doomed entity's facts with it.
- Produces: no new symbols — `reconcile` gains one clause.

- [ ] **Step 1: Write the failing test**

In `MinuteTests/KnowledgeDeletionTests.swift`, add after `launchReconcileRemovesAnEntityLeftWithNoFacts` (ends line 243):

```swift

    @Test func launchReconcileRemovesEntitiesNamedAfterADiarizationPlaceholder() throws {
        let context = try makeContext()
        let meeting = Meeting(title: "Standup")
        context.insert(meeting)
        // Written by a build from before the extractor filtered the label out.
        let placeholder = KnowledgeEntity(name: "Speaker 2", kind: .person)
        let real = KnowledgeEntity(name: "Priya", kind: .person)
        context.insert(placeholder)
        context.insert(real)
        addFact("Owns the Japan launch", to: placeholder, from: meeting, context: context)
        addFact("Owns the Japan launch", to: real, from: meeting, context: context)
        try context.save()

        // "Speaker 2" is a different person in every meeting, so a page under
        // that name mixes strangers. It goes with its facts even though the
        // meeting that produced them is still here.
        #expect(KnowledgeStore.reconcile(context: context))

        #expect(try entities(in: context).map(\.name) == ["Priya"])
        #expect(try facts(in: context).count == 1)
    }

    @Test func launchReconcileKeepsARealNameThatMerelyStartsWithSpeaker() throws {
        let context = try makeContext()
        let meeting = Meeting(title: "Standup")
        context.insert(meeting)
        let person = KnowledgeEntity(name: "Speaker Chen", kind: .person)
        context.insert(person)
        addFact("Runs the reading group", to: person, from: meeting, context: context)
        try context.save()

        #expect(KnowledgeStore.reconcile(context: context))

        // Only the numbered diarization label is a placeholder.
        #expect(try entities(in: context).map(\.name) == ["Speaker Chen"])
    }
```

- [ ] **Step 2: Run the suite to verify it fails**

Run the one-suite command with `KnowledgeDeletionTests`.
Expected: `launchReconcileRemovesEntitiesNamedAfterADiarizationPlaceholder` fails on `entities(in: context).map(\.name) == ["Priya"]` (actual `["Speaker 2", "Priya"]` in some order); `launchReconcileKeepsARealNameThatMerelyStartsWithSpeaker` already passes.

- [ ] **Step 3: Doom placeholder-named entities during reconcile**

In `Minute/Services/KnowledgeStore.swift`, immediately before `settleInboundRedirects(to: &doomed, among: allEntities, removedIDs: removedIDs)` (line 136), insert:

```swift
        // Historical stores hold person entities named "Speaker 3": extraction
        // learned only later that a diarization placeholder is a different
        // person in every meeting, so one page mixes strangers. They go the way
        // of any doomed entity — the cascade takes their facts — and nothing
        // recreates them, because the extractor now drops the name before it
        // can reach ingest.
        for entity in allEntities where KnowledgeExtractionService.isSpeakerPlaceholder(entity.name) {
            doomed[entity.id] = entity
        }
```

- [ ] **Step 4: Run the suite to verify it passes**

Run the one-suite command with `KnowledgeDeletionTests`. Expected: 25 tests pass, including the two new ones.

- [ ] **Step 5: Run the full unit suite**

Run the full-suite command. Expected: `TEST SUCCEEDED`, 300 tests (298 + 2).

- [ ] **Step 6: Commit**

```bash
cd /Users/feihou/workplace/minute/.claude/worktrees/app-code-review-e76404 && git add Minute/Services/KnowledgeStore.swift MinuteTests/KnowledgeDeletionTests.swift && git commit -m "$(cat <<'EOF'
fix: retire Brain entities named after a diarization placeholder

Stores written before the extractor filtered "Speaker N" out still hold person
entities under that name, and "Speaker 2" is a different person in every
meeting — so the page mixes strangers and every new meeting adds more. The
launch reconcile now dooms them; their facts go with them through the existing
cascade, and the extractor's filter keeps them from coming back.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 44: Re-transcription takes an injectable engine, and its empty-pass behavior gets a test (RETRANSCRIBE-INJECTABLE)

**Files:**
- Modify: `Minute/Services/MeetingJobs.swift:122-151` (`retranscribe`)
- Test: `MinuteTests/SummaryGenerationTests.swift`

**Interfaces:**
- Consumes: `TranscriptionEngine` protocol (Minute/Services/TranscriptionEngine.swift:26-56: `availability`, `volatileText`, `segments`, `timestampOffset`, `prepare()`, `start(inputFormat:)`, `finish()`, `cancel()`, `transcribe(file:)`); `TranscriptionEngines.current() -> any TranscriptionEngine` (:59-66); `MeetingJobs.noTextMessage(keptExistingTranscript:)` (MeetingJobs.swift:244-250); the same nil-defaulted pattern already used by `AudioImporter.importAudio(from:context:transcription:)` (AudioImporter.swift:46-51).
- Produces: `MeetingJobs.retranscribe(_ meeting: Meeting, audioAt url: URL, transcription: (any TranscriptionEngine)? = nil) -> Task<Void, Never>?` — existing two-argument call sites keep compiling.

- [ ] **Step 1: Write the failing test**

In `MinuteTests/SummaryGenerationTests.swift`, change the import block (lines 1-4) to:

```swift
import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import Minute
```

and add inside the struct, after `makeMeeting()` (ends line 18):

```swift

    /// Half a second of silence, written as a real WAV file — re-transcription
    /// opens the audio with AVAudioFile before it ever reaches the engine.
    private func makeWavFixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("retranscribe-fixture-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000)!
        buffer.frameLength = 8_000
        try file.write(from: buffer)
        return url
    }

    /// An engine that is "available" and recognizes nothing — audio in a
    /// language the device isn't set to, or plain silence.
    @MainActor
    private final class EmptyTranscriptionEngine: TranscriptionEngine {
        var availability: TranscriptionAvailability = .available
        var volatileText = ""
        var segments: [TranscriptSegment] = []
        var timestampOffset: TimeInterval = 0
        func prepare() async {}
        func start(inputFormat: AVAudioFormat) async -> (@Sendable (AVAudioPCMBuffer) -> Void)? { nil }
        func finish() async -> [TranscriptSegment] { [] }
        func cancel() async {}
        func transcribe(file: AVAudioFile) async throws -> [TranscriptSegment] { [] }
    }
```

and add this test at the end of the struct, after `noTextMessageSaysWhetherTheOldTranscriptWasKept` (ends line 120):

```swift

    @Test func retranscriptionThatRecognizedNothingReportsInsteadOfApplying() async throws {
        let (container, meeting) = try makeMeeting()
        defer { _ = container }
        let source = try makeWavFixture()
        defer { try? FileManager.default.removeItem(at: source) }
        let jobs = MeetingJobs()

        await jobs.retranscribe(meeting, audioAt: source, transcription: EmptyTranscriptionEngine())?.value

        // An empty pass must never be mistaken for "this meeting has no
        // speech": the user hears why, and nothing is written over.
        let message = try #require(jobs.error(.transcription, for: meeting))
        #expect(message.contains("produced no text"))
        #expect(meeting.segments.isEmpty)
        #expect(!jobs.isBusy(meeting))
    }
```

- [ ] **Step 2: Run the suite to verify it fails**

Run the one-suite command with `SummaryGenerationTests`.
Expected: a build failure — `extra argument 'transcription' in call` on `jobs.retranscribe(meeting, audioAt: source, transcription:)`.

- [ ] **Step 3: Make the engine injectable**

In `Minute/Services/MeetingJobs.swift`, replace lines 122-126:

```swift
    @discardableResult
    func retranscribe(_ meeting: Meeting, audioAt url: URL) -> Task<Void, Never>? {
        start(.transcription, for: meeting) {
            let transcription = TranscriptionEngines.current()
            await transcription.prepare()
```

with:

```swift
    /// `transcription` is injectable for tests; it defaults to nil rather than
    /// to `TranscriptionEngines.current()` because a default argument is
    /// evaluated outside this type's main-actor isolation (same pattern as
    /// AudioImporter.importAudio).
    @discardableResult
    func retranscribe(
        _ meeting: Meeting,
        audioAt url: URL,
        transcription: (any TranscriptionEngine)? = nil
    ) -> Task<Void, Never>? {
        start(.transcription, for: meeting) {
            let transcription = transcription ?? TranscriptionEngines.current()
            await transcription.prepare()
```

- [ ] **Step 4: Run the suite to verify it passes**

Run the one-suite command with `SummaryGenerationTests`. Expected: 8 tests pass, including the new one.

- [ ] **Step 5: Run the full unit suite**

Run the full-suite command. Expected: `TEST SUCCEEDED`, 301 tests (300 + 1).

- [ ] **Step 6: Commit**

```bash
cd /Users/feihou/workplace/minute/.claude/worktrees/app-code-review-e76404 && git add Minute/Services/MeetingJobs.swift MinuteTests/SummaryGenerationTests.swift && git commit -m "$(cat <<'EOF'
test: cover the empty re-transcription path with an injectable engine

retranscribe built TranscriptionEngines.current() internally, so the rule that
a pass producing no text is reported rather than applied had no end-to-end
test. Give it the same nil-defaulted injection AudioImporter has (a default
argument cannot be actor-isolated) and pin the behavior with a fake engine
that recognizes nothing.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 45: MeetingJobs announces that user-initiated work started (F55)

**Files:**
- Modify: `Minute/Services/MeetingJobs.swift:49-52` (callbacks), `:172-201` (`start`)
- Test: `MinuteTests/SummaryGenerationTests.swift`

**Interfaces:**
- Consumes: `MeetingJobs.start(_:for:_:)` (MeetingJobs.swift:172-201) and its existing `onContentChanged` callback (:52, fired at :187).
- Produces: `MeetingJobs.onWorkStarted: (@MainActor () -> Void)?` — fired once per job actually started, before the job task begins. Track E wires it to `catchUp.pauseForWork()` (Task 46).

- [ ] **Step 1: Write the failing test**

In `MinuteTests/SummaryGenerationTests.swift`, add at the end of the struct:

```swift

    @Test func startingAJobAnnouncesThatUserWorkBegan() async throws {
        let (container, meeting) = try makeMeeting()
        defer { _ = container }
        let jobs = MeetingJobs()

        var started = 0
        jobs.onWorkStarted = { started += 1 }

        let task = jobs.summarize(meeting, template: .standard, context: "", language: nil)
        // Fired before the work runs: the knowledge catch-up loop has to stop
        // competing for the on-device model with the summary the user is
        // watching, not learn about it once the summary is over.
        #expect(started == 1)

        // Re-entering the screen attaches to the running job; that is not new
        // work and must not fire again.
        jobs.summarize(meeting, template: .standard, context: "", language: nil)
        #expect(started == 1)

        await task?.value
        #expect(started == 1)
    }
```

- [ ] **Step 2: Run the suite to verify it fails**

Run the one-suite command with `SummaryGenerationTests`.
Expected: a build failure — `value of type 'MeetingJobs' has no member 'onWorkStarted'`.

- [ ] **Step 3: Add the hook**

In `Minute/Services/MeetingJobs.swift`, after the `onContentChanged` declaration (line 52), insert:

```swift

    /// Fired on the main actor when a job actually starts, before its work
    /// begins — the knowledge catch-up loop's work pause. Extraction and a
    /// user-tapped summary otherwise issue FoundationModels requests against
    /// the same on-device model at the same time, which is exactly the
    /// competition the README promises the Brain avoids. Optional so tests and
    /// previews can leave it unset.
    var onWorkStarted: (@MainActor () -> Void)?
```

In the same file, in `start(_:for:_:)`, replace lines 178-183:

```swift
        let id = meeting.id
        if let running = running[id] { return running.task }
        failures[id] = nil
        // Keep the app awake through brief app switches so the work isn't
        // suspended part-way through.
        let token = BackgroundTaskToken(name: "MeetingJobs")
```

with:

```swift
        let id = meeting.id
        if let running = running[id] { return running.task }
        failures[id] = nil
        // Before the task, not inside it: whatever yields to user-initiated
        // work has to have yielded by the time the first request goes out.
        onWorkStarted?()
        // Keep the app awake through brief app switches so the work isn't
        // suspended part-way through.
        let token = BackgroundTaskToken(name: "MeetingJobs")
```

- [ ] **Step 4: Run the suite to verify it passes**

Run the one-suite command with `SummaryGenerationTests`. Expected: 9 tests pass.

- [ ] **Step 5: Run the full unit suite**

Run the full-suite command. Expected: `TEST SUCCEEDED`, 302 tests (301 + 1).

- [ ] **Step 6: Commit**

```bash
cd /Users/feihou/workplace/minute/.claude/worktrees/app-code-review-e76404 && git add Minute/Services/MeetingJobs.swift MinuteTests/SummaryGenerationTests.swift && git commit -m "$(cat <<'EOF'
feat: announce when a user-initiated job starts

The coupling between MeetingJobs and the knowledge catch-up loop ran one way:
a finished job nudged the loop, but a starting job did nothing, so extraction
kept issuing FoundationModels requests alongside the summary the user was
waiting on. Add an onWorkStarted hook fired before the job task begins; the
app wires it to the loop's work pause.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 46: Two pauses — the scene's, which only a resume lifts, and a job's, which the next nudge lifts (F23, F55)

The loop has two reasons to stop and they expire differently. A **scene** pause means the app is not foreground: extraction must stay stopped no matter who nudges, because a job finishing in the background nudges too (`MeetingJobs.onContentChanged`) and there is no keep-alive once that job's token ends. A **work** pause means a user-initiated job just took the on-device model: extraction gets out of the way, but the very next nudge — normally that job's own completion callback — brings it back, or the first summary of a session would silence the Brain for the rest of it.

**Files:**
- Modify: `Minute/Services/KnowledgeCatchUp.swift:25-39` (state), `:82-111` (`nudge`, `pause`)
- Test: `MinuteTests/KnowledgeCatchUpTests.swift:283-392` (three existing pause tests), plus two new tests

**Interfaces:**
- Consumes: `KnowledgeCatchUp.nudge(context:)` (KnowledgeCatchUp.swift:82-100), `pause()` (:102-111), `restartRequested` (:32), `running` (:25), `waitUntilIdle()` (:113-119).
- Produces: `KnowledgeCatchUp.pauseForWork()`; `KnowledgeCatchUp.resume(context: ModelContext)`; private `pausedByScene: Bool`, private `pausedByWork: Bool`, private `isPaused: Bool` (read by `nudge` here and by Task 48's automatic restarts), private `lastContext: ModelContext?`, private `stopLoop()`. Track E switches the app's `.active` branch from `nudge` to `resume` and points `jobs.onWorkStarted` at `pauseForWork`.

- [ ] **Step 1: Write the failing tests**

In `MinuteTests/KnowledgeCatchUpTests.swift`, add after `pendingCountStaysAccurateWhenQueueIsFullySkipListed` (ends line 464):

```swift

    @Test func aNudgeWhileTheSceneIsPausedStartsNothingUntilResume() async throws {
        let context = try makeContext()
        let meeting = meetingWithTranscript("Only", createdAt: .now)
        context.insert(meeting)
        try context.save()

        var calls = 0
        let catchUp = makeCatchUp { _, _ in calls += 1; return [] }
        catchUp.pause()

        // A job finishing after the app left the foreground nudges the loop.
        // Extraction is foreground-only — there is no keep-alive once the job's
        // token ends — so this must record the context and start nothing.
        catchUp.nudge(context: context)
        await catchUp.waitUntilIdle()
        #expect(calls == 0)
        #expect(meeting.knowledgeExtractedAt == nil)

        // The scene coming back is what starts reading again.
        catchUp.resume(context: context)
        await catchUp.waitUntilIdle()
        #expect(calls == 1)
        #expect(meeting.knowledgeExtractedAt != nil)
    }

    @Test func aNudgeAfterAJobPausedTheLoopStartsItAgain() async throws {
        let context = try makeContext()
        let meeting = meetingWithTranscript("Only", createdAt: .now)
        context.insert(meeting)
        try context.save()

        var calls = 0
        let catchUp = makeCatchUp { _, _ in calls += 1; return [] }
        // A summary the user asked for takes the on-device model. Unlike a
        // scene pause this one expires on the next nudge — the job's own
        // completion callback — or the first job of a foreground session would
        // stop the Brain until the user backgrounded the app and came back.
        catchUp.pauseForWork()
        catchUp.nudge(context: context)
        await catchUp.waitUntilIdle()

        #expect(calls == 1)
        #expect(meeting.knowledgeExtractedAt != nil)
    }
```

- [ ] **Step 2: Run the suite to verify it fails**

Run the one-suite command with `KnowledgeCatchUpTests`.
Expected: a build failure — `value of type 'KnowledgeCatchUp' has no member 'resume'` and `… has no member 'pauseForWork'`.

- [ ] **Step 3: Add the two pause flags and the remembered context**

In `Minute/Services/KnowledgeCatchUp.swift`, after the `restartRequested` declaration (line 32), insert:

```swift
    /// True between `pause()` and `resume(context:)` — the app is not
    /// foreground. The loop is foreground-only (spec §5): FoundationModels
    /// rate-limits background apps, and once a finished job's background token
    /// ends the app is suspended mid-request. Only the scene coming back lifts
    /// this, so a job that completes in the background cannot restart reading
    /// there by nudging.
    private var pausedByScene = false
    /// True between `pauseForWork()` and the next nudge — a job the user asked
    /// for holds the on-device model. Kept apart from the scene pause because
    /// it expires differently: every nudge caller (a finished job, the Brain
    /// tab appearing) is a moment reading again is wanted, and a job pause that
    /// outlived them would silence the Brain for the rest of the session.
    private var pausedByWork = false
    /// The loop may run only while neither reason to stop is in force.
    private var isPaused: Bool { pausedByScene || pausedByWork }
    /// The context of the most recent nudge, so a loop the device paused
    /// (thermal, rate limit) can restart itself without waiting for the next
    /// scene transition. Every caller nudges with the same main-actor context.
    private var lastContext: ModelContext?
```

- [ ] **Step 4: Split the pause and give nudge both gates**

In the same file, replace `nudge(context:)` and `pause()` (lines 82-111) — their current form:

```swift
    /// Starts the loop if it isn't running. Cheap to call often.
    func nudge(context: ModelContext) {
        if let running {
            if running.isCancelled {
                restartRequested = context
            }
            return
        }
        running = Task { [self] in
            isWorking = true
            await run(context: context)
            isWorking = false
            running = nil
            if let restartContext = restartRequested {
                restartRequested = nil
                nudge(context: restartContext)
            }
        }
    }

    /// Stops after the in-flight meeting. Call when the scene deactivates.
    /// Also disarms any restart a mid-teardown nudge queued: that nudge
    /// belonged to a foreground moment this pause has already ended, and
    /// consuming it later would start an uncancelled loop while the app is
    /// inactive — burning rate-limited FoundationModels calls and
    /// skip-listing every meeting they fail on until the next launch.
    func pause() {
        running?.cancel()
        restartRequested = nil
    }
```

with:

```swift
    /// Starts the loop if it isn't running. Cheap to call often.
    ///
    /// Every caller is a moment reading is wanted: a job finishing
    /// (`MeetingJobs.onContentChanged`), the Brain tab appearing, the scene
    /// coming back. So a nudge lifts the work pause itself — but never the
    /// scene pause, or a job that finished after the user left would restart
    /// extraction in the background.
    func nudge(context: ModelContext) {
        lastContext = context
        pausedByWork = false
        guard !isPaused else { return }
        if let running {
            if running.isCancelled {
                restartRequested = context
            }
            return
        }
        running = Task { [self] in
            isWorking = true
            await run(context: context)
            isWorking = false
            running = nil
            if let restartContext = restartRequested {
                restartRequested = nil
                nudge(context: restartContext)
            }
        }
    }

    /// What both pauses do: stop after the in-flight meeting, and disarm any
    /// restart a mid-teardown nudge queued — that nudge belonged to a moment
    /// the pause has already ended, and consuming it later would start an
    /// uncancelled loop, burning rate-limited FoundationModels calls and
    /// skip-listing every meeting they fail on until the next launch.
    private func stopLoop() {
        running?.cancel()
        restartRequested = nil
    }

    /// The scene left `.active`. Call from the scene-phase handler; only
    /// `resume(context:)` lifts it.
    func pause() {
        pausedByScene = true
        stopLoop()
    }

    /// A job the user started wants the on-device model. Extraction gets out
    /// of the way until the next nudge — which the job itself sends when it
    /// finishes.
    func pauseForWork() {
        pausedByWork = true
        stopLoop()
    }

    /// The scene came back to `.active`: the one door out of `pause()`.
    func resume(context: ModelContext) {
        pausedByScene = false
        nudge(context: context)
    }
```

- [ ] **Step 5: Update the three existing pause tests to come back through `resume`**

In `MinuteTests/KnowledgeCatchUpTests.swift`:

Rename the test at line 283 — replace:

```swift
    @Test func pauseStopsTheLoopAndNudgeResumes() async throws {
```

with:

```swift
    @Test func pauseStopsTheLoopAndResumeRestartsIt() async throws {
```

and in that same test replace line 310:

```swift
        catchUp.nudge(context: context)
```

with:

```swift
        catchUp.resume(context: context)
```

In `nudgeWhileAPausedLoopIsStillUnwindingRestartsTheLoop`, replace lines 343-345:

```swift
        // The scene flickered back to active before the loop finished
        // tearing down. This nudge must not be lost.
        catchUp.nudge(context: context)
```

with:

```swift
        // The scene flickered back to active before the loop finished
        // tearing down. This resume must not be lost.
        catchUp.resume(context: context)
```

In `pauseAfterAMidTeardownNudgeLeavesTheLoopStopped`, replace lines 380-382:

```swift
        catchUp.pause()
        catchUp.nudge(context: context)
        catchUp.pause()
```

with:

```swift
        catchUp.pause()
        catchUp.resume(context: context)
        catchUp.pause()
```

- [ ] **Step 6: Run the suite to verify it passes**

Run the one-suite command with `KnowledgeCatchUpTests`. Expected: 22 tests pass, including both new ones.

- [ ] **Step 7: Run the full unit suite**

Run the full-suite command. Expected: `TEST SUCCEEDED`, 304 tests (302 + 2).

- [ ] **Step 8: Commit**

```bash
cd /Users/feihou/workplace/minute/.claude/worktrees/app-code-review-e76404 && git add Minute/Services/KnowledgeCatchUp.swift MinuteTests/KnowledgeCatchUpTests.swift && git commit -m "$(cat <<'EOF'
fix: keep a background nudge from restarting the catch-up loop

MeetingJobs keeps working after the app leaves the foreground and nudges the
knowledge loop when a job succeeds, which restarted extraction the scene-phase
handler had just paused — against the documented foreground-only design, with
no keep-alive once the job's token ends.

The loop now tracks two reasons to stop. A scene pause latches: a nudge while
it is set only records the context, and resume(context:) is the one door back
in. A work pause, taken when a user-initiated job starts, expires on the next
nudge — the job's own completion callback — so yielding the model to a summary
never costs the rest of the foreground session.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 47: A partly refused meeting keeps its facts but is not stamped as read (F57)

**Files:**
- Modify: `Minute/Services/KnowledgeExtractionService.swift:27-35` (add the result type after `KnowledgeCandidate`), `:61-81` and `:83-116` (both `extract` overloads)
- Modify: `Minute/Services/KnowledgeCatchUp.swift:13` (typealias), `:16-21` (observable state), `:145-165` (the ingest branch in `run`)
- Test: `MinuteTests/KnowledgeCatchUpTests.swift` (every extractor closure), `MinuteTests/KnowledgeExtractionIntegrationTests.swift:15-17`

**Interfaces:**
- Consumes: `KnowledgeCandidate` (KnowledgeExtractionService.swift:28-35); `KnowledgeIngest.apply(_:from:context:)` (called at KnowledgeCatchUp.swift:163); `KnowledgeCatchUp.skip(_:key:)` (:60-62) and `contentKey(for:)` (:43-53).
- Produces: `struct KnowledgeExtractionResult: Sendable, Equatable { var candidates: [KnowledgeCandidate]; var refusedChunkCount: Int = 0; static let empty }`; `KnowledgeExtractionService.extract(transcript:knownEntityNames:) async throws -> KnowledgeExtractionResult`; `KnowledgeCatchUp.Extractor = @MainActor (String, [String]) async throws -> KnowledgeExtractionResult`; `KnowledgeCatchUp.skippedChunksByMeeting: [UUID: Int]` (observable, private(set)).

- [ ] **Step 1: Write the failing tests**

In `MinuteTests/KnowledgeCatchUpTests.swift`, append inside the struct, after the tests Task 46 added:

```swift

    @Test func aPartlyRefusedMeetingKeepsItsFactsButIsNotStamped() async throws {
        let context = try makeContext()
        let meeting = meetingWithTranscript("Health Review", createdAt: .now)
        context.insert(meeting)
        try context.save()

        let catchUp = makeCatchUp { _, _ in
            KnowledgeExtractionResult(
                candidates: [
                    KnowledgeCandidate(entityName: "Sarah", entityKind: .person, fact: "Sarah owns Atlas", validatedQuote: nil),
                ],
                refusedChunkCount: 2
            )
        }
        catchUp.nudge(context: context)
        await catchUp.waitUntilIdle()

        // What the model did read is kept…
        #expect(try context.fetch(FetchDescriptor<KnowledgeEntity>()).map(\.name) == ["Sarah"])
        // …but stamping would retire the meeting with two passages never read.
        #expect(meeting.knowledgeExtractedAt == nil)
        #expect(catchUp.skippedChunksByMeeting[meeting.id] == 2)
        #expect(catchUp.pendingCount == 1)
    }

    @Test func aPartlyRefusedMeetingIsNotRetriedHotInTheSameSession() async throws {
        let context = try makeContext()
        let meeting = meetingWithTranscript("Health Review", createdAt: .now)
        context.insert(meeting)
        try context.save()

        var calls = 0
        let catchUp = makeCatchUp { _, _ in
            calls += 1
            return KnowledgeExtractionResult(candidates: [], refusedChunkCount: 1)
        }
        catchUp.nudge(context: context)
        await catchUp.waitUntilIdle()
        // Guardrail refusals are near-deterministic: retrying inside this
        // session would spin the loop over the same refusal forever.
        #expect(calls == 1)

        catchUp.nudge(context: context)
        await catchUp.waitUntilIdle()
        #expect(calls == 1)
        #expect(meeting.knowledgeExtractedAt == nil)
    }

    @Test func aFullyReadMeetingRecordsNoSkippedChunks() async throws {
        let context = try makeContext()
        let meeting = meetingWithTranscript("Standup", createdAt: .now)
        context.insert(meeting)
        try context.save()

        let catchUp = makeCatchUp { _, _ in .empty }
        catchUp.nudge(context: context)
        await catchUp.waitUntilIdle()

        #expect(meeting.knowledgeExtractedAt != nil)
        #expect(catchUp.skippedChunksByMeeting.isEmpty)
    }
```

- [ ] **Step 2: Run the suite to verify it fails**

Run the one-suite command with `KnowledgeCatchUpTests`.
Expected: a build failure — `cannot find 'KnowledgeExtractionResult' in scope`.

- [ ] **Step 3: Add the result type**

In `Minute/Services/KnowledgeExtractionService.swift`, after the `KnowledgeCandidate` struct (ends line 35), insert:

```swift

/// What one extraction pass produced. The refused count rides along because a
/// meeting the guardrails only partly read must not be stamped as read: the
/// caller has to tell "this transcript held no durable facts" from "part of it
/// was refused", the same distinction the summarizer records as skippedParts.
struct KnowledgeExtractionResult: Sendable, Equatable {
    var candidates: [KnowledgeCandidate]
    /// Chunks the on-device guardrails refused. Non-zero means the transcript
    /// was only partly read.
    var refusedChunkCount: Int = 0

    static let empty = KnowledgeExtractionResult(candidates: [])
}
```

- [ ] **Step 4: Return the result from both extract overloads**

In the same file, in the public `extract` (lines 61-81), change the return type — replace:

```swift
    func extract(
        transcript: String,
        knownEntityNames: [String]
    ) async throws -> [KnowledgeCandidate] {
```

with:

```swift
    func extract(
        transcript: String,
        knownEntityNames: [String]
    ) async throws -> KnowledgeExtractionResult {
```

and in the private `extract` (lines 83-116) replace:

```swift
    private func extract(
        transcript: String,
        knownEntityNames: [String],
        maxChars: Int
    ) async throws -> [KnowledgeCandidate] {
        let chunks = TranscriptChunker.chunks(from: transcript, maxChars: maxChars)
        guard !chunks.isEmpty else { return [] }
```

with:

```swift
    private func extract(
        transcript: String,
        knownEntityNames: [String],
        maxChars: Int
    ) async throws -> KnowledgeExtractionResult {
        let chunks = TranscriptChunker.chunks(from: transcript, maxChars: maxChars)
        guard !chunks.isEmpty else { return .empty }
```

and replace its last two lines (currently 115-116):

```swift
        return candidates
    }
```

with:

```swift
        return KnowledgeExtractionResult(candidates: candidates, refusedChunkCount: refusals)
    }
```

- [ ] **Step 5: Carry the count through the catch-up loop**

The initializer's default extractor (lines 74-76) needs no edit: `KnowledgeExtractionService().extract(...)` now returns the result type the typealias asks for.

In `Minute/Services/KnowledgeCatchUp.swift`, replace the typealias (line 13):

```swift
    typealias Extractor = @MainActor (_ transcript: String, _ knownEntityNames: [String]) async throws -> [KnowledgeCandidate]
```

with:

```swift
    typealias Extractor = @MainActor (_ transcript: String, _ knownEntityNames: [String]) async throws -> KnowledgeExtractionResult
```

After the `isWorking` declaration (ends line 21), insert:

```swift

    /// Chunks the guardrails refused, per meeting, as of the last read of it.
    /// Such a meeting stays unstamped so a later launch retries it; this is
    /// what a Brain surface can show meanwhile, the way a summary shows
    /// "N parts couldn't be summarized".
    private(set) var skippedChunksByMeeting: [UUID: Int] = [:]
```

In `run(context:)`, replace line 147:

```swift
                let candidates = try await extract(transcript, names)
```

with:

```swift
                let result = try await extract(transcript, names)
```

Then replace the ingest branch in `run` (lines 163-165):

```swift
                try KnowledgeIngest.apply(candidates, from: meeting, context: context)
                meeting.knowledgeExtractedAt = .now
                try context.save()
```

with:

```swift
                try KnowledgeIngest.apply(result.candidates, from: meeting, context: context)
                if result.refusedChunkCount > 0 {
                    // Stamping would retire the meeting with those passages
                    // never read — and the meetings richest in durable facts
                    // are exactly the ones a guardrail refuses. Keep what was
                    // extracted, remember how much was missed, and skip-list
                    // the text that was read: a refusal is near-deterministic,
                    // so retrying it inside this session would only spin, while
                    // the next launch (or a re-transcription, which changes the
                    // key) reads the meeting again.
                    skippedChunksByMeeting[meeting.id] = result.refusedChunkCount
                    skip(meeting, key: Self.contentKey(for: transcript))
                } else {
                    meeting.knowledgeExtractedAt = .now
                    skippedChunksByMeeting[meeting.id] = nil
                }
                try context.save()
```

- [ ] **Step 6: Migrate the existing test closures mechanically**

Run:

```bash
cd /Users/feihou/workplace/minute/.claude/worktrees/app-code-review-e76404 && sed -i '' 's/return \[\]/return .empty/g; s/{ _, _ in \[\] }/{ _, _ in .empty }/g' MinuteTests/KnowledgeCatchUpTests.swift && grep -c "return \.empty" MinuteTests/KnowledgeCatchUpTests.swift
```

Expected: prints `17` — the 15 `return []` extractor closures the file had at the branch point plus the two Task 46 added. (The one inline `{ _, _ in [] }` at line 111 is rewritten by the second expression and is deliberately not counted by this grep.)

- [ ] **Step 7: Migrate the four closures that return candidates**

In `MinuteTests/KnowledgeCatchUpTests.swift`, replace **both** occurrences (in `processesUnstampedMeetingsNewestFirstAndStamps` and in `meetingDeletedMidExtractionLeavesNoKnowledgeBehind`) of:

```swift
            return [KnowledgeCandidate(entityName: "Sarah", entityKind: .person, fact: "Sarah spoke", validatedQuote: nil)]
```

with:

```swift
            return KnowledgeExtractionResult(candidates: [
                KnowledgeCandidate(entityName: "Sarah", entityKind: .person, fact: "Sarah spoke", validatedQuote: nil),
            ])
```

In `transcriptReplacedMidExtractionIsReextractedNotStampedStale`, replace:

```swift
                return [KnowledgeCandidate(entityName: "Stale", entityKind: .topic, fact: "from old transcript", validatedQuote: nil)]
```

with:

```swift
                return KnowledgeExtractionResult(candidates: [
                    KnowledgeCandidate(entityName: "Stale", entityKind: .topic, fact: "from old transcript", validatedQuote: nil),
                ])
```

and replace:

```swift
            return [KnowledgeCandidate(entityName: "Fresh", entityKind: .topic, fact: "from new transcript", validatedQuote: nil)]
```

with:

```swift
            return KnowledgeExtractionResult(candidates: [
                KnowledgeCandidate(entityName: "Fresh", entityKind: .topic, fact: "from new transcript", validatedQuote: nil),
            ])
```

- [ ] **Step 8: Update the integration test**

In `MinuteTests/KnowledgeExtractionIntegrationTests.swift`, replace lines 15-17:

```swift
        let candidates = try await KnowledgeExtractionService()
            .extract(transcript: transcript, knownEntityNames: ["Sarah Chen"])

```

with:

```swift
        let result = try await KnowledgeExtractionService()
            .extract(transcript: transcript, knownEntityNames: ["Sarah Chen"])
        let candidates = result.candidates

        // Nothing in this transcript should trip the guardrails.
        #expect(result.refusedChunkCount == 0)
```

- [ ] **Step 9: Run the suite to verify it passes**

Run the one-suite command with `KnowledgeCatchUpTests`. Expected: 25 tests pass, including the three new ones.

- [ ] **Step 10: Run the full unit suite**

Run the full-suite command. Expected: `TEST SUCCEEDED`, 307 tests (304 + 3).

- [ ] **Step 11: Commit**

```bash
cd /Users/feihou/workplace/minute/.claude/worktrees/app-code-review-e76404 && git add Minute/Services/KnowledgeExtractionService.swift Minute/Services/KnowledgeCatchUp.swift MinuteTests/KnowledgeCatchUpTests.swift MinuteTests/KnowledgeExtractionIntegrationTests.swift && git commit -m "$(cat <<'EOF'
fix: stop stamping a meeting the guardrails only partly read

A refusal on some chunks was swallowed and the surviving chunks' candidates
returned as if complete, so the catch-up loop stamped the meeting and the
refused passages were never read again — the meetings richest in durable facts
being exactly the ones a guardrail refuses.

Extraction now returns candidates plus a refused-chunk count. The loop ingests
what came back, records the count for a Brain surface to show, and leaves the
meeting unstamped but skip-listed: no hot retry of a near-deterministic
refusal, and the next launch reads it again.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 48: A loop the device stalled restarts itself (F59)

**Files:**
- Modify: `Minute/Services/KnowledgeCatchUp.swift:1-3` (imports stay as they are — `Foundation` already covers `ProcessInfo`/`NotificationCenter`), the state block from Task 46, `:72-80` (init), `nudge`'s loop-start path and `stopLoop()` from Task 46, `run`'s availability guard (:128) and its `GenerationError` catch (:175-182)
- Test: `MinuteTests/KnowledgeCatchUpTests.swift`

**Interfaces:**
- Consumes: `ProcessInfo.thermalStateDidChangeNotification`; `ProcessInfo.processInfo.thermalState` (already read at KnowledgeCatchUp.swift:133); `LanguageModelSession.GenerationError.rateLimited` (handled at :179); the `pausedByScene`/`pausedByWork`/`isPaused`/`lastContext` state, `stopLoop()` and `restartRequested` from Task 46; the observer-token pattern in `Minute/Services/AudioRecorder.swift:118, 178-186, 248-252`.
- Produces: `KnowledgeCatchUp.init(availabilityMessage:retryDelay:extract:)` with `retryDelay: Duration = .seconds(60)`; `KnowledgeCatchUp.thermalStateDidChange()` (internal, called by the observer and directly by tests); private `retryTask: Task<Void, Never>?`, private `scheduleRetry()`.

- [ ] **Step 1: Write the failing tests**

In `MinuteTests/KnowledgeCatchUpTests.swift`, append inside the struct, after `aFullyReadMeetingRecordsNoSkippedChunks`:

```swift

    @Test func coolingDownRestartsALoopTheDeviceStopped() async throws {
        let context = try makeContext()
        let meeting = meetingWithTranscript("A", createdAt: .now)
        context.insert(meeting)
        try context.save()

        var calls = 0
        let catchUp = makeCatchUp { _, _ in
            calls += 1
            if calls == 1 {
                throw LanguageModelSession.GenerationError.rateLimited(.init(debugDescription: "test"))
            }
            return .empty
        }
        catchUp.nudge(context: context)
        await catchUp.waitUntilIdle()
        #expect(calls == 1)
        #expect(meeting.knowledgeExtractedAt == nil)

        // The device cooling off is the signal the loop's own thermal guard no
        // longer holds. Without it the Brain's "catches up while it's open" row
        // is a lie until the user backgrounds and re-foregrounds the app.
        catchUp.thermalStateDidChange()
        await catchUp.waitUntilIdle()
        #expect(calls == 2)
        #expect(meeting.knowledgeExtractedAt != nil)
    }

    @Test func coolingDownWhilePausedStartsNothing() async throws {
        let context = try makeContext()
        let meeting = meetingWithTranscript("A", createdAt: .now)
        context.insert(meeting)
        try context.save()

        var calls = 0
        let catchUp = makeCatchUp { _, _ in
            calls += 1
            throw LanguageModelSession.GenerationError.rateLimited(.init(debugDescription: "test"))
        }
        catchUp.nudge(context: context)
        await catchUp.waitUntilIdle()
        #expect(calls == 1)

        // Thermal notifications keep arriving while the app is backgrounded;
        // extraction stays foreground-only.
        catchUp.pause()
        catchUp.thermalStateDidChange()
        await catchUp.waitUntilIdle()
        #expect(calls == 1)
        #expect(meeting.knowledgeExtractedAt == nil)
    }

    @Test func aRateLimitedLoopRetriesItselfAfterTheDelay() async throws {
        let context = try makeContext()
        let meeting = meetingWithTranscript("A", createdAt: .now)
        context.insert(meeting)
        try context.save()

        var calls = 0
        let catchUp = KnowledgeCatchUp(
            availabilityMessage: { nil },
            retryDelay: .milliseconds(50),
            extract: { _, _ in
                calls += 1
                if calls == 1 {
                    throw LanguageModelSession.GenerationError.rateLimited(.init(debugDescription: "test"))
                }
                return .empty
            }
        )
        catchUp.nudge(context: context)
        await catchUp.waitUntilIdle()
        #expect(calls == 1)

        // Nothing else would resume this loop while the app stays open: the
        // scene never changes and no job finishes.
        var waited = 0
        while calls < 2 && waited < 2_000 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 10
        }
        await catchUp.waitUntilIdle()
        #expect(calls == 2)
        #expect(meeting.knowledgeExtractedAt != nil)
    }
```

- [ ] **Step 2: Run the suite to verify it fails**

Run the one-suite command with `KnowledgeCatchUpTests`.
Expected: a build failure — `value of type 'KnowledgeCatchUp' has no member 'thermalStateDidChange'` and `extra argument 'retryDelay' in call`.

- [ ] **Step 3: Add the retry state, the observer, and the two restarts**

In `Minute/Services/KnowledgeCatchUp.swift`, after the `lastContext` declaration added in Task 46, insert:

```swift
    /// How long a loop the device stopped waits before nudging itself. A rate
    /// limit and an unready model are both "not now", not "never" — and
    /// nothing else asks again while the app stays in the foreground.
    /// Injectable so tests don't wait a minute.
    private let retryDelay: Duration
    /// At most one delayed retry outstanding: the loop's own guards are cheap,
    /// but a timer per stalled pass would pile up.
    private var retryTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var observerTokens: [any NSObjectProtocol] = []
```

Replace the initializer (lines 72-80) — its current form:

```swift
    init(
        availabilityMessage: @escaping @MainActor () -> String? = { KnowledgeExtractionService.availabilityMessage },
        extract: @escaping Extractor = { transcript, names in
            try await KnowledgeExtractionService().extract(transcript: transcript, knownEntityNames: names)
        }
    ) {
        self.availabilityMessage = availabilityMessage
        self.extract = extract
    }
```

with:

```swift
    init(
        availabilityMessage: @escaping @MainActor () -> String? = { KnowledgeExtractionService.availabilityMessage },
        retryDelay: Duration = .seconds(60),
        extract: @escaping Extractor = { transcript, names in
            try await KnowledgeExtractionService().extract(transcript: transcript, knownEntityNames: names)
        }
    ) {
        self.availabilityMessage = availabilityMessage
        self.retryDelay = retryDelay
        self.extract = extract
        observerTokens.append(NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.thermalStateDidChange()
            }
        })
    }

    deinit {
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// The device cooled back to nominal or fair: the only signal that the
    /// loop's thermal guard no longer holds. Tests call this directly — the
    /// notification itself cannot be provoked, and the observer above is one
    /// line of wiring.
    func thermalStateDidChange() {
        let thermal = ProcessInfo.processInfo.thermalState
        guard thermal == .nominal || thermal == .fair else { return }
        guard !isPaused, let lastContext else { return }
        nudge(context: lastContext)
    }

    /// One delayed re-nudge after the device said "not now". Weak, so a
    /// discarded loop is not kept alive by a pending timer.
    private func scheduleRetry() {
        guard retryTask == nil, !isPaused, lastContext != nil else { return }
        let delay = retryDelay
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            retryTask = nil
            guard !isPaused, let lastContext else { return }
            // The loop that armed this retry may still be unwinding —
            // scheduleRetry() runs inside run(), before the task that owns it
            // clears `running` — and a nudge into a live loop arms nothing.
            // Hand that loop a restart instead; its tail consumes it.
            if running != nil {
                restartRequested = lastContext
                return
            }
            nudge(context: lastContext)
        }
    }
```

- [ ] **Step 4: Drop a pending retry whenever the loop starts or stops**

In the same file, in `nudge(context:)` (as rewritten in Task 46), replace:

```swift
        running = Task { [self] in
            isWorking = true
```

with:

```swift
        // A loop is starting now, so a timer waiting to start one is spent —
        // and leaving it armed would block the next retry the loop needs.
        retryTask?.cancel()
        retryTask = nil
        running = Task { [self] in
            isWorking = true
```

and in `stopLoop()` (Task 46), replace:

```swift
    private func stopLoop() {
        running?.cancel()
        restartRequested = nil
    }
```

with:

```swift
    private func stopLoop() {
        running?.cancel()
        restartRequested = nil
        retryTask?.cancel()
        retryTask = nil
    }
```

- [ ] **Step 5: Schedule the retry where the loop gives up**

In `run(context:)`, replace the availability guard (line 128):

```swift
        guard availabilityMessage() == nil else { return }
```

with:

```swift
        guard availabilityMessage() == nil else {
            scheduleRetry()
            return
        }
```

and in the `LanguageModelSession.GenerationError` catch, replace lines 175-182:

```swift
            } catch let error as LanguageModelSession.GenerationError {
                // Rate limiting is the device saying "not now", not a verdict
                // on this meeting: stop without skip-listing (spec §5
                // pause-and-resume) — the next nudge retries from here.
                if case .rateLimited = error { return }
                // Assets being evicted mid-loop is the same kind of "not now":
                // the model is gone, not this meeting's fault.
                if case .assetsUnavailable = error { return }
```

with:

```swift
            } catch let error as LanguageModelSession.GenerationError {
                // Rate limiting is the device saying "not now", not a verdict
                // on this meeting: stop without skip-listing (spec §5
                // pause-and-resume), and ask again after a delay — while the
                // app stays open nothing else would.
                if case .rateLimited = error {
                    scheduleRetry()
                    return
                }
                // Assets being evicted mid-loop is the same kind of "not now":
                // the model is gone, not this meeting's fault.
                if case .assetsUnavailable = error {
                    scheduleRetry()
                    return
                }
```

- [ ] **Step 6: Run the suite to verify it passes**

Run the one-suite command with `KnowledgeCatchUpTests`. Expected: 28 tests pass, including the three new ones. (`coolingDownRestartsALoopTheDeviceStopped` reads the host's real thermal state, which is nominal on a simulator — the same assumption every other loop test already makes.)

- [ ] **Step 7: Run the full unit suite**

Run the full-suite command. Expected: `TEST SUCCEEDED`, 310 tests (307 + 3).

- [ ] **Step 8: Commit**

```bash
cd /Users/feihou/workplace/minute/.claude/worktrees/app-code-review-e76404 && git add Minute/Services/KnowledgeCatchUp.swift MinuteTests/KnowledgeCatchUpTests.swift && git commit -m "$(cat <<'EOF'
fix: let a stalled catch-up loop restart itself

A warm device, an unready model, or one rate-limited chunk stopped the loop,
and the only things that ever nudged it again were a scene transition and a
finished job — while the Brain kept saying "Minute catches up while it's
open".

Observe thermal-state changes and nudge when the device is back to
nominal/fair, and schedule a single delayed re-nudge (60 s, injectable) after
a rate limit or an unavailable model. Both respect either pause: a paused loop
schedules nothing and cancels what it had.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 49: The mirror skips a meeting deleted since the snapshot — including one deleted mid-run (F47)

**Files:**
- Modify: `Minute/Services/ICloudDriveBackup.swift:55-56` (defaults keys block — new state goes after it), `:598-599` (top of the placement loop in `mirror`)
- Test: `MinuteTests/ICloudDriveBackupTests.swift`

**Interfaces:**
- Consumes: `ICloudDriveBackup.Item.meetingID: String` (ICloudDriveBackup.swift:61, always `meeting.id.uuidString` — set in `items(for:)` at :174); `mirror(_:into:shouldContinue:)` (:534-652), its `owned`/`chosen`/`live`/`parked` bookkeeping (:544-596) and the stale sweep at :625-629; `removeMirror(at:) -> Bool` (:671-717, `@discardableResult`, returns false when anything the app wrote is still there).
- Produces: `ICloudDriveBackup.noteMeetingDeleted(_ id: UUID)` (nonisolated, thread-safe); private `isDeletedSinceSnapshot(_ meetingID: String) -> Bool`. Track E calls `noteMeetingDeleted` from `MeetingStore.delete`.

The check belongs inside the placement loop, not once at the top: the snapshot is captured on the main actor and copied on a background task that takes minutes on a large library, so the deletion F47 is about lands *while* the loop is still working through earlier meetings.

- [ ] **Step 1: Write the failing tests**

In `MinuteTests/ICloudDriveBackupTests.swift`, add this helper next to `Gate` (after it, at line 22 — `Gate` ends at line 21):

```swift

/// Allows every check and runs a side effect from the given check onward —
/// standing in for the user deleting a meeting while the mirror is still
/// copying an earlier one.
private final class Trip: @unchecked Sendable {
    private let lock = NSLock()
    private var checks = 0
    private let from: Int
    private let effect: @Sendable () -> Void

    init(from: Int, effect: @escaping @Sendable () -> Void) {
        self.from = from
        self.effect = effect
    }

    func check() -> Bool {
        lock.lock()
        checks += 1
        let fire = checks >= from
        lock.unlock()
        if fire { effect() }
        return true
    }
}
```

and add these three tests after `mirrorRemovesDeletedMeetings` (ends line 219):

```swift

    /// The toggle-on sync snapshots every meeting on the main actor and copies
    /// them on a Task nothing cancels, so a meeting deleted mid-run is still in
    /// the snapshot when the loop reaches it — and notes.md carries its whole
    /// transcript in memory.
    @Test func mirrorSkipsAndRemovesAMeetingDeletedSinceTheSnapshot() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }

        let deletedID = UUID()
        let deleted = item(id: deletedID.uuidString, folderName: "2026-08-03 09.30 Deleted", notes: "# secret transcript")
        let kept = item(folderName: "2026-08-03 10.00 Kept", notes: "# kept")
        try ICloudDriveBackup.mirror([deleted, kept], into: documents)
        #expect(FileManager.default.fileExists(atPath: documents.appendingPathComponent(deleted.folderName).path))

        // The user deletes that meeting while this snapshot is still being
        // mirrored.
        ICloudDriveBackup.noteMeetingDeleted(deletedID)
        try ICloudDriveBackup.mirror([deleted, kept], into: documents)

        // Its folder goes with it, and the rest of the snapshot still lands.
        #expect(!FileManager.default.fileExists(atPath: documents.appendingPathComponent(deleted.folderName).path))
        let keptFolder = documents.appendingPathComponent(kept.folderName, isDirectory: true)
        #expect(try String(contentsOf: keptFolder.appendingPathComponent("notes.md"), encoding: .utf8) == "# kept")
    }

    @Test func mirrorNeverWritesADeletedMeetingsNotesInTheFirstPlace() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }

        let deletedID = UUID()
        let entry = item(id: deletedID.uuidString, folderName: "2026-08-03 09.30 Deleted", notes: "# secret transcript")
        ICloudDriveBackup.noteMeetingDeleted(deletedID)

        try ICloudDriveBackup.mirror([entry], into: documents)

        // Nothing was ever created: a deleted meeting's transcript must not
        // reach iCloud Drive even for the seconds until the next sync.
        #expect(try visibleNames(in: documents).isEmpty)
    }

    /// The case the snapshot cannot see: the delete lands after `mirror` has
    /// already started, while the loop is still on an earlier meeting.
    @Test func mirrorSkipsAMeetingDeletedWhileTheRunIsStillCopying() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }

        let deletedID = UUID()
        let first = item(folderName: "2026-08-03 09.30 Kept", notes: "# kept")
        let second = item(id: deletedID.uuidString, folderName: "2026-08-03 10.00 Deleted", notes: "# secret transcript")

        // From the second shouldContinue check on — the first is the one
        // `mirror` makes before it touches a folder, so this deletion is
        // unknowable to anything the run read on entry. On a real library
        // those checks are minutes apart.
        let trip = Trip(from: 2) { ICloudDriveBackup.noteMeetingDeleted(deletedID) }
        let outcome = try ICloudDriveBackup.mirror([first, second], into: documents, shouldContinue: { trip.check() })

        #expect(try visibleNames(in: documents) == [first.folderName])
        // Skipping a meeting the user deleted is the run doing its job, not
        // failing at it: an incomplete verdict here would warn about a backup
        // that is exactly as complete as it should be.
        #expect(outcome == .complete)
    }
```

- [ ] **Step 2: Run the suite to verify it fails**

Run the one-suite command with `ICloudDriveBackupTests`.
Expected: a build failure — `type 'ICloudDriveBackup' has no member 'noteMeetingDeleted'`.

- [ ] **Step 3: Record deleted meetings**

In `Minute/Services/ICloudDriveBackup.swift`, after the defaults-key constants (line 56, `private static let deviceVendorKey = "backup.deviceVendorID"`), insert:

```swift

    /// Meetings deleted since some snapshot was taken. A snapshot is captured
    /// on the main actor and mirrored on a background task, so the user can
    /// delete a meeting while the run is still copying earlier ones — and each
    /// Item carries that meeting's full notes text in memory. Never emptied: a
    /// deleted meeting cannot come back, and one UUID per deletion for the life
    /// of the process is nothing beside writing a deleted transcript to iCloud.
    private nonisolated(unsafe) static var deletedMeetingIDs: Set<String> = []
    private static let deletedMeetingLock = NSLock()

    /// Tells any mirror run in flight that this meeting is gone. Safe from any
    /// thread and at any point around the delete — the mirror only reads.
    nonisolated static func noteMeetingDeleted(_ id: UUID) {
        deletedMeetingLock.lock()
        defer { deletedMeetingLock.unlock() }
        deletedMeetingIDs.insert(id.uuidString)
    }

    private nonisolated static func isDeletedSinceSnapshot(_ meetingID: String) -> Bool {
        deletedMeetingLock.lock()
        defer { deletedMeetingLock.unlock() }
        return deletedMeetingIDs.contains(meetingID)
    }
```

- [ ] **Step 4: Check before writing each item**

In the same file, in `mirror(_:into:shouldContinue:)`, replace the top of the placement loop (lines 598-600):

```swift
        for item in items {
            guard shouldContinue() else { return Swift.max(outcome, .interrupted) }
            do {
```

with:

```swift
        for item in items {
            guard shouldContinue() else { return Swift.max(outcome, .interrupted) }
            // The snapshot is minutes old by the time a large library reaches
            // its last meetings, and every Item still holds that meeting's
            // whole notes text in memory: a meeting deleted since must not have
            // it written now, and must lose the folder an earlier sync gave it.
            // Everything it owns goes here rather than through the sweep below,
            // which judges by `chosen` and cannot see a folder this run parked
            // under a staging name — and which, handed URLs this loop already
            // removed, would report the run incomplete over folders that are
            // correctly gone.
            if isDeletedSinceSnapshot(item.meetingID) {
                let movedFrom = parked.removeValue(forKey: item.meetingID)
                var folders = (owned[item.meetingID] ?? []).filter { $0 != movedFrom }
                if let current = live.removeValue(forKey: item.meetingID), !folders.contains(current) {
                    folders.append(current)
                }
                for url in folders where !removeMirror(at: url) {
                    outcome = .incomplete
                }
                continue
            }
            do {
```

- [ ] **Step 5: Run the suite to verify it passes**

Run the one-suite command with `ICloudDriveBackupTests`. Expected: 53 tests pass, including the three new ones.

- [ ] **Step 6: Run the full unit suite**

Run the full-suite command. Expected: `TEST SUCCEEDED`, 313 tests (310 + 3).

- [ ] **Step 7: Commit**

```bash
cd /Users/feihou/workplace/minute/.claude/worktrees/app-code-review-e76404 && git add Minute/Services/ICloudDriveBackup.swift MinuteTests/ICloudDriveBackupTests.swift && git commit -m "$(cat <<'EOF'
fix: never mirror a meeting deleted since the snapshot was taken

Turning iCloud Drive Folder on snapshots every meeting — full notes text
included — and mirrors it on a task nothing cancels. A meeting deleted while
that run was copying earlier ones was still reached later in the loop, so its
folder was created and notes.md written after the user deleted it, and only a
later background sync removed it.

ICloudDriveBackup.noteMeetingDeleted(_:) records the id, and the mirror asks
before writing each item: a meeting that is gone by then is skipped and every
folder it owns removed, in the same run. MeetingStore.delete calls it (wired
separately).

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Hand-offs to Track E

One-line wirings in files this track does not own. Each is required for the corresponding fix to have any effect in the app.

1. `Minute/App/MinuteApp.swift:61` — after `jobs.onContentChanged = { catchUp.nudge(context: mainContext) }`, add `jobs.onWorkStarted = { catchUp.pauseForWork() }` (Tasks 45 and 46, F55). `pauseForWork`, not `pause`: `onWorkStarted` fires on every job, including the automatic post-save summary, and a latching pause there would stop the Brain for the rest of the foreground session. Leave `onContentChanged` on `nudge` — it is what lifts the work pause, and while the scene is paused it starts nothing (F23).
2. `Minute/App/MinuteApp.swift:109` — in the `.onChange(of: scenePhase)` handler, change the `.active` branch from `knowledgeCatchUp.nudge(context: container.mainContext)` to `knowledgeCatchUp.resume(context: container.mainContext)` (Task 46). Without this the loop never restarts after the first background transition, because `pause()` latches.
3. `Minute/Services/MeetingStore.swift`, in `delete(_:context:)` — call `ICloudDriveBackup.noteMeetingDeleted(meeting.id)` before the row is removed (Task 49, F47). Without it the in-flight foreground mirror still writes that meeting's notes.md into iCloud Drive.
4. Optional, and only if the Brain surface is in scope for Track E: `BrainView` can read `catchUp.skippedChunksByMeeting` (Task 47) to show "N parts couldn't be read" the way a summary shows `skippedParts`. Nothing breaks if it doesn't.

### Not done in this track

- **F36's real fix (a device name in the mirror folder).** Only the docs half is planned. Showing the user's iPhone name needs the `com.apple.developer.device-information.user-assigned-device-name` entitlement, which requires Apple's approval; the alternative (a user-typed device label in Settings) is a new Settings control in files Track E owns and a feature decision, not a review fix.
- **F47's mirror-cancellation alternative.** The suggested "cancel and re-request the foreground mirror from MeetingStore.delete" needs `SettingsView`'s toggle-on task to be owned through a cancellable handle, which lives in `Minute/Views/SettingsView.swift` (not owned here). The deleted-id set achieves the same guarantee — no deleted meeting's notes reach iCloud Drive — entirely inside `ICloudDriveBackup`.
- **F10's UI half** (a Stop button on the transcript progress row, and `TranscriptionService`'s cancellation checks). `Minute/Views/MeetingDetailView.swift` and `Minute/Services/TranscriptionService.swift` belong to other tracks; only `DiarizationService` is planned here (Task 40).
- **Persisting the refused-chunk count on `Meeting`** (F57's "e.g. knowledgeSkippedParts on Meeting"). The decision is an in-memory `skippedChunksByMeeting`; a new `@Model` property would be a schema change, and the meeting stays unstamped anyway, so the next launch re-derives the number.

---

## Track E — Post-merge wiring (sequential, after Tracks C, D, F1, F2 are merged)

Track E owns every file. Each task is a one-place wiring named by another track's hand-off; verify the produced symbol exists in the merged tree before editing (grep), and keep the full suite green.

### Task 55: RecordingView renders the Whisper model-loading state (F71 UI side)

**Files:**
- Modify: `Minute/Views/RecordingView.swift` (transcriptArea's switch on `session.transcription.availability`)

**Interfaces:**
- Consumes: `TranscriptionAvailability.loadingModel` (Track C, Task 1).

No unit test (SwiftUI rendering). Verified by build + full suite.

- [ ] **Step 1: Add the case**

In `transcriptArea`, beside `case .downloadingModel:` add:

```swift
            case .loadingModel:
                VStack(spacing: 10) {
                    ProgressView("Loading the transcription model…")
                    Text("Recording continues while the model loads — the live transcript starts once it's ready.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
```

- [ ] **Step 2: Build and run the full unit suite** — Expected: `TEST SUCCEEDED`.
- [ ] **Step 3: Commit**

```bash
git add Minute/Views/RecordingView.swift
git commit -m "fix: show that the Whisper model is loading instead of Listening… while it compiles

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

### Task 56: MinuteApp wires job-start pauses and scene resumes for the catch-up loop (F23, F55)

**Files:**
- Modify: `Minute/App/MinuteApp.swift` (the `jobs.onContentChanged` line in `init`, and the `.active` branch of `.onChange(of: scenePhase)`)

**Interfaces:**
- Consumes: `MeetingJobs.onWorkStarted: (@MainActor () -> Void)?` (Track F2, Task 45); `KnowledgeCatchUp.pauseForWork()` and `KnowledgeCatchUp.resume(context:)` (Track F2, Task 46).

No unit test (app wiring); the underlying behaviors are tested in KnowledgeCatchUpTests and SummaryGenerationTests. Verified by build + full suite.

- [ ] **Step 1: Wire**

After `jobs.onContentChanged = { catchUp.nudge(context: mainContext) }` add:

```swift
        // Extraction yields to work the user is waiting on: every job (the
        // automatic post-save summary included) pauses the loop, and the
        // job's completion nudge lifts that pause.
        jobs.onWorkStarted = { catchUp.pauseForWork() }
```

In the scene-phase handler change the `.active` branch from `knowledgeCatchUp.nudge(context: container.mainContext)` to `knowledgeCatchUp.resume(context: container.mainContext)` (a scene pause is lifted only by a resume; a plain nudge would leave the loop parked after the first background trip).

- [ ] **Step 2: Build and run the full unit suite** — Expected: `TEST SUCCEEDED`.
- [ ] **Step 3: Commit**

```bash
git add Minute/App/MinuteApp.swift
git commit -m "fix: pause the Brain's catch-up loop while a user-initiated job runs and resume it on scene activation

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

### Task 57: Deleting a meeting tells an in-flight iCloud mirror to skip it (F47)

**Files:**
- Modify: `Minute/Services/MeetingStore.swift` (`delete(_:context:)`, before `context.delete(meeting)`)

**Interfaces:**
- Consumes: `ICloudDriveBackup.noteMeetingDeleted(_ id: UUID)` (Track F2, Task 49).

No new unit test here (the skip is tested in ICloudDriveBackupTests by Track F2); verified by build + full suite.

- [ ] **Step 1: Wire**

As the first statement of `MeetingStore.delete(_:context:)` (before `context.delete(meeting)`) add:

```swift
        // A foreground mirror started from the Settings toggle may still be
        // walking its snapshot; it must not write this meeting's notes to
        // iCloud Drive after the user deleted it.
        ICloudDriveBackup.noteMeetingDeleted(meeting.id)
```

- [ ] **Step 2: Build and run the full unit suite** — Expected: `TEST SUCCEEDED`.
- [ ] **Step 3: Commit**

```bash
git add Minute/Services/MeetingStore.swift
git commit -m "fix: keep an in-flight iCloud Drive mirror from writing a meeting deleted since its snapshot

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

### Task 58: Brain tab shows how many parts of a meeting couldn't be read (F57 UI side)

**Files:**
- Modify: `Minute/Views/BrainView.swift` (`catchUpStatus`)

**Interfaces:**
- Consumes: `KnowledgeCatchUp.skippedChunksByMeeting: [UUID: Int]` (Track F2, Task 47).

No unit test (SwiftUI). Verified by build + full suite.

- [ ] **Step 1: Add a row**

In `catchUpStatus`, after the existing pending-but-idle `else if` branch, add a branch shown when `!catchUp.skippedChunksByMeeting.isEmpty`:

```swift
        } else if !catchUp.skippedChunksByMeeting.isEmpty {
            let parts = catchUp.skippedChunksByMeeting.values.reduce(0, +)
            Section {
                Label("\(parts) part\(parts == 1 ? "" : "s") of your meetings couldn't be read and will be retried next time Minute opens.",
                      systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .modifier(BrainRowInsets())
            }
            .listRowSeparator(.hidden)
        }
```

If `catchUpStatus`'s structure makes an `else if` awkward, add it as a separate `if` after the existing block; keep it out of the `isWorking` branch.

- [ ] **Step 2: Build and run the full unit suite** — Expected: `TEST SUCCEEDED`.
- [ ] **Step 3: Commit**

```bash
git add Minute/Views/BrainView.swift
git commit -m "feat: tell the Brain tab when parts of a meeting were refused and will be retried

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```
