import Foundation
import SwiftData
import Testing
@testable import Minute

@MainActor
struct SummaryGenerationTests {
    // The container must outlive the meeting — a deallocated store makes
    // every model access undefined.
    private func makeMeeting() throws -> (ModelContainer, Meeting) {
        let container = try ModelContainer(
            for: Meeting.self,
            configurations: MeetingStore.modelConfiguration(inMemory: true)
        )
        let meeting = Meeting(title: "Empty")
        container.mainContext.insert(meeting)
        return (container, meeting)
    }

    @Test func failedGenerationClearsInFlightStateAndRecordsError() async throws {
        let (container, meeting) = try makeMeeting()
        defer { _ = container }
        let jobs = MeetingJobs()

        let task = jobs.summarize(meeting, template: .standard, context: "", language: nil)
        #expect(jobs.isRunning(.summary, for: meeting))
        await task?.value

        // No transcript: generation fails fast, clears the in-flight state,
        // and surfaces an error the view can show on any later visit.
        #expect(!jobs.isRunning(.summary, for: meeting))
        #expect(!jobs.isBusy(meeting))
        #expect(jobs.status(for: meeting) == nil)
        #expect(jobs.error(.summary, for: meeting) != nil)
        #expect(meeting.summary == nil)
    }

    @Test func generateWhileRunningReturnsTheSameTask() async throws {
        let (container, meeting) = try makeMeeting()
        defer { _ = container }
        let jobs = MeetingJobs()

        let first = jobs.summarize(meeting, template: .standard, context: "", language: nil)
        let second = jobs.summarize(meeting, template: .standard, context: "", language: nil)
        // Re-entering the screen must attach to the running generation, never
        // start a second one for the same meeting.
        #expect(first == second)
        await first?.value
        #expect(!jobs.isBusy(meeting))
    }

    @Test func aSecondKindOfJobIsRefusedWhileOneIsRunning() async throws {
        let (container, meeting) = try makeMeeting()
        defer { _ = container }
        let jobs = MeetingJobs()

        let summary = jobs.summarize(meeting, template: .standard, context: "", language: nil)
        // The whole point of the single slot: re-transcription and speaker
        // identification rewrite the same segments a summary is reading, so
        // they must attach to the running job rather than start alongside it.
        let other = jobs.retranscribe(meeting, audioAt: URL(fileURLWithPath: "/dev/null"))
        #expect(other == summary)
        #expect(jobs.isRunning(.summary, for: meeting))
        #expect(!jobs.isRunning(.transcription, for: meeting))

        await summary?.value
        #expect(!jobs.isBusy(meeting))
    }

    @Test func errorsAreReportedOnlyForTheKindThatFailed() async throws {
        let (container, meeting) = try makeMeeting()
        defer { _ = container }
        let jobs = MeetingJobs()

        await jobs.summarize(meeting, template: .standard, context: "", language: nil)?.value

        // The detail view renders summary and transcript errors in different
        // sections; a summary failure must not light up the transcript one.
        #expect(jobs.error(.summary, for: meeting) != nil)
        #expect(jobs.error(.transcription, for: meeting) == nil)
        #expect(jobs.error(.diarization, for: meeting) == nil)
    }
}
