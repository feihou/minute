# Review Fixes, Batch 1 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the highest-impact confirmed findings of the 2026-09-02 functional review (report: https://claude.ai/code/artifact/5c878fef-8f93-41eb-823c-de180d128bf3) without changing any feature's intended behavior.

**Architecture:** Every fix is a small, local change to an existing service or view, each with a failing Swift Testing test first where the code is testable without hardware. Pure logic that views need is extracted into static helpers on the owning service (`MeetingJobs`, `RecordingSession`, `MeetingStore`) so it can be unit-tested; views only call those helpers. The tasks are grouped into two tracks that touch disjoint files, so the tracks can run in two separate git worktrees at the same time and merge cleanly.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Swift Testing (`@Test`, `#expect`), FoundationModels, WhisperKit 1.0.0, mlx-swift-lm 3.31.4. Xcode 26.6, iOS 26.5 simulator "iPhone 17 Pro".

## Global Constraints

- Privacy invariants from CONTRIBUTING.md hold: no meeting content on the wire; every byte written has a delete path; AI output stays grounded (missing owner/deadline is the literal `"Not specified"`); recording never depends on optional capabilities.
- No new third-party dependencies.
- Unit tests use Swift Testing (`import Testing`, `@Test`, `#expect`, `#require`), never XCTest. Test structs that touch SwiftData are `@MainActor` and build an in-memory container with `MeetingStore.modelConfiguration(inMemory: true)`; containers holding `KnowledgeEntity`/`KnowledgeFact` must be retained for the process lifetime (copy the `retainedContainers` pattern from `MinuteTests/KnowledgeCatchUpTests.swift`).
- Run tests with exactly this command from the worktree root, substituting the suite name (the whole unit suite takes minutes; run one suite while iterating, the full command once before each commit):
  ```bash
  xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MinuteTests/<SuiteName> CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✔|✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
  ```
  Full unit suite (skips the live Apple Intelligence integration suite, matching CI):
  ```bash
  xcodebuild test -project Minute.xcodeproj -scheme Minute -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:MinuteTests -skip-testing:MinuteTests/SummarizationIntegrationTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "✘|error:|Test run|TEST (SUCCEEDED|FAILED)"
  ```
  Baseline at the branch point: **251 tests in 39 suites pass**. Every task must leave that count green plus its own new tests.
- New test files under `MinuteTests/` are picked up automatically (synchronized folder groups); do not edit `Minute.xcodeproj/project.pbxproj`.
- SwiftLint (`.swiftlint.yml`) is strict in CI: keep to the codebase style (4-space indent, doc comments explain *why*, no `for … where` around side effects). `swiftlint` is not installed locally, so read the surrounding code and match it.
- Commit messages follow Conventional Commits (`fix: …`, `test: …`) and end with the trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Commit with explicit paths (`git add <file> …`); never `git add -A`, and never commit anything under `.superpowers/`.
- Line numbers in this plan refer to commit `05992cd`; re-derive them from the file you are editing.
- Track A owns: `Minute/Services/KnowledgeCatchUp.swift`, `Minute/Services/KnowledgeIngest.swift`, `Minute/Services/KnowledgeStore.swift`, `Minute/Services/KnowledgeExtractionService.swift`, `Minute/Views/BrainView.swift`, `Minute/Services/TranscriptionEngine.swift`, `Minute/Services/TranscriptionService.swift`, `Minute/Services/WhisperTranscriptionService.swift`, `Minute/Services/MLXSummarizationService.swift`, and their tests. Track B owns: `Minute/Recording/RecordingSession.swift`, `Minute/Views/MeetingListView.swift`, `Minute/Services/MeetingJobs.swift`, `Minute/Views/MeetingDetailView.swift`, `Minute/Services/AudioRecorder.swift`, `Minute/Services/AudioImporter.swift`, `Minute/Views/RecordingView.swift`, `Minute/Services/MeetingStore.swift`, `Minute/Views/SettingsView.swift`, and their tests. A task must not edit a file the other track owns.

---

## Track A — Knowledge layer and engines

### Task 1: Skip-list keyed by transcript content (F24)

**Files:**
- Modify: `Minute/Services/KnowledgeCatchUp.swift:26-29,82-88,112-116,121-129`
- Test: `MinuteTests/KnowledgeCatchUpTests.swift`

**Interfaces:**
- Consumes: `Meeting.timestampedTranscriptText`, `MeetingJobs.applyNewTranscript(_:to:)` (existing).
- Produces: private `skip(_:)` / `isSkipped(_:)` on `KnowledgeCatchUp`; `static func contentKey(for: Meeting) -> Int`.

- [ ] **Step 1: Write the failing test**

Add to `MinuteTests/KnowledgeCatchUpTests.swift` (inside the struct, after `meetingWithoutTranscriptIsLeftUnstampedAndUntouched`):

```swift
    @Test func reTranscribedMeetingIsReadAgainInTheSameSession() async throws {
        let context = try makeContext()
        let silent = Meeting(title: "Silent")
        context.insert(silent)
        try context.save()

        var calls = 0
        let catchUp = makeCatchUp { _, _ in calls += 1; return [] }
        catchUp.nudge(context: context)
        await catchUp.waitUntilIdle()
        #expect(calls == 0)   // no transcript: skipped for now

        // Re-transcription lands text and resets the cursor (MeetingJobs does
        // exactly this); the same session must read the meeting now, not
        // wait for a relaunch.
        MeetingJobs.applyNewTranscript(
            [TranscriptSegment(text: "now there is text", start: 0, end: 1)],
            to: silent
        )
        catchUp.nudge(context: context)
        await catchUp.waitUntilIdle()

        #expect(calls == 1)
        #expect(silent.knowledgeExtractedAt != nil)
    }

    @Test func failedMeetingIsRetriedOnceItsTranscriptChanges() async throws {
        let context = try makeContext()
        let meeting = meetingWithTranscript("Flaky", createdAt: .now)
        context.insert(meeting)
        try context.save()

        struct Boom: Error {}
        var calls = 0
        let catchUp = makeCatchUp { _, _ in
            calls += 1
            if calls == 1 { throw Boom() }
            return []
        }
        catchUp.nudge(context: context)
        await catchUp.waitUntilIdle()
        #expect(calls == 1)
        #expect(meeting.knowledgeExtractedAt == nil)

        // Same transcript: still skip-listed, no hot retry.
        catchUp.nudge(context: context)
        await catchUp.waitUntilIdle()
        #expect(calls == 1)

        // New transcript: a different meeting as far as the skip-list cares.
        MeetingJobs.applyNewTranscript(
            [TranscriptSegment(text: "re-transcribed line", start: 0, end: 1)],
            to: meeting
        )
        catchUp.nudge(context: context)
        await catchUp.waitUntilIdle()
        #expect(calls == 2)
        #expect(meeting.knowledgeExtractedAt != nil)
    }
```

- [ ] **Step 2: Run the suite to verify both fail**

Run: the suite command with `KnowledgeCatchUpTests`.
Expected: `reTranscribedMeetingIsReadAgainInTheSameSession` fails on `calls == 1` (actual 0); `failedMeetingIsRetriedOnceItsTranscriptChanges` fails on `calls == 2` (actual 1). All pre-existing tests in the suite still pass.

- [ ] **Step 3: Key the skip-list on content**

In `Minute/Services/KnowledgeCatchUp.swift` replace the `skippedThisSession` declaration (lines 26-29) with:

```swift
    /// Meetings that failed or were empty this session, keyed by the
    /// transcript they had at the time. Skipped, not retried hot, so one
    /// permanently-refusing meeting can't head-of-line-block the queue —
    /// but a re-transcription changes the key, so the meeting is read again
    /// in this session instead of waiting for the next launch. Cleared
    /// naturally at next launch.
    private var skippedThisSession: [UUID: Int] = [:]

    /// What the skip-list remembers a meeting by: identity plus the text
    /// the extractor would read, so new text means a new attempt.
    static func contentKey(for meeting: Meeting) -> Int {
        meeting.timestampedTranscriptText.hashValue
    }

    private func skip(_ meeting: Meeting) {
        skippedThisSession[meeting.id] = Self.contentKey(for: meeting)
    }

    private func isSkipped(_ meeting: Meeting) -> Bool {
        skippedThisSession[meeting.id] == Self.contentKey(for: meeting)
    }
```

Replace every `skippedThisSession.insert(meeting.id)` (three sites: the no-transcript branch, the permanent `GenerationError` branch, the generic `catch`) with `skip(meeting)`.

In `nextPending(context:)` replace `return pending.first { !skippedThisSession.contains($0.id) }` with `return pending.first { !isSkipped($0) }`.

- [ ] **Step 4: Run the suite to verify it passes**

Run: the suite command with `KnowledgeCatchUpTests`.
Expected: all tests pass, including the two new ones.

- [ ] **Step 5: Commit**

