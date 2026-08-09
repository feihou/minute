import Foundation
import Testing
@testable import Minute

/// The code-level merge used when the model refuses to combine chunk notes,
/// and the token-density chunk budget.
struct SummaryFallbackTests {
    private func notes(
        keyPoints: [String] = [],
        decisions: [String] = [],
        actionItems: [DraftActionItem] = [],
        openQuestions: [String] = [],
        perspectives: [DraftSpeakerPerspective] = []
    ) -> ChunkNotes {
        ChunkNotes(
            keyPoints: keyPoints,
            decisions: decisions,
            actionItems: actionItems,
            openQuestions: openQuestions,
            speakerPerspectives: perspectives
        )
    }

    @Test func combineConcatenatesAndDedupes() {
        let combined = SummarizationService.mechanicallyCombined([
            notes(keyPoints: ["Budget approved", "Launch moved to May"], openQuestions: ["Who owns pricing?"]),
            notes(keyPoints: ["budget approved", "Hiring freeze lifted"], decisions: ["Ship on Friday"]),
        ])
        // Overlapping parts repeat items; case-insensitive dedupe keeps the first.
        #expect(combined.keyPoints == ["Budget approved", "Launch moved to May", "Hiring freeze lifted"])
        #expect(combined.decisions == ["Ship on Friday"])
        #expect(combined.openQuestions == ["Who owns pricing?"])
    }

    @Test func combinePrefersActionItemCopyWithOwnerAndDeadline() {
        let combined = SummarizationService.mechanicallyCombined([
            notes(actionItems: [DraftActionItem(task: "Update pricing page", owner: "Not specified", deadline: "Not specified")]),
            notes(actionItems: [DraftActionItem(task: "update pricing page", owner: "Maria", deadline: "Thursday")]),
        ])
        #expect(combined.actionItems.count == 1)
        #expect(combined.actionItems[0].owner == "Maria")
        #expect(combined.actionItems[0].deadline == "Thursday")
    }

    @Test func combineKeepsSameTaskUnderDifferentOwners() {
        let combined = SummarizationService.mechanicallyCombined([
            notes(actionItems: [DraftActionItem(task: "Submit the report", owner: "Alice", deadline: "Not specified")]),
            notes(actionItems: [DraftActionItem(task: "submit the report", owner: "Bob", deadline: "Friday")]),
        ])
        // Two people committing to the same wording is two commitments.
        #expect(combined.actionItems.count == 2)
        #expect(combined.actionItems[0].owner == "Alice")
        #expect(combined.actionItems[1].owner == "Bob")
    }

    @Test func combineGroupsSpeakerPerspectives() {
        let combined = SummarizationService.mechanicallyCombined([
            notes(perspectives: [DraftSpeakerPerspective(speaker: "Alice", points: ["Prefers option A"])]),
            notes(perspectives: [
                DraftSpeakerPerspective(speaker: "alice", points: ["Prefers option A", "Worried about cost"]),
                DraftSpeakerPerspective(speaker: "Bob", points: ["Wants a demo"]),
            ]),
        ])
        #expect(combined.speakerPerspectives.count == 2)
        #expect(combined.speakerPerspectives[0].speaker == "Alice")
        #expect(combined.speakerPerspectives[0].points == ["Prefers option A", "Worried about cost"])
        #expect(combined.speakerPerspectives[1].points == ["Wants a demo"])
    }

    @Test func chunkBudgetScalesWithTokenDensity() {
        // English-ish density (~4.2 chars/token) lifts the budget well above
        // the old 6,000-char default…
        #expect(SummarizationService.chunkBudget(transcriptChars: 42_000, transcriptTokens: 10_000) == 8_400)
        // …while CJK-like density (~1.1) right-sizes below it, skipping the
        // overflow-halving lap entirely.
        #expect(SummarizationService.chunkBudget(transcriptChars: 11_000, transcriptTokens: 10_000) == 2_200)
    }

    @Test func chunkBudgetClampsPathologicalRatios() {
        #expect(SummarizationService.chunkBudget(transcriptChars: 100, transcriptTokens: 1_000) == 1_500)
        #expect(SummarizationService.chunkBudget(transcriptChars: 100_000, transcriptTokens: 1_000) == 12_000)
        #expect(SummarizationService.chunkBudget(transcriptChars: 100, transcriptTokens: 0) == TranscriptChunker.defaultMaxChars)
    }
}
