import Foundation
import Testing
@testable import Minute

struct KnowledgeExtractionServiceTests {
    @Test func hintNamesKeepsOnlyNamesAppearingInChunkCappedAt20() {
        let chunk = "[00:01] Sarah: Atlas is on track. Bob is out this week."
        let names = ["Sarah Chen", "Atlas", "Mercury", "Bob"]
        let hints = KnowledgeExtractionService.hintNames(for: chunk, from: names)
        #expect(hints.contains("Atlas"))
        #expect(hints.contains("Bob"))
        // "Sarah Chen": one of its tokens appears — still a valid hint.
        #expect(hints.contains("Sarah Chen"))
        #expect(!hints.contains("Mercury"))

        let many = (0..<50).map { "Sarah \($0)" }
        #expect(KnowledgeExtractionService.hintNames(for: "Sarah spoke", from: many).count == 20)
    }

    @Test func candidateValidatesQuoteAndMapsKind() {
        let transcript = "[00:01] Sarah: I will own the Atlas redesign."
        let good = KnowledgeCandidateDraft(
            entityName: " Sarah ", entityKind: "person",
            fact: " Sarah owns the Atlas redesign. ",
            supportingQuote: "I will own the Atlas redesign"
        )
        let candidate = KnowledgeExtractionService.candidate(from: good, transcript: transcript)
        #expect(candidate?.entityName == "Sarah")
        #expect(candidate?.entityKind == .person)
        #expect(candidate?.fact == "Sarah owns the Atlas redesign.")
        #expect(candidate?.validatedQuote == "I will own the Atlas redesign")

        let paraphrased = KnowledgeCandidateDraft(
            entityName: "Sarah", entityKind: "person",
            fact: "Sarah owns Atlas", supportingQuote: "Sarah said she owns it"
        )
        #expect(KnowledgeExtractionService.candidate(from: paraphrased, transcript: transcript)?.validatedQuote == nil)

        let unknownKind = KnowledgeCandidateDraft(
            entityName: "Atlas", entityKind: "meeting", fact: "f", supportingQuote: ""
        )
        #expect(KnowledgeExtractionService.candidate(from: unknownKind, transcript: transcript)?.entityKind == .topic)

        let empty = KnowledgeCandidateDraft(entityName: "X", entityKind: "person", fact: "   ", supportingQuote: "")
        #expect(KnowledgeExtractionService.candidate(from: empty, transcript: transcript) == nil)
    }
}
