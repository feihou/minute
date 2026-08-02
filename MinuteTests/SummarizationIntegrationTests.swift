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

    @Test func throwsOnEmptyTranscriptWhenModelAvailable() async {
        guard SummarizationService.availabilityMessage == nil else { return }
        await #expect(throws: SummarizerError.self) {
            _ = try await SummarizationService().summarize(transcript: "   ")
        }
    }
}
