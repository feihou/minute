import Foundation
import Testing
@testable import Minute

struct KnowledgeTextTests {
    @Test func normalizedFoldsCaseDiacriticsAndTokenOrder() {
        #expect(KnowledgeText.normalized("Zhang, Wei") == KnowledgeText.normalized("wei ZHÄNG"))
        #expect(KnowledgeText.normalized("  Atlas   Redesign ") == "atlas redesign")
    }

    @Test func inOrderKeepsWritingOrderWhileNormalizedSorts() {
        // Hint matching needs adjacency: after sorting, the two words of a
        // name sit next to each other only by accident of the alphabet.
        #expect(KnowledgeText.inOrder("Zhang, Wei") == "zhang wei")
        #expect(KnowledgeText.normalized("Zhang, Wei") == "wei zhang")
        #expect(KnowledgeText.inOrder("  Atlas   Redesign! ") == "atlas redesign")
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

    @Test func quoteValidationIsTokenAligned() {
        let transcript = "[0:12] Sarah: I disown the atlas plan, and Priya owns the mercury plan."
        // A quote that only matches by cutting into a word must not validate.
        #expect(!KnowledgeText.contains(transcript: transcript, quote: "own the atlas plan"))
        // Whole tokens in order still do, anywhere in the sentence.
        #expect(KnowledgeText.contains(transcript: transcript, quote: "the atlas plan"))
        #expect(KnowledgeText.contains(transcript: transcript, quote: "Priya owns the mercury plan"))

        // Unspaced scripts have no token boundary for a fragment to land on:
        // ideographs are alphanumerics, so a whole Chinese clause is one token
        // and a verbatim fragment of it must still validate.
        let chinese = "[00:12] 今天张伟负责发布 Atlas。"
        #expect(KnowledgeText.contains(transcript: chinese, quote: "张伟负责发布"))
        #expect(
            KnowledgeText.contains(transcript: "[00:30] 我下周负责atlas的发布。", quote: "负责atlas的发布")
        )
        // Words the transcript never says are still refused.
        #expect(!KnowledgeText.contains(transcript: chinese, quote: "李娜"))

        // Cyrillic spells words out, so the cut-into-a-word rule has to hold
        // there too — the fragment leniency is only for unspaced scripts.
        let russian = "[0:03] Иван: я не собственник плана."
        #expect(!KnowledgeText.contains(transcript: russian, quote: "обственник плана"))
        #expect(KnowledgeText.contains(transcript: russian, quote: "собственник плана"))

        // Arabic and Hebrew have no letter case but do separate words with
        // spaces, so cutting into one of their words is the same abuse — the
        // leniency belongs to unsegmented scripts, not to uncased ones.
        // Both fixtures are written without harakat/niqqud so the diacritic
        // fold `tokens` applies is a no-op and the fixture is what is matched.
        let arabic = "[0:05] سارة: المدرسة جاهزة اليوم."
        #expect(!KnowledgeText.contains(transcript: arabic, quote: "درسة جاهزة"))
        #expect(KnowledgeText.contains(transcript: arabic, quote: "المدرسة جاهزة"))
        let hebrew = "[0:07] דנה: בית הספר מוכן היום."
        #expect(!KnowledgeText.contains(transcript: hebrew, quote: "ית הספר"))
        #expect(KnowledgeText.contains(transcript: hebrew, quote: "בית הספר"))
    }

    @Test func fingerprintIsStablePerInstallAndEntity() {
        let entity = UUID()
        let a = KnowledgeText.fingerprint("Alice leads Atlas", entityID: entity)
        #expect(a == KnowledgeText.fingerprint("alice LEADS atlas", entityID: entity))
        #expect(a != KnowledgeText.fingerprint("Alice leads Atlas", entityID: UUID()))
        #expect(a.count == 64)  // hex SHA-256
    }
}
