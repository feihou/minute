# Review Fixes, Batch 3 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the follow-ups the two review-fix batches (PRs #51 and #52) deferred: the deferred per-task Minor items that still apply at `main` b481626, the last two open review findings (Whisper's half of the transcription-death notice; CJK hint names), test-integrity gaps, and small robustness items — each triaged against the current code before planning.

**Architecture:** Four file-disjoint tracks (G engines and downloads; H recording, playback, widgets; I views, app entry, meeting store, models; J knowledge, jobs, backup, docs, test hygiene) run in separate worktrees off `main` at b481626 and merge back; a short sequential Track E follows for one cross-track item. Failing-test-first where the code is testable; pure SwiftUI wiring and hardware paths verified by build, full suite, and strict lint.

**Tech Stack:** Swift 5 language mode, SwiftUI, SwiftData, Swift Testing, FoundationModels, WhisperKit 1.0.0, mlx-swift-lm 3.31.4, swift-huggingface 0.9.0. Xcode 26.6, iOS 26.5 simulators, SwiftLint 0.65.1 (installed locally).

## Global Constraints

- Privacy invariants from CONTRIBUTING.md hold: no meeting content on the wire; every byte written has a delete path; AI output stays grounded ("Not specified" literal); recording never depends on optional capabilities and any handled failure still offers to save captured audio.
- No new third-party dependencies. Do not edit Minute.xcodeproj/project.pbxproj.
- Unit tests use Swift Testing, never XCTest. SwiftData-touching test structs are `@MainActor` with an in-memory container via `MeetingStore.modelConfiguration(inMemory: true)`; containers holding KnowledgeEntity/KnowledgeFact are retained for the process lifetime. Suite-level `-only-testing` selectors only.
- Swift 5 language mode: no actor-isolated default arguments (nil-defaulted injection pattern).
- Baseline at the branch point (b481626): **424 tests in 57 suites pass; `swiftlint --strict` reports 0 violations.** Every task leaves both true plus its own new tests.
- Run `swiftlint --strict --reporter github-actions-logging` from the repo root before every commit.
- Commit messages: Conventional Commits, ending with the trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Explicit paths; never `git add -A`; never commit anything under `.superpowers/`.
- A task edits only files its track owns; cross-track needs are Track E hand-offs.
- After a committed delete a SwiftData object has `isDeleted == false` and `modelContext == nil`; guard stale reads with `isGone`.
- Simulators: Track G "iPhone 17 Pro", Track H "iPhone 17", Track I "iPhone 17 Pro Max", Track J "iPhone Air", Track E "iPhone 17 Pro".

---

## Track G — Engines and downloads

Findings closed here: `new-small-tokenizer-fixture`, `b2-T2-minor-1`, `A5`, `b2-T7-minor-2`, `B8`, `BR1`.

**Files this track owns** (a task must not edit anything else):
`Minute/Services/WhisperTranscriptionService.swift`, `Minute/Services/WhisperDownloadCenter.swift`,
`Minute/Services/MLXSummarizationService.swift`, `Minute/Services/MLXDownloadCenter.swift`,
`Minute/Services/SummarizationEngine.swift`, `Minute/Services/SummarizationService.swift`,
`Minute/Services/TranscriptionEngine.swift`, `Minute/Services/AudioImporter.swift`,
`Minute/Services/LiveLoopGate.swift`, `Minute/Views/TranscriptionModelView.swift`,
`Minute/Views/SummaryModelView.swift`, plus `MinuteTests/Whisper*`, `MinuteTests/MLX*`,
`MinuteTests/SummaryFallbackTests.swift`, `MinuteTests/SummaryTemplateTests.swift`,
`MinuteTests/SummaryLanguageTests.swift`, `MinuteTests/SummaryContextTests.swift`,
`MinuteTests/SummarizationEngineSettingsTests.swift`, `MinuteTests/SummarizationIntegrationTests.swift`,
`MinuteTests/TranscriptionUnavailableErrorTests.swift`, `MinuteTests/AudioImporterTests.swift`,
`MinuteTests/LiveLoopGateTests.swift`, `MinuteTests/TranscriptionEngineSettingsTests.swift`,
and new test files for these types.

### Global Constraints

- Privacy invariants from CONTRIBUTING.md hold: no meeting content on the wire; every byte written has a delete path; AI output stays grounded ("Not specified" literal); recording never depends on optional capabilities and any handled failure still offers to save captured audio.
- No new third-party dependencies. Do not edit Minute.xcodeproj/project.pbxproj (new files under Minute/, MinuteTests/, Shared/, MinuteWidgets/ are picked up automatically).
- Unit tests use Swift Testing, never XCTest. SwiftData-touching test structs are @MainActor with an in-memory container via MeetingStore.modelConfiguration(inMemory: true); containers holding KnowledgeEntity/KnowledgeFact are retained for the process lifetime (retainedContainers pattern in MinuteTests/KnowledgeCatchUpTests.swift). Suite-level -only-testing selectors only (a single-test selector silently selects nothing).
- Swift 5 language mode: an actor-isolated expression cannot be a default argument (use the nil-defaulted injection pattern).
- Baseline at the branch point (main b481626): 424 tests in 57 suites pass; swiftlint --strict reports 0 violations. Every task leaves both true plus its own new tests.
- swiftlint 0.65.1 IS installed locally: run `swiftlint --strict --reporter github-actions-logging` from the repo root before every commit; live rules include multiple_closures_with_trailing_closure and redundant_void_return; line_length, function/type/file length, cyclomatic_complexity, identifier_name, todo, redundant_optional_initialization, trailing_comma, for_where are disabled.
- Commit messages: Conventional Commits (fix:/test:/docs:/refactor:), ending with the trailer line "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>". Explicit paths; never git add -A; never commit anything under .superpowers/.
- A task edits only files its track owns; cross-track needs go in "Hand-offs to Track E".
- After a committed delete a SwiftData object has isDeleted == false and modelContext == nil; guard stale reads with isGone.

**Test commands** (from the worktree root `/Users/feihou/workplace/minute/.claude/worktrees/app-code-review-e76404`; this track uses simulator "iPhone 17 Pro"):

One suite while iterating:
```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MinuteTests/<SuiteName> CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔ Test run|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Full unit suite, once before each commit:
```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```
Lint, before each commit:
```bash
swiftlint --strict --reporter github-actions-logging 2>&1 | grep -E "^::(error|warning)|Done linting"
```

**Line numbers** in this section are as of commit `b481626` and shift as earlier tasks in this track land. Every replacement quotes the exact current text; **the quoted old snippet is the authoritative anchor** — find it, don't count lines. Test counts assume this track's worktree only (424 at the branch point).

**Package sources cited in this section** (read-only; the exact APIs were verified there):
- WhisperKit: `/Users/feihou/Library/Developer/Xcode/DerivedData/Minute-aniwhiyqmtxllnfdgshpvtisjlok/SourcePackages/checkouts/WhisperKit` — `ModelVariant` is `@frozen public enum ModelVariant: CustomStringConvertible, CaseIterable` with exactly `tiny, tinyEn, base, baseEn, small, smallEn, medium, mediumEn, large, largev2, largev3` and descriptions `"tiny", "tiny.en", "base", "base.en", "small", "small.en", "medium", "medium.en", "large", "large-v2", "large-v3"` (Sources/WhisperKit/Core/Models.swift:38-88).
- iOS 26.5 simulator SDK: `Speech.SpeechTranscriber.isAvailable` is `public static var isAvailable: Swift.Bool { get }` with no isolation annotation, so it is callable from a nonisolated `@Sendable` trait closure (Speech.swiftinterface:399).

---

### Task 1: Test fixtures stop sharing tokenizer folders with the real catalog (new-small-tokenizer-fixture)

**Files:**
- Test: `MinuteTests/WhisperModelStoreTests.swift:1-139` (add fixture constants + one new test at the top of the struct; rewire the four tokenizer-touching tests to the constants; the file is 139 lines and holds 7 tests today)

**Interfaces:**
- Consumes: `WhisperModelStore.tokenizerFolder(for: String) -> URL?` (WhisperTranscriptionService.swift:109), `WhisperModelStore.tokenizerVariant(for: String) -> ModelVariant?` (:96), `WhisperModelStore.delete(_ variant: String)` (:219), `WhisperModelStore.isDownloaded(_ variant: String) -> Bool` (:145), `WhisperModelStore.needsTokenizerUpdate(_ variant: String) -> Bool` (:155), `WhisperModelStore.hasLocalData(_ variant: String) -> Bool` (:235), `WhisperModelCatalog.models: [WhisperModel]` (:22), `WhisperModel.variant: String` (:10).
- Produces (test-private): `WhisperModelStoreTests.downloadedFixture`, `.tokenizerUpdateFixture`, `.leftoverFixture`, `.deleteFixture` (all `private static let … : String`), `.fixtureVariants: [String]`, `.fixture(_ base: String) -> String`, and the test `fixtureVariantsOwnTheirTokenizerFolders()`.

Why this is a bug and not tidying: `WhisperModelStore.tokenizerFolder(for:)` resolves a *size*, not a variant — `tokenizerVariant(for:)` matches by `variant.contains($0.description)` (WhisperTranscriptionService.swift:96-98), so `"openai_whisper-small-test-<UUID>"` and the catalog's `"openai_whisper-small"` both land on `<store>/tokenizers/models/openai/whisper-small`. On a machine where Small is downloaded, `modelWithoutItsTokenizerNeedsAnUpdate` reads the user's real tokenizer (so `#expect(WhisperModelStore.needsTokenizerUpdate(variant))` fails) and its `defer { WhisperModelStore.delete(variant) }` deletes it, after which the app tells the user Small "needs a small one-time update". The same collision exists *between* two tests today — `tokenizerOnlyLeftoverCountsAsLocalData` and `deleteRemovesTheTokenizer` both use `openai_whisper-tiny-test-…`, and `WhisperModelStoreTests` is not `.serialized`, so Swift Testing runs them in parallel and one's `delete` can race the other's `#expect`.

**Every rewire below keeps the test's existing `defer { WhisperModelStore.delete(variant) }` line.** That `defer` is the only cleanup these fixtures have; dropping one leaves `tokenizer.json` in the real Application Support store forever with the suite still green — the exact class of store pollution this task exists to remove. All four old snippets quote it, so applying them literally cannot lose it.

- [ ] **Step 1: Write the failing test (and route the fixtures through named constants)**

In `MinuteTests/WhisperModelStoreTests.swift`, replace lines 1-9:

```swift
import Foundation
import Testing
@testable import Minute

/// hasLocalData/isDownloaded drive the picker's Delete swipe action: a
/// variant with partial files must be deletable without ever being offered
/// as a usable model.
struct WhisperModelStoreTests {
    @Test("Partial downloads are deletable but never report as downloaded")
```

with:

```swift
import Foundation
import Testing
@testable import Minute

/// hasLocalData/isDownloaded drive the picker's Delete swipe action: a
/// variant with partial files must be deletable without ever being offered
/// as a usable model.
struct WhisperModelStoreTests {
    // MARK: Fixture variants
    //
    // A fixture that exercises the tokenizer half of the store has to name a
    // real Whisper SIZE — tokenizerVariant matches by substring, and a name
    // that maps to no size makes tokenizerFolder nil, which skips exactly the
    // code under test. But the tokenizer folder is per size, not per variant:
    // "openai_whisper-small-test-<UUID>" resolves to the very folder the
    // catalog's Small model uses, so on a machine that has Small downloaded
    // the test reads the user's real tokenizer AND its `delete` wipes it,
    // leaving the app claiming Small "needs a small one-time update". Two
    // fixtures sharing a size collide with each other the same way, because
    // this suite is not .serialized and Swift Testing runs its tests in
    // parallel. fixtureVariantsOwnTheirTokenizerFolders holds both rules.

    /// tokenizerIsRequiredForADownloadedModel
    private static let downloadedFixture = "openai_whisper-medium-test"
    /// modelWithoutItsTokenizerNeedsAnUpdate
    private static let tokenizerUpdateFixture = "openai_whisper-small-test"
    /// tokenizerOnlyLeftoverCountsAsLocalData
    private static let leftoverFixture = "openai_whisper-tiny-test"
    /// deleteRemovesTheTokenizer
    private static let deleteFixture = "openai_whisper-tiny-test"

    private static let fixtureVariants = [
        downloadedFixture, tokenizerUpdateFixture, leftoverFixture, deleteFixture,
    ]

    /// A variant name under one of those fixtures, unique per run so two
    /// executions can never share a model folder.
    private static func fixture(_ base: String) -> String {
        "\(base)-\(UUID().uuidString)"
    }

    @Test("No fixture shares a tokenizer folder with a catalog model or another fixture")
    func fixtureVariantsOwnTheirTokenizerFolders() throws {
        let catalogFolders = Set(WhisperModelCatalog.models.compactMap {
            WhisperModelStore.tokenizerFolder(for: $0.variant)?.path
        })
        // Every catalog model maps to a size, and to a folder of its own.
        #expect(catalogFolders.count == WhisperModelCatalog.models.count)

        var fixtureFolders: Set<String> = []
        for base in Self.fixtureVariants {
            let folder = try #require(WhisperModelStore.tokenizerFolder(for: Self.fixture(base))).path
            // A fixture must never touch a folder a real download owns…
            #expect(!catalogFolders.contains(folder))
            // …nor one another fixture owns, since they run in parallel.
            #expect(fixtureFolders.insert(folder).inserted)
        }
    }

    @Test("Partial downloads are deletable but never report as downloaded")
```

Then replace lines 63-64 (in `tokenizerIsRequiredForADownloadedModel`):

```swift
        let variant = "openai_whisper-medium-test-\(UUID().uuidString)"
        defer { WhisperModelStore.delete(variant) }
```

with:

```swift
        let variant = Self.fixture(Self.downloadedFixture)
        defer { WhisperModelStore.delete(variant) }
```

Then replace lines 85-86 (in `modelWithoutItsTokenizerNeedsAnUpdate`):

```swift
        let variant = "openai_whisper-small-test-\(UUID().uuidString)"
        defer { WhisperModelStore.delete(variant) }
```

with:

```swift
        let variant = Self.fixture(Self.tokenizerUpdateFixture)
        defer { WhisperModelStore.delete(variant) }
```

Then replace lines 113-120 (in `tokenizerOnlyLeftoverCountsAsLocalData`) — note the `defer` on line 114, which stays:

```swift
        let variant = "openai_whisper-tiny-test-\(UUID().uuidString)"
        defer { WhisperModelStore.delete(variant) }

        let tokenizer = try #require(WhisperModelStore.tokenizerFolder(for: variant))
        try FileManager.default.createDirectory(at: tokenizer, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: tokenizer.appending(path: "tokenizer.json"))

        // A delete that half-succeeded, or a tokenizer fetched for a model
```

with:

```swift
        let variant = Self.fixture(Self.leftoverFixture)
        defer { WhisperModelStore.delete(variant) }

        let tokenizer = try #require(WhisperModelStore.tokenizerFolder(for: variant))
        try FileManager.default.createDirectory(at: tokenizer, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: tokenizer.appending(path: "tokenizer.json"))

        // A delete that half-succeeded, or a tokenizer fetched for a model
```

Then replace lines 129-136 (in `deleteRemovesTheTokenizer`):

```swift
        let variant = "openai_whisper-tiny-test-\(UUID().uuidString)"
        defer { WhisperModelStore.delete(variant) }

        let tokenizer = try #require(WhisperModelStore.tokenizerFolder(for: variant))
        try FileManager.default.createDirectory(at: tokenizer, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: tokenizer.appending(path: "tokenizer.json"))

        WhisperModelStore.delete(variant)
```

with:

```swift
        let variant = Self.fixture(Self.deleteFixture)
        defer { WhisperModelStore.delete(variant) }

        let tokenizer = try #require(WhisperModelStore.tokenizerFolder(for: variant))
        try FileManager.default.createDirectory(at: tokenizer, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: tokenizer.appending(path: "tokenizer.json"))

        WhisperModelStore.delete(variant)
```

The two blocks above are distinguished by their last line: `// A delete that half-succeeded, …` for the leftover test, `WhisperModelStore.delete(variant)` for the delete test.

- [ ] **Step 2: Run the suite to verify it fails**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MinuteTests/WhisperModelStoreTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔ Test run|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST FAILED`. `fixtureVariantsOwnTheirTokenizerFolders` fails twice — once on `#expect(!catalogFolders.contains(folder))` for the `openai_whisper-small-test` fixture (it resolves to the catalog Small model's `.../tokenizers/models/openai/whisper-small`), and once on `#expect(fixtureFolders.insert(folder).inserted)` for the second `openai_whisper-tiny-test` entry. The other 7 tests pass.

- [ ] **Step 3: Move the two colliding fixtures onto sizes nothing else claims**

The catalog ships `base`, `small` and `large-v3` (WhisperTranscriptionService.swift:22-41); the sizes left free are `tiny`, `tiny.en`, `base.en`, `small.en`, `medium`, `medium.en`, `large` and `large-v2`. In `MinuteTests/WhisperModelStoreTests.swift`, replace:

```swift
    /// modelWithoutItsTokenizerNeedsAnUpdate
    private static let tokenizerUpdateFixture = "openai_whisper-small-test"
    /// tokenizerOnlyLeftoverCountsAsLocalData
    private static let leftoverFixture = "openai_whisper-tiny-test"
    /// deleteRemovesTheTokenizer
    private static let deleteFixture = "openai_whisper-tiny-test"
```

with:

```swift
    /// modelWithoutItsTokenizerNeedsAnUpdate. NOT "small": that is a catalog
    /// size, and this test both reads and deletes the tokenizer folder.
    private static let tokenizerUpdateFixture = "openai_whisper-large-v2-test"
    /// tokenizerOnlyLeftoverCountsAsLocalData
    private static let leftoverFixture = "openai_whisper-tiny-test"
    /// deleteRemovesTheTokenizer. NOT "tiny": leftoverFixture owns that size,
    /// and this test deletes the folder while that one is asserting on it.
    private static let deleteFixture = "openai_whisper-base.en-test"
```

`"large-v2"` and `"base.en"` are the longest matching descriptions in their names, so `tokenizerVariant` answers `.largev2` and `.baseEn`, never `.large` or `.base` — true under both the hand-written order shipping today and the sorted order Task 4 installs.

- [ ] **Step 4: Run the suite to verify it passes**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MinuteTests/WhisperModelStoreTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔ Test run|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 8 tests.

- [ ] **Step 5: Confirm all four `defer` cleanups survived the rewire**

```bash
grep -c "defer { WhisperModelStore.delete(variant) }" MinuteTests/WhisperModelStoreTests.swift
```
Expected: `6` (the four tokenizer fixtures plus `partialDownloadLifecycle` and `downloadCacheLifecycle`, which the rewire does not touch). Anything lower means a replacement swallowed a cleanup line and the fixture is now leaking into the real store.

- [ ] **Step 6: Run the full unit suite**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 425 tests.

- [ ] **Step 7: Lint**

```bash
swiftlint --strict --reporter github-actions-logging 2>&1 | grep -E "^::(error|warning)|Done linting"
```
Expected: `Done linting! Found 0 violations, 0 serious in <N> files.`

- [ ] **Step 8: Commit**

```bash
git add MinuteTests/WhisperModelStoreTests.swift
git commit -m "$(cat <<'EOF'
test: stop Whisper store fixtures from sharing real tokenizer folders

tokenizerFolder resolves a SIZE, not a variant, so the fixture
"openai_whisper-small-test-<UUID>" pointed at the same folder the catalog's
Small model uses. On a machine with Small downloaded the "needs an update"
test read the user's real tokenizer and its cleanup deleted it, after which
the app told them Small "needs a small one-time update". Two fixtures also
shared the "tiny" folder while the suite runs its tests in parallel.

Fixtures now come from named constants on sizes the catalog never ships, and
a new test holds both rules: no fixture shares a tokenizer folder with a
catalog model, and no two fixtures share one with each other.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Bind the delete-replacement policy to the real catalog order (b2-T2-minor-1)

**Files:**
- Test: `MinuteTests/WhisperDownloadSelectionTests.swift:38-44` (add one case at the end of the struct; the file is 44 lines and holds 3 tests today)
- Test: `MinuteTests/TranscriptionEngineSettingsTests.swift:69-72` (extend `catalogIsConsistent`, which spans :60-72)

**Interfaces:**
- Consumes: `WhisperDownloadCenter.replacementSelection(after deleted: String, selected: String, downloaded: [String]) -> String?` (WhisperDownloadCenter.swift:41-43), `WhisperModelCatalog.models: [WhisperModel]`, `WhisperModelCatalog.defaultModel: WhisperModel` (`models.last!`, WhisperTranscriptionService.swift:45), `WhisperModel.variant: String`, `WhisperModel.approximateMegabytes: Int`, `WhisperModel: Equatable`.
- Produces: no production symbols. Two new assertions in `catalogIsConsistent` and one new test `picksTheSurvivorFromTheRealCatalog()`.

Why: every literal in `WhisperDownloadSelectionTests` is `"openai_whisper-large-v3"`, which is not a catalog variant (the real one is `"openai_whisper-large-v3-v20240930_626MB"`), and `catalogIsConsistent` checks uniqueness but never ordering. Two behaviours silently depend on the catalog being ordered smallest → most accurate: `defaultModel = models.last!` and `downloaded.last { $0 != deleted }` in `replacementSelection`. Reordering the array for display would flip both to the least accurate model with the whole suite green.

- [ ] **Step 1: Write the failing tests**

In `MinuteTests/WhisperDownloadSelectionTests.swift`, replace lines 38-44 (the tail of the struct):

```swift
        #expect(WhisperDownloadCenter.replacementSelection(
            after: "openai_whisper-large-v3",
            selected: "openai_whisper-large-v3",
            downloaded: ["openai_whisper-large-v3"]
        ) == nil)
    }
}
```

with:

```swift
        #expect(WhisperDownloadCenter.replacementSelection(
            after: "openai_whisper-large-v3",
            selected: "openai_whisper-large-v3",
            downloaded: ["openai_whisper-large-v3"]
        ) == nil)
    }

    @Test("Deleting the real catalog's most accurate model falls back to the one below it")
    func picksTheSurvivorFromTheRealCatalog() throws {
        // The cases above use invented variant names — none of them is a
        // shipping variant, so nothing in this suite proved the function
        // works on the strings it is actually handed. This one runs it over
        // the real catalog.
        let variants = WhisperModelCatalog.models.map(\.variant)
        try #require(variants.count >= 2)
        let deleted = try #require(variants.last)

        #expect(WhisperDownloadCenter.replacementSelection(
            after: deleted,
            selected: deleted,
            downloaded: Array(variants.dropLast())
        ) == variants[variants.count - 2])
    }
}
```

Then in `MinuteTests/TranscriptionEngineSettingsTests.swift`, replace lines 69-72:

```swift
        // The default must be one of the offered models, or the picker would
        // show a selection the user can never see.
        #expect(variants.contains(WhisperModelCatalog.defaultModel.variant))
    }
```

with:

```swift
        // The default must be one of the offered models, or the picker would
        // show a selection the user can never see.
        #expect(variants.contains(WhisperModelCatalog.defaultModel.variant))
        // The catalog is ordered smallest → most accurate, and two behaviours
        // read it that way without saying so: defaultModel is models.last, and
        // WhisperDownloadCenter.replacementSelection takes the LAST still-
        // downloaded variant when the selected model is deleted. A reorder for
        // display would quietly hand both the least accurate model.
        #expect(WhisperModelCatalog.models.last == WhisperModelCatalog.defaultModel)
        let sizes = WhisperModelCatalog.models.map(\.approximateMegabytes)
        #expect(sizes == sizes.sorted())
    }
```

- [ ] **Step 2: Run both suites to verify the new case compiles and is green**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MinuteTests/WhisperDownloadSelectionTests -only-testing:MinuteTests/TranscriptionEngineSettingsTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔ Test run|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`. **These assertions pass against the current catalog — that is the point: they are regression locks on invariants nothing else states.** Step 3 proves each one bites; do not trust any of them until it has.

- [ ] **Step 3: Prove each of the three new assertions actually fails**

Three separate mutations, because no single one reaches all three: `defaultModel` is *defined* as `models.last!`, so a plain reorder of `models` keeps `models.last == defaultModel` true, and `picksTheSurvivorFromTheRealCatalog` derives its expected value from the same array it deletes from, so a reorder leaves it true as well. Apply each probe, run, revert, and confirm the production file is clean before moving on.

**Probe A — `models.last == WhisperModelCatalog.defaultModel`.** In `Minute/Services/WhisperTranscriptionService.swift`, replace line 45:

```swift
    static let defaultModel = models.last!
```

with:

```swift
    static let defaultModel = models.first!
```

Run:

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MinuteTests/TranscriptionEngineSettingsTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔ Test run|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST FAILED` on `catalogIsConsistent` at `#expect(WhisperModelCatalog.models.last == WhisperModelCatalog.defaultModel)`. Restore `models.last!`.

