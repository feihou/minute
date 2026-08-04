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
        let generation = SummaryGeneration()

        let task = generation.generate(meeting, template: .standard, context: "", language: nil)
        #expect(generation.isGenerating(meeting))
        await task?.value

        // No transcript: generation fails fast, clears the in-flight state,
        // and surfaces an error the view can show on any later visit.
        #expect(!generation.isGenerating(meeting))
        #expect(generation.status(for: meeting) == nil)
        #expect(generation.error(for: meeting) != nil)
        #expect(meeting.summary == nil)
    }

    @Test func generateWhileRunningReturnsTheSameTask() async throws {
        let (container, meeting) = try makeMeeting()
        defer { _ = container }
        let generation = SummaryGeneration()

        let first = generation.generate(meeting, template: .standard, context: "", language: nil)
        let second = generation.generate(meeting, template: .standard, context: "", language: nil)
        // Re-entering the screen must attach to the running generation, never
        // start a second one for the same meeting.
        #expect(first == second)
        await first?.value
        #expect(!generation.isGenerating(meeting))
    }
}
