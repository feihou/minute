import Foundation
import Testing
@testable import Minute

/// Exercises the real on-device model when available; skips otherwise —
/// the same gate SummarizationIntegrationTests uses.
struct KnowledgeExtractionIntegrationTests {
    @Test(.enabled(if: KnowledgeExtractionService.availabilityMessage == nil))
    func extractsDurableFactsFromShortTranscript() async throws {
        let transcript = """
            [00:05] Sarah: Quick update — I'm now the lead on the Atlas redesign.
            [00:12] Bob: Great. I'll keep owning the Mercury migration then.
            [00:20] Sarah: Also decided: Atlas ships at the end of Q3.
            """
        let candidates = try await KnowledgeExtractionService()
            .extract(transcript: transcript, knownEntityNames: ["Sarah Chen"])

        #expect(!candidates.isEmpty)
        let names = candidates.map { KnowledgeText.normalized($0.entityName) }
        #expect(names.contains { $0.contains("sarah") || $0.contains("atlas") })
        for candidate in candidates {
            #expect(!candidate.fact.isEmpty)
            if let quote = candidate.validatedQuote {
                #expect(KnowledgeText.contains(transcript: transcript, quote: quote))
            }
        }
    }
}
