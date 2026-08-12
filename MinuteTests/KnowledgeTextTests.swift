import Foundation
import Testing
@testable import Minute

struct KnowledgeTextTests {
    @Test func normalizedFoldsCaseDiacriticsAndTokenOrder() {
        #expect(KnowledgeText.normalized("Zhang, Wei") == KnowledgeText.normalized("wei ZHÄNG"))
        #expect(KnowledgeText.normalized("  Atlas   Redesign ") == "atlas redesign")
    }

    @Test func tokenOverlapIsJaccardOnNormalizedTokens() {
        #expect(KnowledgeText.tokenOverlap("Alice leads Atlas", "alice leads atlas") == 1.0)
        #expect(KnowledgeText.tokenOverlap("Alice leads Atlas", "Bob owns Mercury") == 0.0)
        let partial = KnowledgeText.tokenOverlap("Alice leads Atlas", "Alice leads Mercury")
        #expect(partial > 0.4 && partial < 0.8)
        #expect(KnowledgeText.tokenOverlap("", "anything") == 0.0)
    }

    @Test func tokenOverlapFallsBackToBigramsForUnspacedText() {
        // Paraphrase pair sharing most characters: must land clearly above
        // the near-duplicate band's floor, not collapse to 0-or-1.
        let similar = KnowledgeText.tokenOverlap("张伟负责Atlas项目的重新设计工作", "张伟负责Atlas项目的重新设计")
        #expect(similar > 0.6 && similar < 1.0)
        // Unrelated clauses: clearly below the contradiction band.
        #expect(KnowledgeText.tokenOverlap("张伟负责Atlas项目", "会议下周二举行预算审查") < 0.4)
    }

    @Test func containsIgnoresCasePunctuationAndWhitespaceRuns() {
        let transcript = "[00:12] Sarah: I'll own the Atlas redesign,\nstarting next week."
        #expect(KnowledgeText.contains(transcript: transcript, quote: "own the atlas redesign starting"))
        #expect(!KnowledgeText.contains(transcript: transcript, quote: "own the Mercury redesign"))
        #expect(!KnowledgeText.contains(transcript: transcript, quote: ""))
    }

    @Test func fingerprintIsStablePerInstallAndEntity() {
        let entity = UUID()
        let a = KnowledgeText.fingerprint("Alice leads Atlas", entityID: entity)
        #expect(a == KnowledgeText.fingerprint("alice LEADS atlas", entityID: entity))
        #expect(a != KnowledgeText.fingerprint("Alice leads Atlas", entityID: UUID()))
        #expect(a.count == 64)  // hex SHA-256
    }
}