**Probe B — `sizes == sizes.sorted()`.** This is the assertion a display reorder trips. In the same file, replace line 27 (the Base row's size):

```swift
            approximateMegabytes: 150
```

with:

```swift
            approximateMegabytes: 900
```

Run the same command. Expected: `TEST FAILED` on `catalogIsConsistent` at `#expect(sizes == sizes.sorted())` — sizes become `[900, 490, 630]`. `#expect(model.approximateMegabytes > 0)` still passes, so this failure is the ordering lock and nothing else. Restore `150`.

**Probe C — `picksTheSurvivorFromTheRealCatalog`.** In `Minute/Services/WhisperDownloadCenter.swift`, replace line 43:

```swift
        return downloaded.last { $0 != deleted }
```

with:

```swift
        return downloaded.first { $0 != deleted }
```

Run:

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MinuteTests/WhisperDownloadSelectionTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔ Test run|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST FAILED` on both `picksTheMostAccurateSurvivor` and the new `picksTheSurvivorFromTheRealCatalog` (which gets `"openai_whisper-base"` where it expects `"openai_whisper-small"`). Restore `downloaded.last`.

Then confirm both production files are untouched:

```bash
git diff --stat Minute/Services/WhisperTranscriptionService.swift Minute/Services/WhisperDownloadCenter.swift
```
Expected: no output (this task changes no production file).

- [ ] **Step 4: Run both suites to verify they pass**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MinuteTests/WhisperDownloadSelectionTests -only-testing:MinuteTests/TranscriptionEngineSettingsTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔ Test run|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 4 tests in `WhisperDownloadSelectionTests`.

- [ ] **Step 5: Run the full unit suite**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 426 tests.

- [ ] **Step 6: Lint**

```bash
swiftlint --strict --reporter github-actions-logging 2>&1 | grep -E "^::(error|warning)|Done linting"
```
Expected: `Done linting! Found 0 violations, 0 serious in <N> files.`

- [ ] **Step 7: Commit**

```bash
git add MinuteTests/WhisperDownloadSelectionTests.swift MinuteTests/TranscriptionEngineSettingsTests.swift
git commit -m "$(cat <<'EOF'
test: lock the Whisper catalog's smallest-to-most-accurate ordering

defaultModel is models.last and replacementSelection takes the last still-
downloaded variant, so both silently depend on the catalog being ordered
smallest to most accurate — and nothing said so. Every selection test used
invented variant names, so a reorder for display would have handed both the
least accurate model with the suite green.

catalogIsConsistent now asserts models.last == defaultModel and that the
approximate sizes ascend, and the selection suite gains a case built from the
shipping catalog: delete the last model, expect the one below it.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Engine-unavailable tests skip visibly, and the Apple one stops downloading assets first (A5)

**Files:**
- Test: `MinuteTests/TranscriptionUnavailableErrorTests.swift:1-4` (imports) and `:25-57` (both engine tests plus the struct's closing brace; the file is 57 lines)

**Interfaces:**
- Consumes: `WhisperModelStore.isDownloaded(_ variant: String) -> Bool` (nonisolated static on a plain enum, WhisperTranscriptionService.swift:145), `AppSettings.whisperModel: String` (nonisolated static, AppSettings.swift:86 — WhisperTranscriptionService's `private let variant` reads exactly this at WhisperTranscriptionService.swift:262), `Speech.SpeechTranscriber.isAvailable: Bool` (nonisolated public static; the same predicate `TranscriptionService.prepare()` gates on at TranscriptionService.swift:55), `Testing.Issue.record(_:)`.
- Produces: no production symbols. Two `@Test(.enabled(if:))` traits replacing two silent `return`s.

This task changes only test scaffolding — there is no new behaviour to drive with a failing test, so it is verified by the suite passing under both branches of each trait (Step 3 flips each predicate to prove the skip is real and visible) plus the full suite and lint.

Why: both tests `return` with zero assertions when the engine happens to be available, and nothing in the run output says so — the repo's convention for that is `.enabled(if:)` (SummarizationIntegrationTests.swift:8). Worse for the Apple case: the bail-out happens *after* `await engine.prepare()`, and `prepare()` calls `AssetInventory.assetInstallationRequest(supporting:)` then `downloadAndInstall()` (TranscriptionService.swift:73-76) — so on a physical device the unit suite starts a speech-model download before deciding it has nothing to assert.

- [ ] **Step 1: Record the current behaviour**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MinuteTests/TranscriptionUnavailableErrorTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔ Test run|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 3 tests. On the simulator neither engine is available, so all three genuinely assert.

- [ ] **Step 2: Replace the silent guards with conditions**

In `MinuteTests/TranscriptionUnavailableErrorTests.swift`, replace lines 1-4:

```swift
import AVFoundation
import Foundation
import Testing
@testable import Minute
```

with:

```swift
import AVFoundation
import Foundation
import Speech
import Testing
@testable import Minute
```

Then replace lines 25-57 (both engine tests and the struct's closing brace):

```swift
    @Test func whisperFileTranscriptionWithoutAModelThrowsTheExplanation() async throws {
        let engine = WhisperTranscriptionService()
        await engine.prepare()
        guard case .unavailable(let message) = engine.availability else {
            // A downloaded model on this machine makes the unavailable path
            // unreachable; nothing to assert.
            return
        }
        let url = try makeWavFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)

        await #expect(throws: TranscriptionUnavailableError(message: message)) {
            _ = try await engine.transcribe(file: file)
        }
    }

    @Test func appleSpeechFileTranscriptionWhenUnavailableThrowsTheExplanation() async throws {
        let engine = TranscriptionService()
        await engine.prepare()
        guard case .unavailable(let message) = engine.availability else {
            // Only a physical iPhone has SpeechTranscriber; on one, nothing to assert.
            return
        }
        let url = try makeWavFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)

        await #expect(throws: TranscriptionUnavailableError(message: message)) {
            _ = try await engine.transcribe(file: file)
        }
    }
}
```

with:

```swift
    /// A downloaded model on this machine makes the unavailable path
    /// unreachable. Stated as a condition rather than an early `return`, so
    /// the run output names the skip instead of reporting a test that
    /// asserted nothing. The predicate is the one `prepare()` itself gates
    /// on (WhisperTranscriptionService.swift:279), over the same variant the
    /// engine picks up from AppSettings.
    ///
    /// If this ever fails on a developer machine, look here first:
    /// TranscriptionEngineSettingsTests.whisperModelDefaultsToCatalog removes
    /// the "transcription.whisperModel" key for the length of its body, and
    /// suites run in parallel with each other. A trait evaluated inside that
    /// window reads the catalog default while the engine's `variant` — read
    /// once at init, from the same key — can resolve to a different, actually
    /// downloaded model, and Issue.record fires. Simulator and CI have
    /// nothing downloaded, so the window is harmless there.
    @Test(
        "Whisper's file path explains itself when the model isn't downloaded",
        .enabled(if: !WhisperModelStore.isDownloaded(AppSettings.whisperModel))
    )
    func whisperFileTranscriptionWithoutAModelThrowsTheExplanation() async throws {
        let engine = WhisperTranscriptionService()
        await engine.prepare()
        guard case .unavailable(let message) = engine.availability else {
            Issue.record("prepare() reported \(engine.availability); the condition above guarantees the model isn't downloaded")
            return
        }
        let url = try makeWavFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)

        await #expect(throws: TranscriptionUnavailableError(message: message)) {
            _ = try await engine.transcribe(file: file)
        }
    }

    /// Only a physical iPhone has SpeechTranscriber. Gating on isAvailable
    /// before the body rather than after `prepare()` is what keeps a device
    /// run honest: prepare() calls AssetInventory.assetInstallationRequest
    /// and downloadAndInstall (TranscriptionService.swift:73-76), so the old
    /// early return started a speech-model download and only then decided it
    /// had nothing to assert.
    @Test(
        "Apple Speech's file path explains itself when the engine is unavailable",
        .enabled(if: !SpeechTranscriber.isAvailable)
    )
    func appleSpeechFileTranscriptionWhenUnavailableThrowsTheExplanation() async throws {
        let engine = TranscriptionService()
        await engine.prepare()
        guard case .unavailable(let message) = engine.availability else {
            Issue.record("prepare() reported \(engine.availability); the condition above guarantees SpeechTranscriber is unavailable")
            return
        }
        let url = try makeWavFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)

        await #expect(throws: TranscriptionUnavailableError(message: message)) {
            _ = try await engine.transcribe(file: file)
        }
    }
}
```

The `:279` in the first doc comment is the `guard WhisperModelStore.isDownloaded(variant) else {` line as of `b481626` (`func prepare() async {` is :278) — verified with `grep -n "guard WhisperModelStore.isDownloaded(variant) else" Minute/Services/WhisperTranscriptionService.swift`. Task 4 and Task 6 both edit this file below that point, so the number does not move; re-run that grep if the tasks are done out of order and correct the comment to whatever it prints.

- [ ] **Step 3: Prove each skip is real and visible, then revert the probe**

Temporarily invert both conditions — `.enabled(if: WhisperModelStore.isDownloaded(AppSettings.whisperModel))` and `.enabled(if: SpeechTranscriber.isAvailable)` — and run:

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MinuteTests/TranscriptionUnavailableErrorTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "skipped|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: the output names both tests as skipped (`Test … skipped`) and the run reports 1 test, not 3 — which is exactly what the old silent `return` never showed.

Restore both `!` operators, then confirm nothing else drifted:

```bash
git diff MinuteTests/TranscriptionUnavailableErrorTests.swift | grep -c "enabled(if: !"
```
Expected: `2`.

- [ ] **Step 4: Run the suite to verify it passes**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MinuteTests/TranscriptionUnavailableErrorTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔ Test run|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 3 tests (the simulator has neither engine, so both conditions are true and both tests assert).

- [ ] **Step 5: Run the full unit suite**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 426 tests.

- [ ] **Step 6: Lint**

```bash
swiftlint --strict --reporter github-actions-logging 2>&1 | grep -E "^::(error|warning)|Done linting"
```
Expected: `Done linting! Found 0 violations, 0 serious in <N> files.`

- [ ] **Step 7: Commit**

```bash
git add MinuteTests/TranscriptionUnavailableErrorTests.swift
git commit -m "$(cat <<'EOF'
test: gate the engine-unavailable tests on a condition, not a silent return

Both tests returned with zero assertions when the engine happened to be
available, and nothing in the run output said so. The Apple one was worse:
the bail-out came after prepare(), which calls
AssetInventory.assetInstallationRequest().downloadAndInstall() — so on a
physical device the unit suite kicked off a speech-model download and only
then decided it had nothing to assert.

Both now use .enabled(if:) — the repo's existing convention — on the same
predicates the engines gate on, so the skip is visible in the run and
prepare() never runs on a device that has the engine.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Derive the tokenizer size table from WhisperKit's own enum (b2-T7-minor-2)

**Files:**
- Modify: `Minute/Services/WhisperTranscriptionService.swift:87-91` (the hand-written `tokenizerVariants`)
- Test: `MinuteTests/WhisperModelStoreTests.swift:1-3` (imports) and one new test after `fixtureVariantsOwnTheirTokenizerFolders`

**Interfaces:**
- Consumes: `WhisperKit.ModelVariant` — `@frozen public enum ModelVariant: CustomStringConvertible, CaseIterable` with 11 cases and the descriptions listed in the package-sources note above; `ModelVariant.allCases: [ModelVariant]`, `ModelVariant.description: String`.
- Produces: `WhisperModelStore.tokenizerVariants: [ModelVariant]` changes from `private static let` to an **internal** `static var` (computed). `tokenizerVariant(for:)` keeps its signature `static func tokenizerVariant(for variant: String) -> ModelVariant?`.

Why: the hand-written list fails *wrong* rather than open. A catalog row added later — say `"openai_whisper-large-v4-…"` — contains `"large"`, so `tokenizerVariant` returns `.large`, `hasTokenizer` checks the `whisper-large` folder, `isDownloaded` reports true, and the load gets the wrong tokenizer with no error path anywhere. Sorting `ModelVariant.allCases` by descending description length reproduces the stated most-specific-first rule exactly: `medium.en`(9) → `large-v3`/`large-v2`/`small.en`(8) → `tiny.en`/`base.en`(7) → `medium`(6) → `large`/`small`(5) → `base`/`tiny`(4). Ties are only between distinct equal-length names, and no two distinct equal-length strings can contain each other, so `sorted`'s instability among ties is harmless.

- [ ] **Step 1: Write the failing test**

This test is the first thing under `MinuteTests/` to name WhisperKit — the type `ModelVariant` and its `description` (`grep -rn "import WhisperKit" MinuteTests/` returns nothing today), so it adds the import. That import resolves: `MinuteTests` declares no package product dependencies of its own (project.pbxproj:275-276, and this plan may not edit that file), but `@testable import Minute` already loads Minute's swiftmodule, which itself `import`s WhisperKit — so WhisperKit's swiftmodule is necessarily on the test target's search path already, and the test bundle resolves its symbols through `BUNDLE_LOADER` against the host app, which links the package product (project.pbxproj:224).

In `MinuteTests/WhisperModelStoreTests.swift`, replace lines 1-3:

```swift
import Foundation
import Testing
@testable import Minute
```

with:

```swift
import Foundation
import Testing
import WhisperKit
@testable import Minute
```

Then insert directly after the closing brace of `fixtureVariantsOwnTheirTokenizerFolders()` (added in Task 1) and before `@Test("Partial downloads are deletable but never report as downloaded")`:

```swift
    @Test("Every Whisper size WhisperKit knows maps to its own tokenizer")
    func everyWhisperSizeMapsToItself() {
        // Derived from ModelVariant.allCases, so a size a future WhisperKit
        // release adds is in this table the day the package updates — and it
        // must resolve to itself, never to a shorter name it happens to
        // contain: "large-v3" must not answer .large, "base.en" not .base.
        let sizes = WhisperModelStore.tokenizerVariants.map(\.description)
        #expect(!sizes.isEmpty)
        // The assertion that holds the DERIVATION, not just the table: a list
        // maintained by hand matches allCases only until WhisperKit ships a
        // twelfth size. This is what goes red on that day, instead of the
        // wrong tokenizer being loaded in silence. It cannot fail on today's
        // eleven-entry hand-written list — nothing can, short of a package
        // update — so it is a forward lock, not this task's RED.
        #expect(sizes.count == ModelVariant.allCases.count)
        #expect(Set(sizes).count == sizes.count)
        for size in sizes {
            #expect(WhisperModelStore.tokenizerVariant(for: "openai_whisper-\(size)")?.description == size)
        }
        // A name that is not a Whisper model at all still maps to nothing.
        #expect(WhisperModelStore.tokenizerVariant(for: "nonexistent-model-variant") == nil)
    }
```

- [ ] **Step 2: Run the suite to verify it fails**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MinuteTests/WhisperModelStoreTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔ Test run|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: a compile error, `error: 'tokenizerVariants' is inaccessible due to 'private' protection level`. That is the RED this task drives.

If instead the error is `no such module 'WhisperKit'`, the import assumption above is wrong and the fix is **not** a project change (forbidden): drop the `import WhisperKit` line and the one `#expect(sizes.count == ModelVariant.allCases.count)` assertion, record the gap under "Not done in this track", and continue — the rest of the test stands on `WhisperModelStore.tokenizerVariants` alone, whose element type is inferred and needs no import. Re-run and confirm the `private` error appears before Step 3.

- [ ] **Step 3: Derive the table**

In `Minute/Services/WhisperTranscriptionService.swift`, replace lines 87-91:

```swift
    /// Whisper sizes, most specific name first: "large-v3" must win over
    /// "large", and "base.en" over "base".
    private static let tokenizerVariants: [ModelVariant] = [
        .largev3, .largev2, .large, .mediumEn, .medium, .smallEn, .small, .baseEn, .base, .tinyEn, .tiny,
    ]
```

with:

```swift
    /// Whisper sizes, most specific name first: "large-v3" must win over
    /// "large", and "base.en" over "base".
    ///
    /// Derived from WhisperKit's own enum rather than listed by hand, because
    /// a hand-written list fails WRONG rather than open. A catalog row added
    /// later — say "openai_whisper-large-v4-…" — contains "large", so a stale
    /// list answers .large, hasTokenizer checks the whisper-large folder,
    /// isDownloaded reports true, and the load quietly gets the wrong
    /// tokenizer with no error path anywhere.
    ///
    /// Longest description first IS the most-specific-first rule: a size's
    /// name can only be contained in a strictly longer one, so the longest
    /// match is always the most specific. Ties are between distinct
    /// equal-length names, which cannot contain each other, so `sorted`
    /// making no promise about their order is harmless.
    ///
    /// Computed, not stored: eleven cases sort in nanoseconds, and a stored
    /// static of a public enum from another module (ModelVariant is not
    /// Sendable) is a concurrency-checking question this simply doesn't have.
    /// Internal rather than private so the derivation itself is testable.
    static var tokenizerVariants: [ModelVariant] {
        ModelVariant.allCases.sorted { $0.description.count > $1.description.count }
    }
```

- [ ] **Step 4: Run the suite to verify it passes**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MinuteTests/WhisperModelStoreTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔ Test run|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 9 tests, including `everyWhisperSizeMapsToItself`. `tokenizerFolderMatchesTheHubLayout` still passes, which is the proof the ordering did not regress: `"openai_whisper-large-v3-v20240930_626MB"` still resolves to `whisper-large-v3`, not `whisper-large`. `fixtureVariantsOwnTheirTokenizerFolders` still passes too, which is the proof Task 1's `large-v2` and `base.en` fixtures survive the reordering.

- [ ] **Step 5: Run the full unit suite**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 427 tests.

- [ ] **Step 6: Lint**

```bash
swiftlint --strict --reporter github-actions-logging 2>&1 | grep -E "^::(error|warning)|Done linting"
```
Expected: `Done linting! Found 0 violations, 0 serious in <N> files.`

- [ ] **Step 7: Commit**

```bash
git add Minute/Services/WhisperTranscriptionService.swift MinuteTests/WhisperModelStoreTests.swift
git commit -m "$(cat <<'EOF'
refactor: derive the Whisper tokenizer table from ModelVariant.allCases

The eleven sizes were listed by hand, and that list fails wrong rather than
open: a catalog row added later like "openai_whisper-large-v4-…" contains
"large", so a stale table answers .large, hasTokenizer checks the
whisper-large folder, isDownloaded reports true, and the load gets the wrong
tokenizer with no error path.

ModelVariant is CaseIterable, so the table is now allCases sorted by
descending description length — which is exactly the stated most-specific-
first rule, since a size's name can only be contained in a longer one. A new
test asserts the table covers allCases and that every size WhisperKit knows
resolves to itself.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: The Apple engine's degrade refuses to save a blank summary (B8)

**Files:**
- Modify: `Minute/Services/SummarizationService.swift:298-310` (the refusal degrade), `:431-437` (the overflow fallback), `:539-553` (add the message constant and the two helpers directly after `mechanicalSummary`)
- Test: `MinuteTests/SummaryFallbackTests.swift:79-84` (add two cases at the end of the struct; the file is 84 lines and holds 6 tests today)

**Interfaces:**
- Consumes: `SummarizationService.mechanicalSummary(from notes: [ChunkNotes]) -> MeetingSummary` (private *instance* method, SummarizationService.swift:541), `SummarizationService.normalizedActionItems(_:)` (:621) and `normalizedPerspectives(_:)` (:654), both private instance methods; `SummarizerError.generationFailed(String)`; `MeetingSummary` fields `overview: String`, `keyPoints: [String]`, `decisions: [String]`, `actionItems: [ActionItem]`, `openQuestions: [String]`, `sections: [SummarySection]?` (MeetingSummary.swift:16), `suggestedTitle: String?` (:13), `speakerPerspectives: [SpeakerPerspective]?`; `SummarySection.items: [String]`; the memberwise `SummarizationService(language: String? = nil)` — `struct SummarizationService` at :126 with `var language: String? = nil` at :151, so `SummarizationService()` compiles (precedent at SummarizationIntegrationTests.swift:19).
- Produces:
  - `SummarizationService.emptySummaryMessage: String` — `private static let`, matching `MLXSummarizationService.unreadableMessage` (`private static let`, MLXSummarizationService.swift:622). Its only reader is `validated` two lines below and no test names it, so it stays off the type's surface.
  - `SummarizationService.validated(_ summary: MeetingSummary) throws -> MeetingSummary` — `private static`, same shape as MLXSummarizationService.swift:704-716.
  - `SummarizationService.degradedSummary(from notes: [ChunkNotes]) throws -> MeetingSummary` — internal **instance** method, the tested seam. MLX's counterpart (MLXSummarizationService.swift:951) is `static` because *its* `mechanicalSummary` is static; this engine's is an instance method that calls the instance helpers `normalizedActionItems`/`normalizedPerspectives`, so this one has to be an instance method too.

Why: `summary = mechanicalSummary(from: notes)` (:306, on `.guardrailViolation`/`.refusal`) and `return mechanicalSummary(from: current)` (:436, the overflow fallback) have no content guard, while the MLX engine gained exactly that (`validated` at MLXSummarizationService.swift:704-716, reached through `degradedSummary` at :951). Every chunk can legitimately return empty arrays — the `@Guide` text says "Empty if none" — so an all-empty fold saves blank notes over the meeting's Generate empty-state, the affordance the user needs to retry, with no error shown anywhere.

The two new test display names carry an "(Apple engine)" suffix on purpose: the MLX halves of this same pair already exist at `MinuteTests/SummarizationEngineSettingsTests.swift:229-251` under the bare names "Notes that fold to nothing fail instead of blanking the meeting" and "A fold that rescued something is kept". Identical display names in two suites compile and have distinct IDs, but a run log or CI failure report would show two identically-named tests with nothing to say which engine broke.

- [ ] **Step 1: Write the failing tests**

In `MinuteTests/SummaryFallbackTests.swift`, replace lines 79-84 (the tail of the struct):

```swift
    @Test func chunkBudgetClampsPathologicalRatios() {
        #expect(SummarizationService.chunkBudget(transcriptChars: 100, transcriptTokens: 1_000) == 1_500)
        #expect(SummarizationService.chunkBudget(transcriptChars: 100_000, transcriptTokens: 1_000) == 12_000)
        #expect(SummarizationService.chunkBudget(transcriptChars: 100, transcriptTokens: 0) == TranscriptChunker.defaultMaxChars)
    }
}
```

with:

```swift
    @Test func chunkBudgetClampsPathologicalRatios() {
        #expect(SummarizationService.chunkBudget(transcriptChars: 100, transcriptTokens: 1_000) == 1_500)
        #expect(SummarizationService.chunkBudget(transcriptChars: 100_000, transcriptTokens: 1_000) == 12_000)
        #expect(SummarizationService.chunkBudget(transcriptChars: 100, transcriptTokens: 0) == TranscriptChunker.defaultMaxChars)
    }

    // The MLX engine has this same pair (SummarizationEngineSettingsTests),
    // so both names say which engine they cover — otherwise a failure report
    // shows two identically-named tests and no way to tell them apart.
    @Test("Notes that fold to nothing fail instead of blanking the meeting (Apple engine)")
    func emptyFoldStillFails() {
        // Every chunk prompt says "Empty if none", so explicitly empty arrays
        // are an honest "nothing noteworthy in this part" — every part can
        // succeed and still leave nothing to fold. Saving that would replace
        // the meeting's Generate empty-state, the affordance the user needs
        // to retry, with blank notes and no error anywhere.
        #expect(throws: SummarizerError.self) {
            _ = try SummarizationService().degradedSummary(from: [notes(), notes()])
        }
    }

    @Test("A fold that rescued something is kept (Apple engine)")
    func foldWithContentIsReturned() throws {
        let summary = try SummarizationService().degradedSummary(from: [
            notes(keyPoints: ["Pricing is behind"]),
            notes(),
        ])
        #expect(summary.keyPoints == ["Pricing is behind"])
        // No model wrote these, so the summary must not pretend otherwise.
        #expect(summary.overview.isEmpty)
        #expect(summary.suggestedTitle == nil)
    }
}
```

- [ ] **Step 2: Run the suite to verify it fails**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MinuteTests/SummaryFallbackTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔ Test run|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: a compile error, `error: value of type 'SummarizationService' has no member 'degradedSummary'`.

- [ ] **Step 3: Add the content guard next to the mechanical fold**

In `Minute/Services/SummarizationService.swift`, replace lines 539-553:

```swift
    /// The no-model fallback summary: combined notes with an empty overview
    /// and no suggested title — the detail view hides both when empty.
    private func mechanicalSummary(from notes: [ChunkNotes]) -> MeetingSummary {
        let combined = Self.mechanicallyCombined(notes)
        return MeetingSummary(
            overview: "",
            keyPoints: combined.keyPoints,
            decisions: combined.decisions,
            actionItems: normalizedActionItems(combined.actionItems),
            openQuestions: combined.openQuestions,
            generatedAt: .now,
            suggestedTitle: nil,
            speakerPerspectives: normalizedPerspectives(combined.speakerPerspectives)
        )
    }
```

with:

```swift
    /// The no-model fallback summary: combined notes with an empty overview
    /// and no suggested title — the detail view hides both when empty.
    private func mechanicalSummary(from notes: [ChunkNotes]) -> MeetingSummary {
        let combined = Self.mechanicallyCombined(notes)
        return MeetingSummary(
            overview: "",
            keyPoints: combined.keyPoints,
            decisions: combined.decisions,
            actionItems: normalizedActionItems(combined.actionItems),
            openQuestions: combined.openQuestions,
            generatedAt: .now,
            suggestedTitle: nil,
            speakerPerspectives: normalizedPerspectives(combined.speakerPerspectives)
        )
    }

    /// What an empty fold reports. Not the refusal wording ("declined to
    /// summarize"), which would be only half true on the overflow path: the
    /// honest statement is that nothing came back and trying again is worth
    /// it. Mirrors MLXSummarizationService.unreadableMessage, pointing at the
    /// other engine the way that one points back here.
    private static let emptySummaryMessage =
        "The on-device model returned no notes for this meeting. Try again, or switch engines in Settings → Summary Model."

    /// A summary with nothing in it at all must never be saved: it would
    /// replace the meeting's Generate empty-state — the affordance the user
    /// needs to retry — with blank notes and no error anywhere. Same guard,
    /// and same field list, as MLXSummarizationService.validated, so both
    /// engines refuse the same thing.
    private static func validated(_ summary: MeetingSummary) throws -> MeetingSummary {
        let hasContent = !summary.overview.isEmpty
            || !summary.keyPoints.isEmpty
            || !summary.decisions.isEmpty
            || !summary.actionItems.isEmpty
            || !summary.openQuestions.isEmpty
            || (summary.sections ?? []).contains { !$0.items.isEmpty }
            || summary.speakerPerspectives != nil
        guard hasContent else {
            throw SummarizerError.generationFailed(emptySummaryMessage)
        }
        return summary
    }

    /// The refusal/overflow rescue: the code-level fold, but only when it
    /// actually rescued something. Every chunk prompt says "Empty if none",
    /// so explicitly empty arrays are a valid answer and a fold of parts that
    /// all succeeded can still come out with nothing in it. An instance
    /// method, unlike MLX's static counterpart, because mechanicalSummary
    /// here calls the instance normalizers.
    func degradedSummary(from notes: [ChunkNotes]) throws -> MeetingSummary {
        try Self.validated(mechanicalSummary(from: notes))
    }
```

- [ ] **Step 4: Route the refusal degrade through the guard**

In `Minute/Services/SummarizationService.swift`, replace lines 298-310 — the `catch` whose comment ends "keeps its user-facing error", which is what distinguishes it from the three other `catch let error as LanguageModelSession.GenerationError` blocks in this file (:251, :374, :415):

```swift
            } catch let error as LanguageModelSession.GenerationError {
                // Every part already succeeded, so a model refusal at the
                // finish line degrades the summary (no overview, title, or
                // template sections) instead of destroying it. Anything
                // else — overflow, assets, rate limits — is retryable and
                // keeps its user-facing error.
                switch error {
                case .guardrailViolation, .refusal:
                    summary = mechanicalSummary(from: notes)
                default:
                    throw error
                }
            }
```

with:

```swift
            } catch let error as LanguageModelSession.GenerationError {
                // Every part already succeeded, so a model refusal at the
                // finish line degrades the summary (no overview, title, or
                // template sections) instead of destroying it. Anything
                // else — overflow, assets, rate limits — is retryable and
                // keeps its user-facing error. A degrade that rescued
                // nothing is not a summary: degradedSummary rethrows rather
                // than save blank notes over the Generate empty-state.
                switch error {
                case .guardrailViolation, .refusal:
                    summary = try degradedSummary(from: notes)
                default:
                    throw error
                }
            }
```

- [ ] **Step 5: Route the overflow fallback through the guard**

In `Minute/Services/SummarizationService.swift`, replace lines 431-437:

```swift
        // Mechanical condenses shrink the note count but not necessarily the
        // rendered size. A final prompt that no longer fits would overflow
        // and send the whole meeting back through the halving restart, so
        // fall back to the code-level merge instead.
        if rendered(current).count > maxChars {
            return mechanicalSummary(from: current)
        }
```

with:

```swift
        // Mechanical condenses shrink the note count but not necessarily the
        // rendered size. A final prompt that no longer fits would overflow
        // and send the whole meeting back through the halving restart, so
        // fall back to the code-level merge instead — and, as above, only
        // when that merge actually has something in it.
        if rendered(current).count > maxChars {
            return try degradedSummary(from: current)
        }
```

`merge` is already `throws` and both call sites are inside the type, so no signature or `self.` qualification changes are needed.

- [ ] **Step 6: Run the suite to verify it passes**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MinuteTests/SummaryFallbackTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔ Test run|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 8 tests, including both "(Apple engine)" cases.

- [ ] **Step 7: Run the full unit suite**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 429 tests.

- [ ] **Step 8: Lint**

```bash
swiftlint --strict --reporter github-actions-logging 2>&1 | grep -E "^::(error|warning)|Done linting"
```
Expected: `Done linting! Found 0 violations, 0 serious in <N> files.`

- [ ] **Step 9: Commit**

```bash
git add Minute/Services/SummarizationService.swift MinuteTests/SummaryFallbackTests.swift
git commit -m "$(cat <<'EOF'
fix: never save an empty degraded summary from the Apple engine

Both fallbacks — the refusal degrade after a failed merge, and the overflow
fallback in merge() — saved whatever mechanicalSummary produced, with no
content check. Every chunk prompt says "Empty if none", so all the parts can
succeed and still fold to nothing, and that nothing replaced the meeting's
Generate empty-state with blank notes and no error: the user lost the button
they needed to retry.

Adds the guard the MLX engine already has (validated + degradedSummary, same
field list, same rethrow) and routes both call sites through it.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: The Whisper live loop stops and says so after three failed decodes (BR1)

**Files:**
- Modify: `Minute/Services/WhisperTranscriptionService.swift:454-459` (loop bookkeeping, just above the `while`), `:493-497` (success reset), `:530-533` (the catch), `:556-561` (the policy helpers)
- Create: `MinuteTests/WhisperLiveFailureTests.swift`

**Interfaces:**
- Consumes: `TranscriptionService.liveStoppedMessage(_ error: any Error) -> String` (TranscriptionService.swift:255-257, a static on a `@MainActor` class, so MainActor-isolated — reachable from `WhisperTranscriptionService`, which is also `@MainActor`; cross-engine static reuse is the house pattern, e.g. `MLXSummarizationService` calling `SummarizationService.normalizedField` at MLXSummarizationService.swift:887), `TranscriptionAvailability` (`Equatable`, `case unknown, available, downloadingModel, loadingModel, unavailable(String)` — TranscriptionEngine.swift:6-15), `LiveLoopGate.open()`, `WhisperLiveFeed.stop()` (WhisperTranscriptionService.swift:749), `WhisperTranscriptionService.promoteVolatileText()` (:597).
- Produces: `WhisperTranscriptionService.liveFailureLimit: Int` (static, `3`), `WhisperTranscriptionService.liveLoopShouldStop(consecutiveFailures: Int) -> Bool` (static), `WhisperTranscriptionService.liveStoppedAvailability(_ error: any Error) -> TranscriptionAvailability` (static). All three are MainActor-isolated statics on the `@MainActor` class.

Why: the catch at :530-533 logs, sleeps 500 ms and loops on *every* decode failure, forever, never touching `availability`. The Apple engine does the opposite (TranscriptionService.swift:143-144 writes `.unavailable(Self.liveStoppedMessage(error))`), so on Whisper a dead live decode leaves the recording panel on stale segments for the rest of the meeting and the saved transcript just stops mid-sentence. The loop itself cannot be unit-tested — it needs a downloaded multi-hundred-megabyte model and a live audio feed — so the threshold and the message are pulled into two statics that can be, and the loop's own wiring is verified by build plus the full suite.

**Three things about the give-up branch that are easy to misread while building it:**

