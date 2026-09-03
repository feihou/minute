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
        // "Chen" is nowhere in this chunk, so "Sarah Chen" is a different name
        // that happens to share a token. Offering it invites the model to
        // relabel this meeting's Sarah as someone else.
        #expect(!hints.contains("Sarah Chen"))
        #expect(!hints.contains("Mercury"))

        let many = (0..<50).map { "Sarah \($0)" }
        #expect(KnowledgeExtractionService.hintNames(for: "Sarah spoke", from: many).count == 20)
    }

    @Test func namesSpokenInFullOutrankPartialMatchesWithinTheCap() {
        let chunk = "[00:03] Sarah Chen: the Atlas Program ships at the end of Q3."
        // 25 roster entries whose every long token is in the chunk, and the one
        // name actually spoken sorted last: truncation alone would drop it and
        // the model would write "Sarah", which resolution cannot match.
        let names = (0..<25).map { "Atlas Program \($0)" } + ["Sarah Chen"]
        let hints = KnowledgeExtractionService.hintNames(for: chunk, from: names)

        #expect(hints.first == "Sarah Chen")
        #expect(hints.count == 20)
    }

    @Test func aNameSharingOneCommonTokenIsNotAHint() {
        let chunk = "[00:03] Sarah Chen: the Atlas Program ships at the end of Q3."
        // "the" is in every chunk ever spoken; matching on it is what let
        // common-word entity names crowd out the names actually present.
        // "state" and "union" are absent, so every-long-token fails too.
        #expect(KnowledgeExtractionService.hintNames(for: chunk, from: ["State of the Union"]).isEmpty)
        // Every long token present, in any order: still the same entity.
        #expect(KnowledgeExtractionService.hintNames(for: "Chen, Sarah joined", from: ["Sarah Chen"]) == ["Sarah Chen"])
        // "A/B Testing" normalizes to "a b testing", which this chunk does not
        // contain as a phrase. It is hinted through the token path, where the
        // one-character "a" and "b" are below the floor and "testing" — its
        // only token that carries meaning on its own — is present.
        #expect(KnowledgeExtractionService.hintNames(for: "we ran a testing pass", from: ["A/B Testing"]) == ["A/B Testing"])
    }

    @Test func aNameWithNoTokensIsNeverAHint() {
        // A roster row that is pure punctuation normalizes to nothing, and an
        // empty phrase sits inside every haystack — including the "  " a chunk
        // with no words of its own produces. Such a row has to drop out before
        // the phrase probe, or it would be hinted for a chunk that says nothing.
        #expect(KnowledgeExtractionService.hintNames(for: "", from: ["—"]).isEmpty)
        #expect(KnowledgeExtractionService.hintNames(for: "  ...  ", from: ["!!!"]).isEmpty)
        // And it drops out without taking the real names beside it with it.
        #expect(KnowledgeExtractionService.hintNames(for: "Atlas ships", from: ["—", "Atlas"]) == ["Atlas"])
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

    @Test func speakerPlaceholdersAreNeverCandidates() {
        let transcript = "[00:01] Speaker 2: I will own the Atlas redesign."
        let placeholder = KnowledgeCandidateDraft(
            entityName: "Speaker 2", entityKind: "person",
            fact: "Speaker 2 owns the Atlas redesign", supportingQuote: "I will own the Atlas redesign"
        )
        // Diarization's fallback label is not a person; two meetings' "Speaker 2"
        // are different people and must not share one Brain page.
        #expect(KnowledgeExtractionService.candidate(from: placeholder, transcript: transcript) == nil)
        #expect(KnowledgeExtractionService.isSpeakerPlaceholder("speaker 1"))
        #expect(KnowledgeExtractionService.isSpeakerPlaceholder(" Speaker  12 "))
        #expect(!KnowledgeExtractionService.isSpeakerPlaceholder("Speaker Chen"))
        #expect(!KnowledgeExtractionService.isSpeakerPlaceholder("Sarah"))
    }

    @Test func paddedEntityKindStillMapsToItsKind() {
        let transcript = "[00:01] Sarah: hi"
        let padded = KnowledgeCandidateDraft(entityName: "Sarah", entityKind: " person ", fact: "Sarah spoke", supportingQuote: "")
        #expect(KnowledgeExtractionService.candidate(from: padded, transcript: transcript)?.entityKind == .person)
    }
}
