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

    /// CJK is written without inter-word spaces, so KnowledgeText normalizes a
    /// whole sentence to one token. Both existing probes — the padded phrase
    /// and the per-token one — need a space boundary the script never
    /// provides, so a Chinese or Japanese roster name could never be offered:
    /// the model then invents a second spelling, and KnowledgeIngest.resolve,
    /// which matches on exact normalized text, mints a duplicate entity for it.
    @Test func anUnspacedRosterNameIsHintedAsASubstring() {
        // "张伟" is inside the run "今天张伟负责发布", never a token of its own.
        let chunk = "[00:12] 今天张伟负责发布 Atlas。"
        #expect(KnowledgeExtractionService.hintNames(for: chunk, from: ["张伟"]) == ["张伟"])

        // A roster name this chunk does not contain is still not offered.
        #expect(KnowledgeExtractionService.hintNames(for: chunk, from: ["李娜"]).isEmpty)

        // One character is below the floor: it appears in almost any sentence,
        // and it would spend one of the twenty hint slots on nothing.
        #expect(KnowledgeExtractionService.hintNames(for: chunk, from: ["天"]).isEmpty)

        // The substring match ranks with the names spoken in full, ahead of a
        // name matched only token by token — "mercury atlas" is not contiguous
        // in this chunk, so it comes through the partial path.
        #expect(
            KnowledgeExtractionService.hintNames(for: chunk + " Mercury", from: ["Mercury Atlas", "张伟"])
                == ["张伟", "Mercury Atlas"]
        )
    }

    /// The substring probe is for scripts that write no inter-word spaces.
    /// Latin writes them, so a bare substring probe there is noise, not a fix:
    /// the roster is uncapped and carries aliases and topic entities, so short
    /// rows are expected, and "Tom" sits inside "tomorrow", "PR" inside
    /// "approve", "SLA" inside "Slack". Each such hit would rank as a name
    /// spoken in full, and twenty of them would fill hintCap — the eviction
    /// this function's ordering exists to prevent — under a prompt that tells
    /// the model to reuse the spellings it is given.
    @Test func aLatinNameBuriedInsideALongerWordIsNotHinted() {
        let chunk = "[00:02] Tomorrow the same team will approve the estimate; the Atlas quality guide is available in Slack, and the program build ships."
        let buried = ["Tom", "Sam", "PR", "Tim", "AI", "SLA", "UI", "Ali"]
        for name in buried {
            #expect(KnowledgeExtractionService.hintNames(for: chunk, from: [name]).isEmpty)
        }
        // Spoken in full, the same script still matches — the gate narrows the
        // new probe, it does not touch the two the function already had.
        #expect(KnowledgeExtractionService.hintNames(for: chunk, from: ["Slack"]) == ["Slack"])
        // And the buried rows do not outrank, or crowd out, the roster name
        // whose every long token was actually spoken.
        #expect(
            KnowledgeExtractionService.hintNames(for: chunk, from: buried + ["Atlas Program"]) == ["Atlas Program"]
        )
    }

    /// The other half of the same script problem: a Japanese full name is
    /// commonly written with a space between family and given name, while the
    /// sentence that says it has none. The name is present in full, just
    /// without the delimiter its script does not write, so it is matched on
    /// its characters rather than on a boundary the chunk cannot supply.
    @Test func anUnspacedChunkStillMatchesARosterNameWrittenWithASpace() {
        let chunk = "[00:20] 明日山田太郎が発表します。"
        #expect(KnowledgeExtractionService.hintNames(for: chunk, from: ["山田 太郎"]) == ["山田 太郎"])
        // Order still has to hold: this is a contiguous match, not a bag of
        // characters, so the reversed name is a different name.
        #expect(KnowledgeExtractionService.hintNames(for: chunk, from: ["太郎 山田"]).isEmpty)
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

    /// The Me page is a resolution decision this device makes, never a model
    /// output. EntityKind declares a `.me` case, so a draft whose entityKind
    /// reads "me" is one unchecked line away from minting a `.me` entity — and
    /// every downstream exemption (KnowledgeIngest's review routing,
    /// KnowledgeStore's orphan prune, which both skip `.me`) would then guard
    /// the bogus one. Only the unknown-kind default was pinned before this.
    @Test func aModelWrittenMeKindCollapsesToTopic() {
        let transcript = "[00:01] Sarah: I will own the Atlas redesign."
        let me = KnowledgeCandidateDraft(
            entityName: "Atlas", entityKind: "me",
            fact: "Atlas ships in Q3", supportingQuote: ""
        )
        #expect(KnowledgeExtractionService.candidate(from: me, transcript: transcript)?.entityKind == .topic)

        // The trim-and-lowercase path reaches the same raw value, so it has to
        // collapse there too — a model that writes " Me " must not slip past.
        let padded = KnowledgeCandidateDraft(
            entityName: "Atlas", entityKind: " Me ",
            fact: "Atlas ships in Q3", supportingQuote: ""
        )
        #expect(KnowledgeExtractionService.candidate(from: padded, transcript: transcript)?.entityKind == .topic)
    }
}