```bash
git add Minute/Services/KnowledgeCatchUp.swift MinuteTests/KnowledgeCatchUpTests.swift
git commit -m "fix: re-read a re-transcribed meeting in the same session instead of skip-listing it by id

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: A nudge during a cancelled loop's teardown restarts it (F26)

**Files:**
- Modify: `Minute/Services/KnowledgeCatchUp.swift:25,41-60`
- Test: `MinuteTests/KnowledgeCatchUpTests.swift`

**Interfaces:**
- Produces: `nudge(context:)` restarts after a cancelled loop finishes; `waitUntilIdle()` waits through restarts.

- [ ] **Step 1: Write the failing test**

Add to `MinuteTests/KnowledgeCatchUpTests.swift`:

```swift
    @Test func nudgeWhileAPausedLoopIsStillUnwindingRestartsTheLoop() async throws {
        let context = try makeContext()
        context.insert(meetingWithTranscript("Only", createdAt: .now))
        try context.save()

        var calls = 0
        let (firstCallStarted, startedContinuation) = AsyncStream.makeStream(of: Void.self)
        let catchUp = makeCatchUp { _, _ in
            calls += 1
            if calls == 1 {
                startedContinuation.yield(())
                // An extraction that only notices cancellation late — the
                // real one sits inside a FoundationModels call.
                try? await Task.sleep(for: .milliseconds(150))
                try Task.checkCancellation()
            }
            return []
        }
        catchUp.nudge(context: context)
        var started = firstCallStarted.makeAsyncIterator()
        _ = await started.next()
        catchUp.pause()
        // The scene flickered back to active before the loop finished
        // tearing down. This nudge must not be lost.
        catchUp.nudge(context: context)
        await catchUp.waitUntilIdle()

        #expect(calls == 2)
    }
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: the suite command with `KnowledgeCatchUpTests`.
Expected: the new test fails with `calls == 2` (actual 1). (If it hangs instead, `waitUntilIdle` is the old single-await version and the restart never happened — still a failure.)

- [ ] **Step 3: Remember a nudge that arrives mid-teardown**

In `Minute/Services/KnowledgeCatchUp.swift` replace `nudge(context:)`, `pause()` and `waitUntilIdle()` (lines 41-60) with:

```swift
    /// A nudge that arrived while a cancelled loop was still unwinding.
    /// `pause()` cancels the task but the task clears `running` itself when
    /// it finishes, and cancellation is only noticed between chunks — so a
    /// quick scene flicker (Notification Center, a call banner) would
    /// otherwise hand the restart nudge to a task that is about to exit,
    /// and nothing would run again until the next scene transition.
    private var restartRequested: ModelContext?

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
    func pause() {
        running?.cancel()
    }

    /// Test hook: resolves when the loop (and any restart it queued) has
    /// finished.
    func waitUntilIdle() async {
        while let task = running {
            await task.value
        }
    }
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: the suite command with `KnowledgeCatchUpTests`.
Expected: all pass, including `pauseStopsTheLoopAndNudgeResumes` (its `calls == 3` still holds: the pause there is followed by `waitUntilIdle` before the next nudge, so no restart is queued).

- [ ] **Step 5: Commit**

```bash
git add Minute/Services/KnowledgeCatchUp.swift MinuteTests/KnowledgeCatchUpTests.swift
git commit -m "fix: restart the catch-up loop when a nudge lands while a paused loop is still unwinding

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Model unavailability mid-loop pauses instead of skip-listing (F27)

**Files:**
- Modify: `Minute/Services/KnowledgeCatchUp.swift:103-117`
- Test: `MinuteTests/KnowledgeCatchUpTests.swift`

**Interfaces:**
- Consumes: `SummarizerError.unavailable(String)` (`Minute/Services/SummarizationService.swift:106-107`), `LanguageModelSession.GenerationError.assetsUnavailable`.

- [ ] **Step 1: Write the failing test**

Add to `MinuteTests/KnowledgeCatchUpTests.swift`:

```swift
    @Test func modelGoingUnavailableMidLoopLeavesTheQueueUntouched() async throws {
        let context = try makeContext()
        context.insert(meetingWithTranscript("A", createdAt: .now))
        context.insert(meetingWithTranscript("B", createdAt: .now.addingTimeInterval(-60)))
        try context.save()

        var available = false
        var calls = 0
        let catchUp = makeCatchUp { _, _ in
            calls += 1
            guard available else { throw SummarizerError.unavailable("Apple Intelligence isn't ready.") }
            return []
        }
        catchUp.nudge(context: context)
        await catchUp.waitUntilIdle()
        // Not this meeting's fault: stop, don't march on skip-listing B too.
        #expect(calls == 1)

        available = true
        catchUp.nudge(context: context)
        await catchUp.waitUntilIdle()
        // Neither meeting was skip-listed, so both are read on the next nudge.
        #expect(calls == 3)
    }
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: the suite command with `KnowledgeCatchUpTests`.
Expected: fails at `calls == 1` (actual 2: A was skip-listed and the loop went on to B) and at `calls == 3`.

- [ ] **Step 3: Treat unavailability like rate limiting**

In `Minute/Services/KnowledgeCatchUp.swift`, replace the three `catch` clauses at the end of the `while` loop in `run(context:)` with:

```swift
            } catch is CancellationError {
                return
            } catch let error as SummarizerError {
                // The model went away mid-loop (the per-meeting check inside
                // the extractor caught it). Not a verdict on this meeting:
                // stop without skip-listing, exactly like the availability
                // guard at the top of run(), and let the next nudge retry.
                if case .unavailable = error { return }
                skip(meeting)
            } catch let error as LanguageModelSession.GenerationError {
                // Rate limiting is the device saying "not now", not a verdict
                // on this meeting: stop without skip-listing (spec §5
                // pause-and-resume) — the next nudge retries from here.
                if case .rateLimited = error { return }
                if case .assetsUnavailable = error { return }
                // Permanent (refusal, etc.) failures skip for this session
                // and retry at next launch.
                skip(meeting)
            } catch {
                // Non-FoundationModels failures skip for this session and
                // retry at next launch.
                skip(meeting)
            }
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: the suite command with `KnowledgeCatchUpTests`.
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Minute/Services/KnowledgeCatchUp.swift MinuteTests/KnowledgeCatchUpTests.swift
git commit -m "fix: pause the catch-up loop when the model goes unavailable instead of skip-listing every meeting

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: Pending count excludes transcript-less meetings; Brain tab nudges on appear (F53, F65, F66)

**Files:**
- Modify: `Minute/Services/KnowledgeCatchUp.swift:121-136`
- Modify: `Minute/Views/BrainView.swift:33-65,201-211`
- Test: `MinuteTests/KnowledgeCatchUpTests.swift`

**Interfaces:**
- Consumes: `Meeting.hasTranscript`.
- Produces: `pendingCount` counts only meetings the loop could read.

- [ ] **Step 1: Write the failing test**

Add to `MinuteTests/KnowledgeCatchUpTests.swift`:

```swift
    @Test func meetingWithoutTranscriptIsNotCountedAsPending() async throws {
        let context = try makeContext()
        context.insert(Meeting(title: "No transcript"))
        context.insert(meetingWithTranscript("Readable", createdAt: .now))
        try context.save()

        let catchUp = makeCatchUp { _, _ in [] }
        catchUp.nudge(context: context)
        await catchUp.waitUntilIdle()

        // The Brain tab renders pendingCount as "N meetings still to read —
        // Minute catches up while it's open". A meeting that will never be
        // read (nothing to read) must not sit in that number forever.
        #expect(catchUp.pendingCount == 0)
    }
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: the suite command with `KnowledgeCatchUpTests`.
Expected: fails with `pendingCount == 0` (actual 1).

- [ ] **Step 3: Count only readable meetings**

In `Minute/Services/KnowledgeCatchUp.swift` replace `nextPending(context:)` and `refreshPendingCount(context:)` with:

```swift
    /// Unstamped meetings the loop can actually read. `segments` can't be
    /// predicated, so the transcript filter runs in memory.
    private func pendingMeetings(context: ModelContext) -> [Meeting] {
        let descriptor = FetchDescriptor<Meeting>(
            predicate: #Predicate { $0.knowledgeExtractedAt == nil },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let unstamped = (try? context.fetch(descriptor)) ?? []
        // A meeting with no transcript is deliberately left unstamped (text
        // may arrive later), but it is not "still to read" — counting it
        // shows the Brain tab a number that never goes down.
        return unstamped.filter(\.hasTranscript)
    }

    private func nextPending(context: ModelContext) -> Meeting? {
        let pending = pendingMeetings(context: context)
        pendingCount = pending.count
        return pending.first { !isSkipped($0) }
    }

    private func refreshPendingCount(context: ModelContext) {
        pendingCount = pendingMeetings(context: context).count
    }
```

The `guard meeting.hasTranscript else { skip(meeting); continue }` branch in `run(context:)` is now unreachable; delete it (and its comment). `meetingWithoutTranscriptIsLeftUnstampedAndUntouched` must still pass — it does, because a transcript-less meeting is simply never returned.

- [ ] **Step 4: Run the suite to verify it passes**

Run: the suite command with `KnowledgeCatchUpTests`.
Expected: all pass.

- [ ] **Step 5: Nudge from the Brain tab and show idle-pending work on the empty screen**

In `Minute/Views/BrainView.swift`:

Add `@Environment(\.modelContext) private var context` under `@Environment(KnowledgeCatchUp.self) private var catchUp`.

Add, after `.navigationDestination(for: KnowledgeEntity.self) { … }` inside `body`:

```swift
            // Opening the tab is the moment the user wants to see the latest
            // — refresh the pending count and pick up anything a save left
            // unread (deleting a meeting, for instance, never nudges).
            .task { catchUp.nudge(context: context) }
```

In `emptyState`, replace the `if catchUp.isWorking { … }` block with:

```swift
                // A first-run user's earliest visit likely lands mid-extraction —
                // show that the brain is being built right now, or that work is
                // waiting (warm phone, model not ready) so the screen never looks
                // dead while meetings sit unread.
                if catchUp.isWorking {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Reading your \(catchUp.pendingCount) meeting\(catchUp.pendingCount == 1 ? "" : "s") now…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 28)
                } else if catchUp.pendingCount > 0 {
                    Label("\(catchUp.pendingCount) meeting\(catchUp.pendingCount == 1 ? "" : "s") still to read — Minute catches up while it's open.",
                          systemImage: "clock")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 28)
                }
