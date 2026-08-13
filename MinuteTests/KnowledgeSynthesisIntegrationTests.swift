import Foundation
import Testing
@testable import Minute

/// Runs the real on-device model when available; skips otherwise.
struct KnowledgeSynthesisIntegrationTests {
    @Test(.enabled(if: KnowledgeSynthesisService.availabilityMessage == nil))
    func synthesizesShortNarrativeFromFacts() async throws {
        let narrative = try await KnowledgeSynthesisService().synthesize(
            name: "Sarah Chen",
            kind: .person,
            facts: [
                "Sarah Chen is the lead on the Atlas redesign",
                "Sarah Chen prefers async design reviews",
                "Sarah Chen committed to shipping Atlas by the end of Q3",
            ]
        )
        #expect(!narrative.isEmpty)
        let normalized = KnowledgeText.normalized(narrative)
        #expect(normalized.contains("atlas") || normalized.contains("sarah"))
    }
}
