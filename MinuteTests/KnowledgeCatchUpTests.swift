import Foundation
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
        let catchUp = KnowledgeCatchUp { transcript, _ in
            order.append(transcript.contains("New") ? "New" : "Old")
            return [KnowledgeCandidate(entityName: "Sarah", entityKind: .person, fact: "Sarah spoke", validatedQuote: nil)]
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
        let catchUp = KnowledgeCatchUp { transcript, _ in
            if transcript.contains("Failing") { throw Boom() }
            return []
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
        let catchUp = KnowledgeCatchUp { _, _ in calls += 1; return [] }
        catchUp.nudge(context: context)
        await catchUp.waitUntilIdle()

        #expect(calls == 0)
        #expect(silent.knowledgeExtractedAt == nil)
    }

    @Test func secondNudgeWhileRunningDoesNotStartASecondLoop() async throws {
        let context = try makeContext()
        context.insert(meetingWithTranscript("Only", createdAt: .now))
        try context.save()

        var calls = 0
        let catchUp = KnowledgeCatchUp { _, _ in
            calls += 1
            try await Task.sleep(for: .milliseconds(50))
            return []
        }
        catchUp.nudge(context: context)
        catchUp.nudge(context: context)
        await catchUp.waitUntilIdle()

        #expect(calls == 1)
    }

    @Test func pauseStopsTheLoopAndNudgeResumes() async throws {
        let context = try makeContext()
        context.insert(meetingWithTranscript("A", createdAt: .now))
        context.insert(meetingWithTranscript("B", createdAt: .now.addingTimeInterval(-60)))
        try context.save()

        var calls = 0
        let catchUp = KnowledgeCatchUp { _, _ in
            calls += 1
            try await Task.sleep(for: .milliseconds(1000))
            return []
        }
        catchUp.nudge(context: context)
        // Long enough that the loop's Task is reliably scheduled and past
        // its first `calls += 1` even under full-suite parallel contention,
        // short enough to still land well before the 1000ms extractor sleep
        // completes (keeps the 1:5 ratio from the original 20ms:100ms).
        try await Task.sleep(for: .milliseconds(200))
        catchUp.pause()
        await catchUp.waitUntilIdle()
        let callsAfterPause = calls
        #expect(callsAfterPause <= 1)

        catchUp.nudge(context: context)
        await catchUp.waitUntilIdle()
        // The paused meeting is retried from scratch (cancellation doesn't
        // join the skip-list — only genuine failures do), then the loop
        // continues on to the untouched remainder: 1 partial attempt on A
        // (interrupted by pause) + 1 full retry of A + 1 full run of B.
        #expect(calls == 3)  // the unstamped remainder was picked up
    }

    @Test func unavailableModelLeavesQueueUntouchedForALaterNudge() async throws {
        let context = try makeContext()
        context.insert(meetingWithTranscript("A", createdAt: .now))
        try context.save()

        var calls = 0
        var message: String? = "Apple Intelligence isn't ready."
        let catchUp = KnowledgeCatchUp(
            availabilityMessage: { message },
            extract: { _, _ in calls += 1; return [] }
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
        let catchUp = KnowledgeCatchUp { _, _ in throw Boom() }
        catchUp.nudge(context: context)
        await catchUp.waitUntilIdle()

        // Unstamped work still exists — the count must say so, not lie "done".
        #expect(catchUp.pendingCount == 1)
    }
}