```

- [ ] **Step 6: Build and run the full unit suite**

Run: the full unit suite command.
Expected: `TEST SUCCEEDED`, count = 251 + tests added so far in this track.

- [ ] **Step 7: Commit**

```bash
git add Minute/Services/KnowledgeCatchUp.swift Minute/Views/BrainView.swift MinuteTests/KnowledgeCatchUpTests.swift
git commit -m "fix: count only readable meetings as pending and refresh the Brain tab's catch-up state on appear

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: An entity emptied by re-extraction is removed (F25)

**Files:**
- Modify: `Minute/Services/KnowledgeIngest.swift:168-172`
- Modify: `Minute/Services/KnowledgeStore.swift:109-133`
- Test: `MinuteTests/KnowledgeIngestTests.swift`, `MinuteTests/KnowledgeDeletionTests.swift`

**Interfaces:**
- Consumes: `KnowledgeEntity.facts`, `.redirectTo`, `.kind`; `KnowledgeIngest.apply` already tracks `touched` and `staleIDs`.

- [ ] **Step 1: Write the failing tests**

Add to `MinuteTests/KnowledgeIngestTests.swift`:

```swift
    @Test func reextractionThatDropsAnEntitysOnlyFactRemovesTheEntity() throws {
        let context = try makeContext()
        let meeting = Meeting(title: "m")
        context.insert(meeting)
        try KnowledgeIngest.apply([candidate("Bob", "Bob joined the Atlas team")], from: meeting, context: context)
        #expect(try context.fetch(FetchDescriptor<KnowledgeEntity>()).count == 1)

        // The re-transcribed meeting no longer mentions Bob. His only fact
        // was this meeting's still-suggested one, so it goes — and an
        // entity with nothing left to show must not linger with his name.
        try KnowledgeIngest.apply([], from: meeting, context: context)

        #expect(try context.fetch(FetchDescriptor<KnowledgeEntity>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<KnowledgeFact>()).isEmpty)
    }

    @Test func reextractionKeepsAnEntityThatStillHasFacts() throws {
        let context = try makeContext()
        let meeting = Meeting(title: "m")
        let other = Meeting(title: "other")
        context.insert(meeting)
        context.insert(other)
        try KnowledgeIngest.apply([candidate("Bob", "Bob joined the Atlas team")], from: meeting, context: context)
        try KnowledgeIngest.apply([candidate("Bob", "Bob prefers async reviews")], from: other, context: context)

        try KnowledgeIngest.apply([], from: meeting, context: context)

        let entities = try context.fetch(FetchDescriptor<KnowledgeEntity>())
        #expect(entities.count == 1)
        #expect(entities[0].facts.count == 1)
    }
```

Add to `MinuteTests/KnowledgeDeletionTests.swift` (in the "Deleting a meeting" section):

```swift
    @Test func launchReconcileRemovesAnEntityLeftWithNoFacts() throws {
        let context = try makeContext()
        // An earlier build could leave this behind: a re-extraction deleted
        // the entity's only fact and nothing examined the empty entity.
        context.insert(KnowledgeEntity(name: "Ghost", kind: .person))
        try context.save()

        #expect(KnowledgeStore.reconcile(context: context))

        #expect(try entities(in: context).isEmpty)
    }
```

- [ ] **Step 2: Run both suites to verify the new tests fail**

Run: the suite command with `KnowledgeIngestTests`, then with `KnowledgeDeletionTests`.
Expected: `reextractionThatDropsAnEntitysOnlyFactRemovesTheEntity` fails on `isEmpty` (1 entity remains); `launchReconcileRemovesAnEntityLeftWithNoFacts` fails (Ghost remains); `reextractionKeepsAnEntityThatStillHasFacts` passes already (it pins the guard).

- [ ] **Step 3: Delete emptied entities in ingest**

In `Minute/Services/KnowledgeIngest.swift`, replace the block

```swift
        for entity in touched.values {
            entity.synthesizedFactCount = nil
        }
        try context.save()
        return result
```

with:

```swift
        for entity in touched.values {
            entity.synthesizedFactCount = nil
        }
        // A re-extraction can empty an entity: a new entity only ever gets
        // `.suggested` facts, and this meeting's still-suggested facts were
        // deleted above. Nothing later would remove it — reconcile only
        // examines entities whose facts lost a source — so its name (learned
        // from this meeting) would stay on disk with nothing to show and no
        // delete path. Remove it now; a merge tombstone pointing at it, or
        // the Me entity, is left alone.
        let redirectTargets = Set(known.compactMap(\.redirectTo))
        for entity in touched.values where entity.kind != .me {
            guard entity.redirectTo == nil, !redirectTargets.contains(entity.id) else { continue }
            let remaining = entity.facts.filter { !staleIDs.contains($0.id) }
            if remaining.isEmpty {
                context.delete(entity)
            }
        }
        try context.save()
        return result
```

