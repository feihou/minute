# PR #28 Review Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Repair the validated data-safety, lifecycle, fallback-control, iCloud-configuration, and privacy-copy defects introduced by PR #28.

**Architecture:** Preserve the existing `ICloudDriveBackup` actor and reconciliation flow. Tighten duplicate deletion with source-backed proof, add one small lifecycle task owner around the existing cancellation predicate, and make direct UI/configuration/copy corrections.

**Tech Stack:** Swift 5 mode, Swift Concurrency, Swift Testing, SwiftUI, UIKit background tasks, SwiftData, Xcode property lists and entitlements.

## Global Constraints

- No new dependencies.
- Both backup modes remain off by default and independently controlled.
- Never delete a mirrored recording unless another healthy copy is proven or the meeting no longer names a recording.
- Never mirror the ephemeral fallback store.
- Do not alter unrelated recording, transcription, summarization, or UI behavior.
- Preserve user-added files in iCloud Drive mirror folders.

---

### Task 1: Preserve the last healthy duplicate recording

**Files:**
- Modify: `MinuteTests/ICloudDriveBackupTests.swift`
- Modify: `Minute/Services/ICloudDriveBackup.swift`

**Interfaces:**
- Consumes: `ICloudDriveBackup.Item.audioFileName`, `audioSourceURL`, and `fileSize(at:)`.
- Produces: duplicate cleanup that removes extra folders only after the kept recording has locally verifiable bytes matching a readable source.

- [x] **Step 1: Write the failing regression test**

Add a test beside `mirrorKeepsADuplicateUntilTheKeptFolderHoldsTheRecording` that mirrors and duplicates a healthy recording, truncates the kept copy, then syncs an item with the model's `audioFileName` and a nil `audioSourceURL`. Assert the duplicate still contains the original bytes.

Add a second regression where the kept folder has only an iCloud placeholder while another folder has healthy local bytes. Assert the healthy duplicate remains; a placeholder proves a cloud object exists, not that the chosen copy can safely replace the duplicate.

Add a third regression where the kept copy has different bytes but the same length as the source and duplicate. Assert the mirror repairs the kept copy before pruning the now-redundant duplicate.

```swift
@Test func mirrorKeepsAHealthyDuplicateWhenTheKeptRecordingCannotBeVerified() throws {
    let documents = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: documents) }
    let source = try recording(in: documents, bytes: "healthy audio")
    let id = UUID().uuidString
    let name = "2026-08-03 09.30 Standup"
    try ICloudDriveBackup.mirror([item(id: id, folderName: name, audio: source)], into: documents)

    let kept = documents.appendingPathComponent(name, isDirectory: true)
    let duplicate = documents.appendingPathComponent("\(name) copy", isDirectory: true)
    try FileManager.default.copyItem(at: kept, to: duplicate)
    try Data("bad".utf8).write(to: kept.appendingPathComponent(source.lastPathComponent))

    try ICloudDriveBackup.mirror(
        [item(id: id, folderName: name, audio: nil, audioFileName: source.lastPathComponent)],
        into: documents
    )

    #expect(
        try Data(contentsOf: duplicate.appendingPathComponent(source.lastPathComponent))
            == Data("healthy audio".utf8)
    )
}
```

- [x] **Step 2: Run the test and verify the data-loss reproduction**

Run:

```bash
xcodebuild -project Minute.xcodeproj -scheme Minute \
  -destination 'platform=iOS Simulator,id=08191DCB-4C82-475E-B9A3-82FD969870A8' \
  -only-testing:MinuteTests/ICloudDriveBackupTests test
```

Expected: the new test fails because the duplicate folder is removed.

- [x] **Step 3: Require source-backed proof before duplicate cleanup**

Replace the name-only `holdsRecording` check with an item-aware check:

```swift
private static func holdsCurrentRecording(_ folder: URL, for item: Item) -> Bool {
    guard let name = item.audioFileName else { return true }
    guard let source = item.audioSourceURL, let sourceSize = fileSize(at: source) else { return false }
    return filesMatch(source, folder.appendingPathComponent(name), sourceSize: sourceSize)
}
```

Use it in the duplicate sweep and leave duplicates in place when the source is unreadable or the kept copy has only an iCloud placeholder. When duplicate cleanup is pending, have the write path compare local source and destination bytes and repair same-size corruption before the sweep. Keep ordinary, non-destructive syncs on the existing size fast path so large recordings are not reread on every background transition.

- [x] **Step 4: Run the targeted suite and verify green**

Run the Task 1 command again. Expected: all `ICloudDriveBackupTests` pass.

### Task 2: Cancel lifecycle-owned background mirrors

**Files:**
- Modify: `MinuteTests/ICloudDriveBackupTests.swift`
- Modify: `Minute/Services/ICloudDriveBackup.swift`
- Modify: `Minute/App/MinuteApp.swift`

**Interfaces:**
- Consumes: `syncNow(_:)`, the existing `shouldContinue` predicate, `BackgroundTaskToken`, and SwiftUI `scenePhase`.
- Produces: `BackgroundMirrorTask`, `syncIfEnabled(context:) -> BackgroundMirrorTask?`, and foreground cancellation from `MinuteApp`.

- [x] **Step 1: Write the failing lifecycle cancellation test**

Add an async `@MainActor` test that starts a `BackgroundMirrorTask`, cancels it, and uses Swift Testing confirmation to prove the operation observes `shouldContinue() == false`.

```swift
private actor CancellationProbe {
    private(set) var stopped = false
    func markStopped() { stopped = true }
}

@Test @MainActor
func backgroundMirrorCancellationStopsTheOperation() async {
    let probe = CancellationProbe()
    let operation = BackgroundMirrorTask(name: "test") { shouldContinue in
        while shouldContinue() { await Task.yield() }
        await probe.markStopped()
    }
    let task = operation.cancel()
    await task?.value
    #expect(await probe.stopped)
}
```