1. **The feed must be retired on the way out, or this fix leaks ~230 MB/hour.** The tap closure `start()` hands the recorder (:359-364) captures `feed` strongly and keeps calling `feed.append(...)` for the whole meeting. Today the only thing bounding that growth is the 5-minute cap at the top of the `while` (`if snapshot.samples.count > Self.maximumTailSamples { feed.purge(…); continue }`, :466-469, with `maximumTailSamples = 5 * 60 * WhisperKit.sampleRate` at :561) — so `break`ing out of the loop removes the one thing that purges it, and 16 kHz mono Float32 piles up at 64 KB/s behind a decoder that just failed three times in a row, most likely from memory pressure in the first place. Step 6 therefore calls `feed.stop()` immediately before the `break`, exactly as the model-load failure path already does (`feed.stop()` at :430, under the comment "the recorder's handler would otherwise keep piling audio into it for the rest of the recording (~230 MB/hour) for nothing"), and as `WhisperLiveFeed.append` documents at :701-705 ("A stopped feed DROPS audio: after the decode loop retires … retaining those samples would grow memory with nobody ever consuming them").
2. **Stopping the feed costs nothing that matters.** `stop()` only gates `append` (:749, read by `append`'s `guard !stopped` at :705); `snapshot()` (:723-731) still returns the retained tail, so the one final tail pass below the `while` runs exactly as before, and `finish()`'s own `liveFeed?.stop()` (:369) is idempotent. The recording is untouched either way — `AudioRecorder` writes the audio file itself (AudioRecorder.swift:502, :562), not through this feed — so "you can re-transcribe the audio after saving" stays literally true.
3. **The live panel will visibly swap to the message, and that is intended.** `RecordingView.swift:323` renders `case .unavailable(let reason): transcriptPlaceholder("text.bubble", reason)`, so writing `.unavailable` replaces the visible live transcript with the sentence. The collected `segments` are unaffected and `finish()` still returns them, so nothing is lost from the saved meeting. This is the Apple engine's existing behaviour (TranscriptionService.swift:143-144 writes the same case), so it is parity, not a regression — do not "fix" the panel swap when you see it on device.

Deliberately *not* clearing `volatileText` on the way out, unlike the Apple engine: Whisper's `finish()` calls `promoteVolatileText()` (WhisperTranscriptionService.swift:382), so the last hypothesis still becomes a saved segment instead of being thrown away.

- [ ] **Step 1: Write the failing test**

Create `MinuteTests/WhisperLiveFailureTests.swift`:

```swift
import Foundation
import Testing
@testable import Minute

/// The Whisper live decode loop used to log-and-retry every failed pass
/// forever: a decoder that died mid-meeting left the panel showing stale
/// segments for the rest of the recording and the saved transcript simply
/// stopped mid-sentence, with nothing anywhere to explain it. The Apple
/// engine already says it; these pin the Whisper half's policy. The loop
/// itself can't be exercised here — it needs a downloaded model and a live
/// audio feed — so the two decisions it makes live in statics that can.
@MainActor
struct WhisperLiveFailureTests {
    private struct DecodeFailure: LocalizedError {
        var errorDescription: String? { "The decoder ran out of memory" }
    }

    @Test("Two failed passes are retried; three in a row give up")
    func givesUpAfterThreeConsecutiveFailures() {
        // One bad pass is usually transient — a decode that raced a purge, a
        // moment of memory pressure — and retrying costs half a second.
        #expect(!WhisperTranscriptionService.liveLoopShouldStop(consecutiveFailures: 0))
        #expect(!WhisperTranscriptionService.liveLoopShouldStop(consecutiveFailures: 1))
        #expect(!WhisperTranscriptionService.liveLoopShouldStop(consecutiveFailures: 2))
        // Three in a row is a decoder that isn't coming back.
        #expect(WhisperTranscriptionService.liveLoopShouldStop(consecutiveFailures: 3))
        #expect(WhisperTranscriptionService.liveLoopShouldStop(consecutiveFailures: 4))
        #expect(WhisperTranscriptionService.liveFailureLimit == 3)
    }

    @Test("Giving up says exactly what the Apple engine says")
    func stoppedAvailabilityReusesTheSharedMessage() {
        let availability = WhisperTranscriptionService.liveStoppedAvailability(DecodeFailure())

        // One sentence for both engines: what stopped, and that the recording
        // did not — a user watching the panel must not conclude the meeting
        // is being lost and stop it.
        #expect(availability == .unavailable(
            "Live transcription stopped: The decoder ran out of memory. Recording continues; you can re-transcribe the audio after saving."
        ))
        // And it is literally the same string, not a copy that can drift.
        #expect(availability == .unavailable(TranscriptionService.liveStoppedMessage(DecodeFailure())))
    }
}
```

- [ ] **Step 2: Run the suite to verify it fails**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MinuteTests/WhisperLiveFailureTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔ Test run|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: a compile error, `error: type 'WhisperTranscriptionService' has no member 'liveLoopShouldStop'`.

- [ ] **Step 3: Add the policy helpers**

In `Minute/Services/WhisperTranscriptionService.swift`, replace lines 556-561:

```swift
    /// Speech — not recorded audio — the pin waits for. Recorded time counts
    /// silence and the model-load backlog, so a meeting that starts quiet
    /// crossed the old threshold on its very first decoded second.
    static let languagePinMinimumSpeechSeconds: TimeInterval = 5
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
    /// Enforced inside the decode loop, so any exit from that loop has to
    /// retire the feed rather than leave it growing unbounded.
    private static let maximumTailSamples = 5 * 60 * WhisperKit.sampleRate

    /// Consecutive failed decode passes that end the live loop. One failure
    /// is usually transient — a decode that raced a purge, a moment of memory
    /// pressure — and costs half a second to retry, so a single bad pass must
    /// not cost the meeting its live transcript. Three in a row is a decoder
    /// that is not coming back, and retrying it silently for the rest of the
    /// recording is exactly the failure this replaces.
    static let liveFailureLimit = 3

    /// Whether `consecutiveFailures` failed passes should end the loop.
    static func liveLoopShouldStop(consecutiveFailures: Int) -> Bool {
        consecutiveFailures >= liveFailureLimit
    }

    /// What the recording screen shows once the live decoder has given up.
    /// Deliberately the Apple engine's own sentence rather than a second
    /// wording: the recording is unaffected on both engines, and a user
    /// watching the panel has to be told that in the same breath as what
    /// stopped, or they assume the meeting is being lost and stop it.
    static func liveStoppedAvailability(_ error: any Error) -> TranscriptionAvailability {
        .unavailable(TranscriptionService.liveStoppedMessage(error))
    }
```

- [ ] **Step 4: Count consecutive failures in the loop**

In `Minute/Services/WhisperTranscriptionService.swift`, replace lines 454-459:

```swift
        // Speech confirmed so far, summed over segment durations. Confirmed
        // audio is purged from the tail, so adding the current pass's
        // segments double-counts nothing.
        var decodedSpeechSeconds: TimeInterval = 0

        while !feed.isStopped, !Task.isCancelled {
```

with:

```swift
        // Speech confirmed so far, summed over segment durations. Confirmed
        // audio is purged from the tail, so adding the current pass's
        // segments double-counts nothing.
        var decodedSpeechSeconds: TimeInterval = 0
        // Failed passes since the last good one. Consecutive, not total: a
        // decoder that hiccups once an hour is fine, one that fails every
        // pass is dead.
        var consecutiveFailures = 0

        while !feed.isStopped, !Task.isCancelled {
```

- [ ] **Step 5: Reset the counter after a good pass**

In `Minute/Services/WhisperTranscriptionService.swift`, replace lines 493-497:

```swift
                // A pass that raced finish() still applies its confirmations
                // below, so the final pass only re-decodes the shrunken tail
                // instead of repeating this whole pass's work.
                guard !Task.isCancelled else { break }
                let mapped = Self.mapSegments(results, timeBase: timeBase)
```

with:

```swift
                // A pass that raced finish() still applies its confirmations
                // below, so the final pass only re-decodes the shrunken tail
                // instead of repeating this whole pass's work.
                guard !Task.isCancelled else { break }
                consecutiveFailures = 0
                let mapped = Self.mapSegments(results, timeBase: timeBase)
```

- [ ] **Step 6: Give up, retire the feed, and say so, in the catch**

In `Minute/Services/WhisperTranscriptionService.swift`, replace lines 530-533 — the catch logging "Live whisper pass failed", not the final-pass catch further down that logs "Final whisper pass failed":

```swift
            } catch {
                Self.logger.error("Live whisper pass failed: \(error.localizedDescription)")
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
```

with:

```swift
            } catch {
                consecutiveFailures += 1
                Self.logger.error("Live whisper pass failed (\(consecutiveFailures) in a row): \(error.localizedDescription)")
                if Self.liveLoopShouldStop(consecutiveFailures: consecutiveFailures) {
                    // Losing live results is non-fatal for the recording — but
                    // retrying forever left the panel showing stale segments
                    // (or "Listening…") for the rest of the meeting while the
                    // saved transcript stopped mid-sentence. Say it where the
                    // user is looking, and stop burning a decode every half
                    // second. `segments` keeps everything confirmed so far,
                    // and `volatileText` is deliberately left alone: unlike
                    // the Apple engine, finish() promotes it into a saved
                    // segment (promoteVolatileText), so clearing it here would
                    // throw away the last thing heard.
                    //
                    // Guarded exactly as the Apple engine guards its own write
                    // (TranscriptionService.swift:143-144): only over
                    // "everything is fine", and never onto a session the user
                    // discarded — cancel() stops the feed and cancels the
                    // task, and a non-CancellationError thrown out of the
                    // decode that raced it must not stamp "Live transcription
                    // stopped" on a recording that is already gone.
                    if !Task.isCancelled, availability == .available {
                        availability = Self.liveStoppedAvailability(error)
                    }
                    // Retire the feed for the same reason the model-load
                    // failure above does: the recorder's tap holds it strongly
                    // and keeps appending for the rest of the meeting, and the
                    // 5-minute cap that bounds that lives INSIDE this `while`
                    // — leaving the loop removes the only thing purging it, so
                    // ~230 MB/hour of Float32 samples would pile up with
                    // nobody left to decode them, behind a decoder that just
                    // failed three times in a row. stop() gates append only:
                    // the final tail pass below still reads snapshot(), and
                    // finish()'s own liveFeed?.stop() is idempotent. The saved
                    // audio file is the recorder's, not the feed's, so
                    // re-transcribing after saving still works.
                    feed.stop()
                    // `defer { gate.open() }` at the top of this method
                    // releases any finisher waiting on the loop.
                    break
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
```

- [ ] **Step 7: Run the suite to verify it passes**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MinuteTests/WhisperLiveFailureTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔ Test run|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 2 tests.

- [ ] **Step 8: Confirm both loop exits retire the feed**

```bash
grep -c "        feed.stop()" Minute/Services/WhisperTranscriptionService.swift
```
Expected: `2` — the model-load failure path and the new give-up branch (`liveFeed?.stop()` in `finish()`/`cancel()` has a different receiver and does not match this pattern). `1` means the `feed.stop()` was dropped from Step 6 and the fix now leaks the live feed for the rest of every failed meeting.

- [ ] **Step 9: Run the full unit suite**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 431 tests in 58 suites. `LiveLoopGateTests` and `TranscriptionLiveFailureTests` still pass — the gate contract and the shared message are unchanged.

- [ ] **Step 10: Lint**

```bash
swiftlint --strict --reporter github-actions-logging 2>&1 | grep -E "^::(error|warning)|Done linting"
```
Expected: `Done linting! Found 0 violations, 0 serious in <N> files.`

- [ ] **Step 11: Commit**

```bash
git add Minute/Services/WhisperTranscriptionService.swift MinuteTests/WhisperLiveFailureTests.swift
git commit -m "$(cat <<'EOF'
fix: stop the Whisper live loop after three failed decodes and say so

The loop logged, slept half a second, and retried every failed pass forever
without ever touching availability. A decoder that died mid-meeting therefore
left the recording panel on stale segments for the rest of the recording, the
saved transcript stopped mid-sentence, and nothing anywhere explained it —
while a dead decode kept being retried twice a second.

Three consecutive failures now write the Apple engine's own
liveStoppedMessage ("Live transcription stopped: … Recording continues; you
can re-transcribe the audio after saving.") and break the loop, letting the
gate's defer release any waiting finisher. Leaving the loop also retires the
live feed, the way the model-load failure path already does: the 5-minute
tail cap is enforced inside the loop, so breaking out without stopping the
feed would let the recorder's tap pile up ~230 MB/hour that nothing would
ever decode.

The availability write is guarded the way the Apple engine guards its own —
only over .available, never on a cancelled session. A good pass resets the
counter, the collected segments are kept, and volatileText is left for
finish() to promote. The threshold and the message are statics with unit
tests; the loop around them needs a downloaded model and live audio.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

## Hand-offs to Track E

None. Every change in this track lands entirely inside files this track owns:

- Task 4 widens `WhisperModelStore.tokenizerVariants` from `private static let` to an internal computed `static var` in `Minute/Services/WhisperTranscriptionService.swift`. No other production file reads it (`grep -rn "tokenizerVariants" Minute/` returns only that file, lines 89 and 97); the only new caller is `MinuteTests/WhisperModelStoreTests.swift`.
- Task 5 adds `SummarizationService.degradedSummary(from:)` (plus two private members). Both call sites are inside `SummarizationService.swift`. The behaviour change is visible to `MeetingJobs`, which already renders a thrown `SummarizerError`'s `localizedDescription` and leaves the Generate empty-state in place — no wiring needed.
- Task 6 adds three statics to `WhisperTranscriptionService` and consumes the existing `TranscriptionService.liveStoppedMessage`. It writes an existing `TranscriptionAvailability` case (`.unavailable`) that every surface already handles — `RecordingView.swift:323` swaps the live panel for the message, which is the Apple engine's existing behaviour — so no view needs a new branch.

## Not done in this track

- **E1, E3** — deferred by decision (product decisions), and in any case outside this track's files.
- **E2, E4** — skipped by decision.
- **The Whisper live loop itself is not unit-tested.** Task 6 pins the two decisions the failure path makes (the three-strikes threshold and the exact availability text) as statics with assertions, but `runLiveLoop` needs a downloaded 150–630 MB Core ML model plus a live `WhisperLiveFeed` to run one pass, so the counter's reset-on-success, the `!Task.isCancelled, availability == .available` guard, the `feed.stop()` before the `break`, and the `break` itself are verified by the build, the Step 8 grep, and the full suite only. A future integration test gated on `.enabled(if: WhisperModelStore.isDownloaded(AppSettings.whisperModel))` — the pattern Task 3 establishes — could cover it on a machine that has a model.
- **`picksTheSurvivorFromTheRealCatalog` does not lock the catalog's order.** It derives its expected value from the same array it deletes from, so a reorder leaves it green; Task 2's ordering lock is `sizes == sizes.sorted()` in `catalogIsConsistent` (probe B), and the new selection case locks only that `replacementSelection` behaves correctly on the shipping variant strings (probe C).
- **`everyWhisperSizeMapsToItself` cannot fail on today's code.** Its `sizes.count == ModelVariant.allCases.count` assertion is a forward lock — the hand-written table also had eleven entries, so only a future WhisperKit release can separate the two. Task 4's RED is the access-level error, not this assertion. If `import WhisperKit` turns out not to resolve from the test target (Step 2's fallback), that assertion is dropped and nothing then holds the derivation; adding `WhisperKit` to `MinuteTests`' package product dependencies would fix it but requires a `project.pbxproj` edit this plan may not make.
- **The MLX engine's live/summarize paths are untouched.** `MLXSummarizationService.validated`/`degradedSummary` already carry the guard Task 5 ports to the Apple engine; nothing in the selected items asks for changes there.
- **`AudioImporter`, `LiveLoopGate`, `MLXDownloadCenter`, `TranscriptionModelView`, `SummaryModelView`** are owned by this track but no selected item touches them; they are listed only so a later batch knows where the boundary is.

---

## Track H — Recording, playback, widgets

Findings closed here: b2-T18-minor-1, b2-T12-minor-1, b2-T22-minor-3, b2-T22-minor-2, b2-T15-minor-2, C3, b2-T14-minor-3.

**Files this track owns** (a task must not edit anything else):
`Minute/Recording/RecordingSession.swift`, `Minute/Services/AudioRecorder.swift`,
`Minute/Views/RecordingView.swift`, `Minute/Recording/RecordingLiveActivityController.swift`,
`Minute/Services/TranscriptionService.swift`, `Minute/Services/AudioPlayerController.swift`,
`Minute/Views/PlaybackBarView.swift`, `Minute/Support/AudioBufferConverter.swift`,
`Shared/*`, `MinuteWidgets/*`, plus `MinuteTests/RecordingSession*Tests`,
`MinuteTests/BufferHandlerBoxTests.swift`, `MinuteTests/AudioPlayerControllerTests.swift`,
`MinuteTests/WidgetSnapshot*Tests`, `MinuteTests/MinuteDeepLinkTests.swift`,
and new test files for these types.

### Global Constraints

- Privacy invariants from CONTRIBUTING.md hold: no meeting content on the wire; every byte written has a delete path; AI output stays grounded ("Not specified" literal); recording never depends on optional capabilities and any handled failure still offers to save captured audio.
- No new third-party dependencies. Do not edit `Minute.xcodeproj/project.pbxproj` (new files under `Minute/`, `MinuteTests/`, `Shared/`, `MinuteWidgets/` are picked up automatically).
- Unit tests use Swift Testing, never XCTest. SwiftData-touching test structs are `@MainActor` with an in-memory container via `MeetingStore.modelConfiguration(inMemory: true)`; containers holding `KnowledgeEntity`/`KnowledgeFact` are retained for the process lifetime (`retainedContainers` pattern in `MinuteTests/KnowledgeCatchUpTests.swift`). Suite-level `-only-testing` selectors only (a single-test selector silently selects nothing).
- Swift 5 language mode: an actor-isolated expression cannot be a default argument (use the nil-defaulted injection pattern).
- Baseline at the branch point (main `b481626`): **424 tests in 57 suites pass**; `swiftlint --strict` reports 0 violations. Every task leaves both true plus its own new tests.
- swiftlint 0.65.1 IS installed locally: run `swiftlint --strict --reporter github-actions-logging` from the repo root before every commit; live rules include `multiple_closures_with_trailing_closure` and `redundant_void_return`; `line_length`, function/type/file length, `cyclomatic_complexity`, `identifier_name`, `todo`, `redundant_optional_initialization`, `trailing_comma`, `for_where` are disabled.
- Commit messages: Conventional Commits (`fix:`/`test:`/`docs:`/`refactor:`), ending with the trailer line `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Explicit paths; never `git add -A`; never commit anything under `.superpowers/`.
- A task edits only files its track owns; cross-track needs go in "Hand-offs to Track E".
- After a committed delete a SwiftData object has `isDeleted == false` and `modelContext == nil`; guard stale reads with `isGone`.

**Test commands** (from the worktree root `/Users/feihou/workplace/minute/.claude/worktrees/app-code-review-e76404`; this track uses simulator "iPhone 17"):

One suite while iterating:
```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MinuteTests/<SuiteName> CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔ Test run|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Full unit suite, once before each commit:
```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```
Lint, once before each commit:
```bash
swiftlint --strict --reporter github-actions-logging 2>&1 | grep -E "^::(error|warning)|Done linting"
```

**Line numbers** in this section are as of commit `b481626` and shift as earlier tasks in this track land. Every replacement quotes the exact current text; **the quoted old snippet is the authoritative anchor** — find it, don't count lines.

---

### Task 13: The drain interlock that keeps a live buffer from overtaking the lead-in gets a test (b2-T18-minor-1)

The interlock is `isDraining` (`Minute/Services/AudioRecorder.swift:79`, `:97`, `:100`, `:126`, `:161`). It is the whole basis of the ordering claim in the box's doc comment at `:22-31`, and every existing test in `BufferHandlerBoxTests` is single-threaded with the drain already finished before the next `offer`, so deleting `isDraining` outright leaves all five green. This task adds the one deterministic test that catches it: re-entering `offer` from inside the handler is exactly the tap thread delivering a live buffer mid-replay, without a second thread to make it flaky.

**Files:**
- Modify: `MinuteTests/BufferHandlerBoxTests.swift:7-16` (split the buffer helper so a `@Sendable` handler can call it), and add one test at the end of the struct (after `resettingReArmsTheBoxForTheNextRecording`, which ends at `:114`)
- Read only (not modified): `Minute/Services/AudioRecorder.swift:32-199` (`BufferHandlerBox`)

**Interfaces:**
- Consumes: `BufferHandlerBox()`, `BufferHandlerBox.offer(_ buffer: AVAudioPCMBuffer)`, `BufferHandlerBox.install(_ handler: (@Sendable (AVAudioPCMBuffer) -> Void)?)`, `OSAllocatedUnfairLock`.
- Produces: `BufferHandlerBoxTests.makeBuffer(marker:seconds:sampleRate:)` (private static) and the test `aBufferOfferedDuringTheReplayQueuesBehindTheRestOfTheLeadIn`. No production change.

- [ ] **Step 1: Make the buffer helper callable from a `@Sendable` closure**

In `MinuteTests/BufferHandlerBoxTests.swift`, replace lines 7-16:

```swift
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
```

with:

```swift
    /// One buffer of `seconds` of audio, marked in its first sample so the
    /// test can identify it after the box has copied it.
    private func buffer(marker: Float, seconds: Double = 0.1, sampleRate: Double = 8_000) -> AVAudioPCMBuffer {
        Self.makeBuffer(marker: marker, seconds: seconds, sampleRate: sampleRate)
    }

    /// Static so the re-entrancy test below can build a buffer from inside a
    /// `@Sendable` handler without capturing the test struct.
    private static func makeBuffer(marker: Float, seconds: Double = 0.1, sampleRate: Double = 8_000) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        buffer.floatChannelData![0][0] = marker
        return buffer
    }
```

- [ ] **Step 2: Write the test**

In the same file, add inside `struct BufferHandlerBoxTests`, after `resettingReArmsTheBoxForTheNextRecording` (the closing `}` of that test at line 114) and before the struct's final `}`:

```swift

    /// The interlock that makes the ordering claim in the box's doc comment
    /// true. A live buffer arriving *during* the replay has to queue behind the
    /// rest of the lead-in: `install` sets `isDraining`, and while it is set
    /// `offer` enqueues instead of delivering. Every other test here is
    /// single-threaded with the drain already finished before the next offer,
    /// so deleting `isDraining` leaves them green. Re-entering `offer` from
    /// inside the handler is the tap thread delivering mid-replay, without a
    /// second thread to make it flaky: without the interlock the fourth buffer
    /// is delivered nested inside the first delivery, i.e. [1, 4, 2, 3].
    @Test func aBufferOfferedDuringTheReplayQueuesBehindTheRestOfTheLeadIn() {
        let box = BufferHandlerBox()
        box.offer(buffer(marker: 1))
        box.offer(buffer(marker: 2))
        box.offer(buffer(marker: 3))

        let received = OSAllocatedUnfairLock(initialState: [Float]())
        let liveBufferOffered = OSAllocatedUnfairLock(initialState: false)
        box.install { buffer in
            received.withLock { $0.append(buffer.floatChannelData![0][0]) }
            let isFirstDelivery = liveBufferOffered.withLock { offered -> Bool in
                guard !offered else { return false }
                offered = true
                return true
            }
            if isFirstDelivery {
                box.offer(Self.makeBuffer(marker: 4))
            }
        }

        #expect(received.withLock { $0 } == [1, 2, 3, 4])
        // Drop the handler so the box no longer holds a closure that holds it.
        box.install(nil)
    }
```

- [ ] **Step 3: Run the suite to verify it passes**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MinuteTests/BufferHandlerBoxTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔ Test run|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 6 tests (5 existing + 1 new).

- [ ] **Step 4: Prove the test actually pins the interlock (temporary mutation)**

In `Minute/Services/AudioRecorder.swift`, temporarily replace line 97:

```swift
            if let entry = state.entry, !state.isDraining {
```

with:

```swift
            if let entry = state.entry {
```

then re-run:

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MinuteTests/BufferHandlerBoxTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔ Test run|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST FAILED`, exactly one failure — `aBufferOfferedDuringTheReplayQueuesBehindTheRestOfTheLeadIn`, reporting `[1.0, 4.0, 2.0, 3.0] == [1.0, 2.0, 3.0, 4.0]`. The other five still pass, which is the point of the finding.

- [ ] **Step 5: Restore the interlock**

Put line 97 back exactly as it was:

```swift
            if let entry = state.entry, !state.isDraining {
```

Confirm nothing else changed:

```bash
git diff --stat Minute/Services/AudioRecorder.swift
```
Expected: no output (the file is unmodified).

- [ ] **Step 6: Run the full unit suite**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 425 tests in 57 suites (424 baseline + 1).

- [ ] **Step 7: Lint**

```bash
swiftlint --strict --reporter github-actions-logging 2>&1 | grep -E "^::(error|warning)|Done linting"
```
Expected: `Done linting!` with no `::error` or `::warning` lines.

- [ ] **Step 8: Commit**

```bash
git add MinuteTests/BufferHandlerBoxTests.swift
git commit -m "test: pin the drain interlock that keeps a live buffer behind the lead-in

A buffer offered while the backlog is replaying has to queue behind the
rest of it. Every existing BufferHandlerBox test is single-threaded with
the drain already finished, so isDraining could be deleted outright and
they would all stay green. Re-entering offer() from inside the handler
reproduces the race deterministically.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 14: A refused Play that is retried on the same player clears its own notice (b2-T12-minor-1)

`aPlayerThatStartsClearsTheEarlierFailure` (`MinuteTests/AudioPlayerControllerTests.swift:49-63`) reloads with a `StartingPlayer` at `:57`, and `load(url:makePlayer:)` calls `stop()` first (`Minute/Services/AudioPlayerController.swift:99`), which clears `lastError` at `:165`. So the assertion at `:61` is green even with `lastError = nil` deleted from `play()` (`:140`). The uncovered flow is the real recovery path: tap Play (refused, notice shown), the call ends, tap Play again on the SAME loaded player — nothing reloads there, so only `play()`'s own clearing takes the stale notice off screen.

**Files:**
- Modify: `MinuteTests/AudioPlayerControllerTests.swift` — add a stub after `StartingPlayer` (`:12-16`) and one test after `aPlayerThatStartsClearsTheEarlierFailure` (ends at `:63`)
- Read only (not modified): `Minute/Services/AudioPlayerController.swift:117-143` (`play()`), `:163-173` (`stop()`)

**Interfaces:**
- Consumes: `AudioPlayerController()`, `AudioPlayerController.load(url:makePlayer:) throws`, `.play()`, `.stop()`, `.isPlaying`, `.lastError`, `AudioPlayerController.playbackFailedMessage`.
- Produces: the file-private stub `RefusingThenStartingPlayer: AVAudioPlayer` and the test `retryingPlayOnTheSameLoadedPlayerClearsTheNotice`. No production change.

- [ ] **Step 1: Write the test**

In `MinuteTests/AudioPlayerControllerTests.swift`, replace lines 12-16:

```swift
/// A player that starts, without depending on the test simulator actually
/// having an audio route.
private final class StartingPlayer: AVAudioPlayer {
    override func play() -> Bool { true }
}
```

with:

```swift
/// A player that starts, without depending on the test simulator actually
/// having an audio route.
private final class StartingPlayer: AVAudioPlayer {
    override func play() -> Bool { true }
}

/// A player that refuses the first start and accepts every one after it: the
/// call that held the hardware ends, and the user taps Play again on the same
/// loaded player. Nothing reloads in that flow.
private final class RefusingThenStartingPlayer: AVAudioPlayer {
    private var refusalsLeft = 1

    override func play() -> Bool {
        guard refusalsLeft > 0 else { return true }
        refusalsLeft -= 1
        return false
    }
}
```

then add inside `struct AudioPlayerControllerTests`, after `aPlayerThatStartsClearsTheEarlierFailure` (its closing `}` at line 63) and before the struct's final `}`:

```swift

    /// The real recovery path. The test above reloads between the two taps,
    /// and `load()` calls `stop()`, which clears `lastError` — so it stays
    /// green even with `play()`'s own clearing deleted. Here the player is
    /// loaded once: the only thing that can take the stale "couldn't start"
    /// notice off screen is the successful `play()` itself.
    @Test func retryingPlayOnTheSameLoadedPlayerClearsTheNotice() throws {
        let url = try makeWavFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = AudioPlayerController()
        try controller.load(url: url) { try RefusingThenStartingPlayer(contentsOf: $0) }

        controller.play()
        #expect(controller.isPlaying == false)
        #expect(controller.lastError == AudioPlayerController.playbackFailedMessage)

        // Same loaded player, no reload — exactly what the second tap does.
        controller.play()

        #expect(controller.isPlaying)
        #expect(controller.lastError == nil)
        controller.stop()
    }
```

- [ ] **Step 2: Run the suite to verify it passes**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MinuteTests/AudioPlayerControllerTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔ Test run|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 3 tests (2 existing + 1 new).

- [ ] **Step 3: Prove the test pins `play()`'s clearing (temporary mutation)**

In `Minute/Services/AudioPlayerController.swift`, temporarily comment out line 140 — the `lastError = nil` between the `guard player.play() else { … }` block and `isPlaying = true` — so the tail of `play()` reads:

```swift
//        lastError = nil
        isPlaying = true
        startTicker()
    }
```

then re-run:

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MinuteTests/AudioPlayerControllerTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔ Test run|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST FAILED`, exactly one failure — `retryingPlayOnTheSameLoadedPlayerClearsTheNotice` on `controller.lastError == nil`. `aPlayerThatStartsClearsTheEarlierFailure` still passes, which is the finding.

- [ ] **Step 4: Restore `play()`**

Put the line back so `play()` reads exactly:

```swift
        lastError = nil
        isPlaying = true
        startTicker()
    }
```

Confirm nothing else changed:

```bash
git diff --stat Minute/Services/AudioPlayerController.swift
```
Expected: no output (the file is unmodified).

- [ ] **Step 5: Run the full unit suite**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 426 tests in 57 suites.

- [ ] **Step 6: Lint**

```bash
swiftlint --strict --reporter github-actions-logging 2>&1 | grep -E "^::(error|warning)|Done linting"
```
Expected: `Done linting!` with no `::error` or `::warning` lines.

- [ ] **Step 7: Commit**

```bash
git add MinuteTests/AudioPlayerControllerTests.swift
git commit -m "test: pin that a retried Play clears its own failure notice

The existing test reloads between the two taps, and load() calls stop(),
which clears lastError — so it passed even with play()'s own clearing
deleted. The uncovered flow is the real one: Play refused, then Play
again on the same loaded player, where nothing reloads.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 15: The saveWithoutTranscript() guard gets its two tests (b2-T22-minor-3)

`RecordingSession.swift:364` (`guard phase == .saving, pendingSegments == nil else { return }`) is the only thing stopping (a) a stray call outside `.saving` from banking an empty transcript and cancelling a live engine, and (b) a second call from re-banking the engine's already-emptied `segments` — `ParkedTranscriptionEngine.cancel()` clears them (`MinuteTests/RecordingSessionSaveTests.swift:46-48`), so a second call would overwrite the good banked segments with `[]`. The existing `saveWithoutTranscriptStopsWaitingAndKeepsWhatWasHeard` calls it exactly once, so removing the guard leaves the suite green.

To make the second test deterministic the fake gains one switch: `cancel()` currently releases the parked `finish()`, so after the first `saveWithoutTranscript()` the save can complete before the second call lands and the second call would be rejected on the phase rather than on the banked segments. Holding the park keeps the session in the exact state the finding is about.

**Files:**
- Modify: `MinuteTests/RecordingSessionSaveTests.swift:43-50` (`ParkedTranscriptionEngine.cancel()`), and add two tests after `saveWithoutTranscriptStopsWaitingAndKeepsWhatWasHeard` (ends at `:216`)
- Read only (not modified): `Minute/Recording/RecordingSession.swift:357-380` (`saveWithoutTranscript()`)

**Interfaces:**
- Consumes: `RecordingSession.init(title:prefilledDefaultTitle:transcription:deleteMeeting:)`, `RecordingSession.finish(in:) async -> Meeting?`, `RecordingSession.saveWithoutTranscript() async`, `RecordingSession.phase`, `MeetingStore.modelConfiguration(inMemory:)`, `TranscriptSegment(text:start:end:)`.
- Produces: `ParkedTranscriptionEngine.releasesOnCancel: Bool` (defaults `true`, so the five existing tests are unchanged), and the tests `saveWithoutTranscriptDoesNothingOutsideASave` and `aSecondSaveWithoutTranscriptDoesNotOverwriteWhatTheFirstBanked`. No production change.

- [ ] **Step 1: Let the fake hold its park through a cancel**

In `MinuteTests/RecordingSessionSaveTests.swift`, replace lines 43-50:

```swift
    func cancel() async {
        didCancel = true
        // The real engines clear their own collection here — which is why the
        // session has to bank the segments before cancelling.
        segments = []
        volatileText = ""
        release()
    }
```

with:

```swift
    /// Whether `cancel()` also lets a parked `finish()` return. The real
    /// engines do. A test that has to observe the session *while* it is still
    /// `.saving` with the transcript already banked sets this false, so the
    /// park holds and the observation isn't a race with the save completing.
    var releasesOnCancel = true

    func cancel() async {
        didCancel = true
        // The real engines clear their own collection here — which is why the
        // session has to bank the segments before cancelling.
        segments = []
        volatileText = ""
        if releasesOnCancel {
            release()
        }
    }
```

(The `var releasesOnCancel = true` line goes with `cancel()` so the switch and the branch it controls read together; SwiftLint has no ordering rule that objects.)

- [ ] **Step 2: Write the two failing tests**

In the same file, add inside `struct RecordingSessionSaveTests`, after `saveWithoutTranscriptStopsWaitingAndKeepsWhatWasHeard` (its closing `}` at line 216):

```swift

    /// Nothing is being saved, so there is nothing to stop waiting for. Without
    /// the guard this banks an empty transcript over a session that hasn't
    /// finished, and cancels an engine that is still listening mid-recording.
    @Test func saveWithoutTranscriptDoesNothingOutsideASave() async {
        let engine = ParkedTranscriptionEngine()
        engine.segments = [TranscriptSegment(text: "still being heard", start: 0, end: 1)]
        let session = RecordingSession(
            title: "Not saving yet",
            prefilledDefaultTitle: "Not saving yet",
            transcription: engine
        )
        #expect(session.phase == .idle)

        await session.saveWithoutTranscript()

        #expect(engine.didCancel == false)
        #expect(engine.segments.map(\.text) == ["still being heard"])
        #expect(session.phase == .idle)
    }

    /// The tap a user with a slow engine makes: the phase stays `.saving` and
    /// the screen doesn't change, so they tap "Save without transcript" again.
    /// Cancelling emptied the engine's own collection, so without the
    /// `pendingSegments == nil` half of the guard the second tap banks `[]`
    /// over what the first tap saved and the meeting is written with an empty
    /// transcript.
    @Test func aSecondSaveWithoutTranscriptDoesNotOverwriteWhatTheFirstBanked() async throws {
        let context = try makeContext()
        let engine = ParkedTranscriptionEngine()
        engine.segments = [TranscriptSegment(text: "banked by the first tap", start: 0, end: 1)]
        // Hold the park across the cancel, so the second call lands while the
        // session is still `.saving` — the state the guard is written for.
        engine.releasesOnCancel = false
        let session = RecordingSession(
            title: "Tapped twice",
            prefilledDefaultTitle: "Tapped twice",
            transcription: engine
        )

        let (entered, enteredContinuation) = AsyncStream.makeStream(of: Void.self)
        engine.onFinishEntered = { enteredContinuation.yield(()) }
        let finishTask = Task { @MainActor in await session.finish(in: context)?.id }
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()

        await session.saveWithoutTranscript()
        // The engine's own copy is gone now — cancel() cleared it.
        #expect(engine.segments.isEmpty)
        #expect(session.phase == .saving)

        await session.saveWithoutTranscript()

        engine.release()
        let finishedID = await finishTask.value
        #expect(finishedID != nil)
        let saved = try context.fetch(FetchDescriptor<Meeting>())
        #expect(saved.count == 1)
        #expect(saved.first?.segments.map(\.text) == ["banked by the first tap"])
        #expect(session.phase == .idle)
    }
```

- [ ] **Step 3: Run the suite to verify it passes**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MinuteTests/RecordingSessionSaveTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔ Test run|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 8 tests (6 existing + 2 new).

- [ ] **Step 4: Prove the tests pin the guard (temporary mutation)**

In `Minute/Recording/RecordingSession.swift`, temporarily comment out line 364, so `saveWithoutTranscript()` opens:

```swift
    func saveWithoutTranscript() async {
//        guard phase == .saving, pendingSegments == nil else { return }
        // Bank first: cancelling clears the engine's own collection, and the
```

then re-run:

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MinuteTests/RecordingSessionSaveTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔ Test run|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST FAILED`, exactly two failures — `saveWithoutTranscriptDoesNothingOutsideASave` on `engine.didCancel == false`, and `aSecondSaveWithoutTranscriptDoesNotOverwriteWhatTheFirstBanked` on the saved segments being `[]`. The six pre-existing tests still pass, which is the finding.

- [ ] **Step 5: Restore the guard**

Put line 364 back exactly:

```swift
        guard phase == .saving, pendingSegments == nil else { return }
```

Confirm nothing else changed:

```bash
git diff --stat Minute/Recording/RecordingSession.swift
```
Expected: no output (the file is unmodified).

- [ ] **Step 6: Run the full unit suite**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 428 tests in 57 suites.

- [ ] **Step 7: Lint**

```bash
swiftlint --strict --reporter github-actions-logging 2>&1 | grep -E "^::(error|warning)|Done linting"
```
Expected: `Done linting!` with no `::error` or `::warning` lines.

- [ ] **Step 8: Commit**

```bash
git add MinuteTests/RecordingSessionSaveTests.swift
git commit -m "test: pin the saveWithoutTranscript guard on both of its halves

A stray call outside .saving would bank an empty transcript and cancel a
live engine; a second call would re-bank the engine's already-emptied
segments over the ones the first call saved. The existing test calls it
once, so removing the guard left the suite green.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 16: "Save without transcript" stops being offered once there is nothing left to skip (b2-T22-minor-2)

`RecordingView.swift:105-109` keeps the button enabled while the parked `finish()` runs: `saveWithoutTranscript()` returns as soon as `cancel()` does, but the phase stays `.saving` behind the same `ProgressView`, and the guard at `RecordingSession.swift:364` makes every later tap a silent no-op. This is exactly the slow-engine user who taps repeatedly. The same guard also makes the button inert from the very first tap on the retry-after-a-failed-transcript-save path, where the transcript was already banked.

**Files:**
- Modify: `Minute/Recording/RecordingSession.swift:357-364` (add `canSaveWithoutTranscript` above `saveWithoutTranscript()` and route the guard through it)
- Modify: `Minute/Views/RecordingView.swift:105-109` (the button in the `.saving` case)
- Test: `MinuteTests/RecordingSessionSaveTests.swift` (one test, added after `aSecondSaveWithoutTranscriptDoesNotOverwriteWhatTheFirstBanked` from Task 15)

**Interfaces:**
- Consumes: `RecordingSession.phase: Phase`, the private `pendingSegments: [TranscriptSegment]?`, `ParkedTranscriptionEngine.releasesOnCancel` (Task 15).
- Produces: `RecordingSession.canSaveWithoutTranscript: Bool` (a computed, non-private property on the `@Observable` session, so SwiftUI tracks it) and the test `saveWithoutTranscriptIsOfferedOnlyWhileThereIsSomethingToSkip`.

- [ ] **Step 1: Write the failing test**

In `MinuteTests/RecordingSessionSaveTests.swift`, add inside `struct RecordingSessionSaveTests`, after `aSecondSaveWithoutTranscriptDoesNotOverwriteWhatTheFirstBanked`:

```swift

    /// The phase stays `.saving` after the segments are banked — the parked
    /// finish() is still running — so the phase alone can't drive the button.
    /// Without this property the button stays lit behind the same
    /// ProgressView and every further tap is a silent no-op, which is exactly
    /// what the user with a slow engine does.
    @Test func saveWithoutTranscriptIsOfferedOnlyWhileThereIsSomethingToSkip() async throws {
        let context = try makeContext()
        let engine = ParkedTranscriptionEngine()
        engine.segments = [TranscriptSegment(text: "heard so far", start: 0, end: 1)]
        // Hold the park across the cancel, so "banked but still .saving" is a
        // state the test can observe rather than race.
        engine.releasesOnCancel = false
        let session = RecordingSession(
            title: "Slow engine",
            prefilledDefaultTitle: "Slow engine",
            transcription: engine
        )

        // Nothing is being saved yet, so there is nothing to skip.
        #expect(session.canSaveWithoutTranscript == false)

        let (entered, enteredContinuation) = AsyncStream.makeStream(of: Void.self)
        engine.onFinishEntered = { enteredContinuation.yield(()) }
        let finishTask = Task { @MainActor in await session.finish(in: context)?.id }
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()

        // Parked in `.saving` with nothing banked: the way out is live.
        #expect(session.canSaveWithoutTranscript)

        await session.saveWithoutTranscript()

        // Still `.saving` — finish() hasn't returned — but there is nothing
        // left to skip, so the control has to be dead rather than inert.
        #expect(session.phase == .saving)
        #expect(session.canSaveWithoutTranscript == false)

        engine.release()
        _ = await finishTask.value
        #expect(session.phase == .idle)
        #expect(session.canSaveWithoutTranscript == false)
    }
```

- [ ] **Step 2: Run the suite to verify it fails**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MinuteTests/RecordingSessionSaveTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔ Test run|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: a compile error, `error: value of type 'RecordingSession' has no member 'canSaveWithoutTranscript'`.

- [ ] **Step 3: Add the property and route the guard through it**

In `Minute/Recording/RecordingSession.swift`, replace lines 357-364:

```swift
    /// Stops waiting for the transcript and finishes the save with whatever the
    /// engine has already produced. Nothing bounds a finalization — Whisper's
    /// final pass covers up to five minutes of retained tail, and Apple Speech
    /// waits on its results stream — while `.saving` disables Discard and both
    /// controls, so without this the user has no way out of a recording that is
    /// already safely on disk.
    func saveWithoutTranscript() async {
        guard phase == .saving, pendingSegments == nil else { return }
```

with:

```swift
    /// Whether "Save without transcript" still has anything to do. The phase
    /// stays `.saving` until the parked finalization returns, so the phase
    /// alone can't drive the button: without this it stays lit behind the same
    /// ProgressView after the first tap has already banked the segments, and
    /// every further tap hits the guard below and does nothing — which is what
    /// the user with a slow engine keeps doing. It is also already false on
    /// the retry-after-a-failed-transcript-save path, where the transcript is
    /// banked and there is nothing left to skip, so the dead case is never
    /// offered at all. Mirrors the guard exactly, and the guard reads it, so
    /// the two cannot drift apart.
    var canSaveWithoutTranscript: Bool {
        phase == .saving && pendingSegments == nil
    }

    /// Stops waiting for the transcript and finishes the save with whatever the
    /// engine has already produced. Nothing bounds a finalization — Whisper's
    /// final pass covers up to five minutes of retained tail, and Apple Speech
    /// waits on its results stream — while `.saving` disables Discard and both
    /// controls, so without this the user has no way out of a recording that is
    /// already safely on disk.
    func saveWithoutTranscript() async {
        guard canSaveWithoutTranscript else { return }
```

- [ ] **Step 4: Run the suite to verify it passes**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MinuteTests/RecordingSessionSaveTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔ Test run|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 9 tests.

- [ ] **Step 5: Disable the button when it has nothing to do**

In `Minute/Views/RecordingView.swift`, replace lines 105-109:

```swift
                Button("Save without transcript") {
                    Task { await session.saveWithoutTranscript() }
                }
                .buttonStyle(.bordered)
                .font(.footnote)
```

with:

```swift
                Button("Save without transcript") {
                    Task { await session.saveWithoutTranscript() }
                }
                .buttonStyle(.bordered)
                .font(.footnote)
                // Greys out the moment the segments are banked. The phase
                // stays `.saving` while the parked finalization runs, so
                // without this the tap looks live and silently does nothing —
                // and on the retry-after-a-failed-transcript-save path the
                // action is dead from the very first tap.
                .disabled(!session.canSaveWithoutTranscript)
```

- [ ] **Step 6: Run the full unit suite**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 429 tests in 57 suites.

- [ ] **Step 7: Lint**

```bash
swiftlint --strict --reporter github-actions-logging 2>&1 | grep -E "^::(error|warning)|Done linting"
```
Expected: `Done linting!` with no `::error` or `::warning` lines.

- [ ] **Step 8: Commit**

```bash
git add Minute/Recording/RecordingSession.swift Minute/Views/RecordingView.swift MinuteTests/RecordingSessionSaveTests.swift
git commit -m "fix: stop offering Save without transcript once it can do nothing

The phase stays .saving while the parked finalization runs, so the button
stayed lit after the first tap banked the segments and every further tap
was a silent no-op — the exact thing a user with a slow engine does. It
was also inert from the first tap on the retry-after-a-failed-transcript
path. canSaveWithoutTranscript mirrors the guard and the guard reads it.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 17: Microphone permission is injectable, so the Open Settings failure has a test (b2-T15-minor-2)

`RecordingSession.swift:115` calls the static `AudioRecorder.requestPermission()` with no seam, so the one branch that produces `canOpenSettings: true` (`:116-119`) — the flag that puts the Open Settings button on screen (`RecordingView.swift:119-129`) — has no coverage. Unlike the other untestable recording paths this one needs no audio hardware: the guard returns before the recorder is touched, and the session already carries two injection seams of exactly this shape (`transcription`, `deleteMeeting`).

**Files:**
- Modify: `Minute/Recording/RecordingSession.swift:87-109` (add the stored seam beside `deleteMeeting` and the init parameter) and `:115` (the call)
- Create: `MinuteTests/RecordingSessionPermissionTests.swift`

**Interfaces:**
- Consumes: `AudioRecorder.requestPermission() async -> Bool` (main-actor isolated static on `@MainActor final class AudioRecorder`), `RecordingSession.start() async`, `RecordingSession.Phase.failed(String, canOpenSettings: Bool)`, `RecordingSession.didStartRecording`, the `TranscriptionEngine` protocol (`availability`, `volatileText`, `segments`, `timestampOffset`, `prepare()`, `start(inputFormat:)`, `finish()`, `cancel()`, `transcribe(file:)`).
- Produces: `RecordingSession.init(title:prefilledDefaultTitle:transcription:deleteMeeting:requestPermission:)` — the new parameter is last and defaulted to `nil`, so `MeetingListView.swift:195` and `:218` and every existing test call site keep compiling unchanged. Nil-defaulted rather than `= AudioRecorder.requestPermission` because that expression is main-actor isolated and a default argument is evaluated outside this type's isolation.

- [ ] **Step 1: Write the failing test**

Create `MinuteTests/RecordingSessionPermissionTests.swift`:

```swift
import AVFoundation
import Foundation
import Testing
@testable import Minute

/// An engine that does nothing. The permission guard returns before the
/// recorder or the engine is touched; injecting one only keeps the session
/// from constructing the real Whisper / Apple Speech service in a test process.
@MainActor
private final class InertTranscriptionEngine: TranscriptionEngine {
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

/// A denied microphone is the one recording failure the user can fix without
/// leaving the meeting behind, and `canOpenSettings` is what puts the Open
/// Settings button on the recording screen for it. Until permission was
/// injectable that flag could only be produced by denying the real system
/// prompt on a device, so the branch had no coverage at all.
@MainActor
struct RecordingSessionPermissionTests {
    @Test func aDeniedMicrophoneFailsWithTheOpenSettingsAffordance() async {
        let session = RecordingSession(
            title: "No microphone",
            prefilledDefaultTitle: "No microphone",
            transcription: InertTranscriptionEngine(),
            requestPermission: { false }
        )

        await session.start()

        guard case .failed(let message, let canOpenSettings) = session.phase else {
            Issue.record("Expected a failed phase after permission was denied, got \(session.phase)")
            return
        }
        // The flag RecordingView keys the Open Settings button off.
        #expect(canOpenSettings)
        #expect(message.contains("Settings"))
        // The guard returns before any hardware is touched, so nothing was
        // captured and the failure must not offer to save a recording.
        #expect(session.didStartRecording == false)
    }
}
```

- [ ] **Step 2: Run the suite to verify it fails**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MinuteTests/RecordingSessionPermissionTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔ Test run|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: a compile error, `error: extra argument 'requestPermission' in call`.

- [ ] **Step 3: Add the stored seam**

In `Minute/Recording/RecordingSession.swift`, replace lines 87-94:

```swift
    /// How a saved meeting is removed — `MeetingStore.delete` in the app.
    /// Injectable because the branch that decides whether this session can
    /// corrupt the library is the one where that delete does NOT commit:
    /// MeetingStore re-inserts the row and returns false, and the audio the
    /// live row still points at then has to be left alone. The delete fails
    /// only when `context.save()` throws, which SwiftData's in-memory store
    /// has no way to be made to do, so that branch is unreachable otherwise.
    private let deleteMeeting: @MainActor (Meeting, ModelContext) -> Bool
```

with:

```swift
    /// How a saved meeting is removed — `MeetingStore.delete` in the app.
    /// Injectable because the branch that decides whether this session can
    /// corrupt the library is the one where that delete does NOT commit:
    /// MeetingStore re-inserts the row and returns false, and the audio the
    /// live row still points at then has to be left alone. The delete fails
    /// only when `context.save()` throws, which SwiftData's in-memory store
    /// has no way to be made to do, so that branch is unreachable otherwise.
    private let deleteMeeting: @MainActor (Meeting, ModelContext) -> Bool

    /// How microphone permission is asked for — `AudioRecorder.requestPermission`
    /// in the app. Injectable because a denial is the only thing that produces
    /// `canOpenSettings: true`, the flag that puts the Open Settings button on
    /// the recording screen, and a real system prompt can't be answered from a
    /// test. Unlike the rest of the recording path this branch needs no audio
    /// hardware: it returns before the recorder is touched.
    private let requestPermission: @Sendable () async -> Bool
```

- [ ] **Step 4: Add the init parameter**

In the same file, replace `init` (lines 96-109):

```swift
    /// `transcription` is injectable for tests; it defaults to nil rather than
    /// to `TranscriptionEngines.current()` because a default argument is
    /// evaluated outside this type's main-actor isolation.
    init(
        title: String,
        prefilledDefaultTitle: String = RecordingSession.defaultTitle(),
        transcription: (any TranscriptionEngine)? = nil,
        deleteMeeting: @escaping @MainActor (Meeting, ModelContext) -> Bool = MeetingStore.delete
    ) {
        self.title = title
        self.prefilledDefaultTitle = prefilledDefaultTitle
        self.transcription = transcription ?? TranscriptionEngines.current()
        self.deleteMeeting = deleteMeeting
    }
```

with:

```swift
    /// `transcription` and `requestPermission` are injectable for tests; both
    /// default to nil rather than to their real implementations because a
    /// default argument is evaluated outside this type's main-actor isolation
    /// and both real values are main-actor isolated.
    init(
        title: String,
        prefilledDefaultTitle: String = RecordingSession.defaultTitle(),
        transcription: (any TranscriptionEngine)? = nil,
        deleteMeeting: @escaping @MainActor (Meeting, ModelContext) -> Bool = MeetingStore.delete,
        requestPermission: (@Sendable () async -> Bool)? = nil
    ) {
        self.title = title
        self.prefilledDefaultTitle = prefilledDefaultTitle
        self.transcription = transcription ?? TranscriptionEngines.current()
        self.deleteMeeting = deleteMeeting
        self.requestPermission = requestPermission ?? { await AudioRecorder.requestPermission() }
    }
```

- [ ] **Step 5: Call the seam**

In the same file, replace line 115 (inside `start()`):

```swift
        guard await AudioRecorder.requestPermission() else {
```

with:

```swift
        guard await requestPermission() else {
```

- [ ] **Step 6: Run the suite to verify it passes**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MinuteTests/RecordingSessionPermissionTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔ Test run|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 1 test.

- [ ] **Step 7: Run the full unit suite**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 430 tests in 58 suites (the new suite is the 58th).

- [ ] **Step 8: Lint**

```bash
swiftlint --strict --reporter github-actions-logging 2>&1 | grep -E "^::(error|warning)|Done linting"
```
Expected: `Done linting!` with no `::error` or `::warning` lines.

- [ ] **Step 9: Commit**

```bash
git add Minute/Recording/RecordingSession.swift MinuteTests/RecordingSessionPermissionTests.swift
git commit -m "test: make microphone permission injectable and cover the denied branch

The denial is the only branch that sets canOpenSettings: true, the flag
that puts the Open Settings button on the recording screen, and it had no
coverage because the static call had no seam. The guard returns before
the recorder is touched, so the test needs no audio hardware.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 18: A failed route-restart stops blaming a call or Siri (C3)

`AudioRecorder.swift:392` routes the failed in-place restart after a route change through `systemPause(causedByInterruption: false)` → `onAutoPause?()` (`:405`), and the only handler (`RecordingSession.swift:123-132`) always says "Recording was paused by the system (a call or Siri). Tap resume to continue." So the user whose headset just switched away is told a phone call did it and goes looking in the wrong place. The recorder's own doc comment (`:244-247`) was updated for this; the user-facing string was not. The fix gives the callback the cause the recorder already knows.

**Files:**
- Modify: `Minute/Services/AudioRecorder.swift:8-20` (add the cause enum beside `RecorderError`), `:244-248` (`onAutoPause`), `:330-333` and `:390-393` (the two call sites), `:396-406` (`systemPause`)
- Modify: `Minute/Recording/RecordingSession.swift:123-132` (the handler) and add `autoPauseNotice(for:)` beside `savedTitles(draft:prefilledDefault:)` at `:504-507`
- Test: create `MinuteTests/RecordingSessionAutoPauseTests.swift`

**Interfaces:**
- Consumes: `AudioRecorder.pause()`, `AudioRecorder.state: State`, `RecordingSession.phase`, `RecordingSession.notice`.
- Produces: file-scope `enum AutoPauseCause: CaseIterable { case interruption, restartFailed }` in `AudioRecorder.swift`; `AudioRecorder.onAutoPause: ((AutoPauseCause) -> Void)?` (was `(() -> Void)?`); `AudioRecorder.systemPause(cause: AutoPauseCause)` (private, was `systemPause(causedByInterruption: Bool)`); `RecordingSession.autoPauseNotice(for: AutoPauseCause) -> String` (static, main-actor isolated). `RecordingSession.swift:123` is the only assignment to `onAutoPause` in the repo, so nothing else has to change.

- [ ] **Step 1: Write the failing test**

Create `MinuteTests/RecordingSessionAutoPauseTests.swift`:

```swift
import Foundation
import Testing
@testable import Minute

/// A route change now restarts capture in place, and only a *failed* restart
/// falls back to the auto-pause a phone call also lands on. Telling that user
/// "a call or Siri" sends them looking at their phone for a pause their headset
/// caused — the one thing they could actually act on goes unmentioned.
@MainActor
struct RecordingSessionAutoPauseTests {
    @Test func eachAutoPauseCauseIsExplainedInItsOwnWords() {
        let interruption = RecordingSession.autoPauseNotice(for: .interruption)
        let restartFailed = RecordingSession.autoPauseNotice(for: .restartFailed)

        #expect(interruption == "Recording was paused by the system (a call or Siri). Tap resume to continue.")
        #expect(restartFailed == "Recording paused — the audio device changed and capture couldn't restart. Tap resume to continue.")
        #expect(restartFailed.contains("call or Siri") == false)
    }

    /// Both notices stay up until the user acts, so both have to name the
    /// action: the recorder is paused, not stopped, and everything captured so
    /// far is still on disk and saveable.
    @Test func everyAutoPauseNoticeNamesTheWayOut() {
        for cause in AutoPauseCause.allCases {
            #expect(RecordingSession.autoPauseNotice(for: cause).contains("Tap resume to continue."))
        }
    }
}
```

- [ ] **Step 2: Run the suite to verify it fails**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MinuteTests/RecordingSessionAutoPauseTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔ Test run|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: a compile error, `error: cannot find 'AutoPauseCause' in scope`.

- [ ] **Step 3: Add the cause enum**

In `Minute/Services/AudioRecorder.swift`, replace lines 8-20:

```swift
enum RecorderError: LocalizedError {
    case noAudioInput
    case formatConversionFailed

    var errorDescription: String? {
        switch self {
        case .noAudioInput:
            return "No microphone input is available."
        case .formatConversionFailed:
            return "The microphone's audio format changed and couldn't be converted."
        }
    }
}
```

with:

```swift
enum RecorderError: LocalizedError {
    case noAudioInput
    case formatConversionFailed

    var errorDescription: String? {
        switch self {
        case .noAudioInput:
            return "No microphone input is available."
        case .formatConversionFailed:
            return "The microphone's audio format changed and couldn't be converted."
        }
    }
}

/// Why the recorder paused itself. Both causes reach the same callback, but
/// they send the user to different places, so the owner has to be able to tell
/// them apart: an interruption is a call or Siri and the system will offer to
/// resume it, while a failed restart is the audio device that just changed
/// under them and will not announce anything further.
///
/// File-scope rather than nested in `AudioRecorder` so it carries no
/// main-actor isolation of its own.
enum AutoPauseCause: CaseIterable {
    /// A phone call or Siri took the microphone.
    case interruption
    /// The input route changed and capture could not be restarted in place
    /// against the new hardware.
    case restartFailed
}
```

- [ ] **Step 4: Give the callback the cause**

In the same file, replace lines 244-248:

```swift
    /// Called after the system auto-pauses recording — a phone call or Siri
    /// taking the microphone — so the owner can reflect it in UI. A route
    /// change no longer arrives here: capture restarts in place against the
    /// new hardware and only a failed restart falls back to this pause.
    var onAutoPause: (() -> Void)?
```

with:

```swift
    /// Called after the system auto-pauses recording — a phone call or Siri
    /// taking the microphone — so the owner can reflect it in UI. A route
    /// change no longer arrives here: capture restarts in place against the
    /// new hardware and only a failed restart falls back to this pause, which
    /// is why the cause is passed: those two need different words on screen.
    var onAutoPause: ((AutoPauseCause) -> Void)?
```

- [ ] **Step 5: Pass the cause through `systemPause`**

In the same file, replace lines 396-406:

```swift
    /// Pauses because the system took the microphone away, not because the
    /// user asked. Only an interruption arms the auto-resume: a route change
    /// gets no matching "ended" callback, so treating it as resumable would
    /// let an unrelated later interruption restart a recording nobody asked to
    /// restart.
    private func systemPause(causedByInterruption: Bool) {
        guard state == .recording else { return }
        pause()
        pausedByInterruption = causedByInterruption
        onAutoPause?()
    }
```

with:

```swift
    /// Pauses because the system took the microphone away, not because the
    /// user asked. Only an interruption arms the auto-resume: a route change
    /// gets no matching "ended" callback, so treating it as resumable would
    /// let an unrelated later interruption restart a recording nobody asked to
    /// restart.
    private func systemPause(cause: AutoPauseCause) {
        guard state == .recording else { return }
        pause()
        pausedByInterruption = cause == .interruption
        onAutoPause?(cause)
    }
```

- [ ] **Step 6: Update the two call sites**

In the same file, replace lines 330-333:

```swift
            case .began:
                Task { @MainActor [weak self] in
                    self?.systemPause(causedByInterruption: true)
                }
```

with:

```swift
            case .began:
                Task { @MainActor [weak self] in
                    self?.systemPause(cause: .interruption)
                }
```

and replace lines 390-393:

```swift
        } catch {
            Self.logger.error("Restarting after an audio route change failed: \(error.localizedDescription)")
            systemPause(causedByInterruption: false)
        }
```

with:

```swift
        } catch {
            Self.logger.error("Restarting after an audio route change failed: \(error.localizedDescription)")
            systemPause(cause: .restartFailed)
        }
```

- [ ] **Step 7: Pick the message per cause in the session**

In `Minute/Recording/RecordingSession.swift`, replace lines 123-132:

```swift
        recorder.onAutoPause = { [weak self] in
            guard let self, self.phase == .recording else { return }
            self.phase = .paused
            // Names what actually gets here: a call or Siri taking the
            // microphone. A route change restarts capture in place now, and
            // the transient "Microphone changed — still recording" notice says
            // so; blaming an "audio change" here sent people looking at their
            // headphones for a pause a phone call caused.
            self.notice = "Recording was paused by the system (a call or Siri). Tap resume to continue."
        }
```

with:

```swift
        recorder.onAutoPause = { [weak self] cause in
            guard let self, self.phase == .recording else { return }
            self.phase = .paused
            self.notice = Self.autoPauseNotice(for: cause)
        }
```

and add, in the same file, after `savedTitles(draft:prefilledDefault:)` (its closing `}` at line 507) and before the type's final `}`:

```swift

    /// What the recording screen says after the system paused capture. The two
    /// causes send the user to two different places, so they must not share a
    /// sentence: a call or Siri resolves itself and the system offers the
    /// resume, while a failed restart is the audio device that just changed
    /// under them. Blaming a call for a headset that switched away sent people
    /// looking at their phone, and naming an "audio change" for a call sent
    /// them to their headphones — the recorder knows which it was, so say it.
    static func autoPauseNotice(for cause: AutoPauseCause) -> String {
        switch cause {
        case .interruption:
            "Recording was paused by the system (a call or Siri). Tap resume to continue."
        case .restartFailed:
            "Recording paused — the audio device changed and capture couldn't restart. Tap resume to continue."
        }
    }
```

- [ ] **Step 8: Run the suite to verify it passes**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MinuteTests/RecordingSessionAutoPauseTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔ Test run|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 2 tests.

- [ ] **Step 9: Run the full unit suite**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 432 tests in 59 suites.

- [ ] **Step 10: Lint**

```bash
swiftlint --strict --reporter github-actions-logging 2>&1 | grep -E "^::(error|warning)|Done linting"
```
Expected: `Done linting!` with no `::error` or `::warning` lines.

- [ ] **Step 11: Commit**

```bash
git add Minute/Services/AudioRecorder.swift Minute/Recording/RecordingSession.swift MinuteTests/RecordingSessionAutoPauseTests.swift
git commit -m "fix: a failed route-restart stops blaming a call or Siri for the pause

Both an interruption and a route change whose in-place restart failed
land on onAutoPause, and the single message named a call or Siri — so the
user whose headset switched away went looking at their phone. The
recorder already knows which happened; pass the cause and say it.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 19: A dead live-results stream closes the analyzer's input instead of letting buffers pile up (b2-T14-minor-3)

The general catch at `TranscriptionService.swift:129-146` sets availability and clears `volatileText` but leaves `inputContinuation` open, and the handler the recorder holds keeps yielding `AnalyzerInput` into it (`:165-168`) for the rest of the meeting. `AsyncStream` buffers unbounded, so with the analyzer no longer consuming, the process grows at roughly the ~230 MB/hour `WhisperTranscriptionService` explicitly guards against — on a long meeting that is a jetsam risk on a recording the user believes is safe.

**This change is not unit-testable**: reaching that catch needs a real `SpeechTranscriber` whose `results` stream throws, which no simulator can be made to produce (`SpeechTranscriber.isAvailable` is false there). It is verified by build + the full unit suite + lint, and the reason is recorded in the code comment.

**Files:**
- Modify: `Minute/Services/TranscriptionService.swift:129-146` (the general `catch` in `resultsTask`)

**Interfaces:**
- Consumes: `TranscriptionService.inputContinuation: AsyncStream<AnalyzerInput>.Continuation?` (private, `:32`), `AsyncStream.Continuation.finish()`, `TranscriptionService.liveStoppedMessage(_:)` (`:255-257`).
- Produces: no new symbols. The cleanup matches what `start()`'s analyzer-failed branch (`:152-162`) and `cancel()` (`:260-266`) already do with the same continuation.

- [ ] **Step 1: Close the input stream when the results stream dies**

In `Minute/Services/TranscriptionService.swift`, replace lines 129-146:

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
                // Only over "everything is fine". `start()` writes its own,
                // more specific message when the analyzer refuses to start —
                // and it cancels this task right afterwards, so the generic
                // "live transcription stopped" would land on top of the one
                // sentence that actually explains what happened.
                if self?.availability == .available {
                    self?.availability = .unavailable(Self.liveStoppedMessage(error))
                }
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
                // Close the analyzer's input as well. The recorder still holds
                // the handler returned below and keeps yielding into this
                // stream for the rest of the meeting; with nothing consuming
                // it, an AsyncStream buffers without bound — the ~230 MB/hour
                // WhisperTranscriptionService guards against, which on a long
                // meeting is a jetsam risk on a recording the user believes is
                // safe. Yields to a finished continuation are dropped, so the
                // tap handler becomes a no-op, and `finish()`'s
                // `finalizeAndFinishThroughEndOfInput` returns promptly
                // instead of waiting on a stream that never ends. Nothing is
                // lost: results had already stopped arriving.
                //
                // Not reachable from a unit test — provoking it needs a real
                // SpeechTranscriber whose results stream throws, and
                // SpeechTranscriber.isAvailable is false on the simulator.
                self?.inputContinuation?.finish()
                self?.inputContinuation = nil
                // Only over "everything is fine". `start()` writes its own,
                // more specific message when the analyzer refuses to start —
                // and it cancels this task right afterwards, so the generic
                // "live transcription stopped" would land on top of the one
                // sentence that actually explains what happened.
                if self?.availability == .available {
                    self?.availability = .unavailable(Self.liveStoppedMessage(error))
                }
            }
```

- [ ] **Step 2: Build and run the full unit suite**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 432 tests in 59 suites, no new warnings from `Minute/`.

- [ ] **Step 3: Lint**

```bash
swiftlint --strict --reporter github-actions-logging 2>&1 | grep -E "^::(error|warning)|Done linting"
```
Expected: `Done linting!` with no `::error` or `::warning` lines.

- [ ] **Step 4: Commit**

```bash
git add Minute/Services/TranscriptionService.swift
git commit -m "fix: close the analyzer's input when the live results stream dies

The catch reported the failure but left inputContinuation open, and the
recorder kept yielding into it for the rest of the meeting. With nothing
consuming the stream, AsyncStream buffers without bound — the ~230 MB/hour
that makes a long meeting a jetsam risk. Finishing the continuation makes
the tap handler a no-op and lets finish() return promptly.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Hand-offs to Track E

None. Every file touched by Tasks 13-19 (`Minute/Recording/RecordingSession.swift`, `Minute/Services/AudioRecorder.swift`, `Minute/Services/TranscriptionService.swift`, `Minute/Services/AudioPlayerController.swift`, `Minute/Views/RecordingView.swift`, and this track's test files) is owned by Track H, and the only cross-file signature changes — `AudioRecorder.onAutoPause` (Task 18) and `RecordingSession.init` (Task 17) — have their sole call sites inside this track's files (`RecordingSession.swift:123`) or keep compiling unchanged because the new parameter is last and defaulted (`Minute/Views/MeetingListView.swift:195` and `:218`, owned by another track, are not edited).

### Not done in this track

- No items assigned to Track H were dropped: all seven triage items map to Tasks 13-19.
- Task numbers 20-24 are unused — this track's item list is seven items and every one is small; padding it into more tasks would split single commits.
- Task 19 (`b2-T14-minor-3`) ships without a unit test, by necessity: the catch it changes is only reachable from a real `SpeechTranscriber` whose results stream throws, and `SpeechTranscriber.isAvailable` is false on the simulator. It is verified by build + the full unit suite + lint, and the reason is written into the code comment rather than left implicit.
- Tasks 13, 14 and 15 make no production change; their mutation steps (temporarily breaking the production line, watching exactly the new test fail, restoring) exist because these findings are specifically that the *existing* tests stay green when the production behavior is removed. The mutation is never committed — each of those tasks ends with a `git diff --stat` on the production file that must print nothing.

---

## Track I — Views, app entry, meeting store, models

Findings closed here: B9 (view half), b2-T28-minor-1, b2-T30-minor-1, B6, B12, b1-T11-minor-3, A2 (view + model half), b2-T33-minor-2, B10, b2-T35-minor-1.

**Files this track owns** (a task must not edit anything else):
`Minute/Views/MeetingListView.swift`, `Minute/Views/MeetingDetailView.swift`,
`Minute/Views/SettingsView.swift`, `Minute/Views/SummaryEditorView.swift`,
`Minute/App/MinuteApp.swift`, `Minute/App/DemoSeed.swift`,
`Minute/Services/MeetingStore.swift`, `Minute/Services/WidgetSnapshotPublisher.swift`,
`Minute/Support/MeetingDeepLinkState.swift`, `Minute/Support/AppSettings.swift`,
`Minute/Models/*`, plus the tests `MinuteTests/MeetingStoreTests.swift`,
`MinuteTests/SummaryEditorParsingTests.swift`, `MinuteTests/MeetingDeepLinkStateTests.swift`,
`MinuteTests/MeetingDetailIdentityTests.swift`, `MinuteTests/AppSettingsStorageFailureTests.swift`,
`MinuteTests/MeetingDateGroupTests.swift`, and new test files for these types.

`Minute/Services/MeetingJobs.swift` and `MinuteTests/SpeakerAssignmentTests.swift` are **not** owned here — two findings (A2, B9) have a half that lives there, and each of those tasks ends at the owned side with the remainder listed under "Hand-offs to Track E".

### Global Constraints

- Privacy invariants from CONTRIBUTING.md hold: no meeting content on the wire; every byte written has a delete path; AI output stays grounded ("Not specified" literal); recording never depends on optional capabilities and any handled failure still offers to save captured audio.
- No new third-party dependencies. Do not edit Minute.xcodeproj/project.pbxproj (new files under Minute/, MinuteTests/, Shared/, MinuteWidgets/ are picked up automatically).
- Unit tests use Swift Testing, never XCTest. SwiftData-touching test structs are @MainActor with an in-memory container via MeetingStore.modelConfiguration(inMemory: true); containers holding KnowledgeEntity/KnowledgeFact are retained for the process lifetime (retainedContainers pattern in MinuteTests/KnowledgeCatchUpTests.swift). Suite-level -only-testing selectors only (a single-test selector silently selects nothing).
- Swift 5 language mode: an actor-isolated expression cannot be a default argument (use the nil-defaulted injection pattern).
- Baseline at the branch point (main b481626): 424 tests in 57 suites pass; swiftlint --strict reports 0 violations. Every task leaves both true plus its own new tests.
- swiftlint 0.65.1 IS installed locally: run `swiftlint --strict --reporter github-actions-logging` from the repo root before every commit; live rules include multiple_closures_with_trailing_closure and redundant_void_return; line_length, function/type/file length, cyclomatic_complexity, identifier_name, todo, redundant_optional_initialization, trailing_comma, for_where are disabled.
- Commit messages: Conventional Commits (fix:/test:/docs:/refactor:), ending with the trailer line "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>". Explicit paths; never git add -A; never commit anything under .superpowers/.
- A task edits only files its track owns; cross-track needs go in "Hand-offs to Track E".
- After a committed delete a SwiftData object has isDeleted == false and modelContext == nil; guard stale reads with isGone.

**Test commands** (run from the worktree root; prefix every shell command with `cd /Users/feihou/workplace/minute/.claude/worktrees/app-code-review-e76404 &&`). This track uses simulator "iPhone 17 Pro Max".

One suite while iterating:

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:MinuteTests/<SuiteName> CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔ Test run|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```

Full unit suite, once before each commit:

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```

Build only (the verification for the four view-only tasks, which nothing can unit-test):

```bash
xcodebuild build -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|warning:.*Minute/|BUILD (SUCCEEDED|FAILED)"
```

Lint, before each commit:

```bash
swiftlint --strict --reporter github-actions-logging 2>&1 | grep -E "^::(error|warning)|Done linting"
```

**Line numbers** in this section are as of commit `b481626` and shift as earlier tasks in this track land. Every replacement quotes the exact current text; **the quoted old snippet is the authoritative anchor** — find it, don't count lines.

---

### Task 25: The title's defocus commit survives the LazyVStack recycling the masthead (B9, view half)

`.onChange(of: titleFocused)` is attached to the `TextField` inside the page's `LazyVStack`, while the `@FocusState` it observes is owned by the outer view. A lazy stack destroys the rows it scrolls out of view, taking the handler with it — and that handler's commit is what makes Copy Notes, Share Notes and Edit Summary read the title the user just typed. Pure SwiftUI modifier placement: nothing here is reachable from a unit test, so this task is verified by the build, the full unit suite, and lint.

**Files:**
- Modify: `Minute/Views/MeetingDetailView.swift:112` (add the handler to the `Group` in `body`, before `.onChange(of: meeting.isGone)`), `Minute/Views/MeetingDetailView.swift:316-328` (remove it from the `TextField`)

**Interfaces:**
- Consumes: `@FocusState private var titleFocused: Bool` (`MeetingDetailView.swift:50`), `private func commitTitle()` (`MeetingDetailView.swift:733`).
- Produces: nothing new. The second half of B9 — `MeetingJobs.swift:292` re-deriving `titleFallback` — is Hand-off 1.

- [ ] **Step 1: Move the handler onto the view that owns the focus state**

In `Minute/Views/MeetingDetailView.swift`, in `body`, find:

```swift
        .onChange(of: meeting.isGone) { _, gone in
```

and insert immediately above it:

```swift
        // On the Group, not on the field: the field lives inside the page's
        // LazyVStack, and a lazy stack destroys and rebuilds the rows it
        // scrolls out of view — taking a handler attached down there with it.
        // The commit it performs is what makes every toolbar action (Copy
        // Notes, Share Notes, Edit Summary) read the title the user just
        // typed, so it belongs to the same view that owns the @FocusState.
        .onChange(of: titleFocused) { _, focused in
            if !focused {
                commitTitle()
            }
        }
        .onChange(of: meeting.isGone) { _, gone in
```

- [ ] **Step 2: Remove the handler from the TextField**

In the same file, in `masthead`, replace:

```swift
            TextField("Title", text: Binding(
                get: { titleDraft ?? meeting.title },
                set: { titleDraft = $0 }
            ), axis: .vertical)
                .font(.largeTitle.bold())
                .textFieldStyle(.plain)
                .focused($titleFocused)
                .onChange(of: titleFocused) { _, focused in
                    if !focused {
                        commitTitle()
                    }
                }
                .accessibilityLabel("Meeting title")
```

with:

```swift
            TextField("Title", text: Binding(
                get: { titleDraft ?? meeting.title },
                set: { titleDraft = $0 }
            ), axis: .vertical)
                .font(.largeTitle.bold())
                .textFieldStyle(.plain)
                .focused($titleFocused)
                .accessibilityLabel("Meeting title")
```

- [ ] **Step 3: Build**

Run: the build-only command.

Expected: `BUILD SUCCEEDED`, no new warnings under `Minute/`.

- [ ] **Step 4: Run the full unit suite**

Run: the full unit suite command.

Expected: `TEST SUCCEEDED`, 424 tests in 57 suites (unchanged — this task adds none).

- [ ] **Step 5: Lint**

Run: the lint command.

Expected: a `Done linting!` line reporting 0 violations, and no `::error` or `::warning` lines.

- [ ] **Step 6: Commit**

```bash
git add Minute/Views/MeetingDetailView.swift
git commit -m "fix: keep the title's defocus commit outside the lazy stack that recycles the masthead

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 26: The greyed-out Generate Summary button says why (b2-T28-minor-1)

The empty-summary state disables Generate on `isBusy`, but the row that explains the wait — "Re-transcribing on device…" — lives on the Transcript tab, so a user sitting on Summary sees only a dead button. A caption under the button, rendered from the same `jobStatus` the transcript row uses. View-body-only: nothing here is reachable from a unit test, so this task is verified by the build, the full unit suite, and lint.

**Files:**
- Modify: `Minute/Views/MeetingDetailView.swift:495-511` (the button inside `emptySummaryState`)

**Interfaces:**
- Consumes: `private var isBusy: Bool` (`MeetingDetailView.swift:71`), `private var jobStatus: String?` (`MeetingDetailView.swift:76`, `jobs.status(for: meeting)`).
- Produces: nothing new.

- [ ] **Step 1: Render the reason under the disabled button**

In `Minute/Views/MeetingDetailView.swift`, in `emptySummaryState`, replace:

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
                if isBusy {
                    // A disabled button with no reason on screen is still a
                    // dead end: the row that explains the wait — "Re-transcribing
                    // on device…" — lives on the Transcript tab, and the tab
                    // picker means a user sitting on Summary never sees it.
                    // Same text the transcript row shows, with a fixed fallback
                    // for a job that reports no progress string.
                    Text(jobStatus ?? "Available once the current job finishes.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
```

- [ ] **Step 2: Build**

Run: the build-only command.

Expected: `BUILD SUCCEEDED`, no new warnings under `Minute/`.

- [ ] **Step 3: Run the full unit suite**

Run: the full unit suite command.

Expected: `TEST SUCCEEDED`, 424 tests in 57 suites.

- [ ] **Step 4: Lint**

Run: the lint command.

Expected: 0 violations.

- [ ] **Step 5: Commit**

```bash
git add Minute/Views/MeetingDetailView.swift
git commit -m "fix: say why Generate Summary is unavailable instead of showing a dead button

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 27: A background trip commits the title without ending the edit (b2-T30-minor-1)

`commitTitle` nils `titleDraft` unconditionally, and the scene-phase handler calls it on any non-`.active` phase. Pulling down Control Center, switching apps, or a system alert therefore refills a focused field with the committed value — for a user who had cleared it to retype, the fallback "Meeting Sep 2, 2026 at 9:41 AM" appears under their cursor, and any in-progress IME composition is replaced. The value must still be committed (the background pass mirrors the meeting and may be the last thing that runs), but the draft may not be dropped while the field still has focus. View state only: nothing here is reachable from a unit test, so this task is verified by the build, the full unit suite, and lint.

**Deliberate deviation from the source, which literally says to restore `titleDraft = committed`:** this task restores `titleDraft = draft` — the user's own text — instead. For an emptied field `committed` *is* the fallback, so writing it back would put "Meeting Sep 2, 2026 at 9:41 AM" under the cursor of the user who had just cleared the field, which is the exact symptom the finding describes. `committed` is also `nil` whenever nothing changed, so there would be nothing to restore in the common case. The intent of the fix is unchanged; only the value put back differs. Do not "correct" this back to the source's literal wording.

**Files:**
- Modify: `Minute/Views/MeetingDetailView.swift:733-740` (`commitTitle`), `Minute/Views/MeetingDetailView.swift:124-134` (the `scenePhase` handler)

**Interfaces:**
- Consumes: `Meeting.titleCommit(draft:current:fallback:) -> String?` (`Minute/Models/Meeting.swift:112`), `meeting.titleFallback` (`Meeting.swift:121`), `@State private var titleDraft: String?` (`MeetingDetailView.swift:44`), `@FocusState private var titleFocused: Bool` (`:50`).
- Produces: `private func commitTitle(keepEditing: Bool = false)` — the default keeps the two existing call sites (`onDisappear`, and the focus handler moved in Task 25) unchanged.

- [ ] **Step 1: Give commitTitle a keepEditing parameter**

In `Minute/Views/MeetingDetailView.swift`, replace:

```swift
    /// Writes the edited title back to the meeting, substituting the fallback
    /// when the user left the field empty. Called from every way out of the
    /// field — the keyboard being dismissed, the screen being left, the app
    /// being backgrounded — so it is a no-op when nothing is pending: merely
    /// opening and leaving this screen never touches the model, which also
    /// keeps the widget snapshot from being rewritten for a visit. Clearing
    /// the draft before the `isGone` check is what keeps a pending edit from
    /// being re-applied to a meeting deleted between two of those calls.
    private func commitTitle() {
        guard let draft = titleDraft else { return }
        titleDraft = nil
        guard !meeting.isGone else { return }
        if let committed = Meeting.titleCommit(draft: draft, current: meeting.title, fallback: meeting.titleFallback) {
            meeting.title = committed
        }
    }
```

with:

```swift
    /// Writes the edited title back to the meeting, substituting the fallback
    /// when the user left the field empty. Called from every way out of the
    /// field — the keyboard being dismissed, the screen being left, the app
    /// being backgrounded — so it is a no-op when nothing is pending: merely
    /// opening and leaving this screen never touches the model, which also
    /// keeps the widget snapshot from being rewritten for a visit. Clearing
    /// the draft before the `isGone` check is what keeps a pending edit from
    /// being re-applied to a meeting deleted between two of those calls.
    ///
    /// `keepEditing` is for the callers that are not the end of the edit: a
    /// scene change is Control Center, a system alert, or a glance at another
    /// app, and the field can still be focused with a half-typed title in it.
    /// Committing there is what makes the value safe to mirror; ending the
    /// user's edit session is not part of that.
    private func commitTitle(keepEditing: Bool = false) {
        guard let draft = titleDraft else { return }
        titleDraft = nil
        guard !meeting.isGone else { return }
        if let committed = Meeting.titleCommit(draft: draft, current: meeting.title, fallback: meeting.titleFallback) {
            meeting.title = committed
        }
        if keepEditing {
            // The user's own text, never the committed value: an emptied field
            // commits the fallback, and writing that back would put "Meeting
            // Sep 2, 2026 at 9:41 AM" under the cursor of someone who had just
            // cleared it to retype. Restored after the write and after the
            // isGone guard, so a meeting deleted mid-edit still ends with no
            // draft to re-apply.
            titleDraft = draft
        }
    }
```

- [ ] **Step 2: Pass the focus state from the scene-phase handler**

In the same file, in `body`, replace:

```swift
            if phase != .active, !meeting.isGone {
                commitTitle()
                saveQuietly()
            }
```

with:

```swift
            if phase != .active, !meeting.isGone {
                commitTitle(keepEditing: titleFocused)
                saveQuietly()
            }
```

- [ ] **Step 3: Build**

Run: the build-only command.

Expected: `BUILD SUCCEEDED`, no new warnings under `Minute/`.

- [ ] **Step 4: Run the full unit suite**

Run: the full unit suite command.

Expected: `TEST SUCCEEDED`, 424 tests in 57 suites. `MeetingTitleTests` covers `titleCommit`/`committedTitle` and is untouched by this change.

- [ ] **Step 5: Lint**

Run: the lint command.

Expected: 0 violations.

- [ ] **Step 6: Commit**

```bash
git add Minute/Views/MeetingDetailView.swift
git commit -m "fix: a background trip commits the title without resetting the field under the cursor

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 28: The New Meeting deep link waits for Settings to close (B6)

`handleDeepLink`'s `.presentNewMeeting` case calls `dismissPresentedSheets()` (which sets `showingSettings = false`) and then `beginNewMeeting()` (which sets `showingNewMeeting = true`) inside one SwiftUI update, with the two `.sheet` modifiers as siblings. SwiftUI is unreliable at replacing one sheet with another in a single transaction, so the widget's New Meeting button pressed while Settings is open can end with neither sheet on screen and nothing to explain it. Per the recorded decision, the presentation moves to the Settings sheet's `onDismiss`. SwiftUI sheet lifecycle: nothing here is reachable from a unit test (`MeetingDeepLinkState.action` already covers the arbitration that precedes it), so this task is verified by the build, the full unit suite, and lint.

**Files:**
- Modify: `Minute/Views/MeetingListView.swift:52-55` (add the new `@State`), `Minute/Views/MeetingListView.swift:221-223` (the Settings sheet), `Minute/Views/MeetingListView.swift:514-516` (the `.presentNewMeeting` case)

**Interfaces:**
- Consumes: `MeetingDeepLinkState.action(for:isRecording:isShowingNewMeeting:) -> Action` (`Minute/Support/MeetingDeepLinkState.swift:37`), `private func beginNewMeeting()` (`MeetingListView.swift:456`), `private func dismissPresentedSheets()` (`:529`).
- Produces: `@State private var presentNewMeetingAfterSettings = false` on `MeetingListView` (private view state; no test-visible surface).

- [ ] **Step 1: Add the deferred-presentation flag**

In `Minute/Views/MeetingListView.swift`, replace:

```swift
    @State private var deepLinkState = MeetingDeepLinkState()
```

with:

```swift
    @State private var deepLinkState = MeetingDeepLinkState()
    /// Set when a New Meeting deep link arrives while Settings is open, so the
    /// swap happens across two updates instead of one. SwiftUI is unreliable at
    /// replacing one sheet with another inside a single transaction: flipping
    /// `showingSettings` false and `showingNewMeeting` true together can end
    /// with neither sheet on screen, and the widget's New Meeting button then
    /// looks like it did nothing at all.
    @State private var presentNewMeetingAfterSettings = false
```

- [ ] **Step 2: Present from the Settings sheet's onDismiss**

In the same file, replace:

```swift
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
```

with:

```swift
        // `content:` spelled out rather than trailing: `.sheet` then takes two
        // closure arguments, and SwiftLint's multiple_closures_with_trailing_closure
        // — live in this repo, fatal under --strict — rejects the trailing form
        // as soon as a second closure is passed.
        .sheet(isPresented: $showingSettings, onDismiss: {
            if presentNewMeetingAfterSettings {
                presentNewMeetingAfterSettings = false
                beginNewMeeting()
            }
        }, content: {
            SettingsView()
        })
```

- [ ] **Step 3: Defer the presentation when Settings is up**

In the same file, in `handleDeepLink`, replace:

```swift
        case .presentNewMeeting:
            dismissPresentedSheets()
            beginNewMeeting()
```

with:

```swift
        case .presentNewMeeting:
            if showingSettings {
                // Not in this update — see `presentNewMeetingAfterSettings`.
                // dismissPresentedSheets() still runs: it is what takes
                // Settings down, and the onDismiss above is what opens the
                // sheet the link actually asked for.
                presentNewMeetingAfterSettings = true
                dismissPresentedSheets()
            } else {
                dismissPresentedSheets()
                beginNewMeeting()
            }
```

- [ ] **Step 4: Build**

Run: the build-only command.

Expected: `BUILD SUCCEEDED`, no new warnings under `Minute/`.

- [ ] **Step 5: Run the full unit suite**

Run: the full unit suite command.

Expected: `TEST SUCCEEDED`, 424 tests in 57 suites. `MeetingDeepLinkStateTests` still passes: the arbitration it covers is unchanged, only what the `.presentNewMeeting` case does with the answer.

- [ ] **Step 6: Lint**

Run: the lint command.

Expected: 0 violations. In particular no `multiple_closures_with_trailing_closure` on the new `.sheet`: both `onDismiss` and `content` are passed as labeled arguments and nothing trails. Keeping the trailing form (`.sheet(isPresented:onDismiss: { … }) { SettingsView() }`) is what the rule rejects — verified against the installed swiftlint 0.65.1 with this repo's config, which reports `Trailing closure syntax should not be used when passing more than one closure argument (multiple_closures_with_trailing_closure)` as an `::error` and fails the gate.

- [ ] **Step 7: Commit**

```bash
git add Minute/Views/MeetingListView.swift
git commit -m "fix: present the New Meeting sheet after Settings closes, not in the same update

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 29: "Ship it | Alice |" saves the owner as "Alice" (B12)

For a line ending in a separator the backwards search finds the whole `" | "` before it first, so `splitActionItemLine` returns `["Ship it", "Alice |"]` and the owner is saved with a dangling pipe — through the exact format the editor's own footer invites, with no undo. Per the recorded decision, a trailing empty field is dropped rather than turned into an owner.

**Files:**
- Modify: `Minute/Views/SummaryEditorView.swift:219-252` (`splitActionItemLine`, doc comment and body)
- Test: `MinuteTests/SummaryEditorParsingTests.swift` (add at the end of the struct, after `aSeparatorInsideTheDeadlineStillShiftsFields`)

**Interfaces:**
- Consumes: `SummaryEditorView.actionItemSeparator` (`" | "`, `SummaryEditorView.swift:205`), `SummaryEditorView.serializeActionItems(_:) -> String` (`:213`), `SummaryEditorView.parseActionItems(_:) -> [ActionItem]` (`:254`), `SummarizationService.normalizedField(_:)`.
- Produces: no signature change — `static func splitActionItemLine(_ line: String) -> [String]` keeps its shape, with a new pre-loop step.

- [ ] **Step 1: Write the failing tests**

Add to `MinuteTests/SummaryEditorParsingTests.swift`, inside `struct SummaryEditorParsingTests`, after `aSeparatorInsideTheDeadlineStillShiftsFields`:

```swift
    /// B12: a row typed left to right and abandoned after the owner —
    /// "Ship it | Alice |" — ends with a separator that opens a field nobody
    /// filled. The backwards search finds the whole separator before it first,
    /// so that empty tail came back attached to the owner: "Alice |" saved as
    /// the person's name, dangling pipe and all, and there is no undo. An empty
    /// trailing field is what "nothing typed there" looks like, so it is
    /// dropped. The trailing-space form is the same line with the separator
    /// fully typed out.
    @Test func splitActionItemLineDropsATrailingEmptyFieldInsteadOfMakingItAnOwner() {
        #expect(SummaryEditorView.splitActionItemLine("Ship it | Alice |") == ["Ship it", "Alice"])
        #expect(SummaryEditorView.splitActionItemLine("Ship it | Alice | ") == ["Ship it", "Alice"])
        #expect(SummaryEditorView.splitActionItemLine("Ship it |") == ["Ship it"])
        // Repeated, or the pipe the first shed leaves behind rides along on the
        // task: "Ship it | |" is two openings, not a task called "Ship it |".
        #expect(SummaryEditorView.splitActionItemLine("Ship it | |") == ["Ship it"])
    }

    @Test func parseActionItemsSavesAnOwnerWithoutTheDanglingPipe() {
        let parsed = SummaryEditorView.parseActionItems("Ship it | Alice |")
        #expect(parsed == [ActionItem(task: "Ship it", owner: "Alice", deadline: "Not specified")])
    }

    /// What dropping a trailing empty field costs, pinned like this file's
    /// other accepted limits: a deadline that is itself a bare "|" serializes
    /// to a line ending in " |", and now reads as a field the user never
    /// filled. Owners are names and deadlines are dates — a lone pipe in one is
    /// not something anyone types, while "Ship it | Alice |" is exactly what
    /// people do type.
    @Test func aTrailingBarePipeDeadlineIsDroppedRatherThanKept() {
        let serialized = SummaryEditorView.serializeActionItems([
            ActionItem(task: "Ship it", owner: "Alice", deadline: "|"),
        ])

        #expect(serialized == "Ship it | Alice | |")
        #expect(SummaryEditorView.parseActionItems(serialized)
            == [ActionItem(task: "Ship it", owner: "Alice", deadline: "Not specified")])
    }
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: the one-suite command with `SummaryEditorParsingTests`.

Expected: it builds and three tests fail — the first with `Expectation failed: SummaryEditorView.splitActionItemLine("Ship it | Alice |") == ["Ship it", "Alice"]` (the actual value is `["Ship it", "Alice |"]`), the second with an owner of `"Alice |"`, the third with a deadline of `"|"`.

- [ ] **Step 3: Shed a trailing empty field before splitting**

In `Minute/Views/SummaryEditorView.swift`, replace `splitActionItemLine` in full — doc comment and body:

```swift
    /// Splits one line into at most three fields, on the LAST two separators.
    /// Everything left of them is the task, however many pipes it contains —
    /// splitting on every "|" turned a model-written "Compare vendor A |
    /// vendor B" into a task, an owner and a deadline that all belonged to the
    /// task, silently and with no undo. A line with a single separator still
    /// means task + owner, which is what a user typing one row expects.
    ///
    /// Two adjacent separators share the one space between their pipes, which
    /// is how "task | | deadline" — a row with a deadline and no owner — is
    /// typed. Taking the second separator takes that shared space with it, so
    /// what is left of the first is a " |" at the very end of `head`, matching
    /// no whole separator: the deadline slid into the owner and the task kept a
    /// dangling pipe, while the two-space form parsed fine. So once a separator
    /// has been consumed, its leading space is lent back and a trailing " |"
    /// closes a separator too. A whole separator is still preferred, or an owner
    /// that is itself a bare "|" ("task | | | deadline") would read as an empty
    /// one.
    static func splitActionItemLine(_ line: String) -> [String] {
        var fields: [String] = []
        var head = Substring(line)
        while fields.count < 2 {
            if let range = head.range(of: actionItemSeparator, options: .backwards) {
                fields.insert(String(head[range.upperBound...]), at: 0)
                head = head[..<range.lowerBound]
            } else if !fields.isEmpty, head.hasSuffix(" |") {
                fields.insert("", at: 0)
                head = head.dropLast(2)
            } else {
                break
            }
        }
        fields.insert(String(head), at: 0)
        return fields
    }
```

with:

```swift
    /// Splits one line into at most three fields, on the LAST two separators.
    /// Everything left of them is the task, however many pipes it contains —
    /// splitting on every "|" turned a model-written "Compare vendor A |
    /// vendor B" into a task, an owner and a deadline that all belonged to the
    /// task, silently and with no undo. A line with a single separator still
    /// means task + owner, which is what a user typing one row expects.
    ///
    /// A row left ending in a separator — "Ship it | Alice |", typed left to
    /// right by someone who never filled the third field — opens a field with
    /// nothing in it. The backwards search finds the whole separator before it
    /// first, so that empty tail used to come back attached to the owner:
    /// "Alice |" saved as the person's name, dangling pipe and all, with no
    /// undo. It is dropped instead, which is what "nothing typed there" means.
    /// Trailing spaces are shed with it, so a line ending " | " reads the same
    /// as one ending " |", and the shedding repeats so "Ship it | |" leaves a
    /// clean task rather than one carrying a pipe. The cost is that a deadline
    /// which is *itself* a bare "|" no longer survives the round trip — the
    /// same class of accepted limit as a separator typed inside a deadline, and
    /// pinned by a test for the same reason.
    ///
    /// Two adjacent separators share the one space between their pipes, which
    /// is how "task | | deadline" — a row with a deadline and no owner — is
    /// typed. Taking the second separator takes that shared space with it, so
    /// what is left of the first is a " |" at the very end of `head`, matching
    /// no whole separator: the deadline slid into the owner and the task kept a
    /// dangling pipe, while the two-space form parsed fine. So once a separator
    /// has been consumed, its leading space is lent back and a trailing " |"
    /// closes a separator too. A whole separator is still preferred, or an owner
    /// that is itself a bare "|" ("task | | | deadline") would read as an empty
    /// one — which is why that preference stays inside the loop while the
    /// shedding above happens once, at the line's end, before any of it.
    static func splitActionItemLine(_ line: String) -> [String] {
        var fields: [String] = []
        var head = Substring(line)
        while head.hasSuffix(" ") || head.hasSuffix(" |") {
            head = head.hasSuffix(" ") ? head.dropLast() : head.dropLast(2)
        }
        while fields.count < 2 {
            if let range = head.range(of: actionItemSeparator, options: .backwards) {
                fields.insert(String(head[range.upperBound...]), at: 0)
                head = head[..<range.lowerBound]
            } else if !fields.isEmpty, head.hasSuffix(" |") {
                fields.insert("", at: 0)
                head = head.dropLast(2)
            } else {
                break
            }
        }
        fields.insert(String(head), at: 0)
        return fields
    }
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: the one-suite command with `SummaryEditorParsingTests`.

Expected: all pass — the three new tests plus the seventeen pre-existing ones (20 in the suite). In particular `splitActionItemLinePrefersAWholeSeparatorOverABorrowedSpace` ("Ship it | | | Friday" → `["Ship it", "|", "Friday"]`) still passes: its trailing field is non-empty, so the shedding loop never fires on it. So does `parseActionItemsSkipsLinesWithoutTask` (" | Alex | Friday"): `parseActionItems` feeds raw `splitLines` output, leading space intact, and the shedding only touches the line's end.

- [ ] **Step 5: Run the full unit suite**

Run: the full unit suite command.

Expected: `TEST SUCCEEDED`, 427 tests in 57 suites.

- [ ] **Step 6: Lint**

Run: the lint command.

Expected: 0 violations.

- [ ] **Step 7: Commit**

```bash
git add Minute/Views/SummaryEditorView.swift MinuteTests/SummaryEditorParsingTests.swift
git commit -m "fix: drop an action item's trailing empty field instead of saving it as the owner

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 30: The save-time Brain nudge decision gets a testable seam (b1-T11-minor-3)

`nudgeBrain` is a private view method the test target cannot reach, and its one-line guard carries a 25-line rationale for two non-obvious skips. Dropping either regresses something real and silent — nudging a transcript-less meeting spends its one chance and the catch-up loop skip-lists it for the whole process, so a transcript a later Re-transcribe Audio produces never gets extracted — and nothing would go red.

**Files:**
- Modify: `Minute/Views/MeetingListView.swift:462-489` (extract the rule, move the rationale onto it)
- Create: `MinuteTests/MeetingListNudgeTests.swift`

**Interfaces:**
- Consumes: `Meeting.hasTranscript` (`Minute/Models/Meeting.swift:63`), `@State private var destinationAutoSummarizes` (`MeetingListView.swift:40`), `KnowledgeCatchUp.nudge(context:)`.
- Produces: `MeetingListView.shouldNudgeBrain(hasTranscript: Bool, destinationAutoSummarizes: Bool) -> Bool` — internal and static, so `@testable import Minute` reaches it without building a view.

- [ ] **Step 1: Write the failing test**

Create `MinuteTests/MeetingListNudgeTests.swift`:

```swift
import Testing
@testable import Minute

/// The two skips in the save-time Brain nudge, which are the whole content of
/// the decision and were previously locked inside a private view method. Each
/// one is load-bearing and silent when wrong, so each gets a case here.
@MainActor
struct MeetingListNudgeTests {
    /// A silent save, or an import whose transcription failed: there is nothing
    /// to read, and nudging spends the meeting's one chance — the catch-up loop
    /// skip-lists it for the rest of the process, so the transcript a later
    /// Re-transcribe Audio produces would never be extracted. That job nudges
    /// the loop itself when it lands, so nothing is lost by waiting.
    @Test func aMeetingWithNoTranscriptIsNotNudged() {
        #expect(!MeetingListView.shouldNudgeBrain(hasTranscript: false, destinationAutoSummarizes: false))
        #expect(!MeetingListView.shouldNudgeBrain(hasTranscript: false, destinationAutoSummarizes: true))
    }

    /// With Auto-Summarize on, the summary starting on the next screen nudges
    /// the loop when it ends, however it ends. Nudging now would only make
    /// extraction and that summary contend for the single on-device model.
    @Test func anAutoSummarizingDestinationIsLeftToItsOwnJobsEnd() {
        #expect(!MeetingListView.shouldNudgeBrain(hasTranscript: true, destinationAutoSummarizes: true))
    }

    /// The default configuration, and the reason this nudge exists at all: with
    /// Auto-Summarize off, no job is coming, so without this the meeting goes
    /// unread until the app is backgrounded and reopened.
    @Test func aTranscribedMeetingWithNoSummaryComingIsNudgedNow() {
        #expect(MeetingListView.shouldNudgeBrain(hasTranscript: true, destinationAutoSummarizes: false))
    }
}
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: the one-suite command with `MeetingListNudgeTests`.

Expected: the build fails — `type 'MeetingListView' has no member 'shouldNudgeBrain'`.

- [ ] **Step 3: Extract the rule**

In `Minute/Views/MeetingListView.swift`, replace:

```swift
    /// Lets the Brain read a meeting that has just arrived from a recording or
    /// an import. The loop is otherwise only nudged by a finished job or a
    /// scene activation, so with Auto-Summarize off (the default) neither
    /// happens and the meeting goes unread until the app is backgrounded and
    /// reopened.
    ///
    /// Two cases skip the nudge. A meeting with no transcript (a silent save,
    /// an import whose transcription failed) has nothing to read, and the loop
    /// skip-lists it for the rest of the process — spending its one chance, so
    /// the transcript a later Re-transcribe Audio produces would never be
    /// extracted. Nothing is lost by waiting there: that job nudges the loop
    /// itself when it lands. And with Auto-Summarize on, the summary starting
    /// on the next screen nudges the loop when it ends, however it ends:
    /// `MeetingJobs.onWorkEnded` fires on success, on the cancel a Stop tap
    /// produces, and on failure alike, and `KnowledgeCatchUp.workEnded(context:)`
    /// starts reading again once the last outstanding job is gone. Nudging now
    /// would only make extraction and that summary contend for the single
    /// on-device model.
    ///
    /// The gap left in that second case is a summary that never starts at all
    /// — the selected engine is unavailable, or the auto-summary was already
    /// claimed — since no job means no end to nudge from. The meeting then
    /// waits for the Brain tab's own `.task` or the next scene activation to be
    /// read: later than a nudge here, but never lost.
    private func nudgeBrain(for meeting: Meeting) {
        guard meeting.hasTranscript, !destinationAutoSummarizes else { return }
        catchUp.nudge(context: context)
    }
```

with:

```swift
    /// Whether a meeting that has just arrived from a recording or an import
    /// should nudge the Brain now. The loop is otherwise only nudged by a
    /// finished job or a scene activation, so with Auto-Summarize off (the
    /// default) neither happens and the meeting goes unread until the app is
    /// backgrounded and reopened.
    ///
    /// Two cases skip the nudge. A meeting with no transcript (a silent save,
    /// an import whose transcription failed) has nothing to read, and the loop
    /// skip-lists it for the rest of the process — spending its one chance, so
    /// the transcript a later Re-transcribe Audio produces would never be
    /// extracted. Nothing is lost by waiting there: that job nudges the loop
    /// itself when it lands. And with Auto-Summarize on, the summary starting
    /// on the next screen nudges the loop when it ends, however it ends:
    /// `MeetingJobs.onWorkEnded` fires on success, on the cancel a Stop tap
    /// produces, and on failure alike, and `KnowledgeCatchUp.workEnded(context:)`
    /// starts reading again once the last outstanding job is gone. Nudging now
    /// would only make extraction and that summary contend for the single
    /// on-device model.
    ///
    /// The gap left in that second case is a summary that never starts at all
    /// — the selected engine is unavailable, or the auto-summary was already
    /// claimed — since no job means no end to nudge from. The meeting then
    /// waits for the Brain tab's own `.task` or the next scene activation to be
    /// read: later than a nudge here, but never lost.
    ///
    /// Static and parameterized rather than folded into the call below, because
    /// both skips are silent when they regress and a private view method is
    /// unreachable from the tests that would say so.
    static func shouldNudgeBrain(hasTranscript: Bool, destinationAutoSummarizes: Bool) -> Bool {
        hasTranscript && !destinationAutoSummarizes
    }

    /// Lets the Brain read a meeting that has just arrived — see
    /// `shouldNudgeBrain` for which arrivals qualify and why.
    private func nudgeBrain(for meeting: Meeting) {
        guard Self.shouldNudgeBrain(
            hasTranscript: meeting.hasTranscript,
            destinationAutoSummarizes: destinationAutoSummarizes
        ) else { return }
        catchUp.nudge(context: context)
    }
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: the one-suite command with `MeetingListNudgeTests`.

Expected: 3 tests pass.

- [ ] **Step 5: Run the full unit suite**

Run: the full unit suite command.

Expected: `TEST SUCCEEDED`, 430 tests in 58 suites.

- [ ] **Step 6: Lint**

Run: the lint command.

Expected: 0 violations.

- [ ] **Step 7: Commit**

The subject names the extraction, because this commit changes production code as well as adding tests — `test:` alone would misdescribe it.

```bash
git add Minute/Views/MeetingListView.swift MinuteTests/MeetingListNudgeTests.swift
git commit -m "refactor: extract the save-time Brain nudge rule and pin its two skips

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 31: A no-op speaker rename stops re-queueing the whole meeting (A2, view + model half)

`MeetingDetailView.renameSpeaker` calls `MeetingJobs.applySpeakerName` unconditionally, and that write sets `meeting.knowledgeExtractedAt = nil` with no comparison — so opening Rename Speaker and tapping Save without typing re-queues the entire meeting for on-device re-extraction (a full LLM pass per chunk) and nudges the catch-up loop. `MeetingJobs.swift` belongs to another track, so the comparison lands where the caller can use it: a predicate on `Meeting` (owned), read by the view before it writes. `MeetingDetailView` is the only production caller of `applySpeakerName` (verified by grep), so the guard is complete; giving `applySpeakerName` itself a `Bool` return is Hand-off 2.

**Files:**
- Modify: `Minute/Models/Meeting.swift:82-123` (add to the existing `extension Meeting`, after `titleFallback`), `Minute/Views/MeetingDetailView.swift:704-709` (`renameSpeaker`)
- Create: `MinuteTests/SpeakerRenameGuardTests.swift`

**Interfaces:**
- Consumes: `MeetingJobs.applySpeakerName(_ name: String, at index: Int, to meeting: Meeting)` (`Minute/Services/MeetingJobs.swift:265`, `@MainActor`), `Meeting.speakerNames: [String]?` (`Meeting.swift:21`), `MeetingJobs.onContentChanged: (@MainActor () -> Void)?` (`MeetingJobs.swift:52`).
- Produces: `Meeting.speakerRenameChangesAnything(at index: Int, to name: String) -> Bool` — an instance method on the existing `extension Meeting`.

- [ ] **Step 1: Write the failing test**

Create `MinuteTests/SpeakerRenameGuardTests.swift`:

```swift
import Testing
@testable import Minute

/// A2: the rename write resets the extraction cursor, which re-queues the whole
/// meeting for on-device extraction — an LLM pass per chunk — and nudges the
/// catch-up loop. Opening Rename Speaker and tapping Save without typing must
/// not buy that, so the detail view asks first.
@MainActor
struct SpeakerRenameGuardTests {
    private func meeting() -> Meeting {
        let meeting = Meeting(title: "m")
        meeting.speakerNames = ["Priya", "Diego"]
        meeting.knowledgeExtractedAt = .now
        return meeting
    }

    @Test func aRenameToTheStoredNameChangesNothing() {
        let meeting = meeting()
        #expect(!meeting.speakerRenameChangesAnything(at: 1, to: "Diego"))
        // Trimmed the same way the write trims, or Save on an untouched field
        // whose text picked up a stray space would still cost a full pass.
        #expect(!meeting.speakerRenameChangesAnything(at: 1, to: "  Diego "))
    }

    @Test func aRenameToADifferentNameChanges() {
        let meeting = meeting()
        #expect(meeting.speakerRenameChangesAnything(at: 1, to: "Sarah Chen"))
        // Clearing a name is a change too: it sends the speaker back to
        // "Speaker 2" everywhere the transcript is read.
        #expect(meeting.speakerRenameChangesAnything(at: 1, to: ""))
    }

    /// An index the array does not reach yet — the common case, since
    /// `speakerNames` is nil until someone renames a speaker. Padding writes
    /// empty entries, so an empty name for an unnamed speaker is a no-op while
    /// a real name is not.
    @Test func anIndexWithNoEntryYetCountsAsTheEmptyName() {
        let meeting = Meeting(title: "m")
        #expect(meeting.speakerRenameChangesAnything(at: 2, to: "Mei"))
        #expect(!meeting.speakerRenameChangesAnything(at: 2, to: "   "))
        meeting.speakerNames = ["Priya"]
        #expect(!meeting.speakerRenameChangesAnything(at: 4, to: ""))
    }

    /// What the guard is actually protecting, spelled out: the unguarded write
    /// clears the cursor even when the name is identical.
    @Test func theUnguardedWriteIsWhatResetsTheExtractionCursor() {
        let meeting = meeting()

        MeetingJobs.applySpeakerName("  Diego ", at: 1, to: meeting)

        #expect(meeting.speakerNames == ["Priya", "Diego"])
        #expect(meeting.knowledgeExtractedAt == nil)
    }
}
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: the one-suite command with `SpeakerRenameGuardTests`.

Expected: the build fails — `value of type 'Meeting' has no member 'speakerRenameChangesAnything'`.

- [ ] **Step 3: Add the predicate to the model**

In `Minute/Models/Meeting.swift`, at the end of `extension Meeting` (after `titleFallback`'s closing brace and before the extension's own closing brace), add:

```swift

    /// Whether writing `name` as speaker `index`'s display name would actually
    /// change this meeting.
    ///
    /// Asked before the write because the write is expensive in a way the
    /// gesture does not suggest: `MeetingJobs.applySpeakerName` resets
    /// `knowledgeExtractedAt`, which re-queues the entire meeting for on-device
    /// extraction — one LLM pass per chunk — and nudges the catch-up loop. That
    /// is the right price for a real rename, because the Brain reads the
    /// transcript with names in it, and no price at all for opening the Rename
    /// Speaker alert and tapping Save without typing.
    ///
    /// Trimmed the same way the write trims before it stores, and an index the
    /// array does not reach yet counts as the empty name that its padding would
    /// have written there.
    func speakerRenameChangesAnything(at index: Int, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing: String
        if let names = speakerNames, names.indices.contains(index) {
            existing = names[index]
        } else {
            existing = ""
        }
        return trimmed != existing
    }
```

- [ ] **Step 4: Guard the view's write**

In `Minute/Views/MeetingDetailView.swift`, replace:

```swift
    private func renameSpeaker(_ index: Int, to name: String) {
        MeetingJobs.applySpeakerName(name, at: index, to: meeting)
        saveQuietly()
        // The rename changed the text the Brain reads; let it catch up.
        jobs.onContentChanged?()
    }
```

with:

```swift
    private func renameSpeaker(_ index: Int, to name: String) {
        // Save on an unchanged field is a gesture that changed nothing, and the
        // write below is not free: it resets the extraction cursor, so the
        // whole meeting would be re-read on device, a model pass per chunk.
        guard meeting.speakerRenameChangesAnything(at: index, to: name) else { return }
        MeetingJobs.applySpeakerName(name, at: index, to: meeting)
        saveQuietly()
        // The rename changed the text the Brain reads; let it catch up.
        jobs.onContentChanged?()
    }
```

- [ ] **Step 5: Run the suite to verify it passes**

Run: the one-suite command with `SpeakerRenameGuardTests`.

Expected: 4 tests pass.

- [ ] **Step 6: Run the full unit suite**

Run: the full unit suite command.

Expected: `TEST SUCCEEDED`, 434 tests in 59 suites. `SpeakerJobApplicationTests` is untouched: `applySpeakerName` still behaves exactly as it did.

- [ ] **Step 7: Lint**

Run: the lint command.

Expected: 0 violations.

- [ ] **Step 8: Commit**

```bash
git add Minute/Models/Meeting.swift Minute/Views/MeetingDetailView.swift MinuteTests/SpeakerRenameGuardTests.swift
git commit -m "fix: a rename to the same speaker name no longer re-queues the meeting for extraction

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 32: A failing Recordings step still stamps the store files (b2-T33-minor-2)

The scoped `do`/`catch` around the Recordings step exists precisely so a failure reaching the audio costs only the audio and still leaves the store files stamped — the other half of the F34/F35 fix — and nothing covers it. `dataProtectionKeepsGoingAfterOneTargetFails` throws from the injected applier, which exercises the per-target loop: a different branch. Collapsing the scoped `do`/`catch` back into the outer one would stay green. Test-only task; no production code changes.

**Files:**
- Test: `MinuteTests/MeetingStoreTests.swift` (add after `dataProtectionKeepsGoingAfterOneTargetFails`, line 347-367)
- Temporarily modified in Step 3 only, then reverted: `Minute/Services/MeetingStore.swift:213-216`

**Interfaces:**
- Consumes: `MeetingStore.applyDataProtection(base:appGroup:apply:) -> Bool` (`Minute/Services/MeetingStore.swift:171-180`), `MeetingStore.storeFileNames` (`:91`), `MeetingStore.dataProtectionClass` (`:108`).
- Produces: nothing.

- [ ] **Step 1: Write the test**

Add to `MinuteTests/MeetingStoreTests.swift`, inside `struct MeetingStoreTests`, after `dataProtectionKeepsGoingAfterOneTargetFails`:

```swift
    /// The other half of F34/F35, and the reason the Recordings step sits in a
    /// scope of its own: a failure reaching the audio — a stray file where the
    /// directory belongs, a full disk — must cost only the audio. The store
    /// files still get the class, because those are what the locked-phone reads
    /// need just as much. `dataProtectionKeepsGoingAfterOneTargetFails` throws
    /// from the applier, which is the per-target loop; this is the step before
    /// it, and collapsing its do/catch back into the outer one would stay green
    /// without this test.
    @Test func dataProtectionStillStampsTheStoreWhenTheRecordingsStepFails() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("protection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        // A regular file where the directory belongs. `createDirectory` with
        // `withIntermediateDirectories: true` tolerates an existing *directory*
        // and throws on this — the first statement of the scoped step.
        try Data("not a directory".utf8).write(to: base.appendingPathComponent("Recordings"))
        try Data("db".utf8).write(to: base.appendingPathComponent("default.store"))

        var applied: [String] = []
        let succeeded = MeetingStore.applyDataProtection(base: base, appGroup: nil) { url, _ in
            applied.append(url.lastPathComponent)
        }

        // Reported as a failure — the audio really did not get the class — and
        // the store files were stamped anyway.
        #expect(!succeeded)
        #expect(applied == [base.lastPathComponent, "default.store"])
    }
```

- [ ] **Step 2: Run the suite to verify it passes**

Run: the one-suite command with `MeetingStoreTests`.

Expected: all pass — this test pins behavior that already exists, so it is green as written. Steps 3 and 4 prove it is not vacuous.

- [ ] **Step 3: Prove the test fails when the scope is collapsed**

Temporarily, in `Minute/Services/MeetingStore.swift`, replace:

```swift
        } catch {
            logger.error("Reaching the recordings for the data protection pass failed: \(error.localizedDescription)")
            succeeded = false
        }
```

with:

```swift
        } catch {
            logger.error("Reaching the recordings for the data protection pass failed: \(error.localizedDescription)")
            return false
        }
```

That is exactly what folding this step back into the outer scope would do. Run: the one-suite command with `MeetingStoreTests`.

Expected: the new test fails with `Expectation failed: applied == [base.lastPathComponent, "default.store"]` — `applied` is empty, because the pass gave up before the target loop. No other test changes.

- [ ] **Step 4: Revert the temporary change**

```bash
git checkout -- Minute/Services/MeetingStore.swift
```

Run: the one-suite command with `MeetingStoreTests`.

Expected: all pass again, including the new test.

- [ ] **Step 5: Run the full unit suite**

Run: the full unit suite command.

Expected: `TEST SUCCEEDED`, 435 tests in 59 suites.

- [ ] **Step 6: Lint**

Run: the lint command.

Expected: 0 violations.

- [ ] **Step 7: Commit**

```bash
git add MinuteTests/MeetingStoreTests.swift
git commit -m "test: pin that a failing Recordings step still stamps the store files

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 33: The data-protection walk runs once per install, not every cold launch (B10)

`MinuteApp.init` calls `MeetingStore.applyDataProtection()` unconditionally, and the pass does a synchronous `createDirectory` + `contentsOfDirectory` + one `setAttributes` per recording, on the main thread, at every cold launch — forever, long after every file already carries the right class. Per the recorded decision it becomes one-shot per install per class: a marker holding the applied class name, written only after a fully successful pass, and consulted before the walk. A failed pass leaves the marker unset, so the next launch retries — which is also the first real reader the `@discardableResult` Bool has ever had (`MinuteApp` discards it, so a transient refusal used to be log-only).

**Files:**
- Modify: `Minute/Support/AppSettings.swift:33` (add the key after `persistentStoreFailureKey`), `Minute/Support/AppSettings.swift:58-67` (add the accessor after `persistentStoreFailure`)
- Modify: `Minute/Services/MeetingStore.swift:116-193` (the `applyDataProtection` doc comment and the top of its body), `Minute/Services/MeetingStore.swift:255-263` (the tail of its body)
- Test: `MinuteTests/MeetingStoreTests.swift` (add after `dataProtectionStillStampsTheStoreWhenTheRecordingsStepFails`, added in Task 32)

**Interfaces:**
- Consumes: `MeetingStore.dataProtectionClass: FileProtectionType` (`MeetingStore.swift:108`; `FileProtectionType.rawValue` is a `String`), `MeetingStore.applyDataProtection(base:appGroup:apply:) -> Bool` (`:171-180`), the `AppSettings` key/accessor pattern of `persistentStoreFailureKey` / `persistentStoreFailure`.
- Produces: `AppSettings.dataProtectionClassKey: String` (`"storage.dataProtectionClass"`), `AppSettings.appliedDataProtectionClass: String?`. `applyDataProtection` keeps its exact signature; `MinuteApp.swift:67` is unchanged.

**On test isolation:** both new tests live in `@MainActor struct MeetingStoreTests` with synchronous bodies, so they cannot interleave with each other, and `storage.dataProtectionClass` is touched by no other suite (grep: `dataProtectionClassKey` appears only in `AppSettings.swift`, `MeetingStore.swift` and this file). No `.serialized` attribute is needed here — unlike Task 34, where two suites would have shared a key.

- [ ] **Step 1: Write the failing tests**

Add to `MinuteTests/MeetingStoreTests.swift`, inside `struct MeetingStoreTests`, after `dataProtectionStillStampsTheStoreWhenTheRecordingsStepFails`:

```swift
    /// B10: the pass walked every recording in the library, one `setAttributes`
    /// per file, on the main thread, at every cold launch — forever, long after
    /// every file already carried the right class. Once a full pass has
    /// succeeded, new files inherit the class from the directories it stamped,
    /// so there is nothing left for the walk to do: the marker turns it into a
    /// one-shot per install per class.
    ///
    /// Driven against the app's own tree (`base: nil`) because that is the only
    /// pass the marker describes — a caller that injects `base` is stamping
    /// some other directory, which says nothing about this install. The nine
    /// injected-base tests above are what pin that they still run in full: the
    /// test host's own launch sets this marker before any of them run.
    @Test func dataProtectionWalksOncePerInstallAndThenSkipsTheWalk() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: AppSettings.dataProtectionClassKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: AppSettings.dataProtectionClassKey)
            } else {
                defaults.removeObject(forKey: AppSettings.dataProtectionClassKey)
            }
        }
        AppSettings.appliedDataProtectionClass = nil

        var firstPass: [String] = []
        let firstSucceeded = MeetingStore.applyDataProtection(base: nil, appGroup: nil) { url, _ in
            firstPass.append(url.lastPathComponent)
        }

        #expect(firstSucceeded)
        // The Application Support root at least; whatever else this install
        // holds rides along.
        #expect(!firstPass.isEmpty)
        #expect(AppSettings.appliedDataProtectionClass == MeetingStore.dataProtectionClass.rawValue)

        var secondPass: [String] = []
        let secondSucceeded = MeetingStore.applyDataProtection(base: nil, appGroup: nil) { url, _ in
            secondPass.append(url.lastPathComponent)
        }

        // Not one target, and — the point of the fix — not one listing of the
        // Recordings directory either.
        #expect(secondSucceeded)
        #expect(secondPass.isEmpty)
    }

    /// A pass that could not finish must not be remembered as one that did, or
    /// a transient refusal at one launch would leave the files unstamped for
    /// the life of the install. This is also the first reader the pass's
    /// `Bool` has ever had: `MinuteApp` discards it.
    @Test func aFailedDataProtectionPassLeavesTheMarkerUnsetSoTheNextLaunchRetries() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: AppSettings.dataProtectionClassKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: AppSettings.dataProtectionClassKey)
            } else {
                defaults.removeObject(forKey: AppSettings.dataProtectionClassKey)
            }
        }
        AppSettings.appliedDataProtectionClass = nil

        let succeeded = MeetingStore.applyDataProtection(base: nil, appGroup: nil) { _, _ in
            throw CocoaError(.fileWriteNoPermission)
        }

        #expect(!succeeded)
        #expect(AppSettings.appliedDataProtectionClass == nil)
    }
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: the one-suite command with `MeetingStoreTests`.

Expected: the build fails — `type 'AppSettings' has no member 'dataProtectionClassKey'`.

- [ ] **Step 3: Add the marker to AppSettings**

In `Minute/Support/AppSettings.swift`, replace:

```swift
    static let persistentStoreFailureKey = "storage.persistentStoreFailure"
```

with:

```swift
    static let persistentStoreFailureKey = "storage.persistentStoreFailure"
    /// The data protection class the last fully successful pass stamped on this
    /// install's files, or absent when no pass has finished one. Holds the
    /// class name rather than a Bool so that changing
    /// `MeetingStore.dataProtectionClass` re-runs the pass by itself.
    static let dataProtectionClassKey = "storage.dataProtectionClass"
```

Then, in the same file, replace:

```swift
    /// Encoder quality applied to new recordings.
    static var audioQuality: AudioQuality {
```

with:

```swift
    /// The data protection class already applied to this install's files — see
    /// `MeetingStore.applyDataProtection`, which is the only writer. Absent
    /// until a pass has fully succeeded, so a failed one is retried at the next
    /// launch.
    static var appliedDataProtectionClass: String? {
        get { UserDefaults.standard.string(forKey: dataProtectionClassKey) }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: dataProtectionClassKey)
            } else {
                UserDefaults.standard.removeObject(forKey: dataProtectionClassKey)
            }
        }
    }

    /// Encoder quality applied to new recordings.
    static var audioQuality: AudioQuality {
```

- [ ] **Step 4: Skip the walk once it has succeeded**

In `Minute/Services/MeetingStore.swift`, replace:

```swift
    /// `apply` is injected so tests can assert what gets which class: the
    /// simulator accepts `.protectionKey` and then reports it back as nil, so
    /// reading the attribute afterwards would assert nothing.
    @discardableResult
    static func applyDataProtection(
        base: URL? = nil,
        appGroup: URL? = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: WidgetConstants.appGroupIdentifier
        ),
        apply: (URL, FileProtectionType) throws -> Void = { url, protection in
            try FileManager.default.setAttributes([.protectionKey: protection], ofItemAtPath: url.path)
        }
    ) -> Bool {
        let root: URL
```

with:

```swift
    /// `apply` is injected so tests can assert what gets which class: the
    /// simulator accepts `.protectionKey` and then reports it back as nil, so
    /// reading the attribute afterwards would assert nothing.
    ///
    /// One-shot per install per class. Everything above is a walk of the whole
    /// recording library — a `contentsOfDirectory` plus one `setAttributes` per
    /// file — on the main thread of the launch path, and it is worth exactly
    /// once: afterwards every one of those files carries the class, and new
    /// ones inherit it from the directories this stamped. So a fully successful
    /// pass records the class it applied and the next launch returns
    /// immediately. A pass that failed anywhere records nothing, which is what
    /// makes the next launch retry — and the first use the returned `Bool` has
    /// ever had, since `MinuteApp` discards it. Changing
    /// `dataProtectionClass` changes the recorded value, so the walk runs again
    /// for the new class without anyone remembering to reset anything, and
    /// `resetPersistentStore` needs no reset either: what it removes is
    /// recreated inside a root that already carries the class.
    ///
    /// The marker describes the install's own tree, so it is read and written
    /// only for a pass over that tree. A caller that injects `base` is stamping
    /// some other directory, and what happened there says nothing about whether
    /// this install still needs the walk.
    ///
    /// Two residuals the marker freezes, both accepted. The class-B files a
    /// pass could not reach are one — that is what the failure path and its
    /// retry are for. The other is the App Group half: a pass that ran with
    /// `appGroup` nil (the entitlement not in force) still records success for
    /// a tree that never contained the group container, so a later launch where
    /// the container *is* available skips the walk and leaves the group root,
    /// its Library/Preferences and the widget snapshot plist unstamped. What
    /// sits there is the widget's snapshot, not meeting audio or the database,
    /// and reaching that state takes a provisioning change between two launches
    /// of the same install. Encoding the group's coverage into the marker is
    /// the fix if that ever stops being true.
    @discardableResult
    static func applyDataProtection(
        base: URL? = nil,
        appGroup: URL? = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: WidgetConstants.appGroupIdentifier
        ),
        apply: (URL, FileProtectionType) throws -> Void = { url, protection in
            try FileManager.default.setAttributes([.protectionKey: protection], ofItemAtPath: url.path)
        }
    ) -> Bool {
        let describesTheInstall = base == nil
        if describesTheInstall, AppSettings.appliedDataProtectionClass == dataProtectionClass.rawValue {
            return true
        }
        let root: URL
```

- [ ] **Step 5: Record the class after a fully successful pass**

In the same function, replace (this is the loop that calls `apply`; the other `for url in targets` in this file, inside `resetPersistentStore`, calls `removeItem`):

```swift
        for url in targets {
            do {
                try apply(url, dataProtectionClass)
            } catch {
                logger.error("Pinning the data protection class on \(url.lastPathComponent) failed: \(error.localizedDescription)")
                succeeded = false
            }
        }
        return succeeded
    }
```

with:

```swift
        for url in targets {
            do {
                try apply(url, dataProtectionClass)
            } catch {
                logger.error("Pinning the data protection class on \(url.lastPathComponent) failed: \(error.localizedDescription)")
                succeeded = false
            }
        }
        // Only on a clean sweep: a partial one leaves files this pass believed
        // it had covered, and the marker is what would stop anybody looking
        // again.
        if describesTheInstall, succeeded {
            AppSettings.appliedDataProtectionClass = dataProtectionClass.rawValue
        }
        return succeeded
    }
```

- [ ] **Step 6: Run the suite to verify it passes**

Run: the one-suite command with `MeetingStoreTests`.

Expected: all pass — the two new tests plus the nine data-protection tests that inject a `base` (the eight at HEAD plus Task 32's), which are themselves the proof that an injected base ignores the marker: the test host's own launch sets it before any test runs.

- [ ] **Step 7: Run the full unit suite**

Run: the full unit suite command.

Expected: `TEST SUCCEEDED`, 437 tests in 59 suites.

- [ ] **Step 8: Lint**

Run: the lint command.

Expected: 0 violations.

- [ ] **Step 9: Commit**

```bash
git add Minute/Support/AppSettings.swift Minute/Services/MeetingStore.swift MinuteTests/MeetingStoreTests.swift
git commit -m "fix: walk the recordings for data protection once per install, not at every launch

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 34: The launch's store-failure capture becomes testable (b2-T35-minor-1)

`AppSettingsStorageFailureTests` covers only the `AppSettings` accessor round-trip; the two behaviors its doc comment claims — the failure captured when the persistent container will not open, and cleared on a healthy launch — live inside an `@main` App initializer no test can drive. A refactor that moves the write above the success case, or drops the unconditional write, would silently leave a destructive reset button on screen in a perfectly healthy app. The resolution moves into `MeetingStore` with both container constructors injected.

Two shapes here are forced and must not be "simplified" back:

- The resolver returns a **named struct**, not a tuple. A `(container:failure:isEphemeral:)` tuple has three members and SwiftLint's `large_tuple` rule (default threshold 2) rejects it — verified against the installed swiftlint 0.65.1 on this exact signature: `Tuples should have at most 2 members (large_tuple)`, an `::error` under `--strict`. `isEphemeral` is a computed property rather than a stored one, because it is exactly `failure != nil` on both paths; every `resolved.container` / `resolved.failure` / `resolved.isEphemeral` access reads identically either way.
- The two new tests go **inside the existing `AppSettingsStorageFailureTests` struct**, which becomes `@Suite(.serialized) @MainActor`. Both they and the existing test write and assert `AppSettings.persistentStoreFailure` (UserDefaults key `storage.persistentStoreFailure`); Swift Testing runs separate suites in parallel — this repo has no `.xctestplan` and no parallelization override, and `MeetingStoreTests.swift:70-76` records a prior flake from parallel scheduling — so a second suite on that key would let one test's write land between the other's `= nil` and its `#expect(… == nil)`. `SummarizationEngineSettingsTests.swift:9` and `TranscriptionEngineSettingsTests.swift:11` are the repo's precedent for serializing a defaults-mutating suite. This is why the suite count stays at 59.

**Files:**
- Modify: `Minute/Services/MeetingStore.swift:270-272` (add `ResolvedContainer` and `resolveContainer` before `modelConfiguration`), `Minute/App/MinuteApp.swift:21-54` (call it)
- Test: `MinuteTests/AppSettingsStorageFailureTests.swift` (add `import SwiftData`, make the existing suite serialized and `@MainActor`, add two tests and their helpers inside it)

**Interfaces:**
- Consumes: `MeetingStore.modelConfiguration(inMemory:) -> ModelConfiguration` (`MeetingStore.swift:270`), `AppSettings.persistentStoreFailure: String?` (`Minute/Support/AppSettings.swift:58`), `ModelContainer` (`public class ModelContainer` in SwiftData, so tests compare with `===`).
- Produces: `MeetingStore.ResolvedContainer` (`let container: ModelContainer`, `let failure: String?`, `var isEphemeral: Bool { failure != nil }`) and `MeetingStore.resolveContainer(makePersistent: () throws -> ModelContainer, makeInMemory: () throws -> ModelContainer) -> ResolvedContainer`.

- [ ] **Step 1: Write the failing test**

In `MinuteTests/AppSettingsStorageFailureTests.swift`, replace the imports, doc comment and struct declaration:

```swift
import Foundation
import Testing
@testable import Minute

/// F68: the persistent container's error was discarded by `try?`, so a
/// migration failure that strands the store at every launch was invisible and
/// undiagnosable. It is recorded here, and Settings is the only place the user
/// can act on it.
struct AppSettingsStorageFailureTests {
```

with:

```swift
import Foundation
import SwiftData
import Testing
@testable import Minute

/// F68: the persistent container's error was discarded by `try?`, so a
/// migration failure that strands the store at every launch was invisible and
/// undiagnosable. It is recorded here, and Settings is the only place the user
/// can act on it.
///
/// Serialized, and one suite rather than two: every test below writes and then
/// asserts the single `storage.persistentStoreFailure` key, and Swift Testing
/// runs separate suites in parallel — a second suite on this key would let one
/// test's write land between another's `= nil` and its `#expect(… == nil)`,
/// which is the flake `MeetingStoreTests` already records once. `@MainActor`
/// for the SwiftData containers the launch-resolution tests build.
@Suite(.serialized)
@MainActor
struct AppSettingsStorageFailureTests {
```

Then add inside that struct, after the closing brace of `persistentStoreFailureRoundTripsAndClearsOnASuccessfulLaunch` and before the struct's own closing brace:

```swift

    /// The launch half of F68, which lived inside `MinuteApp.init` — `@main`
    /// scaffolding no test can drive. Both behaviors below are one assignment
    /// each and both are silent when wrong: a failure that is not recorded is a
    /// store stranded with no explanation and no reset, and a failure that is
    /// not cleared is a destructive reset button offered in a healthy app.
    ///
    /// A context does not keep its container alive; letting one go traps on the
    /// next insert. Held for the process, as the other SwiftData suites do.
    private static var retainedContainers: [ModelContainer] = []

    private func makeContainer() throws -> ModelContainer {
        let container = try ModelContainer(
            for: Meeting.self,
            configurations: MeetingStore.modelConfiguration(inMemory: true)
        )
        Self.retainedContainers.append(container)
        return container
    }

    /// The error a lightweight migration that cannot run reports — the case
    /// `KnowledgeFact` documents, and the one that strands a store identically
    /// at every launch.
    private struct StoreUnavailable: LocalizedError {
        var errorDescription: String? { "The model configuration is incompatible with the store." }
    }

    private func withRestoredFailureKey(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: AppSettings.persistentStoreFailureKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: AppSettings.persistentStoreFailureKey)
            } else {
                defaults.removeObject(forKey: AppSettings.persistentStoreFailureKey)
            }
        }
        try body()
    }

    @Test func aHealthyLaunchKeepsThePersistentStoreAndRetiresTheOldMessage() throws {
        try withRestoredFailureKey {
            AppSettings.persistentStoreFailure = "A failure recorded at the previous launch."
            let persistent = try makeContainer()
            var madeInMemory = false

            let resolved = MeetingStore.resolveContainer(
                makePersistent: { persistent },
                makeInMemory: {
                    madeInMemory = true
                    return try makeContainer()
                }
            )
            // What MinuteApp.init does with the answer, and the half that is
            // easiest to lose in a refactor.
            AppSettings.persistentStoreFailure = resolved.failure

            #expect(resolved.container === persistent)
            #expect(!resolved.isEphemeral)
            #expect(resolved.failure == nil)
            // The fallback container is never even built on this path.
            #expect(!madeInMemory)
            // Written on every launch, success included, so a store that
            // recovered stops offering the destructive reset.
            #expect(AppSettings.persistentStoreFailure == nil)
        }
    }

    @Test func aStoreThatWillNotOpenFallsBackToMemoryAndRecordsWhy() throws {
        try withRestoredFailureKey {
            AppSettings.persistentStoreFailure = nil
            let inMemory = try makeContainer()

            let resolved = MeetingStore.resolveContainer(
                makePersistent: { throw StoreUnavailable() },
                makeInMemory: { inMemory }
            )
            AppSettings.persistentStoreFailure = resolved.failure

            #expect(resolved.container === inMemory)
            // Drives the session-only recordings directory and the warning
            // banner the whole app shows.
            #expect(resolved.isEphemeral)
            #expect(resolved.failure == "The model configuration is incompatible with the store.")
            // Recorded, not swallowed: Settings is the only place the user can
            // see this or act on it.
            #expect(AppSettings.persistentStoreFailure == "The model configuration is incompatible with the store.")
        }
    }
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: the one-suite command with `AppSettingsStorageFailureTests`.

Expected: the build fails — `type 'MeetingStore' has no member 'resolveContainer'`.

- [ ] **Step 3: Add the resolver to MeetingStore**

In `Minute/Services/MeetingStore.swift`, find:

```swift
    /// A local-only SwiftData configuration. The iCloud Documents
```

and insert immediately above it:

```swift
    /// The container the app runs on, plus what the launch has to record about
    /// how it got there. A named type rather than a tuple because a three-member
    /// tuple is a `large_tuple` lint error, and `isEphemeral` is computed
    /// because it is exactly "the persistent store did not open" — one fact, one
    /// place.
    struct ResolvedContainer {
        let container: ModelContainer
        /// The persistent store's error when it would not open, else nil.
        let failure: String?
        /// Whether meetings now live only in memory: drives the session-only
        /// recordings directory and the warning banner the whole app shows.
        var isEphemeral: Bool { failure != nil }
    }

    /// Opens the app's container, falling back to a session-only one when the
    /// persistent store will not open.
    ///
    /// Extracted from `MinuteApp.init` because that initializer is `@main`
    /// scaffolding no test can drive, and both of its outcomes are load-bearing
    /// and silent when wrong. The error is recorded, not swallowed: this is the
    /// one failure the user can neither see nor act on, the same open is
    /// retried identically at every launch, and so a deterministic cause (a
    /// lightweight migration that cannot run, the case `KnowledgeFact`
    /// documents) strands the store and every recording forever unless Settings
    /// can say what went wrong and offer the reset. And a launch that succeeds
    /// has to clear it again, or a store that recovered keeps a destructive
    /// reset button on screen.
    ///
    /// Both constructors are injected so a test can drive either branch; the
    /// app passes the real `ModelContainer` initializers.
    static func resolveContainer(
        makePersistent: () throws -> ModelContainer,
        makeInMemory: () throws -> ModelContainer
    ) -> ResolvedContainer {
        do {
            return ResolvedContainer(container: try makePersistent(), failure: nil)
        } catch {
            // ponytail: corrupt store falls back to a session-only container so
            // recording still works; the list view shows a warning banner.
            guard let inMemory = try? makeInMemory() else {
                fatalError("Unable to create a SwiftData container")
            }
            return ResolvedContainer(container: inMemory, failure: error.localizedDescription)
        }
    }

```

- [ ] **Step 4: Call it from the launch**

In `Minute/App/MinuteApp.swift`, replace:

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
```

with:

```swift
    init() {
        // The resolution itself lives in MeetingStore so both of its outcomes
        // can be driven from a test — this initializer is @main scaffolding no
        // test can reach, and what happens to the failure here is the whole of
        // the user's ability to see a stranded store and act on it.
        let resolved = MeetingStore.resolveContainer(
            makePersistent: {
                try ModelContainer(
                    for: Meeting.self, KnowledgeEntity.self, KnowledgeFact.self,
                    configurations: MeetingStore.modelConfiguration()
                )
            },
            makeInMemory: {
                try ModelContainer(
                    for: Meeting.self, KnowledgeEntity.self, KnowledgeFact.self,
                    configurations: MeetingStore.modelConfiguration(inMemory: true)
                )
            }
        )
        container = resolved.container
        storeIsEphemeral = resolved.isEphemeral
        // Written on every launch, success included, so a store that recovers
        // retires the message and the reset button with it.
        AppSettings.persistentStoreFailure = resolved.failure
```

- [ ] **Step 5: Run the suite to verify it passes**

Run: the one-suite command with `AppSettingsStorageFailureTests`.

Expected: 3 tests pass — the pre-existing accessor round-trip plus the two new ones.

- [ ] **Step 6: Run the full unit suite**

Run: the full unit suite command.

Expected: `TEST SUCCEEDED`, 439 tests in 59 suites — two more tests than Task 33 left, and no new suite, because the new tests joined `AppSettingsStorageFailureTests`. The test host itself launches through the new code, so a failure here would also show up as the app failing to start.

- [ ] **Step 7: Lint**

Run: the lint command.

Expected: 0 violations. Two rules are in play and both are satisfied by the shapes above: `large_tuple` (avoided by returning `ResolvedContainer` instead of a three-member tuple) and `multiple_closures_with_trailing_closure` (both `makePersistent` and `makeInMemory` are labeled arguments at every call site, and nothing trails).

- [ ] **Step 8: Commit**

```bash
git add Minute/Services/MeetingStore.swift Minute/App/MinuteApp.swift MinuteTests/AppSettingsStorageFailureTests.swift
git commit -m "refactor: make the launch's store-failure capture testable

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Hand-offs to Track E

One-line wirings in files this track does not own.

1. `Minute/Services/MeetingJobs.swift:292`, in `applySuggestedTitleIfDefault` — replace `let baseline = meeting.defaultTitle ?? RecordingSession.defaultTitle(for: meeting.createdAt)` with `let baseline = meeting.titleFallback` (B9, second half). That expression is verbatim `Meeting.titleFallback` (`Minute/Models/Meeting.swift:121-123`): two copies of the "is this still the default title" rule that must not drift, and the model's copy is the one `MeetingDetailView.commitTitle` already uses. No behavior change.
2. Optional, `Minute/Services/MeetingJobs.swift:265-273` — give `applySpeakerName` a `@discardableResult -> Bool` return that is `false` when nothing changed, computed with `meeting.speakerRenameChangesAnything(at:to:)` (Task 31), so the guard travels with the write rather than with its caller. Not required: `MeetingDetailView.renameSpeaker` is the only production caller (grep: `applySpeakerName` appears in that one view, in `MeetingJobs` itself, and in `MinuteTests/SpeakerAssignmentTests.swift`), and Task 31 guards it there. If Track E does take this, `MinuteTests/SpeakerAssignmentTests.swift` is the place for the "a rename to the identical name leaves `knowledgeExtractedAt` non-nil" case the triage named — `SpeakerRenameGuardTests` already pins the predicate and the unguarded write's cost.

### Not done in this track

- **B9's `MeetingJobs` half and A2's `applySpeakerName` signature** — both are Hand-off 1 and 2 above; the files belong to another track, and each task closes its owned side completely (the focus handler moves; the no-op rename is blocked before the write).
- **The same single-transaction sheet swap for the file importer.** `dismissPresentedSheets()` also clears `showingImporter`, so a New Meeting deep link arriving while the document picker is up hits the shape B6 describes. The recorded decision names Settings, and reaching that state means the user is inside the Files UI when the widget button is pressed; `.fileImporter` has no `onDismiss` hook to hang the same fix on, so it would need its own presentation flag. Left alone deliberately.
- **A unit test for the four view-only tasks (25, 26, 27, 28).** `@FocusState`, sheet lifecycle, `@State` drafts and view bodies are not reachable from the test target, and an assertion-free test would be worse than none; each is verified by the build, the full unit suite and lint. `Meeting.titleCommit` (Task 27's actual write rule) and `MeetingDeepLinkState.action` (Task 28's arbitration) are already covered by `MeetingTitleTests` and `MeetingDeepLinkStateTests`.
- **Encoding the App Group's coverage into Task 33's marker.** A first successful pass that ran without the App Group entitlement in force records success for a tree that never included the group container, and a later launch where the container is available skips the walk. Named in `applyDataProtection`'s doc comment as an accepted residual rather than fixed: the recorded decision is a marker holding the class name, and what stays unstamped is the widget snapshot, not meeting audio or the database.
- **E1 and E3** (deferred by triage as product decisions) and **E2/E4** (skipped): nothing in this track's file set implements them.

---

## Track J — Knowledge, jobs, backup, docs, test hygiene

Findings closed here: BR3, B9, A3, F-2, F-5, F-4, F-7, D3, A1, B14.

**Files this track owns** (a task must not edit anything else):
`Minute/Services/KnowledgeCatchUp.swift`, `Minute/Services/KnowledgeIngest.swift`,
`Minute/Services/KnowledgeStore.swift`, `Minute/Services/KnowledgeExtractionService.swift`,
`Minute/Services/KnowledgeSynthesisService.swift`, `Minute/Services/KnowledgeMigration.swift`,
`Minute/Support/KnowledgeText.swift`, `Minute/Support/KnowledgeBrief.swift`,
`Minute/Views/BrainView.swift`, `Minute/Services/MeetingJobs.swift`,
`Minute/Services/DiarizationService.swift`, `Minute/Support/SpeakerAssignment.swift`,
`Minute/Services/ICloudDriveBackup.swift`, a new `Minute/Support/BackgroundTaskToken.swift`,
`README.md`, `CONTRIBUTING.md`, `docs/**`, plus `MinuteTests/Knowledge*Tests.swift`,
`MinuteTests/BrainSectionsTests.swift`, `MinuteTests/ICloudDriveBackupTests.swift`,
`MinuteTests/SummaryGenerationTests.swift`, `MinuteTests/SpeakerAssignmentTests.swift`,
`MinuteTests/NotesExporterTests.swift`, and new test files for these types.

### Global Constraints

- Privacy invariants from CONTRIBUTING.md hold: no meeting content on the wire; every byte written has a delete path; AI output stays grounded ("Not specified" literal); recording never depends on optional capabilities and any handled failure still offers to save captured audio.
- No new third-party dependencies. Do not edit Minute.xcodeproj/project.pbxproj (new files under Minute/, MinuteTests/, Shared/, MinuteWidgets/ are picked up automatically).
- Unit tests use Swift Testing, never XCTest. SwiftData-touching test structs are @MainActor with an in-memory container via MeetingStore.modelConfiguration(inMemory: true); containers holding KnowledgeEntity/KnowledgeFact are retained for the process lifetime (retainedContainers pattern in MinuteTests/KnowledgeCatchUpTests.swift). Suite-level -only-testing selectors only (a single-test selector silently selects nothing).
- Swift 5 language mode: an actor-isolated expression cannot be a default argument (use the nil-defaulted injection pattern).
- Baseline at the branch point (main b481626): 424 tests in 57 suites pass; swiftlint --strict reports 0 violations. Every task leaves both true plus its own new tests.
- swiftlint 0.65.1 IS installed locally: run `swiftlint --strict --reporter github-actions-logging` from the repo root before every commit; live rules include multiple_closures_with_trailing_closure and redundant_void_return; line_length, function/type/file length, cyclomatic_complexity, identifier_name, todo, redundant_optional_initialization, trailing_comma, for_where are disabled.
- Commit messages: Conventional Commits (fix:/test:/docs:/refactor:), ending with the trailer line "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>". Explicit paths; never git add -A; never commit anything under .superpowers/.
- A task edits only files its track owns; cross-track needs go in "Hand-offs to Track E".
- After a committed delete a SwiftData object has isDeleted == false and modelContext == nil; guard stale reads with isGone.

**Test commands** (run from the worktree root `/Users/feihou/workplace/minute/.claude/worktrees/app-code-review-e76404`; this track uses simulator "iPhone Air"):

One suite while iterating:
```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:MinuteTests/<SuiteName> CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔ Test run|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Full unit suite, once before each commit:
```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```
Lint, before each commit:
```bash
swiftlint --strict --reporter github-actions-logging 2>&1 | grep -E "^::(error|warning)|Done linting"
```

**Line numbers** in this section are as of commit `b481626` and shift as earlier tasks in this track land. Every replacement quotes the exact current text; **the quoted old snippet is the authoritative anchor** — find it, don't count lines.

**Test counts** below are this track's own worktree, branched at `b481626` (424 tests, 57 suites). No task adds a test suite, so the suite count stays 57; a merge from another track shifts the absolute test number, and the per-task deltas are what matters.

---

### Task 39: Move BackgroundTaskToken into its own file (BR3)

**Files:**
- Create: `Minute/Support/BackgroundTaskToken.swift`
- Modify: `Minute/Services/ICloudDriveBackup.swift:1123-1149` (the trailing blank line and the `BackgroundTaskToken` declaration; the file is 1149 lines long, so this is its tail)
- Test: none — a verbatim type move with no behavior change cannot be unit-tested beyond what the existing suite already covers; verified by build + full suite + lint.

**Interfaces:**
- Consumes: nothing new. `UIApplication.shared.beginBackgroundTask(withName:expirationHandler:)`, `UIApplication.shared.endBackgroundTask(_:)`, `UIBackgroundTaskIdentifier.invalid`.
- Produces: `BackgroundTaskToken` unchanged and still internal to the module — `@MainActor final class BackgroundTaskToken`, `init(name: String, expirationHandler: @escaping @MainActor @Sendable () -> Void = {})`, `func end()`. Its five callers (`Minute/Recording/RecordingSession.swift`, `Minute/Services/MeetingJobs.swift`, `Minute/Services/MLXDownloadCenter.swift`, `Minute/Services/WhisperDownloadCenter.swift`, `Minute/Services/ICloudDriveBackup.swift` itself) need no edit.

- [ ] **Step 1: Create the new file**

Create `Minute/Support/BackgroundTaskToken.swift` with exactly this content (the doc comment is the one moved verbatim; `import UIKit` is the only addition):

```swift
import UIKit

/// Keeps the app awake long enough to finish background work (mirroring,
/// summary generation). iOS suspends a backgrounded app within seconds
/// otherwise.
@MainActor
final class BackgroundTaskToken {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init(
        name: String,
        expirationHandler: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        // The expiration handler is documented to run on the main thread.
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated {
                expirationHandler()
                self?.end()
            }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
```

- [ ] **Step 2: Verify the duplicate declaration breaks the build**

The tree is knowingly red at this point — the type is declared twice, and Step 3 removes the old copy. Run the build anyway, because the error it produces is the only cheap proof of two things at once:

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:MinuteTests/ICloudDriveBackupTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔ Test run|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `error: invalid redeclaration of 'BackgroundTaskToken'`. That the new file compiled at all is proof it reached the target without any project.pbxproj edit (the Xcode project uses `fileSystemSynchronizedGroups`); that the redeclaration is a *pair* is proof exactly one other declaration exists — the one in `ICloudDriveBackup.swift` that Step 3 deletes — which is the hand-off's concern about a second copy surviving a merge, checked here for free.

- [ ] **Step 3: Delete the type from ICloudDriveBackup.swift**

In `Minute/Services/ICloudDriveBackup.swift`, delete the blank line 1123 and everything after it. The file currently ends with:

```swift
    /// Returns the task so callers that need a graceful stop can await it.
    @discardableResult
    func cancel() -> Task<Void, Never>? {
        task?.cancel()
        token?.end()
        return task
    }
}

/// Keeps the app awake long enough to finish background work (mirroring,
/// summary generation). iOS suspends a backgrounded app within seconds
/// otherwise.
@MainActor
final class BackgroundTaskToken {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init(
        name: String,
        expirationHandler: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        // The expiration handler is documented to run on the main thread.
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated {
                expirationHandler()
                self?.end()
            }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
```

and must end with:

```swift
    /// Returns the task so callers that need a graceful stop can await it.
    @discardableResult
    func cancel() -> Task<Void, Never>? {
        task?.cancel()
        token?.end()
        return task
    }
}
```

`BackgroundMirrorTask` stays where it is. Keep `import UIKit` at the top of `ICloudDriveBackup.swift`: `UIDevice.current` is still used twice (lines 242 and 253).

- [ ] **Step 4: Run the full unit suite**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 424 tests.

- [ ] **Step 5: Lint**

```bash
swiftlint --strict --reporter github-actions-logging 2>&1 | grep -E "^::(error|warning)|Done linting"
```
Expected: `Done linting!` with no `::error` or `::warning` lines.

- [ ] **Step 6: Commit**

```bash
git add Minute/Support/BackgroundTaskToken.swift Minute/Services/ICloudDriveBackup.swift
git commit -m "$(cat <<'EOF'
refactor: move BackgroundTaskToken out of ICloudDriveBackup

It is a general UIKit lifecycle helper — RecordingSession, MeetingJobs and
both download centers use it — but it was declared at the bottom of
ICloudDriveBackup.swift, filed under iCloud backup where nobody looking for
it would search. Moved verbatim, doc comment included, to
Minute/Support/BackgroundTaskToken.swift. BackgroundMirrorTask stays with
the backup it belongs to. No behavior change, no caller edits.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 40: MeetingJobs asks the model what the auto-generated title is (B9)

**Files:**
- Modify: `Minute/Services/MeetingJobs.swift:285-295` (the doc comment and body of `applySuggestedTitleIfDefault`; `:296` is the type's own closing brace)
- Test: none — `applySuggestedTitleIfDefault` is private and reached only through `summarize`, which has no injectable summarization engine (`Minute/Services/MeetingJobs.swift:114-137` calls `SummarizationEngines.current(language:)` directly), so this one-line de-duplication cannot be unit-tested without widening that seam; verified by build + full suite + lint.

**Interfaces:**
- Consumes: `Meeting.titleFallback: String` (`Minute/Models/Meeting.swift:121-123`, `defaultTitle ?? RecordingSession.defaultTitle(for: createdAt)`), `MeetingSummary.suggestedTitle: String?`.
- Produces: nothing new. `RecordingSession` stops being referenced from `MeetingJobs.swift` (it was referenced only on the line this task removes); no import changes, both types are in the same module.

- [ ] **Step 1: Replace the re-derived baseline with the model's own property**

In `Minute/Services/MeetingJobs.swift`, replace:

```swift
    /// Adopts the model's title only while the meeting still carries the
    /// default "Meeting <date>" name — never over a user-chosen title. The
    /// stored default is authoritative; re-deriving it is only a fallback for
    /// meetings saved before the default was persisted, and can miss when the
    /// locale or time zone changed since then.
    private func applySuggestedTitleIfDefault(_ summary: MeetingSummary, to meeting: Meeting) {
        guard let suggested = summary.suggestedTitle else { return }
        let baseline = meeting.defaultTitle ?? RecordingSession.defaultTitle(for: meeting.createdAt)
        guard meeting.title == baseline else { return }
        meeting.title = suggested
    }
```

with:

```swift
    /// Adopts the model's title only while the meeting still carries the
    /// auto-generated name — never over a user-chosen title.
    ///
    /// What counts as that name is `Meeting.titleFallback`, the same property
    /// the title editor reverts an emptied field to. Deciding it a second time
    /// here is how the two drift: a change to the fallback rule — locale,
    /// format, a stored column — would fix the editor and silently stop every
    /// suggested title from ever being adopted, with no test failing.
    private func applySuggestedTitleIfDefault(_ summary: MeetingSummary, to meeting: Meeting) {
        guard let suggested = summary.suggestedTitle else { return }
        guard meeting.title == meeting.titleFallback else { return }
        meeting.title = suggested
    }
```

- [ ] **Step 2: Run the full unit suite**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 424 tests. In particular no `warning:.*Minute/` line about an unused variable — `baseline` is gone, not orphaned.

- [ ] **Step 3: Lint**

```bash
swiftlint --strict --reporter github-actions-logging 2>&1 | grep -E "^::(error|warning)|Done linting"
```
Expected: `Done linting!` with no violations.

- [ ] **Step 4: Commit**

```bash
git add Minute/Services/MeetingJobs.swift
git commit -m "$(cat <<'EOF'
refactor: adopt a suggested title against Meeting.titleFallback

applySuggestedTitleIfDefault re-derived the auto-generated title
character-for-character from Meeting.titleFallback, giving "what counts as
the default title" two sources of truth. A change to the fallback rule
would fix the title editor and silently stop suggested titles from being
adopted, with no test failing — MeetingTitleTests only exercises the
property. Use the property.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 41: applySpeakerName's doc comment describes what a rename actually does (A3)

**Files:**
- Modify: `Minute/Services/MeetingJobs.swift:262-264` (the doc comment above `applySpeakerName`)
- Test: none — a comment-only change; verified by build + full suite + lint.

**Interfaces:**
- Consumes (named in the new comment, all verified present): `KnowledgeExtractionService.candidate(from:transcript:)` drops placeholder names at `Minute/Services/KnowledgeExtractionService.swift:209` (`guard !name.isEmpty, !fact.isEmpty, !isSpeakerPlaceholder(name) else { return nil }`); `KnowledgeStore` deletes historical placeholder entities at `Minute/Services/KnowledgeStore.swift:142-144` (`for entity in allEntities where KnowledgeExtractionService.isSpeakerPlaceholder(entity.name) { doomed[entity.id] = entity }`); `KnowledgeIngest.apply` leaves approved/auto-captured rows alone at `Minute/Services/KnowledgeIngest.swift:94-95`; the near-duplicate drop is `Minute/Services/KnowledgeIngest.swift:119-121` (`if KnowledgeText.normalized(existing.originalText) == candidateNormalized { return true }` — `:122` is the fuzzy `tokenOverlap` guard below it).
- Produces: nothing.

- [ ] **Step 1: Replace the comment**

In `Minute/Services/MeetingJobs.swift`, replace:

```swift
    /// Sets one speaker's display name. The Brain reads the transcript with
    /// names in it, so a rename resets the extraction cursor: facts about
    /// "Speaker 2" become facts about the person.
    static func applySpeakerName(_ name: String, at index: Int, to meeting: Meeting) {
```

with:

```swift
    /// Sets one speaker's display name and resets the extraction cursor: the
    /// Brain reads the transcript with the names in it, so the NEXT extraction
    /// can attribute this meeting's facts to the person.
    ///
    /// It does not re-point anything already stored, and there is nothing to
    /// re-point: a candidate named "Speaker N" never reaches ingest
    /// (KnowledgeExtractionService.candidate drops it) and historical
    /// placeholder entities are deleted at launch (KnowledgeStore), so no fact
    /// is ever filed under a placeholder entity. What the rename does not
    /// change is wording. An approved or auto-captured row this meeting alone
    /// states survives re-extraction untouched (KnowledgeIngest.apply), so a
    /// fact reading "Speaker 2 will ship Atlas" keeps that text on the Atlas
    /// page, and the re-extracted "Sarah will ship Atlas" is either dropped as
    /// a near-duplicate or filed as a second suggested row.
    static func applySpeakerName(_ name: String, at index: Int, to meeting: Meeting) {
```

- [ ] **Step 2: Run the full unit suite**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 424 tests.

- [ ] **Step 3: Lint**

```bash
swiftlint --strict --reporter github-actions-logging 2>&1 | grep -E "^::(error|warning)|Done linting"
```
Expected: `Done linting!` with no violations.

- [ ] **Step 4: Commit**

```bash
git add Minute/Services/MeetingJobs.swift
git commit -m "$(cat <<'EOF'
docs: say what a speaker rename really does to stored facts

applySpeakerName claimed that "facts about 'Speaker 2' become facts about
the person". After the placeholder drop in KnowledgeExtractionService and
the launch prune in KnowledgeStore, no fact is ever filed under a
placeholder entity, so there is nothing to re-point — the rename lets the
NEXT extraction attribute facts to the person. The residual the old wording
hid is now stated: an approved or auto-captured row this meeting alone
states keeps the wording it was captured with.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 42: Pin the .me → .topic collapse in candidate(from:transcript:) (F-2)

**Files:**
- Test: `MinuteTests/KnowledgeExtractionServiceTests.swift` (add at the end of `struct KnowledgeExtractionServiceTests`, after `paddedEntityKindStillMapsToItsKind`, which ends at line 107)
- Modify (temporarily, then restore): `Minute/Services/KnowledgeExtractionService.swift:215`

**Interfaces:**
- Consumes: `KnowledgeExtractionService.candidate(from: KnowledgeCandidateDraft, transcript: String) -> KnowledgeCandidate?`; `KnowledgeCandidateDraft(entityName:entityKind:fact:supportingQuote:)` (memberwise, all `String`); `EntityKind` (`case person, project, topic, me`, `Minute/Models/KnowledgeEntity.swift:6`).
- Produces: one new test, `aModelWrittenMeKindCollapsesToTopic`.

- [ ] **Step 1: Write the test**

Add to `MinuteTests/KnowledgeExtractionServiceTests.swift`, inside `struct KnowledgeExtractionServiceTests`, after `paddedEntityKindStillMapsToItsKind`:

```swift
    /// The Me page is a resolution decision this device makes, never a model
    /// output. EntityKind declares a `.me` case, so a draft whose entityKind
    /// reads "me" is one unchecked line away from minting a `.me` entity — and
    /// every downstream exemption (KnowledgeIngest's review routing,
    /// KnowledgeStore's orphan prune, which both skip `.me`) would then guard
    /// the bogus one. Only the unknown-kind default was pinned before this.
    @Test func aModelWrittenMeKindCollapsesToTopic() {
        let transcript = "[00:01] Sarah: I will own the Atlas redesign."
        let me = KnowledgeCandidateDraft(
            entityName: "Atlas", entityKind: "me",
            fact: "Atlas ships in Q3", supportingQuote: ""
        )
        #expect(KnowledgeExtractionService.candidate(from: me, transcript: transcript)?.entityKind == .topic)

        // The trim-and-lowercase path reaches the same raw value, so it has to
        // collapse there too — a model that writes " Me " must not slip past.
        let padded = KnowledgeCandidateDraft(
            entityName: "Atlas", entityKind: " Me ",
            fact: "Atlas ships in Q3", supportingQuote: ""
        )
        #expect(KnowledgeExtractionService.candidate(from: padded, transcript: transcript)?.entityKind == .topic)
    }
```

- [ ] **Step 2: Run the suite — the test passes, which is the point of a characterization test**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:MinuteTests/KnowledgeExtractionServiceTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔ Test run|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 8 tests.

- [ ] **Step 3: Prove the test is load-bearing**

Temporarily, in `Minute/Services/KnowledgeExtractionService.swift`, replace:

```swift
            entityKind: kind == .me ? .topic : kind,
```

with:

```swift
            entityKind: kind,
```

Run:
```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:MinuteTests/KnowledgeExtractionServiceTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔ Test run|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST FAILED`, with `✘` on `aModelWrittenMeKindCollapsesToTopic` (both expectations, `.me` where `.topic` was expected) and no other test failing — the guard is unpinned today.

- [ ] **Step 4: Restore the guard**

Put the line back exactly:

```swift
            entityKind: kind == .me ? .topic : kind,
```

Re-run the suite command from Step 2. Expected: `TEST SUCCEEDED`, 8 tests.

- [ ] **Step 5: Run the full unit suite**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 425 tests.

- [ ] **Step 6: Lint**

```bash
swiftlint --strict --reporter github-actions-logging 2>&1 | grep -E "^::(error|warning)|Done linting"
```
Expected: `Done linting!` with no violations.

- [ ] **Step 7: Commit**

```bash
git add MinuteTests/KnowledgeExtractionServiceTests.swift
git commit -m "$(cat <<'EOF'
test: pin that a model-written "me" kind collapses to .topic

EntityKind declares a `me` case and candidate(from:transcript:) maps it to
.topic in one expression, but nothing pinned it — the existing coverage
stops at the unknown-kind default. That expression is what keeps the Me page
a resolution decision rather than a model output; without it every
downstream .me exemption would protect a bogus entity.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 43: Pin same-batch duplicate dropping in KnowledgeIngest.apply (F-5)

**Files:**
- Test: `MinuteTests/KnowledgeIngestTests.swift` (add after `twoCandidatesForOneNewNameShareOneEntity`, which ends at line 58)
- Modify (temporarily, then restore): `Minute/Services/KnowledgeIngest.swift:99` (the candidate-loop head), `:114` (the dedup scan), `:220-221` (the two lines closing the `KnowledgeFact` insert)

**Interfaces:**
- Consumes: `KnowledgeIngest.apply(_:from:context:replacingExisting:) throws -> KnowledgeIngest.Result` (`replacingExisting` defaults to `true`); `KnowledgeIngest.Result` (`autoCaptured`, `suggested`, `duplicatesDropped`, all `Int`); the suite's own `candidate(_:_:kind:quote:)` helper (`MinuteTests/KnowledgeIngestTests.swift:29-31`, defaults `kind: .person`, `quote: "q"`) and `makeContext()`; `KnowledgeFact.originalText: String` (`Minute/Models/KnowledgeFact.swift:39`), read only by the temporary mutation in Step 3.
- Produces: one new test, `twoIdenticalCandidatesInOneMeetingLandOnce`.

- [ ] **Step 1: Write the test**

Add to `MinuteTests/KnowledgeIngestTests.swift`, inside `struct KnowledgeIngestTests`, after `twoCandidatesForOneNewNameShareOneEntity`:

```swift
    /// Two identical candidates from one meeting. The dedup scan reads
    /// `entity.facts`, and for a fact inserted earlier in this same apply()
    /// call that relationship is populated only by SwiftData's inverse-update
    /// before the save — an unverified framework assumption the whole loop
    /// rests on. The closest existing test gives its two candidates different
    /// fact texts, so it exercises the `known` entity array, not `entity.facts`.
    /// If the assumption ever failed, the entity page would show one claim
    /// twice.
    @Test func twoIdenticalCandidatesInOneMeetingLandOnce() throws {
        let context = try makeContext()
        let meeting = Meeting(title: "m")
        context.insert(meeting)

        let result = try KnowledgeIngest.apply(
            [candidate("Sarah", "Sarah leads Atlas"), candidate("Sarah", "Sarah leads Atlas")],
            from: meeting, context: context
        )

        #expect(result.suggested == 1)
        #expect(result.duplicatesDropped == 1)
        // Not auto-captured either: on the second pass through the loop the
        // entity is no longer new (`resolve` finds it in `known`), and a
        // quoted candidate on a known entity is exactly the shape that earns
        // auto-capture. Dropping it as a repeat is the only thing standing
        // between a re-stated claim and a row nobody reviewed.
        #expect(result.autoCaptured == 0)
        #expect(try context.fetch(FetchDescriptor<KnowledgeFact>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<KnowledgeEntity>()).count == 1)
    }
```

- [ ] **Step 2: Run the suite**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:MinuteTests/KnowledgeIngestTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔ Test run|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED` — the assumption holds today, and this test is what will report it if it stops holding.

- [ ] **Step 3: Prove the test is load-bearing**

The mutation has to break the *one* thing this test pins and nothing else, which rules out disabling a dedup branch: flipping the exact-normalized `return true` at `:120` to `return false` leaves this test passing, because control falls through to the fuzzy path — `KnowledgeText.tokenOverlap("Sarah leads Atlas", "Sarah leads Atlas")` is 1.0 (three word tokens a side, so the Jaccard branch, not the bigram fallback), it clears `nearDuplicateThreshold` at `:122`, and `existing.sourceMeetingIDs.contains(meetingID)` at `:129` is true because the fact the first candidate inserted carries `sourceMeetingID: meetingID` (`:212-220`), which `sourceMeetingIDs` derives from `sources` (`Minute/Models/KnowledgeFact.swift:136`). The duplicate is still found and every expectation still holds.

What the test actually pins is that `entity.facts` already contains a fact inserted *earlier in this same `apply()` call*, before the save. Hide exactly those from the scan. Three hunks, temporarily, in `Minute/Services/KnowledgeIngest.swift`.

Hunk 1 — replace:

```swift
        for candidate in candidates {
            let resolved = resolve(candidate, in: &known, context: context)
```

with:

```swift
        var insertedThisRun: Set<String> = []
        for candidate in candidates {
            let resolved = resolve(candidate, in: &known, context: context)
```

Hunk 2 — replace:

```swift
            let duplicate = entity.facts.first { existing in
```

with:

```swift
            let duplicate = entity.facts.filter { !insertedThisRun.contains($0.originalText) }.first { existing in
```

Hunk 3 — replace:

```swift
            ))
            touched[entity.id] = entity
```

with:

```swift
            ))
            insertedThisRun.insert(candidate.fact)
            touched[entity.id] = entity
```

Run the Step 2 command. Expected: `TEST FAILED`, with `✘ twoIdenticalCandidatesInOneMeetingLandOnce` failing three of its five expectations — `result.duplicatesDropped == 1` (it is 0), `result.autoCaptured == 0` (it is 1), and the `KnowledgeFact` count (two rows, not one). `result.suggested == 1` and the entity count still hold: the second candidate resolves to the entity the first one created, so `resolved.isNew` is false and it lands as `.autoCaptured`, not as a second suggestion.

No other test in the suite fails. Only three tests apply more than one candidate in a single call, and none of them needs a fact inserted by an earlier candidate to be visible: `twoCandidatesForOneNewNameShareOneEntity` (`:49-58`) gives its two candidates non-overlapping fact texts, and `aParaphraseAfterACorroborationInTheSameRunIsStillAWithinMeetingRepeat` (`:545-575`) and `aSecondCandidateInTheSameRunKeepsTheQuoteTheFirstOneValidated` (`:577-614`) both dedup against a fact saved before `apply()` ran, so both of their candidates are dropped and nothing is ever inserted for `insertedThisRun` to hide.

(Filtering on `hasChanges` instead would be wrong here: the pre-loop mutates existing rows with `fact.removeSource(meetingID:)` at `:87`, and the duplicate branch calls `duplicate.addSource(...)` at `:177`, so `hasChanges` is also true for saved rows the re-extraction tests dedup against — it would take `reExtractionKeepsACorroborationTheMeetingStillMakes`, `reextractedParaphraseOfAFactTheMeetingCorroboratedIsNotANewDraft`, `reextractedParaphraseWithoutAQuoteStillKeepsTheMeetingAsASource` and `aParaphraseAfterACorroborationInTheSameRunIsStillAWithinMeetingRepeat` down with it.)

- [ ] **Step 4: Restore the three hunks**

Delete the added `var insertedThisRun: Set<String> = []` line, put `let duplicate = entity.facts.first { existing in` back verbatim, and delete the added `insertedThisRun.insert(candidate.fact)` line. `git diff Minute/Services/KnowledgeIngest.swift` must be empty. Re-run the Step 2 command. Expected: `TEST SUCCEEDED`.

- [ ] **Step 5: Run the full unit suite**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 426 tests.

- [ ] **Step 6: Lint**

```bash
swiftlint --strict --reporter github-actions-logging 2>&1 | grep -E "^::(error|warning)|Done linting"
```
Expected: `Done linting!` with no violations.

- [ ] **Step 7: Commit**

```bash
git add MinuteTests/KnowledgeIngestTests.swift
git commit -m "$(cat <<'EOF'
test: pin that one meeting's identical candidates land once

KnowledgeIngest.apply dedups against entity.facts, which for a fact
inserted earlier in the same call is populated only by SwiftData's
inverse-relationship update before the save. Nothing exercised that: the
nearest test gives its two candidates different fact texts, so it covers
the `known` entity array instead. Two identical candidates in one meeting
now assert one row and one dropped duplicate.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 44: Pin onContentChanged's success-only contract at the MeetingJobs level (F-4)

**Files:**
- Test: `MinuteTests/SummaryGenerationTests.swift` — add a fixture engine after `EmptyTranscriptionEngine` (ends line 70), add assertions to `aJobThatFailsStillAnnouncesThatItsWorkEnded` (line 215) and `aStoppedJobStillAnnouncesThatItsWorkEnded` (line 236-237), and add one new test at the end of the struct (after `aStoppedJobStillAnnouncesThatItsWorkEnded`, which ends at line 261)
- Modify (temporarily, then restore): `Minute/Services/MeetingJobs.swift:212-215` (the `do` block inside `start`)

**Interfaces:**
- Consumes: `MeetingJobs.onContentChanged: (@MainActor () -> Void)?` (`Minute/Services/MeetingJobs.swift:52`), `MeetingJobs.onWorkEnded: (@MainActor () -> Void)?` (:69), `MeetingJobs.retranscribe(_:audioAt:transcription:) -> Task<Void, Never>?` (:143-148, `transcription` nil-defaulted for injection), `MeetingJobs.error(_:for:)`, `MeetingJobs.isBusy(_:)`, `TranscriptSegment(text:start:end:)` (`Minute/Models/TranscriptSegment.swift:4-12`, `speaker` defaults to nil), the suite's `makeMeeting()` and `makeWavFixture()` helpers.
- Produces: `private final class OneSegmentTranscriptionEngine: TranscriptionEngine` inside the test struct, and one new test `aSuccessfulJobAnnouncesThatTheContentChanged`.

- [ ] **Step 1: Add the successful-job fixture engine**

Add to `MinuteTests/SummaryGenerationTests.swift`, inside `struct SummaryGenerationTests`, immediately after the `EmptyTranscriptionEngine` class (i.e. after its closing `}` on line 70):

```swift
    /// An engine that recognizes one line. This file's only fixture for a job
    /// that actually succeeds — every other one fails, stops, or produces
    /// nothing, so nothing here ever reached the tail of `start`'s do block.
    @MainActor
    private final class OneSegmentTranscriptionEngine: TranscriptionEngine {
        var availability: TranscriptionAvailability = .available
        var volatileText = ""
        var segments: [TranscriptSegment] = []
        var timestampOffset: TimeInterval = 0
        func prepare() async {}
        func start(inputFormat: AVAudioFormat) async -> (@Sendable (AVAudioPCMBuffer) -> Void)? { nil }
        func finish() async -> [TranscriptSegment] { [] }
        func cancel() async {}
        func transcribe(file: AVAudioFile) async throws -> [TranscriptSegment] {
            [TranscriptSegment(text: "Atlas ships in Q3.", start: 0, end: 1)]
        }
    }
```

- [ ] **Step 2: Assert the failed job announces no content change**

In `MinuteTests/SummaryGenerationTests.swift`, replace:

```swift
        var started = 0
        var ended = 0
        jobs.onWorkStarted = { started += 1 }
        jobs.onWorkEnded = { ended += 1 }

        // No transcript: the summary throws. Nothing else speaks for this job
        // — onContentChanged fires only on success — so the catch-up pause it
        // took is given back here or never, and the Brain goes quiet for the
        // rest of the foreground session.
        await jobs.summarize(meeting, template: .standard, context: "", language: nil)?.value

        #expect(started == 1)
        #expect(ended == 1)
        #expect(jobs.error(.summary, for: meeting) != nil)
```

with:

```swift
        var started = 0
        var ended = 0
        var changed = 0
        jobs.onWorkStarted = { started += 1 }
        jobs.onWorkEnded = { ended += 1 }
        jobs.onContentChanged = { changed += 1 }

        // No transcript: the summary throws. Nothing else speaks for this job
        // — onContentChanged fires only on success — so the catch-up pause it
        // took is given back here or never, and the Brain goes quiet for the
        // rest of the foreground session.
        await jobs.summarize(meeting, template: .standard, context: "", language: nil)?.value

        #expect(started == 1)
        #expect(ended == 1)
        // The other half of that sentence, and the whole basis of the catch-up
        // loop's "only success nudges" reasoning: a failed job wrote nothing,
        // so there is nothing new for the Brain to read.
        #expect(changed == 0)
        #expect(jobs.error(.summary, for: meeting) != nil)
```

- [ ] **Step 3: Assert the stopped job announces no content change**

In the same file, replace:

```swift
        var ended = 0
        jobs.onWorkEnded = { ended += 1 }

        let engine = ParkedTranscriptionEngine()
```

with:

```swift
        var ended = 0
        var changed = 0
        jobs.onWorkEnded = { ended += 1 }
        jobs.onContentChanged = { changed += 1 }

        let engine = ParkedTranscriptionEngine()
```

and replace:

```swift
        #expect(ended == 1)
        #expect(!jobs.isBusy(meeting))
    }
}
```

with:

```swift
        #expect(ended == 1)
        // A cancelled job left the transcript exactly as it was.
        #expect(changed == 0)
        #expect(!jobs.isBusy(meeting))
    }
}
```

- [ ] **Step 4: Add the successful-job test**

Add to `MinuteTests/SummaryGenerationTests.swift`, inside `struct SummaryGenerationTests`, after `aStoppedJobStillAnnouncesThatItsWorkEnded` (as the struct's last member):

```swift
    @Test func aSuccessfulJobAnnouncesThatTheContentChanged() async throws {
        let (container, meeting) = try makeMeeting()
        defer { _ = container }
        let source = try makeWavFixture()
        defer { try? FileManager.default.removeItem(at: source) }
        let jobs = MeetingJobs()

        var changed = 0
        var ended = 0
        jobs.onContentChanged = { changed += 1 }
        jobs.onWorkEnded = { ended += 1 }

        await jobs.retranscribe(meeting, audioAt: source, transcription: OneSegmentTranscriptionEngine())?.value

        // The knowledge catch-up loop reads this as "there is new text to
        // extract" — exactly once, for a job that really wrote something.
        #expect(changed == 1)
        #expect(ended == 1)
        #expect(meeting.segments.count == 1)
        #expect(jobs.error(.transcription, for: meeting) == nil)
        #expect(!jobs.isBusy(meeting))
    }
```

- [ ] **Step 5: Run the suite**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:MinuteTests/SummaryGenerationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔ Test run|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 12 tests.

- [ ] **Step 6: Prove the tests are load-bearing**

Temporarily, in `Minute/Services/MeetingJobs.swift`, replace:

```swift
            do {
                try await work()
                onContentChanged?()
            } catch is CancellationError {
```

with:

```swift
            do {
                try await work()
            } catch is CancellationError {
```

and replace:

```swift
            statuses[id] = nil
            running[id] = nil
```

with:

```swift
            onContentChanged?()
            statuses[id] = nil
            running[id] = nil
```

Run the Step 5 command. Expected: `TEST FAILED`, with `✘` on `aJobThatFailsStillAnnouncesThatItsWorkEnded` and `aStoppedJobStillAnnouncesThatItsWorkEnded` (`changed == 1`, expected 0) — the regression that would nudge extraction after every failed or stopped job.

- [ ] **Step 7: Restore the success-only call**

Put `onContentChanged?()` back inside the `do`, immediately after `try await work()`, and remove the one added above `statuses[id] = nil`. Re-run the Step 5 command. Expected: `TEST SUCCEEDED`, 12 tests.

- [ ] **Step 8: Run the full unit suite**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 427 tests.

- [ ] **Step 9: Lint**

```bash
swiftlint --strict --reporter github-actions-logging 2>&1 | grep -E "^::(error|warning)|Done linting"
```
Expected: `Done linting!` with no violations.

- [ ] **Step 10: Commit**

```bash
git add MinuteTests/SummaryGenerationTests.swift
git commit -m "$(cat <<'EOF'
test: pin that only a successful job announces a content change

No test in the suite ever assigned onContentChanged, so MeetingJobs firing
it inside the do block — the basis of its doc comment and of the catch-up
loop's "only success nudges" reasoning — rested on reading the code. A
regression that moved the call below the catch would nudge extraction after
every stopped or failed job. The failure and Stop tests now assert it never
fires, and a one-segment engine gives the file its first successful-job
fixture, asserting it fires exactly once.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 45: hintNames offers roster names written without spaces (F-7)

**Files:**
- Modify: `Minute/Services/KnowledgeExtractionService.swift:174-188` (the loop inside `hintNames(for:from:)`)
- Test: `MinuteTests/KnowledgeExtractionServiceTests.swift` (add after `aNameWithNoTokensIsNeverAHint`, which ends at line 58)

**Interfaces:**
- Consumes: `KnowledgeText.inOrder(_:) -> String` (`Minute/Support/KnowledgeText.swift:20-22`; order-preserving normalized tokens joined by single spaces — its tokenizer splits on `CharacterSet.alphanumerics.inverted`, and CJK ideographs are alphanumerics, so an unspaced sentence normalizes to one token), `KnowledgeExtractionService.minimumHintTokenLength` (3), `KnowledgeExtractionService.hintCap` (20).
- Produces: no new symbol. `hintNames(for:from:)` keeps its signature `static func hintNames(for chunk: String, from names: [String]) -> [String]` and gains one match path, which ranks with the phrase matches.

- [ ] **Step 1: Write the failing test**

Add to `MinuteTests/KnowledgeExtractionServiceTests.swift`, inside `struct KnowledgeExtractionServiceTests`, after `aNameWithNoTokensIsNeverAHint`:

```swift
    /// CJK is written without inter-word spaces, so KnowledgeText normalizes a
    /// whole sentence to one token. Both existing probes — the padded phrase
    /// and the per-token one — need a space boundary the script never
    /// provides, so a Chinese or Japanese roster name could never be offered:
    /// the model then invents a second spelling, and KnowledgeIngest.resolve,
    /// which matches on exact normalized text, mints a duplicate entity for it.
    @Test func anUnspacedRosterNameIsHintedAsASubstring() {
        // "张伟" is inside the run "今天张伟负责发布", never a token of its own.
        let chunk = "[00:12] 今天张伟负责发布 Atlas。"
        #expect(KnowledgeExtractionService.hintNames(for: chunk, from: ["张伟"]) == ["张伟"])

        // A roster name this chunk does not contain is still not offered.
        #expect(KnowledgeExtractionService.hintNames(for: chunk, from: ["李娜"]).isEmpty)

        // One character is below the floor: it appears in almost any sentence,
        // and it would spend one of the twenty hint slots on nothing.
        #expect(KnowledgeExtractionService.hintNames(for: chunk, from: ["天"]).isEmpty)

        // The substring match ranks with the names spoken in full, ahead of a
        // name matched only token by token — "mercury atlas" is not contiguous
        // in this chunk, so it comes through the partial path.
        #expect(
            KnowledgeExtractionService.hintNames(for: chunk + " Mercury", from: ["Mercury Atlas", "张伟"])
                == ["张伟", "Mercury Atlas"]
        )
    }
```

- [ ] **Step 2: Run the suite to verify it fails**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:MinuteTests/KnowledgeExtractionServiceTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔ Test run|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST FAILED`, `✘ anUnspacedRosterNameIsHintedAsASubstring` — the first expectation gets `[]` where `["张伟"]` was expected, and the last gets `["Mercury Atlas"]`.

- [ ] **Step 3: Add the substring path**

In `Minute/Services/KnowledgeExtractionService.swift`, replace:

```swift
        for name in names {
            let normalized = KnowledgeText.inOrder(name)
            guard !normalized.isEmpty else { continue }
            if haystack.contains(" \(normalized) ") {
                phrases.append(name)
                continue
            }
            let tokens = normalized
```

with:

```swift
        for name in names {
            let normalized = KnowledgeText.inOrder(name)
            guard !normalized.isEmpty else { continue }
            if haystack.contains(" \(normalized) ") {
                phrases.append(name)
                continue
            }
            // Unspaced scripts (CJK) normalize to one giant token, so neither
            // the padded probe above nor the per-token probe below can ever
            // find a boundary, and a Chinese or Japanese roster name could
            // never be hinted at all — the model invents a second spelling and
            // resolution, which matches exact normalized text, mints a
            // duplicate entity for it. KnowledgeText.tokenOverlap already
            // carries a bigram fallback for this same script problem; this is
            // the matcher that lacked one. A name that is itself a single
            // token is matched as a bare substring, and counts as a phrase:
            // the whole name is present, just without delimiters. Two
            // characters minimum — one appears in nearly every sentence. The
            // known cost is over-offering a short single-token Latin name
            // ("Ann" inside "annual"): one of twenty hint slots, against a
            // name that otherwise can never be offered.
            if !normalized.contains(" "), normalized.count >= 2, haystack.contains(normalized) {
                phrases.append(name)
                continue
            }
            let tokens = normalized
```

- [ ] **Step 4: Run the suite to verify it passes**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:MinuteTests/KnowledgeExtractionServiceTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔ Test run|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 9 tests. The four existing spaced-name tests (`hintNamesKeepsOnlyNamesAppearingInChunkCappedAt20`, `namesSpokenInFullOutrankPartialMatchesWithinTheCap`, `aNameSharingOneCommonTokenIsNotAHint`, `aNameWithNoTokensIsNeverAHint`) must still pass unchanged — every multi-token name in them normalizes with a space and so never reaches the new path, and the single-token "Mercury" is genuinely absent from its chunk.

- [ ] **Step 5: Run the full unit suite**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 428 tests.

- [ ] **Step 6: Lint**

```bash
swiftlint --strict --reporter github-actions-logging 2>&1 | grep -E "^::(error|warning)|Done linting"
```
Expected: `Done linting!` with no violations.

- [ ] **Step 7: Commit**

```bash
git add Minute/Services/KnowledgeExtractionService.swift MinuteTests/KnowledgeExtractionServiceTests.swift
git commit -m "$(cat <<'EOF'
fix: hint roster names written in scripts without spaces

KnowledgeText splits on the inverse of alphanumerics and CJK ideographs are
alphanumerics, so an unspaced sentence normalizes to one giant token. Both
of hintNames' probes required a space boundary that script never provides,
so a Chinese or Japanese roster name was never offered — the model invented
a second spelling and resolution, which matches exact normalized text,
minted a duplicate entity for it. A name that is itself one token (≥ 2
characters) is now matched as a bare substring and ranks as a phrase.
tokenOverlap already had a bigram fallback for the same problem.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 46: A genuinely failed take-back reports the mirror incomplete (D3)

**Files:**
- Test: `MinuteTests/ICloudDriveBackupTests.swift` (add after `mirrorSkipsAndRemovesAMeetingDeletedSinceTheSnapshot`, which ends at line 324)
- Modify (temporarily, then restore): `Minute/Services/ICloudDriveBackup.swift:762` (inside `takeBack`)

**Interfaces:**
- Consumes: `ICloudDriveBackup.mirror(_:into:shouldContinue:) throws -> SyncOutcome` (`@discardableResult`, `shouldContinue` defaults to `{ true }`); `ICloudDriveBackup.SyncOutcome` (`complete`, `interrupted`, `incomplete`, `unavailable` — an `Int`-raw enum, so `==` is synthesized); `ICloudDriveBackup.noteMeetingDeleted(_ id: UUID)`; `ICloudDriveBackup.meetingID(inFolder: URL) -> String?`; the suite's `scratchDirectory()` and `item(id:folderName:notes:audio:audioFileName:)` helpers.
- Produces: one new test, `aFailedTakeBackReportsTheMirrorIncomplete`.

- [ ] **Step 1: Write the test**

Add to `MinuteTests/ICloudDriveBackupTests.swift`, inside `struct ICloudDriveBackupTests`, after `mirrorSkipsAndRemovesAMeetingDeletedSinceTheSnapshot`:

```swift
    /// The promise SyncOutcome exists for: a deleted meeting's bytes still
    /// sitting in iCloud Drive are reported, not swallowed, so the caller does
    /// not clear the backup warning over them. Every other deletion test
    /// asserts `.complete`, so takeBack's false branch — and the fileExists
    /// guard that sits directly in it — was otherwise unexercised.
    @Test func aFailedTakeBackReportsTheMirrorIncomplete() throws {
        let documents = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }

        let deletedID = UUID()
        let deleted = item(
            id: deletedID.uuidString,
            folderName: "2026-08-03 09.30 Deleted",
            notes: "# secret transcript"
        )
        #expect(try ICloudDriveBackup.mirror([deleted], into: documents) == .complete)
        let folder = documents.appendingPathComponent(deleted.folderName, isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("notes.md").path))

        // Unlinking an entry needs write permission on the directory that
        // holds it, so a read-only folder makes every removal inside it fail
        // for real — no seam, no stub. Restored before the scratch tree is
        // torn down: this defer is registered second, so it runs first.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }

        ICloudDriveBackup.noteMeetingDeleted(deletedID)
        let outcome = try ICloudDriveBackup.mirror([deleted], into: documents)

        // The notes of a meeting the user deleted are still in iCloud Drive.
        #expect(outcome == .incomplete)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("notes.md").path))
        // removeMirror drops the marker last and only if everything else went,
        // so the marker survives and a later sync can still find this folder
        // and finish the job.
        #expect(ICloudDriveBackup.meetingID(inFolder: folder) == deletedID.uuidString)
    }
```

- [ ] **Step 2: Run the suite**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:MinuteTests/ICloudDriveBackupTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔ Test run|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED` — the reporting works today, and this is what will notice when it stops.

- [ ] **Step 3: Prove the test is load-bearing**

Temporarily, in `Minute/Services/ICloudDriveBackup.swift` inside `takeBack`, replace:

```swift
            if !removeMirror(at: url) { removed = false }
```

with:

```swift
            _ = removeMirror(at: url)
```

Run the Step 2 command. Expected: `TEST FAILED`, with `✘ aFailedTakeBackReportsTheMirrorIncomplete` on `outcome == .incomplete` (it is `.complete`) and no other test failing — the swallowed failure this test exists to catch.

- [ ] **Step 4: Restore the reporting**

Put `if !removeMirror(at: url) { removed = false }` back. Re-run the Step 2 command. Expected: `TEST SUCCEEDED`.

- [ ] **Step 5: Run the full unit suite**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 429 tests. If a run is interrupted while the folder is still `0o555`, `rm -rf` the leftover directory under `$TMPDIR` by hand — the test restores the mode in a `defer`, but a killed process cannot.

- [ ] **Step 6: Lint**

```bash
swiftlint --strict --reporter github-actions-logging 2>&1 | grep -E "^::(error|warning)|Done linting"
```
Expected: `Done linting!` with no violations.

- [ ] **Step 7: Commit**

```bash
git add MinuteTests/ICloudDriveBackupTests.swift
git commit -m "$(cat <<'EOF'
test: pin that a failed take-back reports the mirror incomplete

takeBack returns false when removeMirror fails and both callers turn that
into .incomplete — the promise that a deleted meeting's bytes still in
iCloud Drive are reported rather than swallowed. Every deletion test
asserted .complete, so that branch, and the fileExists guard sitting in it,
were unexercised: widening the guard would silently start reporting success
over bytes that are still there. A read-only meeting folder makes one
removal genuinely fail, and the test asserts .incomplete plus a surviving
marker so a later sync can finish the job.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 47: The blocked catch-up path counts cheaply, and a failed fetch keeps the last count (A1)

**Files:**
- Modify: `Minute/Services/KnowledgeCatchUp.swift:259-278` (head of `run(context:)`, declaration through the `while !Task.isCancelled {`), `:386-398` (`pendingMeetings`, doc comment included), `:400-418` (`livePendingMeetings`, doc comment included), `:420-424` (`nextPending`), `:426-428` (`refreshPendingCount`)
- Test: `MinuteTests/KnowledgeCatchUpTests.swift` (add after `unavailableModelStillCountsPendingWork`, which ends at line 260)

**Interfaces:**
- Consumes: `ModelContext.fetchCount(_ descriptor: FetchDescriptor<T>) throws -> Int` (SwiftData, iOS 17+ — asks the store for a number instead of materializing models); `Meeting.knowledgeExtractedAt: Date?`; `Meeting.hasTranscript` (reads `segments`, which is a codable column and cannot be predicated); `KnowledgeCatchUp.init(availabilityMessage:retryDelay:extract:)` with all three defaulted.
- Produces: `KnowledgeCatchUp.pendingMeetings(context:) -> [Meeting]?` and `livePendingMeetings(context:) -> [Meeting]?` (were non-optional; both private), and a new private `refreshBlockedPendingCount(context: ModelContext)`. `pendingCount` stays `private(set) var pendingCount = 0` — no schema change, no public API change, and `BrainView` needs no edit.

- [ ] **Step 1: Write the failing test**

Add to `MinuteTests/KnowledgeCatchUpTests.swift`, inside `struct KnowledgeCatchUpTests`, after `unavailableModelStillCountsPendingWork`:

```swift
    /// A phone that cannot run Apple Intelligence takes this path on EVERY
    /// nudge — BrainView's `.task` fires on each appearance of the tab, and
    /// every finished job nudges too — and its unstamped set only ever grows.
    /// Counting there must not fetch every unstamped Meeting and decode its
    /// `segments` to test `hasTranscript`, which would hold every transcript
    /// in mainContext on exactly those devices.
    @Test func theBlockedPathCountsWithoutReadingTranscripts() async throws {
        let context = try makeContext()
        context.insert(meetingWithTranscript("Readable", createdAt: .now))
        // No segments at all: the honest count leaves this one out, and a
        // count that never touches `segments` cannot tell the difference.
        context.insert(Meeting(title: "Silent", createdAt: .now.addingTimeInterval(-60)))
        try context.save()

        var calls = 0
        let blocked = KnowledgeCatchUp(
            availabilityMessage: { "This iPhone doesn't support Apple Intelligence." },
            extract: { _, _ in calls += 1; return .empty }
        )
        blocked.nudge(context: context)
        await blocked.waitUntilIdle()

        #expect(calls == 0)
        // Both unstamped meetings are counted. Over-counting a transcript-less
        // one is the accepted price of not decoding any transcript here: with
        // no entities in the store the Brain tab renders the "needs Apple
        // Intelligence" state, so this number is not on screen.
        #expect(blocked.pendingCount == 2)

        // And the count the loop itself keeps is still the honest one: the
        // meeting with nothing to read never sits in it.
        let ready = makeCatchUp { _, _ in .empty }
        ready.nudge(context: context)
        await ready.waitUntilIdle()
        #expect(ready.pendingCount == 0)
    }
```

- [ ] **Step 2: Run the suite to verify it fails**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:MinuteTests/KnowledgeCatchUpTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔ Test run|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST FAILED`, `✘ theBlockedPathCountsWithoutReadingTranscripts` — `blocked.pendingCount` is 1, not 2, because the blocked path still runs the full fetch and filters on `hasTranscript`.

- [ ] **Step 3: Move the count behind the availability guard**

In `Minute/Services/KnowledgeCatchUp.swift`, replace:

```swift
    private func run(context: ModelContext) async {
        // Count before any guard can bail: even when the model isn't ready
        // or the device is warm, the Brain tab must know unread work exists.
        refreshPendingCount(context: context)
        // Not a per-meeting failure: when the model isn't ready, leave the
```

with:

```swift
    private func run(context: ModelContext) async {
        // Not a per-meeting failure: when the model isn't ready, leave the
```

- [ ] **Step 4: Count cheaply on the blocked path**

In the same function, replace:

```swift
        guard availabilityMessage() == nil else { return }

        while !Task.isCancelled {
```

with:

```swift
        guard availabilityMessage() == nil else {
            // The Brain tab still has to know unread work exists — but this
            // is the path an ineligible iPhone takes on every nudge, and the
            // nudges are frequent (the tab's `.task` on each appearance, every
            // job that ends) while its unstamped set only grows. Pay for a
            // count, not for fetching every unstamped meeting and decoding its
            // `segments`.
            refreshBlockedPendingCount(context: context)
            return
        }
        // Counted before the thermal guard can bail: even on a warm phone the
        // Brain tab must know unread work exists.
        refreshPendingCount(context: context)

        while !Task.isCancelled {
```

- [ ] **Step 5: Let a failed fetch say so instead of reporting an empty queue**

In the same file, replace:

```swift
    /// Unstamped meetings the loop can actually read. `segments` can't be
    /// predicated, so the transcript filter runs in memory.
    private func pendingMeetings(context: ModelContext) -> [Meeting] {
        let descriptor = FetchDescriptor<Meeting>(
            predicate: #Predicate { $0.knowledgeExtractedAt == nil },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let unstamped = (try? context.fetch(descriptor)) ?? []
```

with:

```swift
    /// Unstamped meetings the loop can actually read, or nil when the fetch
    /// itself failed. `segments` can't be predicated, so the transcript filter
    /// runs in memory.
    ///
    /// nil rather than []: a store error is not "nothing left to read".
    /// Folding it into an empty list drops `pendingCount` to 0 and the Brain
    /// tab tells the user everything has been read, over a queue that is still
    /// entirely there.
    private func pendingMeetings(context: ModelContext) -> [Meeting]? {
        let descriptor = FetchDescriptor<Meeting>(
            predicate: #Predicate { $0.knowledgeExtractedAt == nil },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        guard let unstamped = try? context.fetch(descriptor) else { return nil }
```

- [ ] **Step 6: Carry the nil through the pruning wrapper**

In the same file, replace:

```swift
    private func livePendingMeetings(context: ModelContext) -> [Meeting] {
        let pending = pendingMeetings(context: context)
        guard !skippedChunksByMeeting.isEmpty else { return pending }
```

with:

```swift
    private func livePendingMeetings(context: ModelContext) -> [Meeting]? {
        guard let pending = pendingMeetings(context: context) else { return nil }
        guard !skippedChunksByMeeting.isEmpty else { return pending }
```

- [ ] **Step 7: Consume the nil at both readers, and add the cheap counter**

In the same file, replace:

```swift
    private func nextPending(context: ModelContext) -> Meeting? {
        let pending = livePendingMeetings(context: context)
        pendingCount = pending.count
        return pending.first { !isSkipped($0) }
    }

    private func refreshPendingCount(context: ModelContext) {
        pendingCount = livePendingMeetings(context: context).count
    }
```

with:

```swift
    /// A failed fetch ends the pass without touching `pendingCount`: nothing
    /// can be read this time round, and the next nudge tries again.
    private func nextPending(context: ModelContext) -> Meeting? {
        guard let pending = livePendingMeetings(context: context) else { return nil }
        pendingCount = pending.count
        return pending.first { !isSkipped($0) }
    }

    /// Keeps the last known count when the fetch fails, for the same reason:
    /// a transient store error must not tell the Brain tab the queue is empty.
    private func refreshPendingCount(context: ModelContext) {
        pendingCount = livePendingMeetings(context: context)?.count ?? pendingCount
    }

    /// The count for a pass that is not going to read anything. `fetchCount`
    /// asks the store for a number instead of materializing every unstamped
    /// Meeting and decoding its `segments` for `hasTranscript`. It cannot
    /// apply that filter, so it over-counts transcript-less meetings — which
    /// the loop's own count corrects the moment extraction can run, and which
    /// is not on screen meanwhile: a store with no entities renders the "Brain
    /// Needs Apple Intelligence" state instead.
    ///
    /// It also skips `livePendingMeetings`, so this pass does not prune
    /// `skippedChunksByMeeting`. A device that has always been blocked has no
    /// refusals to prune — recording one takes a pass that actually ran the
    /// extractor. One that has Apple Intelligence switched off mid-session can
    /// hold a stale refused-parts row until the next unblocked pass, which is
    /// the moment the user could act on it anyway.
    private func refreshBlockedPendingCount(context: ModelContext) {
        let descriptor = FetchDescriptor<Meeting>(predicate: #Predicate { $0.knowledgeExtractedAt == nil })
        guard let count = try? context.fetchCount(descriptor) else { return }
        pendingCount = count
    }
```

- [ ] **Step 8: Run the suite to verify it passes**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:MinuteTests/KnowledgeCatchUpTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔ Test run|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`. The two other tests that assert a blocked-path count still hold, because each seeds exactly one meeting and that meeting has a transcript: `unavailableModelStillCountsPendingWork` (`pendingCount == 1`) and `anUnavailableModelSchedulesNoRepeatingPoll` (`pendingCount == 1`). `meetingWithoutTranscriptIsNotCountedAsPending` runs on the available path and still expects 0.

- [ ] **Step 9: Run the full unit suite**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 430 tests.

The `?? pendingCount` half of this task has no unit test: nothing in the suite can make `ModelContext.fetch` throw without a store seam this change is not adding, so it is verified by build + full suite + lint together with the count path above.

- [ ] **Step 10: Lint**

```bash
swiftlint --strict --reporter github-actions-logging 2>&1 | grep -E "^::(error|warning)|Done linting"
```
Expected: `Done linting!` with no violations.

- [ ] **Step 11: Commit**

```bash
git add Minute/Services/KnowledgeCatchUp.swift MinuteTests/KnowledgeCatchUpTests.swift
git commit -m "$(cat <<'EOF'
fix: stop the blocked catch-up path decoding every transcript

run() counted before the availability guard, so a phone without Apple
Intelligence fetched every unstamped Meeting and decoded its segments for
hasTranscript on every nudge — including BrainView's .task on each tab
appearance — holding every transcript in mainContext on exactly the devices
whose unstamped set only grows. The guard now comes first and the blocked
path uses fetchCount on the unstamped predicate; the full fetch stays where
the loop needs the objects.

The same fetch also swallowed its own failure: `(try? fetch) ?? []` made a
store error look like an empty queue, and the Brain tab claimed everything
had been read. pendingMeetings returns nil on a throw and both readers keep
the last known count instead.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Task 48: Replace the two wall-clock negative assertions with positive controls (B14)

**Files:**
- Test: `MinuteTests/KnowledgeCatchUpTests.swift:946-973` (`anUnavailableModelSchedulesNoRepeatingPoll`) and `:975-1003` (`aPendingRetryStartsNothingWhileTheAppIsAway`) — the file's last two tests
- No production change.

**Interfaces:**
- Consumes: `KnowledgeCatchUp.init(availabilityMessage:retryDelay:extract:)`, `nudge(context:)`, `pause()`, `waitUntilIdle()`, `pendingCount`; `LanguageModelSession.GenerationError.rateLimited(_:)` with `.init(debugDescription:)` (already used at line 987); `AsyncStream.makeStream(of:)` — the event-driven park handshake this file already uses at lines 328-340 and 358-372; the `.timeLimit(.minutes(1))` trait (used in `MinuteTests/SummaryGenerationTests.swift:236`).
- Produces: no new symbol. Both tests keep their names and every existing expectation.

- [ ] **Step 1: Give the unavailable-model test a positive control**

In `MinuteTests/KnowledgeCatchUpTests.swift`, replace the whole of `anUnavailableModelSchedulesNoRepeatingPoll`:

```swift
    @Test func anUnavailableModelSchedulesNoRepeatingPoll() async throws {
        let context = try makeContext()
        context.insert(meetingWithTranscript("Unread", createdAt: .now))
        try context.save()

        // One availability check per run() pass — a retry that re-arms itself
        // shows up here as passes climbing with nothing touching the loop.
        var passes = 0
        var calls = 0
        let catchUp = KnowledgeCatchUp(
            availabilityMessage: { passes += 1; return "This iPhone doesn't support Apple Intelligence." },
            retryDelay: .milliseconds(20),
            extract: { _, _ in calls += 1; return .empty }
        )
        catchUp.nudge(context: context)
        await catchUp.waitUntilIdle()
        #expect(passes == 1)

        // An ineligible iPhone never becomes eligible. A retry on this guard
        // re-arms itself on the next pass, so it would refetch every unstamped
        // meeting once a delay for the whole foreground lifetime — on exactly
        // the phones whose pending set can only grow.
        try await Task.sleep(for: .milliseconds(200))
        #expect(passes == 1)
        #expect(calls == 0)
        // Bailing still has to leave the Brain tab an honest count.
        #expect(catchUp.pendingCount == 1)
    }
```

with:

```swift
    @Test(.timeLimit(.minutes(1)))
    func anUnavailableModelSchedulesNoRepeatingPoll() async throws {
        let context = try makeContext()
        context.insert(meetingWithTranscript("Unread", createdAt: .now))
        try context.save()

        // One availability check per run() pass — a retry that re-arms itself
        // shows up here as passes climbing with nothing touching the loop.
        var passes = 0
        var calls = 0
        let catchUp = KnowledgeCatchUp(
            availabilityMessage: { passes += 1; return "This iPhone doesn't support Apple Intelligence." },
            retryDelay: .milliseconds(20),
            extract: { _, _ in calls += 1; return .empty }
        )
        catchUp.nudge(context: context)
        await catchUp.waitUntilIdle()
        #expect(passes == 1)

        // A positive control rather than a wall-clock guess: a second loop on
        // its own store, with the same retry delay, failing in a way that DOES
        // earn a retry. Waiting for its retry to fire proves a retry window
        // really elapsed — a fixed sleep on a loaded runner would pass this
        // test for the wrong reason.
        let controlContext = try makeContext()
        controlContext.insert(meetingWithTranscript("Control", createdAt: .now))
        try controlContext.save()
        var controlCalls = 0
        let (controlPasses, controlContinuation) = AsyncStream.makeStream(of: Void.self)
        let control = KnowledgeCatchUp(
            availabilityMessage: { nil },
            retryDelay: .milliseconds(20),
            extract: { _, _ in
                controlCalls += 1
                controlContinuation.yield(())
                throw LanguageModelSession.GenerationError.rateLimited(.init(debugDescription: "test"))
            }
        )
        control.nudge(context: controlContext)
        var controlIterator = controlPasses.makeAsyncIterator()
        _ = await controlIterator.next()   // its first pass
        _ = await controlIterator.next()   // its retry fired: a delay has passed
        // Its extractor always fails, so it would retry forever; stop it here.
        control.pause()
        await control.waitUntilIdle()
        #expect(controlCalls >= 2)

        // An ineligible iPhone never becomes eligible. A retry on this guard
        // re-arms itself on the next pass, so it would refetch every unstamped
        // meeting once a delay for the whole foreground lifetime — on exactly
        // the phones whose pending set can only grow.
        #expect(passes == 1)
        #expect(calls == 0)
        // Bailing still has to leave the Brain tab an honest count.
        #expect(catchUp.pendingCount == 1)
    }
```

- [ ] **Step 2: Give the paused-retry test a positive control**

In the same file, replace the whole of `aPendingRetryStartsNothingWhileTheAppIsAway`:

```swift
    @Test func aPendingRetryStartsNothingWhileTheAppIsAway() async throws {
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
                throw LanguageModelSession.GenerationError.rateLimited(.init(debugDescription: "test"))
            }
        )
        catchUp.nudge(context: context)
        await catchUp.waitUntilIdle()
        #expect(calls == 1)

        // The scene left before the retry came due. Extraction is
        // foreground-only, so the timer must not resurrect the loop there —
        // waking a rate-limited model in the background is how the app gets
        // suspended mid-request.
        catchUp.pause()
        try await Task.sleep(for: .milliseconds(200))
        await catchUp.waitUntilIdle()
        #expect(calls == 1)
        #expect(meeting.knowledgeExtractedAt == nil)
    }
```

with:

```swift
    @Test(.timeLimit(.minutes(1)))
    func aPendingRetryStartsNothingWhileTheAppIsAway() async throws {
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
                throw LanguageModelSession.GenerationError.rateLimited(.init(debugDescription: "test"))
            }
        )
        catchUp.nudge(context: context)
        await catchUp.waitUntilIdle()
        #expect(calls == 1)

        // The scene left before the retry came due. Extraction is
        // foreground-only, so the timer must not resurrect the loop there —
        // waking a rate-limited model in the background is how the app gets
        // suspended mid-request.
        catchUp.pause()

        // A positive control rather than a wall-clock guess: the same failure
        // and the same delay on its own store, left in the foreground. Waiting
        // for ITS retry to fire is what makes the silence above meaningful —
        // a fixed sleep would also "pass" on a runner too loaded to have run
        // any timer at all.
        let controlContext = try makeContext()
        controlContext.insert(meetingWithTranscript("Control", createdAt: .now))
        try controlContext.save()
        var controlCalls = 0
        let (controlPasses, controlContinuation) = AsyncStream.makeStream(of: Void.self)
        let control = KnowledgeCatchUp(
            availabilityMessage: { nil },
            retryDelay: .milliseconds(50),
            extract: { _, _ in
                controlCalls += 1
                controlContinuation.yield(())
                throw LanguageModelSession.GenerationError.rateLimited(.init(debugDescription: "test"))
            }
        )
        control.nudge(context: controlContext)
        var controlIterator = controlPasses.makeAsyncIterator()
        _ = await controlIterator.next()   // its first pass
        _ = await controlIterator.next()   // its retry fired: a delay has passed
        control.pause()
        await control.waitUntilIdle()
        #expect(controlCalls >= 2)

        await catchUp.waitUntilIdle()
        #expect(calls == 1)
        #expect(meeting.knowledgeExtractedAt == nil)
    }
```

- [ ] **Step 3: Run the suite**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:MinuteTests/KnowledgeCatchUpTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔ Test run|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, same test count as after Task 47 (no test added or removed).

- [ ] **Step 4: Prove both controls actually fire**

Temporarily, in `Minute/Services/KnowledgeCatchUp.swift` inside `scheduleRetry()`, replace:

```swift
        let delay = retryDelay
```

with:

```swift
        let delay = Duration.seconds(600)
```

Run the Step 3 command. Expected: `TEST FAILED` — both rewritten tests exceed the one-minute time limit waiting on `controlIterator.next()` for a retry that will not come for ten minutes. That is the point: the controls, not a sleep, are what these two tests now wait on. Expect the run to take a few minutes, since each of the two is killed by its own one-minute limit.

`aRateLimitedLoopRetriesItselfAfterTheDelay` (`MinuteTests/KnowledgeCatchUpTests.swift:912-944`) fails in the same run, on `#expect(calls == 2)` observing 1. It does not hang: it has its own bounded wait loop (`while calls < 2 && waited < 2_000`, `:936-940`), so it gives up after ~2 s and reports. Only the two rewritten tests depend on `.timeLimit(.minutes(1))` to end at all.

- [ ] **Step 5: Restore the injected delay**

Put back:

```swift
        let delay = retryDelay
```

Re-run the Step 3 command. Expected: `TEST SUCCEEDED`.

- [ ] **Step 6: Run the full unit suite**

```bash
xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|warning:.*Minute/|Test run|TEST (SUCCEEDED|FAILED)"
```
Expected: `TEST SUCCEEDED`, 430 tests.

- [ ] **Step 7: Lint**

```bash
swiftlint --strict --reporter github-actions-logging 2>&1 | grep -E "^::(error|warning)|Done linting"
```
Expected: `Done linting!` with no violations.

- [ ] **Step 8: Commit**

```bash
git add MinuteTests/KnowledgeCatchUpTests.swift
git commit -m "$(cat <<'EOF'
test: wait on a retry that fires, not on a fixed 200 ms sleep

The file's last two tests asserted that nothing happened after sleeping
200 ms against a 20 ms and a 50 ms injected retry delay. Both fail loudly
under the defect they guard on a healthy host, but a loaded runner that
lets 200 ms of wall clock pass without completing a 50 ms Task.sleep passes
them for the wrong reason. Each now drives a second, un-paused loop with
the same delay on its own store and awaits ITS retry firing — the
event-driven park shape the rest of this file already uses — before
asserting the loop under test never moved.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
)"
```

---

### Hand-offs to Track E

None. Every file this track's tasks touch is owned by this track:

- Task 39 moves `BackgroundTaskToken` verbatim between two owned files. Its five callers (`Minute/Recording/RecordingSession.swift`, `Minute/Services/MLXDownloadCenter.swift`, `Minute/Services/WhisperDownloadCenter.swift`, `Minute/Services/MeetingJobs.swift`, `Minute/Services/ICloudDriveBackup.swift`) reference it by bare name inside the same module and need no edit — **but Track E should confirm no other track deleted or duplicated that declaration** when merging, since a second `BackgroundTaskToken` anywhere in the target is a redeclaration error rather than a silent conflict.
- Task 47 changes only private members of `KnowledgeCatchUp`; `BrainView`'s `pendingCount` reads and its `.task { catchUp.nudge(context: context) }` are unchanged.

### Not done in this track

- **E1** (a heavy-job gate in `MeetingJobs` spanning both engines, so a Whisper re-transcription and an MLX summary cannot hold two models resident at once) — deferred by decision: it is a product call about how much concurrency to give up, and the gate's shape depends on it. Touches `Minute/Services/MeetingJobs.swift`, this track's file.
- **E3** (a user-typed device label in Settings used as the iCloud Drive device-folder name, since the entitlement for the real name is not held) — deferred by decision: a feature, not a fix. Touches `Minute/Services/ICloudDriveBackup.swift`, this track's file.
- **E2** and **E4** — skipped by decision.
- **G1** (`KnowledgeText.contains(transcript:quote:)` should pad both joined strings so quote matches are token-aligned) — a decision exists for it but it is not in this track's selected item list, so no task here implements it. It edits `Minute/Support/KnowledgeText.swift`, which this track owns: whichever track carries G1 must be merged before or after Track J rather than concurrently with it, and Track E should watch for a conflict in that one file. Nothing in Tasks 39-48 touches `KnowledgeText.swift`.
- The `?? pendingCount` fallback added in Task 47 ships without a unit test of its own: making `ModelContext.fetch` throw needs a store seam this batch is not adding. It is covered by build + full suite + lint.

---

## Track E — Post-merge (sequential, after Tracks G, H, I, J are merged)

Track E owns every file. Verify symbols in the merged tree before editing; keep the full suite green and lint clean.

### Task 55: Quote validation matches whole tokens only (G1)

**Files:**
- Modify: `Minute/Support/KnowledgeText.swift` (`contains(transcript:quote:)`)
- Test: `MinuteTests/KnowledgeTextTests.swift`

**Interfaces:**
- Consumes: `KnowledgeText.tokens(_:)`, `KnowledgeText.contains(transcript:quote:)` (existing signatures; read them first).

- [ ] **Step 1: Write the failing test**

Add to `MinuteTests/KnowledgeTextTests.swift`:

```swift
    @Test func quoteValidationIsTokenAligned() {
        let transcript = "[0:12] Sarah: I disown the atlas plan, and Priya owns the mercury plan."
        // A quote that only matches by cutting into a word must not validate.
        #expect(!KnowledgeText.contains(transcript: transcript, quote: "own the atlas plan"))
        // Whole tokens in order still do, anywhere in the sentence.
        #expect(KnowledgeText.contains(transcript: transcript, quote: "the atlas plan"))
        #expect(KnowledgeText.contains(transcript: transcript, quote: "Priya owns the mercury plan"))
    }
```

- [ ] **Step 2: Run to verify it fails** — `xcodebuild test … -only-testing:MinuteTests/KnowledgeTextTests …` (simulator "iPhone 17 Pro"). Expected: the first expectation fails (substring match validates "own the atlas plan" inside "disown the atlas plan").

- [ ] **Step 3: Pad both joined strings**

In `KnowledgeText.contains(transcript:quote:)`, keep the existing token joins but compare with a leading and trailing space on both sides so a match can only start and end on token boundaries — e.g. `let needle = " " + tokens(quote).joined(separator: " ") + " "` and `let haystack = " " + tokens(transcript).joined(separator: " ") + " "`, then `haystack.contains(needle)`, preserving the existing empty-quote guard. Add a one-sentence WHY comment (a quote that only matches by cutting into a word would let the model ground a fact in text the transcript does not say).

- [ ] **Step 4: Run the suite to verify it passes** — all `KnowledgeTextTests` pass, including the pre-existing multi-word quote test (it matches whole tokens, so padding does not break it). If an existing test relied on a partial-word match, fix the test's fixture to a whole-token quote and say so in the commit body.

- [ ] **Step 5: Lint, then commit**

```bash
git add Minute/Support/KnowledgeText.swift MinuteTests/KnowledgeTextTests.swift
git commit -m "fix: validate a supporting quote only on whole tokens so a fact can't be grounded in a cut word

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```
