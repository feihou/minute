import Foundation
import Testing
@testable import Minute

/// Exercises the real on-device Apple Intelligence model when it's available;
/// skips (passes trivially) on machines where it isn't.
struct SummarizationIntegrationTests {
    @Test(.enabled(if: SummarizationService.availabilityMessage == nil))
    func summarizesShortTranscriptWithStructuredOutput() async throws {
        let transcript = """
            Okay, let's get started with the weekly product sync.
            First, the launch: we all agree the new dashboard ships on Friday. That's decided.
            Maria will prepare the release notes by Thursday.
            Someone still needs to update the pricing page, but we haven't picked who yet.
            One thing we couldn't resolve today: should the free tier include exports? Let's revisit next week.
            That's everything, thanks all.
            """

        let summary = try await SummarizationService().summarize(transcript: transcript)

        #expect(!summary.overview.isEmpty)
        #expect(!summary.actionItems.isEmpty)
        // Owners/deadlines must be the literal placeholder when absent, never invented.
        for item in summary.actionItems {
            #expect(!item.owner.isEmpty)
            #expect(!item.deadline.isEmpty)
        }
    }

    @Test(.enabled(if: SummarizationService.availabilityMessage == nil))
    func standupTemplateProducesSections() async throws {
        let transcript = """
            Quick standup. Yesterday I finished the login screen and Maria fixed the crash on iPad.
            Today I'm starting on the settings page, and Maria is reviewing the API changes.
            One blocker: I'm still waiting on the new app icons from design.
            """

        let summary = try await SummarizationService().summarize(transcript: transcript, template: .standup)

        let sections = try #require(summary.sections)
        #expect(!sections.isEmpty)
        #expect(sections.contains { !$0.items.isEmpty })
        // The fixed fields belong to the standard template only.
        #expect(summary.keyPoints.isEmpty)
        #expect(summary.openQuestions.isEmpty)
    }

    @Test func throwsOnEmptyTranscriptWhenModelAvailable() async {
        guard SummarizationService.availabilityMessage == nil else { return }
        await #expect(throws: SummarizerError.self) {
            _ = try await SummarizationService().summarize(transcript: "   ")
        }
    }
}