(`for … where` here filters on a stored property, not a side effect — the codebase's `for_where` exception is about mutation in the header.)

- [ ] **Step 4: Doom factless entities in the launch reconcile**

In `Minute/Services/KnowledgeStore.swift`, change the loop header

```swift
        for entity in allEntities where changedEntities.contains(entity.id) {
```

to

```swift
        // Also entities with no facts at all: a re-extraction in an earlier
        // build could empty one without anything examining it afterwards.
        for entity in allEntities where changedEntities.contains(entity.id) || (entity.facts.isEmpty && entity.kind != .me) {
```

The existing body already dooms an entity whose `visibleFacts` are all removed and that no live meeting backs; a factless entity takes that path.

- [ ] **Step 5: Run both suites to verify they pass**

Run: the suite command with `KnowledgeIngestTests`, then `KnowledgeDeletionTests`.
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add Minute/Services/KnowledgeIngest.swift Minute/Services/KnowledgeStore.swift MinuteTests/KnowledgeIngestTests.swift MinuteTests/KnowledgeDeletionTests.swift
git commit -m "fix: remove an entity that a re-extraction or an earlier build left with no facts

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: A re-extracted meeting's paraphrase of a fact it corroborated is a within-meeting repeat (F56)

**Files:**
- Modify: `Minute/Services/KnowledgeIngest.swift:47-68,96-102`
- Test: `MinuteTests/KnowledgeIngestTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `MinuteTests/KnowledgeIngestTests.swift`:

```swift
    @Test func reextractedParaphraseOfAFactTheMeetingCorroboratedIsNotANewDraft() throws {
        let context = try makeContext()
        let first = Meeting(title: "A", createdAt: .now.addingTimeInterval(-3600))
        let second = Meeting(title: "B", createdAt: .now)
        context.insert(first)
        context.insert(second)
        let sarah = KnowledgeEntity(name: "Sarah", kind: .person)
        context.insert(sarah)
        let fact = KnowledgeFact(
            text: "Sarah leads the Atlas redesign", originalText: "Sarah leads the Atlas redesign",
            status: .autoCaptured, sourceMeetingID: first.id, capturedAt: first.createdAt, entity: sarah
        )
        context.insert(fact)
        // Meeting B stated it too and was recorded as a second source.
        fact.addSource(FactSource(meetingID: second.id, quote: "Sarah leads the Atlas redesign", capturedAt: second.createdAt))
        try context.save()

        // B is re-transcribed and re-extracted; the model now paraphrases
        // (five of six tokens overlap — a near-duplicate, not an exact repeat).
        try KnowledgeIngest.apply(
            [candidate("Sarah", "Sarah leads the Atlas redesign work")],
            from: second, context: context
        )

        // One fact, not a second near-identical draft beside it.
        #expect(try context.fetch(FetchDescriptor<KnowledgeFact>()).count == 1)
    }
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: the suite command with `KnowledgeIngestTests`.
Expected: fails with count == 1 (actual 2).

- [ ] **Step 3: Remember which facts this meeting used to support**

In `Minute/Services/KnowledgeIngest.swift`, above the pre-loop `for fact in allFacts where …` add:

```swift
        // Facts this meeting vouched for before this re-extraction. The
        // pre-loop strips this meeting from them so the new transcript decides
        // afresh; a paraphrase of one must still count as a within-meeting
        // repeat, or it routes to review as a "cross-meeting" near-duplicate
        // and the entity page shows the same claim twice.
        var previouslySupported: Set<UUID> = []
```

Inside the `if fact.sources.count > 1 {` branch, before `fact.removeSource(meetingID: meetingID)`, add `previouslySupported.insert(fact.id)`.

In the dedup closure, change

```swift
                if existing.sourceMeetingIDs.contains(meetingID) { return true }
```

to

```swift
                if existing.sourceMeetingIDs.contains(meetingID) || previouslySupported.contains(existing.id) { return true }
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: the suite command with `KnowledgeIngestTests`.
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Minute/Services/KnowledgeIngest.swift MinuteTests/KnowledgeIngestTests.swift
git commit -m "fix: treat a re-extracted meeting's paraphrase of a fact it corroborated as a within-meeting repeat

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: "Speaker N" placeholders never become entities; entity kind is trimmed (F28, F31)

**Files:**
- Modify: `Minute/Services/KnowledgeExtractionService.swift:154-168`
- Test: `MinuteTests/KnowledgeExtractionServiceTests.swift`

**Interfaces:**
- Produces: `static func isSpeakerPlaceholder(_ name: String) -> Bool` on `KnowledgeExtractionService`.

- [ ] **Step 1: Write the failing tests**

Add to `MinuteTests/KnowledgeExtractionServiceTests.swift`:

```swift
    @Test func speakerPlaceholdersAreNeverCandidates() {
        let transcript = "[00:01] Speaker 2: I will own the Atlas redesign."
        let placeholder = KnowledgeCandidateDraft(
            entityName: "Speaker 2", entityKind: "person",
            fact: "Speaker 2 owns the Atlas redesign", supportingQuote: "I will own the Atlas redesign"
        )
        // Diarization's fallback label is not a person; two meetings' "Speaker 2"
        // are different people and must not share one Brain page.
        #expect(KnowledgeExtractionService.candidate(from: placeholder, transcript: transcript) == nil)
        #expect(KnowledgeExtractionService.isSpeakerPlaceholder("speaker 1"))
        #expect(KnowledgeExtractionService.isSpeakerPlaceholder(" Speaker  12 "))
        #expect(!KnowledgeExtractionService.isSpeakerPlaceholder("Speaker Chen"))
        #expect(!KnowledgeExtractionService.isSpeakerPlaceholder("Sarah"))
    }

    @Test func paddedEntityKindStillMapsToItsKind() {
        let transcript = "[00:01] Sarah: hi"
        let padded = KnowledgeCandidateDraft(entityName: "Sarah", entityKind: " person ", fact: "Sarah spoke", supportingQuote: "")
        #expect(KnowledgeExtractionService.candidate(from: padded, transcript: transcript)?.entityKind == .person)
    }
```

- [ ] **Step 2: Run the suite to verify they fail**

Run: the suite command with `KnowledgeExtractionServiceTests`.
Expected: `speakerPlaceholdersAreNeverCandidates` fails to compile until `isSpeakerPlaceholder` exists — add the function as a stub returning `false` first, then the test fails on the first two expectations; `paddedEntityKindStillMapsToItsKind` fails with `.topic`.

- [ ] **Step 3: Filter placeholders and trim the kind**

In `Minute/Services/KnowledgeExtractionService.swift`, replace `candidate(from:transcript:)` with:

```swift
    /// Diarization labels unnamed voices "Speaker N" (Meeting.speakerName).
    /// The transcript the extractor reads carries those labels, and the model
    /// dutifully reports facts about "Speaker 1" — but that is a different
    /// person in every meeting, so it must never resolve to a shared entity.
    static func isSpeakerPlaceholder(_ name: String) -> Bool {
        KnowledgeText.normalized(name).range(of: #"^speaker \d+$"#, options: .regularExpression) != nil
    }

    /// Trims, maps the kind (unknown → .topic), validates the quote against
    /// the transcript, and drops empty facts and placeholder speakers.
    static func candidate(from draft: KnowledgeCandidateDraft, transcript: String) -> KnowledgeCandidate? {
        let name = draft.entityName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fact = draft.fact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !fact.isEmpty, !isSpeakerPlaceholder(name) else { return nil }
        let quote = draft.supportingQuote.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawKind = draft.entityKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let kind = EntityKind(rawValue: rawKind) ?? .topic
        return KnowledgeCandidate(
            entityName: name,
            entityKind: kind == .me ? .topic : kind,
            fact: fact,
            validatedQuote: KnowledgeText.contains(transcript: transcript, quote: quote) ? quote : nil
        )
    }
```

Check `KnowledgeText.normalized` (in `Minute/Support/KnowledgeText.swift`) lowercases and collapses whitespace to single spaces; if it does not collapse internal runs, use `KnowledgeText.tokens(name).joined(separator: " ")` instead so `" Speaker  12 "` normalizes to `"speaker 12"`.

- [ ] **Step 4: Run the suite to verify it passes**

Run: the suite command with `KnowledgeExtractionServiceTests`.
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Minute/Services/KnowledgeExtractionService.swift MinuteTests/KnowledgeExtractionServiceTests.swift
git commit -m "fix: never turn a \"Speaker N\" placeholder into a Brain entity, and trim the model's entity kind

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: File transcription failures carry the engine's own explanation (F06)

**Files:**
- Modify: `Minute/Services/TranscriptionEngine.swift` (add the error type)
- Modify: `Minute/Services/WhisperTranscriptionService.swift:412-415`
- Modify: `Minute/Services/TranscriptionService.swift:157-160`
- Test: create `MinuteTests/TranscriptionUnavailableErrorTests.swift`

**Interfaces:**
- Produces: `struct TranscriptionUnavailableError: LocalizedError, Equatable { let message: String }`.

- [ ] **Step 1: Write the failing test**

Create `MinuteTests/TranscriptionUnavailableErrorTests.swift`:

```swift
import AVFoundation
import Foundation
import Testing
@testable import Minute

@MainActor
struct TranscriptionUnavailableErrorTests {
    private func makeWavFixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("unavailable-fixture-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000)!
        buffer.frameLength = 8_000
        try file.write(from: buffer)
        return url
    }

    @Test func errorSurfacesItsMessageAsTheLocalizedDescription() {
        let error = TranscriptionUnavailableError(message: "The model isn't downloaded yet.")
        // MeetingJobs and AudioImporter render localizedDescription verbatim.
        #expect(error.localizedDescription == "The model isn't downloaded yet.")
    }

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

- [ ] **Step 2: Add the type as a stub and verify the tests fail**

In `Minute/Services/TranscriptionEngine.swift`, after `TranscriptionAvailability`, add:

```swift
/// Thrown by the file path when the engine can't run, carrying the same
/// explanation `availability` shows the live path. Re-transcribe and import
/// render `localizedDescription` verbatim, so a bare framework error there
/// would hide the one sentence that tells the user what to do.
struct TranscriptionUnavailableError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}
```

Run: the suite command with `TranscriptionUnavailableErrorTests`.
Expected: `errorSurfacesItsMessage…` passes (it tests the new type); the two engine tests fail because a `CocoaError` is thrown instead. (On this simulator both engines are unavailable — Whisper has no model, Apple Speech has no `SpeechTranscriber` — so both tests exercise the throw.)

- [ ] **Step 3: Throw the explanation**

In `Minute/Services/WhisperTranscriptionService.swift` replace the guard at the top of `transcribe(file:)`:

```swift
        guard availability == .available, let whisperKit = await loadedWhisperKit() else {
            // loadedWhisperKit() has just written the actionable text into
            // availability when the load failed; prepare() wrote it when the
            // model was missing. Either way, throw that, not a bare code.
            if case .unavailable(let message) = availability {
                throw TranscriptionUnavailableError(message: message)
            }
            throw TranscriptionUnavailableError(
                message: "Whisper transcription isn't ready. Check Settings → Transcription Model, or switch back to Apple Speech."
            )
        }
```

In `Minute/Services/TranscriptionService.swift` replace the guard at the top of `transcribe(file:)`:

```swift
        guard availability == .available, let transcriber else {
            if case .unavailable(let message) = availability {
                throw TranscriptionUnavailableError(message: message)
            }
            throw TranscriptionUnavailableError(
                message: "On-device speech recognition isn't ready yet. Try again in a moment."
            )
        }
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: the suite command with `TranscriptionUnavailableErrorTests`.
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Minute/Services/TranscriptionEngine.swift Minute/Services/WhisperTranscriptionService.swift Minute/Services/TranscriptionService.swift MinuteTests/TranscriptionUnavailableErrorTests.swift
git commit -m "fix: throw the engine's own explanation when file transcription can't run

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: Local-model load failures get the friendly wrapper (F48)

**Files:**
- Modify: `Minute/Services/MLXSummarizationService.swift:253-257`

No unit test: loading a real model container needs downloaded weights, and the wrapper's behavior is a straight `catch`. Verified by build plus the full unit suite; the reviewer checks the catch ordering by reading.

- [ ] **Step 1: Wrap the container load**

In `Minute/Services/MLXSummarizationService.swift` replace

```swift
        onProgress?("Loading the summary model…")
        let container = try await loadedContainer()
```

with

```swift
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
```

Confirm `Self.logger` exists in this file (it is used at the chunk-failure log a few lines below); if the file names it differently, use that name.

- [ ] **Step 2: Build and run the full unit suite**

Run: the full unit suite command.
Expected: `TEST SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add Minute/Services/MLXSummarizationService.swift
git commit -m "fix: explain a local summary model that fails to load instead of showing a raw framework error

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Track B — Recording, jobs, and views

### Task 10: The saved default title is the one the sheet showed (F50)

**Files:**
- Modify: `Minute/Recording/RecordingSession.swift:42,58-60,184-195`
- Modify: `Minute/Views/MeetingListView.swift:12,172-176,374-377`
- Test: create `MinuteTests/RecordingSessionTitleTests.swift`

**Interfaces:**
- Produces: `RecordingSession.init(title:prefilledDefaultTitle:)` (second parameter defaults to `RecordingSession.defaultTitle()`), `static func savedTitles(draft:prefilledDefault:) -> (title: String, defaultTitle: String)`.

- [ ] **Step 1: Write the failing tests**

Create `MinuteTests/RecordingSessionTitleTests.swift`:

```swift
import Foundation
import Testing
@testable import Minute

/// The title a recording saves, and the default it is later compared against
/// when the model suggests a better one. Both must come from the same
/// string the New Meeting sheet showed: the default has minute resolution,
/// so regenerating it at save time drifted whenever the sheet stayed open
/// across a minute boundary, and the suggested title was then never adopted.
@MainActor
struct RecordingSessionTitleTests {
    @Test func untouchedDraftSavesAsItsOwnDefault() {
        let saved = RecordingSession.savedTitles(
            draft: "Meeting Sep 2, 2026 at 9:30 AM",
            prefilledDefault: "Meeting Sep 2, 2026 at 9:30 AM"
        )
        #expect(saved.title == saved.defaultTitle)
    }

    @Test func emptyDraftFallsBackToThePrefilledDefault() {
        let saved = RecordingSession.savedTitles(draft: "   ", prefilledDefault: "Meeting Sep 2, 2026 at 9:30 AM")
        #expect(saved.title == "Meeting Sep 2, 2026 at 9:30 AM")
        #expect(saved.defaultTitle == "Meeting Sep 2, 2026 at 9:30 AM")
    }

    @Test func customDraftIsTrimmedAndStillRecordsThePrefilledDefault() {
        let saved = RecordingSession.savedTitles(draft: "  Q3 roadmap  ", prefilledDefault: "Meeting Sep 2, 2026 at 9:30 AM")
        #expect(saved.title == "Q3 roadmap")
        #expect(saved.defaultTitle == "Meeting Sep 2, 2026 at 9:30 AM")
    }

    @Test func sessionKeepsThePrefilledDefaultItWasCreatedWith() {
        let session = RecordingSession(title: "Meeting Sep 2, 2026 at 9:30 AM", prefilledDefaultTitle: "Meeting Sep 2, 2026 at 9:30 AM")
        #expect(session.prefilledDefaultTitle == "Meeting Sep 2, 2026 at 9:30 AM")
    }
}
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: the suite command with `RecordingSessionTitleTests`.
Expected: compile error — `savedTitles` and `prefilledDefaultTitle` do not exist.

- [ ] **Step 3: Store the prefilled default on the session and use it at save time**

In `Minute/Recording/RecordingSession.swift`:

Replace `var title: String` (line 42) and the initializer (lines 58-60) with:

```swift
    var title: String
    /// The default the New Meeting sheet prefilled — stored, not regenerated:
    /// see `savedTitles(draft:prefilledDefault:)`.
    let prefilledDefaultTitle: String

    init(title: String, prefilledDefaultTitle: String = RecordingSession.defaultTitle()) {
        self.title = title
        self.prefilledDefaultTitle = prefilledDefaultTitle
    }
```

Replace lines 184-195 (from `let trimmedTitle = …` through the `Meeting(` initializer's `defaultTitle:` argument) so the block reads:

```swift
        let saved = Self.savedTitles(draft: title, prefilledDefault: prefilledDefaultTitle)
        let meeting = Meeting(
            title: saved.title,
            defaultTitle: saved.defaultTitle,
            createdAt: startedAt,
            duration: finishedRecording.duration,
            audioFileName: audioFileName,
            segments: finishedRecording.segments
        )
```

Add next to `static func defaultTitle(for:)`:

```swift
    /// The title to store and the default it is later compared against
    /// (MeetingJobs adopts the model's suggested title only while the two
    /// still match). The default is the exact string the sheet prefilled,
    /// never one regenerated now: both have minute resolution, so
    /// regenerating drifted whenever the sheet stayed open across a minute
    /// boundary, and the suggested title was then silently never adopted.
    static func savedTitles(draft: String, prefilledDefault: String) -> (title: String, defaultTitle: String) {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.isEmpty ? prefilledDefault : trimmed, prefilledDefault)
    }
```

In `Minute/Views/MeetingListView.swift`:

Add `@State private var draftDefaultTitle = ""` after `@State private var draftTitle = ""`.

Replace `beginNewMeeting()`:

```swift
    private func beginNewMeeting() {
        draftDefaultTitle = RecordingSession.defaultTitle()
        draftTitle = draftDefaultTitle
        showingNewMeeting = true
    }
```

In the `.sheet(isPresented: $showingNewMeeting)` closure change `activeSession = RecordingSession(title: draftTitle)` to `activeSession = RecordingSession(title: draftTitle, prefilledDefaultTitle: draftDefaultTitle)`.

The DEBUG `-DemoOpenRecorder` path's `RecordingSession(title: "Weekly Product Sync")` keeps working through the default argument.

- [ ] **Step 4: Run the suite to verify it passes, then the full unit suite**

Run: the suite command with `RecordingSessionTitleTests`; then the full unit suite command.
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Minute/Recording/RecordingSession.swift Minute/Views/MeetingListView.swift MinuteTests/RecordingSessionTitleTests.swift
git commit -m "fix: save the default title the New Meeting sheet showed so a suggested title can still replace it

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 11: A saved recording or import nudges the Brain (F29)

**Files:**
- Modify: `Minute/Views/MeetingListView.swift:8-9,180-188,402-420,544-550`

View wiring only; `KnowledgeCatchUp.nudge` is already covered by `KnowledgeCatchUpTests`. Verified by build plus the full unit suite.

- [ ] **Step 1: Nudge where meetings are created**

In `Minute/Views/MeetingListView.swift`:

Add `@Environment(KnowledgeCatchUp.self) private var catchUp` under `@Environment(\.modelContext) private var context`.

In the `.fullScreenCover(item: $activeSession)` closure, replace the `if let finished { … }` block with:

```swift
                if let finished {
                    destinationAutoSummarizes = AppSettings.autoSummarizeEnabled
                    meetingDestination = finished
                    // The loop is otherwise only nudged by a finished job or a
                    // scene activation; with Auto-Summarize off (the default)
                    // neither happens, and the Brain never reads this meeting
                    // until the app is backgrounded and reopened.
                    catchUp.nudge(context: context)
                }
```

In `startImport(_:)`, after `meetingDestination = result.meeting`, add:

```swift
                catchUp.nudge(context: context)
```

In the `#Preview` at the bottom, add `.environment(KnowledgeCatchUp())` after `.environment(MeetingJobs())`.

- [ ] **Step 2: Build and run the full unit suite**

Run: the full unit suite command.
Expected: `TEST SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add Minute/Views/MeetingListView.swift
git commit -m "fix: nudge the Brain's catch-up loop when a recording is saved or audio is imported

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 12: Automatic summarization fires once per meeting (F16)

**Files:**
- Modify: `Minute/Services/MeetingJobs.swift:43-45,74-76`
- Modify: `Minute/Views/MeetingDetailView.swift:202-212`
- Test: `MinuteTests/SummaryGenerationTests.swift`

**Interfaces:**
- Produces: `func claimAutoSummary(for meeting: Meeting) -> Bool` on `MeetingJobs`.

- [ ] **Step 1: Write the failing tests**

Add to `MinuteTests/SummaryGenerationTests.swift`:

```swift
    @Test func autoSummaryIsClaimedOnlyOncePerMeeting() throws {
        let (container, meeting) = try makeMeeting()
        defer { _ = container }
        let jobs = MeetingJobs()

        // The detail view's .task re-runs on every re-appearance (tab switch,
        // a cover dismissed over it). Automatic generation must not restart
        // one the user stopped: first ask wins, every later ask is refused.
        #expect(jobs.claimAutoSummary(for: meeting))
        #expect(!jobs.claimAutoSummary(for: meeting))

        let other = Meeting(title: "Other")
        container.mainContext.insert(other)
        #expect(jobs.claimAutoSummary(for: other))
    }

    @Test func autoSummaryIsNotClaimedWhileAFailureIsShowing() async throws {
        let (container, meeting) = try makeMeeting()
        defer { _ = container }
        let jobs = MeetingJobs()

        // No transcript: the job fails fast and records an error.
        await jobs.summarize(meeting, template: .standard, context: "", language: nil)?.value
        #expect(jobs.error(.summary, for: meeting) != nil)

        // A failed generation is retried only by an explicit tap; restarting
        // it automatically would also wipe the error the user should read.
        #expect(!jobs.claimAutoSummary(for: meeting))
    }
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: the suite command with `SummaryGenerationTests`.
Expected: compile error — `claimAutoSummary` does not exist.

- [ ] **Step 3: Add the claim**

In `Minute/Services/MeetingJobs.swift`, after `private var failures: [UUID: Failure] = [:]` add:

```swift
    /// Meetings whose one automatic summary has been requested this run.
    private var autoSummaryClaimed: Set<UUID> = []
```

After `func cancel(_ meeting: Meeting)` add:

```swift
    /// Whether an automatic (post-save) summary may start now. True exactly
    /// once per meeting while the app runs, and never while that meeting's
    /// summary failure is showing: the detail view's `.task` re-runs on every
    /// re-appearance, and an automatic generation must not restart one the
    /// user stopped or wipe the error from one that failed. An explicit tap
    /// goes through `summarize` directly and is unaffected.
    func claimAutoSummary(for meeting: Meeting) -> Bool {
        guard !autoSummaryClaimed.contains(meeting.id), error(.summary, for: meeting) == nil else {
            return false
        }
        autoSummaryClaimed.insert(meeting.id)
        return true
    }
```

In `Minute/Views/MeetingDetailView.swift` replace the `.task { … }` block (lines 202-212) with:

```swift
        .task {
            guard meeting.summary == nil, meeting.hasTranscript,
                  SummarizationEngines.availabilityMessage == nil else { return }
            if autoGenerateSummary, jobs.claimAutoSummary(for: meeting) {
                generateSummary()
            } else {
                // The user will probably tap Generate; start loading the
                // model now so the tap doesn't pay the model-load wait too.
                SummarizationEngines.prewarm(language: AppSettings.summaryLanguage)
            }
        }
```

- [ ] **Step 4: Run the suite to verify it passes, then the full unit suite**

Run: the suite command with `SummaryGenerationTests`; then the full unit suite command.
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Minute/Services/MeetingJobs.swift Minute/Views/MeetingDetailView.swift MinuteTests/SummaryGenerationTests.swift
git commit -m "fix: run the automatic summary once per meeting instead of on every re-appearance of the detail view

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 13: An empty transcription result is reported, not applied (F17, F09)

**Files:**
- Modify: `Minute/Services/MeetingJobs.swift:119-135`
- Modify: `Minute/Services/AudioImporter.swift:38-42,84-85`
- Test: `MinuteTests/SummaryGenerationTests.swift`, `MinuteTests/AudioImporterTests.swift`

**Interfaces:**
- Produces: `static func noTextMessage(keptExistingTranscript: Bool) -> String` on `MeetingJobs`; `AudioImporter.importAudio(from:context:transcription:)` with a defaulted third parameter; `static let noSpeechNote: String` on `AudioImporter`.

- [ ] **Step 1: Write the failing tests**

Add to `MinuteTests/SummaryGenerationTests.swift`:

```swift
    @Test func noTextMessageSaysWhetherTheOldTranscriptWasKept() {
        let kept = MeetingJobs.noTextMessage(keptExistingTranscript: true)
        let fresh = MeetingJobs.noTextMessage(keptExistingTranscript: false)
        #expect(kept.contains("existing transcript was kept"))
        #expect(!fresh.contains("kept"))
        #expect(fresh.hasPrefix("Re-transcription produced no text"))
    }
```

Add to `MinuteTests/AudioImporterTests.swift` (inside the struct):

```swift
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

    @Test func importWithNoRecognizedSpeechExplainsItself() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let source = try makeWavFixture()
        defer { try? FileManager.default.removeItem(at: source) }

        let result = try await AudioImporter.importAudio(
            from: source, context: context, transcription: EmptyTranscriptionEngine()
        )

        // The meeting is kept (the audio is worth having), but the user must
        // hear that nothing was recognized rather than assume the file is silent.
        #expect(result.meeting.segments.isEmpty)
        #expect(result.transcriptionNote == AudioImporter.noSpeechNote)

        MeetingStore.delete(result.meeting, context: context)
    }
```

- [ ] **Step 2: Run both suites to verify they fail**

Run: the suite command with `SummaryGenerationTests`, then `AudioImporterTests`.
Expected: both fail to compile (`noTextMessage`, the `transcription:` parameter, and `noSpeechNote` do not exist).

- [ ] **Step 3: Report empty results**

In `Minute/Services/MeetingJobs.swift` replace the `guard !segments.isEmpty || !meeting.hasTranscript else { … }` block in `retranscribe` with:

```swift
            // A pass that produced nothing — the device language no longer
            // matching the audio, say — must not be mistaken for "this meeting
            // has no speech". Applying it would either destroy the only copy
            // the user has, or silently leave a transcript-less meeting
            // looking exactly as it did before they asked.
            guard !segments.isEmpty else {
                throw JobMessage(message: Self.noTextMessage(keptExistingTranscript: meeting.hasTranscript))
            }
```

After `applyNewTranscript(_:to:)` add:

```swift
    /// Why an empty re-transcription is reported instead of applied. The
    /// language hint only applies to Apple Speech; Whisper auto-detects.
    static func noTextMessage(keptExistingTranscript: Bool) -> String {
        let kept = keptExistingTranscript ? ", so the existing transcript was kept" : ""
        let hint = AppSettings.transcriptionEngine == .appleSpeech
            ? " Check that the iPhone's language matches the language spoken in this meeting."
            : ""
        return "Re-transcription produced no text\(kept)." + hint
    }
```

In `Minute/Services/AudioImporter.swift`:

Change the signature of `importAudio` and its first line:

```swift
    static func importAudio(
        from sourceURL: URL,
        context: ModelContext,
        transcription: any TranscriptionEngine = TranscriptionEngines.current()
    ) async throws -> Result {
        let scoped = sourceURL.startAccessingSecurityScopedResource()
```

(delete the old `let transcription = TranscriptionEngines.current()` line.)

Add after `struct Result { … }`:

```swift
    /// Shown when the engine ran and recognized nothing: the meeting is still
    /// saved, but "no transcript" must not read as "no speech".
    static let noSpeechNote = "The audio was imported, but no speech was recognized in it. If the recording is in another language, check the iPhone's language or the transcription engine in Settings, then use Re-transcribe Audio."
```

In the `.available` case, replace `segments = try await transcription.transcribe(file: audioFile)` with:

```swift
                segments = try await transcription.transcribe(file: audioFile)
                if segments.isEmpty {
                    transcriptionNote = Self.noSpeechNote
                }
```

- [ ] **Step 4: Run both suites to verify they pass, then the full unit suite**

Run: the suite command with `SummaryGenerationTests`, then `AudioImporterTests`, then the full unit suite command.
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Minute/Services/MeetingJobs.swift Minute/Services/AudioImporter.swift MinuteTests/SummaryGenerationTests.swift MinuteTests/AudioImporterTests.swift
git commit -m "fix: report a transcription pass that produced no text instead of applying it silently

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 14: Speaker identification and renaming tell the Brain, and re-identify asks first (F18, F19, F58)

**Files:**
- Modify: `Minute/Services/MeetingJobs.swift:139-153,192-200`
- Modify: `Minute/Views/MeetingDetailView.swift:29-35,133-139,183-194,588-596`
- Test: `MinuteTests/SpeakerAssignmentTests.swift` (add a new struct at the bottom of the file)

**Interfaces:**
- Consumes: `SpeakerRange` (`Minute/Support/SpeakerAssignment.swift:4-8`), `SpeakerAssignment.apply(_:to:)`, `MeetingJobs.JobMessage`.
- Produces: `static func applySpeakerIdentification(_ ranges: [SpeakerRange], to meeting: Meeting) throws` and `static func applySpeakerName(_ name: String, at index: Int, to meeting: Meeting)` on `MeetingJobs`.

- [ ] **Step 1: Write the failing tests**

Append to `MinuteTests/SpeakerAssignmentTests.swift` (a second struct in the same file; keep the existing one untouched):

```swift
@MainActor
struct SpeakerJobApplicationTests {
    private func meeting() -> Meeting {
        let meeting = Meeting(
            title: "m",
            segments: [
                TranscriptSegment(text: "one", start: 0, end: 2),
                TranscriptSegment(text: "two", start: 2, end: 4),
            ]
        )
        meeting.speakerNames = ["Priya", "Diego"]
        meeting.knowledgeExtractedAt = .now
        return meeting
    }

    @Test func identificationLabelsSegmentsClearsNamesAndResetsTheExtractionCursor() throws {
        let meeting = meeting()
        try MeetingJobs.applySpeakerIdentification(
            [SpeakerRange(speaker: 7, start: 0, end: 2), SpeakerRange(speaker: 3, start: 2, end: 4)],
            to: meeting
        )
        #expect(meeting.segments.map(\.speaker) == [0, 1])
        // A fresh identification renumbers from scratch, so old names no
        // longer describe anyone.
        #expect(meeting.speakerNames == nil)
        // The Brain reads speaker labels; it must re-read this meeting.
        #expect(meeting.knowledgeExtractedAt == nil)
    }

    @Test func identificationThatLabelsNothingThrowsAndLeavesTheMeetingAlone() {
        let meeting = meeting()
        #expect(throws: MeetingJobs.JobMessage.self) {
            try MeetingJobs.applySpeakerIdentification([SpeakerRange(speaker: 0, start: 100, end: 101)], to: meeting)
        }
        #expect(meeting.speakerNames == ["Priya", "Diego"])
        #expect(meeting.knowledgeExtractedAt != nil)
    }

    @Test func renamingASpeakerTrimsTheNameAndResetsTheExtractionCursor() {
        let meeting = meeting()
        MeetingJobs.applySpeakerName("  Sarah Chen ", at: 1, to: meeting)
        #expect(meeting.speakerNames == ["Priya", "Sarah Chen"])
        #expect(meeting.knowledgeExtractedAt == nil)
    }

    @Test func renamingPadsMissingEntries() {
        let meeting = Meeting(title: "m")
        MeetingJobs.applySpeakerName("Mei", at: 2, to: meeting)
        #expect(meeting.speakerNames == ["", "", "Mei"])
    }
}
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: the suite command with `SpeakerJobApplicationTests`.
Expected: compile error — the two static functions do not exist.

- [ ] **Step 3: Move the mutations into testable helpers**

In `Minute/Services/MeetingJobs.swift`, after `applyNewTranscript(_:to:)` add:

```swift
    /// Applies diarization output: labels segments, drops names attached to
    /// the previous numbering (a fresh identification renumbers from
    /// scratch), and resets the extraction cursor so the Brain re-reads the
    /// meeting with speakers attributed. Throws when nothing was labeled, so
    /// the user hears that instead of watching the spinner vanish over an
    /// unchanged transcript.
    static func applySpeakerIdentification(_ ranges: [SpeakerRange], to meeting: Meeting) throws {
        let labeled = SpeakerAssignment.apply(ranges, to: meeting.segments)
        guard labeled.contains(where: { $0.speaker != nil }) else {
            throw JobMessage(message: "No distinct speakers could be identified in this recording.")
        }
        meeting.segments = labeled
        meeting.speakerNames = nil
        meeting.knowledgeExtractedAt = nil
    }

    /// Sets one speaker's display name. The Brain reads the transcript with
    /// names in it, so a rename resets the extraction cursor: facts about
    /// "Speaker 2" become facts about the person.
    static func applySpeakerName(_ name: String, at index: Int, to meeting: Meeting) {
        var names = meeting.speakerNames ?? []
        while names.count <= index {
            names.append("")
        }
        names[index] = name.trimmingCharacters(in: .whitespacesAndNewlines)
        meeting.speakerNames = names
        meeting.knowledgeExtractedAt = nil
    }
```

In `identifySpeakers(_:audioAt:)` replace

```swift
            guard !meeting.isDeleted else { return }
            meeting.segments = SpeakerAssignment.apply(ranges, to: meeting.segments)
            // A fresh identification renumbers speakers from scratch, so names
            // attached to the previous numbering no longer describe anyone.
            meeting.speakerNames = nil
            try? meeting.modelContext?.save()
```

with

```swift
            guard !meeting.isDeleted else { return }
            try MeetingJobs.applySpeakerIdentification(ranges, to: meeting)
            try? meeting.modelContext?.save()
```

In `Minute/Views/MeetingDetailView.swift`:

Replace the body of `renameSpeaker(_:to:)` with:

```swift
    private func renameSpeaker(_ index: Int, to name: String) {
        MeetingJobs.applySpeakerName(name, at: index, to: meeting)
        saveQuietly()
        // The rename changed the text the Brain reads; let it catch up.
        jobs.onContentChanged?()
    }
```

Add `@State private var confirmingReidentify = false` next to `confirmingRetranscribe`.

Replace the Identify Speakers menu button's action:

```swift
                    Button {
                        if meeting.hasSpeakers {
                            confirmingReidentify = true
                        } else {
                            identifySpeakers()
                        }
                    } label: {
                        Label(meeting.hasSpeakers ? "Re-identify Speakers" : "Identify Speakers",
                              systemImage: "person.2.wave.2")
                    }
```

After the re-transcribe `.confirmationDialog(…)` add:

```swift
        .confirmationDialog(
            "Re-identify speakers?",
            isPresented: $confirmingReidentify,
            titleVisibility: .visible
        ) {
            Button("Re-identify Speakers") {
                identifySpeakers()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Speakers are numbered again from scratch, and any names you entered are cleared.")
        }
```

- [ ] **Step 4: Run the suite to verify it passes, then the full unit suite**

Run: the suite command with `SpeakerJobApplicationTests`; then the full unit suite command.
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Minute/Services/MeetingJobs.swift Minute/Views/MeetingDetailView.swift MinuteTests/SpeakerAssignmentTests.swift
git commit -m "fix: re-read a meeting in the Brain after speakers are identified or renamed, report an empty identification, and confirm before re-identifying

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 15: The detail view is keyed to its meeting and survives that meeting's deletion (F22, F38)

**Files:**
- Modify: `Minute/Views/MeetingListView.swift:109-111`
- Modify: `Minute/Views/MeetingDetailView.swift:66-217`

View restructuring; no unit test is possible. Verified by build plus the full unit suite; the reviewer checks that no property of a deleted model is read outside the guard.

- [ ] **Step 1: Key the programmatic destination to the meeting**

In `Minute/Views/MeetingListView.swift` change the `navigationDestination(item:)` closure to:

```swift
            .navigationDestination(item: $meetingDestination) { meeting in
                // Keyed so replacing the destination in place (a widget link
                // while a detail is up, a recording finishing under one)
                // builds a fresh view instead of reusing the old one's player,
                // tab, and auto-summary state for a different meeting.
                MeetingDetailView(meeting: meeting, autoGenerateSummary: destinationAutoSummarizes)
                    .id(meeting.id)
            }
```

- [ ] **Step 2: Guard the detail view against a deleted meeting**

In `Minute/Views/MeetingDetailView.swift`, restructure `body` so that every read of `meeting` sits behind an `isDeleted` check. Rename the current `body` contents to a private `page` property and make `body`:

```swift
    var body: some View {
        Group {
            if meeting.isDeleted {
                // The same meeting can be open in two stacks — the Brain tab
                // pushes a detail from a fact's source link — and deleted from
                // the other one. Reading any property of a deleted model is
                // unsafe, so this branch comes before the page, the title,
                // and the tasks below.
                ContentUnavailableView {
                    Label("Meeting Deleted", systemImage: "trash")
                } description: {
                    Text("This meeting was deleted from this iPhone.")
                }
            } else {
                page
            }
        }
        .navigationTitle(meeting.isDeleted ? "" : meeting.createdAt.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !meeting.isDeleted, meeting.summary == nil, meeting.hasTranscript,
                  SummarizationEngines.availabilityMessage == nil else { return }
            if autoGenerateSummary, jobs.claimAutoSummary(for: meeting) {
                generateSummary()
            } else {
                // The user will probably tap Generate; start loading the
                // model now so the tap doesn't pay the model-load wait too.
                SummarizationEngines.prewarm(language: AppSettings.summaryLanguage)
            }
        }
        .onDisappear {
            player.stop()
            if !meeting.isDeleted {
                saveQuietly()
            }
        }
    }

    /// The page for a live meeting: the ScrollView with masthead, brief,
    /// tabs, and the toolbar, sheets, and dialogs that read the meeting.
    private var page: some View {
        ScrollView {
            …everything that was in body up to and including `.scrollEdgeEffectStyle(.soft, for: .all)`…
        }
        .toolbar { … }
        .sheet(isPresented: $showingEditor) { … }
        .confirmationDialog("Delete this meeting?", …) { … }
        .alert("This meeting couldn't be deleted", …) { … }
        .confirmationDialog("Re-transcribe this meeting?", …) { … }
        .confirmationDialog("Re-identify speakers?", …) { … }
        .alert("Rename Speaker", …) { … }
    }
```

Concretely: move `.toolbar`, `.sheet`, both `.confirmationDialog`s (three after Task 14), both `.alert`s onto `page`; keep `.navigationTitle`, `.navigationBarTitleDisplayMode`, `.task`, `.onDisappear` on `body`. The `.task` body is the Task 12 version plus the leading `!meeting.isDeleted` check. Do not change any other behavior.

- [ ] **Step 3: Build and run the full unit suite**

Run: the full unit suite command.
Expected: `TEST SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add Minute/Views/MeetingListView.swift Minute/Views/MeetingDetailView.swift
git commit -m "fix: rebuild the meeting detail when its destination changes, and show a placeholder once the meeting is deleted

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 16: Deleting asks first, everywhere, and stops the meeting's running job (F63, F03, F20)

**Files:**
- Modify: `Minute/Views/MeetingListView.swift:26,205-227,248-252`
- Modify: `Minute/Views/MeetingDetailView.swift:159-173`
- Modify: `Minute/Views/SettingsView.swift:10-12,465-476,507-510`
- Modify: `Minute/Views/RecordingView.swift:115-121`

View wiring; `MeetingJobs.cancel` and `MeetingStore.delete` are already tested. Verified by build plus the full unit suite.

- [ ] **Step 1: Confirm list deletes, and cancel the job first**

In `Minute/Views/MeetingListView.swift`:

Add `@Environment(MeetingJobs.self) private var jobs` under the `catchUp` environment.

Add `@State private var pendingDelete: Meeting?` after `@State private var deleteFailed = false`.

Change both delete actions (swipe and context menu) from `deleteFailed = !MeetingStore.delete(meeting, context: context)` to `pendingDelete = meeting`.

Replace the `.alert("This meeting couldn't be deleted", …)` modifier on the list with:

```swift
        .confirmationDialog(
            "Delete this meeting?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { meeting in
            Button("Delete Meeting", role: .destructive) {
                deleteMeeting(meeting)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The recording, transcript, summary, and everything Brain learned from this meeting will be permanently deleted from this iPhone.")
        }
        .alert("This meeting couldn't be deleted", isPresented: $deleteFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Storage may be full or unavailable. Free up space and try again.")
        }
```

Add a helper next to `beginNewMeeting()`:

```swift
    private func deleteMeeting(_ meeting: Meeting) {
        // A summary or re-transcription still running on this meeting would
        // keep decoding a deleted file for minutes; stop it first.
        jobs.cancel(meeting)
        deleteFailed = !MeetingStore.delete(meeting, context: context)
    }
```

In `Minute/Views/MeetingDetailView.swift`, in the "Delete this meeting?" dialog's destructive button, add `jobs.cancel(meeting)` as the first line before `if MeetingStore.delete(meeting, context: context) {`.

In `Minute/Views/SettingsView.swift`:

Add `@Environment(MeetingJobs.self) private var jobs` under `@Environment(\.modelContext) private var context`.

In `deleteAllMeetings()`, inside the loop, add `jobs.cancel(meeting)` before the `if !MeetingStore.delete(meeting, context: context)` line.

In the `#Preview` at the bottom add `.environment(MeetingJobs())` after `.modelContainer(MeetingStore.previewContainer())`.

- [ ] **Step 2: Confirm the failed-state Discard when audio was captured**

In `Minute/Views/RecordingView.swift` replace the failed-state Discard/Close button (lines 115-121) with:

```swift
                    Button(session.didStartRecording ? "Discard" : "Close", role: .destructive) {
                        if session.didStartRecording {
                            // Captured audio deserves the same confirmation the
                            // toolbar Discard has; this button sits 12pt from
                            // Save Recording.
                            confirmingDiscard = true
                        } else {
                            Task {
                                await session.discard()
                                onFinish(nil)
                            }
                        }
                    }
                    .buttonStyle(.bordered)
```

- [ ] **Step 3: Build and run the full unit suite**

Run: the full unit suite command.
Expected: `TEST SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add Minute/Views/MeetingListView.swift Minute/Views/MeetingDetailView.swift Minute/Views/SettingsView.swift Minute/Views/RecordingView.swift
git commit -m "fix: confirm before deleting from the list or discarding captured audio, and stop a meeting's running job when it is deleted

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 17: A failed manual Resume keeps the interruption's auto-resume armed (F01)

**Files:**
- Modify: `Minute/Services/AudioRecorder.swift:374-401`

No unit test: reaching `.paused` with `pausedByInterruption` set requires a live audio engine and a system interruption. Verified by build plus the full unit suite; the reviewer checks that every throwing path restores the flag.

- [ ] **Step 1: Restore ownership on failure**

In `Minute/Services/AudioRecorder.swift` replace `resume()` with:

```swift
    func resume() throws {
        guard state == .paused else { return }
        // Retire interruption ownership only once the resume succeeds. The
        // notice tells the user to tap Resume, and a tap while the call still
        // holds the microphone throws below; clearing first would also cancel
        // the automatic resume the interruption's `.ended` is about to offer,
        // and the rest of the meeting would silently go uncaptured.
        let wasInterrupted = pausedByInterruption
        pausedByInterruption = false
        // An interruption deactivates the session; reactivate before
        // restarting the engine or start() throws.
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            pausedByInterruption = wasInterrupted
            throw error
        }
        // Give writes another chance after resume (the user may have freed space).
        didReportWriteError = false
        // The hardware format may have changed while paused (route change) —
        // reinstall the tap so it matches, avoiding a format-mismatch crash.
        engine.inputNode.removeTap(onBus: 0)
        do {
            try installTap()
            try engine.start()
        } catch {
            pausedByInterruption = wasInterrupted
            // Resume failed after the session was reactivated above — release
            // it so other apps' audio isn't left interrupted while we stay
            // paused; the next resume attempt reactivates it.
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                Self.logger.error("Deactivating session after failed resume failed: \(error.localizedDescription)")
            }
            throw error
        }
        segmentStartedAt = Date()
        state = .recording
    }
```

- [ ] **Step 2: Build and run the full unit suite**

Run: the full unit suite command.
Expected: `TEST SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add Minute/Services/AudioRecorder.swift
git commit -m "fix: keep the interruption's automatic resume armed when a manual Resume fails during the call

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 18: The launch orphan sweep reads the store itself (F37)

**Files:**
- Modify: `Minute/Services/MeetingStore.swift:232-249`
- Modify: `Minute/Views/MeetingListView.swift:122-134`
- Test: `MinuteTests/MeetingStoreTests.swift`

**Interfaces:**
- Produces: `static func referencedAudioFileNames(context: ModelContext) -> Set<String>?` on `MeetingStore`.

- [ ] **Step 1: Write the failing test**

Add to `MinuteTests/MeetingStoreTests.swift`:

```swift
    @Test func referencedAudioFileNamesListsEveryStoredMeetingsFile() throws {
        let container = try ModelContainer(
            for: Meeting.self,
            configurations: MeetingStore.modelConfiguration(inMemory: true)
        )
        let context = container.mainContext
        context.insert(Meeting(title: "A", audioFileName: "a.m4a"))
        context.insert(Meeting(title: "B", audioFileName: "b.wav"))
        context.insert(Meeting(title: "No audio"))
        try context.save()

        // The launch sweep deletes every recording NOT in this set, so it
        // must come from a fetch that can say "I failed" — never from a view
        // query whose failure reads as an empty library.
        #expect(MeetingStore.referencedAudioFileNames(context: context) == ["a.m4a", "b.wav"])
    }
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: the suite command with `MeetingStoreTests`.
Expected: compile error — `referencedAudioFileNames` does not exist.

- [ ] **Step 3: Fetch with a failure signal**

In `Minute/Services/MeetingStore.swift`, above `removeOrphanedAudio(referencedFileNames:in:)` add:

```swift
    /// The audio files the library still references, or nil when the store
    /// couldn't be read. The launch sweep deletes everything NOT in this set,
    /// so a failed read must never be mistaken for an empty library — the
    /// knowledge sweep already refuses to run on one, and the audio sweep
    /// must too.
    static func referencedAudioFileNames(context: ModelContext) -> Set<String>? {
        do {
            let meetings = try context.fetch(FetchDescriptor<Meeting>())
            return Set(meetings.compactMap(\.audioFileName))
        } catch {
            logger.error("Could not read the library before sweeping orphaned audio, so nothing was swept: \(error.localizedDescription)")
            return nil
        }
    }
```

In `Minute/Views/MeetingListView.swift` replace the `.task { … }` sweep block with:

```swift
        .task {
            // Clean up audio left behind by a crash mid-recording — but never
            // while running on the fallback store, where meetings that
            // reference these files may still exist in the real database.
            guard !storeIsEphemeral, !didSweepOrphans else { return }
            didSweepOrphans = true
            // Its own fetch, not the view's @Query: a query whose fetch failed
            // is silently empty, and an empty referenced set would delete
            // every recording in the library.
            if let referenced = MeetingStore.referencedAudioFileNames(context: context) {
                MeetingStore.removeOrphanedAudio(referencedFileNames: referenced)
            }
            // Same idea for the knowledge base: drops support left by meetings
            // deleted before this existed, and by any earlier pass whose save
            // failed. Runs on the same guard, so it never touches the fallback
            // store, where the meetings backing these facts still exist.
            KnowledgeStore.reconcile(context: context)
        }
```

- [ ] **Step 4: Run the suite to verify it passes, then the full unit suite**

Run: the suite command with `MeetingStoreTests`; then the full unit suite command.
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Minute/Services/MeetingStore.swift Minute/Views/MeetingListView.swift MinuteTests/MeetingStoreTests.swift
git commit -m "fix: sweep orphaned audio from a fetch that can fail instead of a view query that reads as empty

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Deferred to batch 2 (not in this plan)

F05/F11 (Hugging Face after Get: tokenizer folder, commit-pinned MLX revision), F13/F12 (app-wide local-model gate, mechanical merge fallback), F69/F02 (persist the meeting before finalizing the transcript, "save without transcript"), F57 (refused-chunk count leaves the meeting unstamped), F59 (thermal / rate-limit resume trigger), F47 (foreground mirror skips meetings deleted since its snapshot), F34/F35 (file-protection class), F68 (fallback store exit), F45 (download keep-alive), F07 (Whisper language pin), F15/F52 (placeholder normalization, editor pipe parsing), F10/F62, F39/F44, F40/F64, F14/F41/F08/F67, F21, F49/F71/F70/F72, F04/F46/F42/F73, F23/F55, F60, F36/F54.
