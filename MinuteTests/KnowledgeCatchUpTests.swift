import Foundation
import FoundationModels
import SwiftData
import Testing
@testable import Minute

@MainActor
struct KnowledgeCatchUpTests {
    /// Containers are retained for the process lifetime: ModelContainer
    /// teardown is not actor-isolated, and a container deiniting in the
    /// background while another test runs crashes the test host inside
    /// SwiftData.framework. Tests still get a fresh, isolated container
    /// each — they just never tear it down mid-run. Pattern copied from
    /// MinuteTests/KnowledgeSchemaTests.swift.
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

    /// CI simulators have no Apple Intelligence; every loop test injects an
    /// always-available model so the availability gate never no-ops them.
    /// Tests OF the gate construct KnowledgeCatchUp directly instead.
    private func makeCatchUp(_ extract: @escaping KnowledgeCatchUp.Extractor) -> KnowledgeCatchUp {
        KnowledgeCatchUp(availabilityMessage: { nil }, extract: extract)
    }

    private func meetingWithTranscript(_ title: String, createdAt: Date) -> Meeting {
        Meeting(
            title: title, createdAt: createdAt,
            segments: [TranscriptSegment(text: "\(title) transcript line", start: 0, end: 1)]
        )
    }

    @Test func processesUnstampedMeetingsNewestFirstAndStamps() async throws {
        let context = try makeContext()
        let old = meetingWithTranscript("Old", createdAt: .now.addingTimeInterval(-3600))
        let new = meetingWithTranscript("New", createdAt: .now)
        context.insert(old)
        context.insert(new)
        try context.save()

        var order: [String] = []
        let catchUp = makeCatchUp {transcript, _ in
            order.append(transcript.contains("New") ? "New" : "Old")
            return KnowledgeExtractionResult(candidates: [
                KnowledgeCandidate(entityName: "Sarah", entityKind: .person, fact: "Sarah spoke", validatedQuote: nil),
            ])
        }
        catchUp.nudge(context: context)
        await catchUp.waitUntilIdle()

        #expect(order == ["New", "Old"])
        #expect(new.knowledgeExtractedAt != nil)
        #expect(old.knowledgeExtractedAt != nil)
    }

    @Test func failedMeetingIsSkippedWithoutStampAndLoopContinues() async throws {
        let context = try makeContext()
        let failing = meetingWithTranscript("Failing", createdAt: .now)
        let fine = meetingWithTranscript("Fine", createdAt: .now.addingTimeInterval(-60))
        context.insert(failing)
        context.insert(fine)
        try context.save()

        struct Boom: Error {}
        let catchUp = makeCatchUp {transcript, _ in
            if transcript.contains("Failing") { throw Boom() }
            return .empty
        }
        catchUp.nudge(context: context)
        await catchUp.waitUntilIdle()

        #expect(failing.knowledgeExtractedAt == nil)   // retried next launch
        #expect(fine.knowledgeExtractedAt != nil)      // not blocked behind the failure

        // Within this instance the failure is remembered — no hot retry loop.
        catchUp.nudge(context: context)
        await catchUp.waitUntilIdle()
        #expect(failing.knowledgeExtractedAt == nil)
    }

    @Test func meetingWithoutTranscriptIsLeftUnstampedAndUntouched() async throws {
        let context = try makeContext()
        let silent = Meeting(title: "Recording in progress")
        context.insert(silent)
        try context.save()

        var calls = 0
        let catchUp = makeCatchUp {_, _ in calls += 1; return .empty }
        catchUp.nudge(context: context)
        await catchUp.waitUntilIdle()

        #expect(calls == 0)
        #expect(silent.knowledgeExtractedAt == nil)
    }

    @Test func meetingWithoutTranscriptIsNotCountedAsPending() async throws {
        let context = try makeContext()
        context.insert(Meeting(title: "No transcript"))
        context.insert(meetingWithTranscript("Readable", createdAt: .now))
        try context.save()

        let catchUp = makeCatchUp { _, _ in .empty }
        catchUp.nudge(context: context)
        await catchUp.waitUntilIdle()

        // The Brain tab renders pendingCount as "N meetings still to read —
        // Minute catches up while it's open". A meeting that will never be
        // read (nothing to read) must not sit in that number forever.
        #expect(catchUp.pendingCount == 0)
    }