- [x] **Step 2: Run the test and verify red**

Run the Task 1 test command. Expected: compilation fails because `BackgroundMirrorTask` does not exist.

- [x] **Step 3: Implement the lifecycle owner and predicate composition**

Implement `BackgroundMirrorTask` with a cancellation flag, a Swift task, and a `BackgroundTaskToken`. Update `syncNow` to accept an additional `@Sendable () -> Bool`, check it before and after ubiquity-container resolution, and compose it with the existing live toggle and `Task.isCancelled` checks. Return the owner from `syncIfEnabled`.

- [x] **Step 4: Cancel on scene transitions**

Store the returned owner in `MinuteApp` state. Cancel and clear it on every scene transition; start a new owner only for `.background`.

- [x] **Step 5: Run the targeted suite and verify green**

Run the Task 1 test command. Expected: all `ICloudDriveBackupTests` pass, including the cancellation test.

### Task 3: Restore fallback controls and align privacy configuration

**Files:**
- Modify: `Minute/Views/SettingsView.swift`
- Modify: `Minute/Minute.entitlements`
- Modify: `README.md`

**Interfaces:**
- Consumes: `MeetingStore.useEphemeralStorage`, existing backup toggle handlers, `NSUbiquitousContainers`, and the two iCloud entitlement arrays.
- Produces: reachable backup controls during fallback and one literal production container identifier across the processed configuration.

- [x] **Step 1: Keep backup controls reachable during fallback**

Leave only `storageSection` inside the `!MeetingStore.useEphemeralStorage` condition and render `backupSection` immediately after it. Remove the duplicated fallback comment.

Keep the existing iCloud-unavailable alert for a healthy persistent store, but show a storage-recovery alert when ephemeral fallback is the reason a mirror cannot start.

- [x] **Step 2: Align the container identifiers**

Change both entitlement array values to:

```xml
<string>iCloud.com.minuteapp.Minute</string>
```

This matches the existing `NSUbiquitousContainers` dictionary key.

- [x] **Step 3: Correct privacy and contributor copy**

Replace absolute “nothing ever leaves” wording with “stays on device by default; optional backups are explicit.” Clarify that non-owner device builds must remove or replace the iCloud entitlement and matching Info.plist container entry.

- [x] **Step 4: Verify processed build configuration**

Build with `PRODUCT_BUNDLE_IDENTIFIER=com.example.Minute`, then inspect the processed `Info.plist` and `Minute.app-Simulated.xcent`. Expected: both name `iCloud.com.minuteapp.Minute`.

### Task 4: Full verification and independent review

**Files:**
- Verify all modified files from Tasks 1–3.

**Interfaces:**
- Consumes: the completed repair diff.
- Produces: fresh test, build, lint, and review evidence.

- [x] **Step 1: Run the PR-related suites**

```bash
xcodebuild -project Minute.xcodeproj -scheme Minute \
  -destination 'platform=iOS Simulator,id=08191DCB-4C82-475E-B9A3-82FD969870A8' \
  -only-testing:MinuteTests/ICloudDriveBackupTests \
  -only-testing:MinuteTests/MeetingStoreTests \
  -only-testing:MinuteTests/AudioImporterTests \
  -skip-testing:MinuteTests/SummarizationIntegrationTests \
  CODE_SIGNING_ALLOWED=NO test
```

- [x] **Step 2: Run all unit tests except the real-model integration suite**

```bash
xcodebuild -project Minute.xcodeproj -scheme Minute \
  -destination 'platform=iOS Simulator,id=08191DCB-4C82-475E-B9A3-82FD969870A8' \
  -only-testing:MinuteTests \
  -skip-testing:MinuteTests/SummarizationIntegrationTests \
  CODE_SIGNING_ALLOWED=NO test
```

- [x] **Step 3: Run lint/static checks available in the repository**

Run:

```bash
swiftlint --strict --reporter github-actions-logging
```

If the pinned SwiftLint binary is unavailable locally, record that limitation and rely on the matching GitHub Actions check; do not install a new dependency into the project.

- [x] **Step 4: Request independent final code review**

Review the complete branch diff against this plan. Fix every Critical or Important finding, rerun the covering tests, and report any remaining physical-device-only risk.

## Verification Record

- Red tests reproduced the corrupt/unreadable copy, evicted-placeholder, same-size corruption, and missing lifecycle-owner cases before their fixes.
- `ICloudDriveBackupTests`: 46 passed, 0 failed.
- PR-related `ICloudDriveBackupTests`, `MeetingStoreTests`, and `AudioImporterTests`: 57 passed, 0 failed.
- All `MinuteTests` except `SummarizationIntegrationTests`: 127 passed, 0 failed after rebasing onto current `main`.
- Alternate `com.example.Minute` simulator build: processed Info.plist and both processed iCloud entitlement arrays use `iCloud.com.minuteapp.Minute`; app and widget processed entitlements both use `group.com.minuteapp.Minute`.
- `xcodebuild analyze`, property-list lint, and `git diff --check` exit successfully. The clean build/analyze reports one pre-existing Swift 6 warning in `AudioRecorder.swift:52`; the repository-pinned SwiftLint command could not run because SwiftLint is not installed in this environment, and no dependency was installed to work around that.
- Independent final and scoped follow-up reviews report no remaining Critical, Important, or Minor findings after the fixes.
- The branch was rebased onto `main` at `4b5ea63`; conflict resolution preserves both the new summary/widget behavior and the cancellable mirror lifecycle.
- Remaining physical-device check: real UIKit expiration timing and signed iCloud ubiquity behavior.