    @Test func reTranscribedMeetingIsReadAgainInTheSameSession() async throws {
        let context = try makeContext()
        let silent = Meeting(title: "Silent")
        context.insert(silent)
        try context.save()

        var calls = 0
        let catchUp = makeCatchUp { _, _ in calls += 1; return .empty }
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
            return .empty
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

    @Test func failureSkipListsTheTextThatWasReadNotAMidExtractionReplacement() async throws {
        let context = try makeContext()
        let meeting = meetingWithTranscript("Original", createdAt: .now)
        context.insert(meeting)
        try context.save()

        struct Boom: Error {}
        var reads: [String] = []
        let catchUp = makeCatchUp {transcript, _ in
            reads.append(transcript)
            if reads.count == 1 {
                // A re-transcription lands while the model is mid-read; the
                // attempt then fails on the text it actually read.
                MeetingJobs.applyNewTranscript(
                    [TranscriptSegment(text: "replacement line", start: 0, end: 1)],
                    to: meeting
                )
                throw Boom()
            }
            return .empty
        }
        catchUp.nudge(context: context)
        await catchUp.waitUntilIdle()

        // The replacement text was never read, so it must not inherit the
        // failure's skip — otherwise it waits for a relaunch unread.
        #expect(reads.count == 2)
        #expect(reads.last?.contains("replacement line") == true)
        #expect(meeting.knowledgeExtractedAt != nil)

        // The text that actually failed stays skipped: reverting to it is
        // not a hot retry.
        MeetingJobs.applyNewTranscript(
            [TranscriptSegment(text: "Original transcript line", start: 0, end: 1)],
            to: meeting
        )
        catchUp.nudge(context: context)
        await catchUp.waitUntilIdle()
        #expect(reads.count == 2)
        #expect(meeting.knowledgeExtractedAt == nil)
    }

    @Test func secondNudgeWhileRunningDoesNotStartASecondLoop() async throws {
        let context = try makeContext()
        context.insert(meetingWithTranscript("Only", createdAt: .now))
        try context.save()

        var calls = 0
        let catchUp = makeCatchUp {_, _ in
            calls += 1
            try await Task.sleep(for: .milliseconds(50))
            return .empty
        }
        catchUp.nudge(context: context)
        catchUp.nudge(context: context)
        await catchUp.waitUntilIdle()

        #expect(calls == 1)
    }

    @Test func unavailableModelStillCountsPendingWork() async throws {
        let context = try makeContext()
        context.insert(meetingWithTranscript("Unread", createdAt: .now))
        try context.save()

        var calls = 0
        let catchUp = KnowledgeCatchUp(
            availabilityMessage: { "Apple Intelligence isn't ready." },
            extract: { _, _ in calls += 1; return .empty }
        )
        catchUp.nudge(context: context)
        await catchUp.waitUntilIdle()

        // The guard bails before any processing, but the Brain tab must
        // still learn that unread work exists.
        #expect(calls == 0)
        #expect(catchUp.pendingCount == 1)
    }

    @Test func isWorkingIsTrueOnlyWhileTheLoopRuns() async throws {
        let context = try makeContext()
        context.insert(meetingWithTranscript("Only", createdAt: .now))
        try context.save()

        var observedDuringRun = false
        var catchUpRef: KnowledgeCatchUp?
        let catchUp = makeCatchUp {_, _ in
            observedDuringRun = catchUpRef?.isWorking ?? false
            return .empty
        }
        catchUpRef = catchUp
        #expect(!catchUp.isWorking)

        catchUp.nudge(context: context)
        await catchUp.waitUntilIdle()

        // The Brain tab's spinner keys on this: true mid-run, false after —
        // even when pendingCount would still be nonzero (skip-listed work).
        #expect(observedDuringRun)
        #expect(!catchUp.isWorking)
    }

    @Test func pauseStopsTheLoopAndResumeRestartsIt() async throws {
        let context = try makeContext()
        context.insert(meetingWithTranscript("A", createdAt: .now))
        context.insert(meetingWithTranscript("B", createdAt: .now.addingTimeInterval(-60)))
        try context.save()

        var calls = 0
        // Event-driven, not timed: fixed pre-pause sleeps flaked on slow CI
        // runners no matter how wide the window. The first extract call
        // signals the test, then parks until pause() cancels it —
        // deterministic on any host speed.
        let (firstCallStarted, startedContinuation) = AsyncStream.makeStream(of: Void.self)
        let catchUp = makeCatchUp { _, _ in
            calls += 1
            if calls == 1 {
                startedContinuation.yield(())
                try await Task.sleep(for: .seconds(60))
            }
            return .empty
        }
        catchUp.nudge(context: context)
        var started = firstCallStarted.makeAsyncIterator()
        _ = await started.next()   // the first extract call is definitely in flight
        catchUp.pause()
        await catchUp.waitUntilIdle()
        #expect(calls == 1)

        catchUp.resume(context: context)
        await catchUp.waitUntilIdle()
        // The paused meeting is retried from scratch (cancellation doesn't
        // join the skip-list — only genuine failures do), then the loop
        // continues on to the untouched remainder: 1 partial attempt on A
        // (interrupted by pause) + 1 full retry of A + 1 full run of B.
        #expect(calls == 3)  // the unstamped remainder was picked up
    }

    @Test func nudgeWhileAPausedLoopIsStillUnwindingRestartsTheLoop() async throws {
        let context = try makeContext()
        let meeting = meetingWithTranscript("Only", createdAt: .now)
        context.insert(meeting)
        try context.save()

        var calls = 0
        let (firstCallStarted, startedContinuation) = AsyncStream.makeStream(of: Void.self)
        let catchUp = makeCatchUp { _, _ in
            calls += 1
            if calls == 1 {
                startedContinuation.yield(())
                // Parks until pause() cancels it, so the teardown this test
                // nudges into is still in progress by construction. A timed
                // sleep here would only be racing the main-actor hop that
                // clears the loop, and would pass or fail on host speed.
                try await Task.sleep(for: .seconds(60))
            }
            return .empty
        }
        catchUp.nudge(context: context)
        var started = firstCallStarted.makeAsyncIterator()
        _ = await started.next()
        catchUp.pause()
        // The scene flickered back to active before the loop finished
        // tearing down. This resume must not be lost.
        catchUp.resume(context: context)
        await catchUp.waitUntilIdle()

        // Not just "the restart entered the extractor": the restarted loop
        // has to carry the meeting all the way to a stamp, or the user is
        // still waiting for a relaunch.
        #expect(calls == 2)
        #expect(meeting.knowledgeExtractedAt != nil)
        #expect(!catchUp.isWorking)
    }

    @Test func pauseAfterAMidTeardownNudgeLeavesTheLoopStopped() async throws {
        let context = try makeContext()
        let meeting = meetingWithTranscript("Only", createdAt: .now)
        context.insert(meeting)
        try context.save()

        var calls = 0
        let (firstCallStarted, startedContinuation) = AsyncStream.makeStream(of: Void.self)
        let catchUp = makeCatchUp { _, _ in
            calls += 1
            if calls == 1 {
                startedContinuation.yield(())
                // Parks until pause() cancels it: an extraction that notices
                // cancellation only when the model call returns.
                try await Task.sleep(for: .seconds(60))
            }
            return .empty
        }
        catchUp.nudge(context: context)
        var started = firstCallStarted.makeAsyncIterator()
        _ = await started.next()
        // active → inactive → active → inactive, all inside one teardown
        // window: the queued restart belongs to a foreground moment that is
        // already over by the time the loop unwinds.
        catchUp.pause()
        catchUp.resume(context: context)
        catchUp.pause()
        await catchUp.waitUntilIdle()

        // The scene is inactive, so the loop stays stopped (spec §5,
        // foreground-only). A background pass would burn rate-limited
        // FoundationModels calls and skip-list what it failed on.
        #expect(calls == 1)
        #expect(meeting.knowledgeExtractedAt == nil)
        #expect(!catchUp.isWorking)
    }

    @Test func nudgeWhileAHealthyLoopIsRunningQueuesNoSecondPass() async throws {
        let context = try makeContext()
        context.insert(meetingWithTranscript("Only", createdAt: .now))
        try context.save()

        // One availability check per run() pass — the honest way to count
        // passes from outside, since a redundant pass over an
        // already-stamped queue never reaches the extractor at all.
        var passes = 0
        var calls = 0
        let (firstCallStarted, startedContinuation) = AsyncStream.makeStream(of: Void.self)
        let (extractMayFinish, finishContinuation) = AsyncStream.makeStream(of: Void.self)
        let catchUp = KnowledgeCatchUp(
            availabilityMessage: { passes += 1; return nil },
            extract: { _, _ in
                calls += 1
                if calls == 1 {
                    startedContinuation.yield(())
                    var mayFinish = extractMayFinish.makeAsyncIterator()
                    _ = await mayFinish.next()
                }
                return .empty
            }
        )
        catchUp.nudge(context: context)
        var started = firstCallStarted.makeAsyncIterator()
        _ = await started.next()
        // A healthy loop, not a teardown: this nudge is already served by the
        // pass in flight and must queue nothing.
        catchUp.nudge(context: context)
        finishContinuation.yield(())
        await catchUp.waitUntilIdle()

        #expect(calls == 1)
        #expect(passes == 1)
    }

    @Test func unavailableModelLeavesQueueUntouchedForALaterNudge() async throws {
        let context = try makeContext()
        context.insert(meetingWithTranscript("A", createdAt: .now))
        try context.save()

        var calls = 0
        var message: String? = "Apple Intelligence isn't ready."
        let catchUp = KnowledgeCatchUp(
            availabilityMessage: { message },
            extract: { _, _ in calls += 1; return .empty }
        )
        catchUp.nudge(context: context)
        await catchUp.waitUntilIdle()
        #expect(calls == 0)

        // The model becoming ready must not require an app relaunch.
        message = nil
        catchUp.nudge(context: context)
        await catchUp.waitUntilIdle()
        #expect(calls == 1)
    }

    @Test func pendingCountStaysAccurateWhenQueueIsFullySkipListed() async throws {
        let context = try makeContext()
        context.insert(meetingWithTranscript("Failing", createdAt: .now))
        try context.save()

        struct Boom: Error {}
        let catchUp = makeCatchUp {_, _ in throw Boom() }
        catchUp.nudge(context: context)
        await catchUp.waitUntilIdle()

        // Unstamped work still exists — the count must say so, not lie "done".
        #expect(catchUp.pendingCount == 1)
    }

    @Test func aNudgeWhileTheSceneIsPausedStartsNothingUntilResume() async throws {
        let context = try makeContext()
        let meeting = meetingWithTranscript("Only", createdAt: .now)
        context.insert(meeting)
        try context.save()

        var calls = 0
        let catchUp = makeCatchUp { _, _ in calls += 1; return .empty }
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
        let catchUp = makeCatchUp { _, _ in calls += 1; return .empty }
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

    @Test func transcriptReplacedMidExtractionIsReextractedNotStampedStale() async throws {
        let context = try makeContext()
        let meeting = meetingWithTranscript("Original", createdAt: .now)
        context.insert(meeting)
        try context.save()

        var calls = 0
        let catchUp = makeCatchUp {transcript, _ in
            calls += 1
            if calls == 1 {
                // A re-transcription lands while the model is mid-read.
                meeting.segments = [TranscriptSegment(text: "Replaced transcript line", start: 0, end: 1)]
                meeting.knowledgeExtractedAt = nil
                return KnowledgeExtractionResult(candidates: [
                    KnowledgeCandidate(entityName: "Stale", entityKind: .topic, fact: "from old transcript", validatedQuote: nil),
                ])
            }
            #expect(transcript.contains("Replaced"))
            return KnowledgeExtractionResult(candidates: [
                KnowledgeCandidate(entityName: "Fresh", entityKind: .topic, fact: "from new transcript", validatedQuote: nil),
            ])
        }
        catchUp.nudge(context: context)
        await catchUp.waitUntilIdle()

        #expect(calls == 2)
        #expect(meeting.knowledgeExtractedAt != nil)
        let entities = try context.fetch(FetchDescriptor<KnowledgeEntity>())
        #expect(entities.map(\.name).sorted() == ["Fresh"])  // stale facts never ingested
    }

    @Test func meetingDeletedMidExtractionLeavesNoKnowledgeBehind() async throws {
        let context = try makeContext()
        let meeting = meetingWithTranscript("Botched Take", createdAt: .now)
        context.insert(meeting)
        try context.save()

        let catchUp = makeCatchUp { _, _ in
            // Deleting a botched take the moment it is saved is routine — that
            // save is also what nudges this loop — so the delete lands while
            // the model is still reading the transcript.
            #expect(MeetingStore.delete(meeting, context: context))
            return KnowledgeExtractionResult(candidates: [
                KnowledgeCandidate(entityName: "Sarah", entityKind: .person, fact: "Sarah spoke", validatedQuote: nil),
            ])
        }
        catchUp.nudge(context: context)
        await catchUp.waitUntilIdle()

        // The confirmation dialog promised everything the Brain learned from
        // this meeting is gone. Ingesting afterwards writes facts keyed to a
        // meeting that no longer exists, so no later delete can remove them.
        let facts = try context.fetch(FetchDescriptor<KnowledgeFact>())
        let entities = try context.fetch(FetchDescriptor<KnowledgeEntity>())
        #expect(facts.isEmpty)
        #expect(entities.isEmpty)
        #expect(catchUp.pendingCount == 0)
    }

    @Test func rateLimitedPausesWithoutPoisoningTheQueue() async throws {
        let context = try makeContext()
        let meeting = meetingWithTranscript("A", createdAt: .now)
        context.insert(meeting)
        try context.save()

        var calls = 0
        let catchUp = makeCatchUp {_, _ in
            calls += 1
            if calls == 1 {
                throw LanguageModelSession.GenerationError.rateLimited(.init(debugDescription: "test"))
            }
            return .empty
        }
        catchUp.nudge(context: context)
        await catchUp.waitUntilIdle()
        #expect(calls == 1)
        #expect(catchUp.pendingCount == 1)  // still pending, not skip-listed
        #expect(meeting.knowledgeExtractedAt == nil)

        // A later nudge retries the same meeting rather than treating it as skip-listed.
        catchUp.nudge(context: context)
        await catchUp.waitUntilIdle()
        #expect(calls == 2)
        #expect(meeting.knowledgeExtractedAt != nil)
    }

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
            return .empty
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
}
