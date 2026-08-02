import Foundation
import Testing
@testable import Minute

struct NotesExporterTests {
    @Test func exportContainsAllSections() {
        let meeting = Meeting(
            title: "Weekly Standup",
            segments: [TranscriptSegment(text: "We shipped version one.", start: 0, end: 3)],
            summary: MeetingSummary(
                overview: "A quick sync about the launch.",
                keyPoints: ["Version one shipped"],
                decisions: ["Ship version two on Friday"],
                actionItems: [ActionItem(task: "Write release notes", owner: ActionItem.notSpecified, deadline: "Friday")],
                openQuestions: ["What is the budget?"],
                generatedAt: .now
            )
        )

        let text = NotesExporter.notesText(for: meeting)

        #expect(text.contains("# Weekly Standup"))
        #expect(text.contains("## Overview"))
        #expect(text.contains("## Key Points"))
        #expect(text.contains("## Decisions"))
        #expect(text.contains("- Write release notes (Owner: Not specified, Due: Friday)"))
        #expect(text.contains("## Open Questions"))
        #expect(text.contains("[0:00] We shipped version one."))
    }

    @Test func exportSkipsEmptySections() {
        let meeting = Meeting(title: "Empty Meeting")
        let text = NotesExporter.notesText(for: meeting)

        #expect(text.contains("# Empty Meeting"))
        #expect(!text.contains("## "))
    }

    @Test func exportIncludesTemplateSections() {
        let meeting = Meeting(
            title: "Standup",
            summary: MeetingSummary(
                overview: "Daily sync.",
                keyPoints: [],
                decisions: [],
                actionItems: [],
                openQuestions: [],
                generatedAt: .now,
                sections: [
                    SummarySection(title: "Yesterday", items: ["Shipped the exporter"]),
                    SummarySection(title: "Blockers", items: []),
                ]
            )
        )

        let text = NotesExporter.notesText(for: meeting)

        #expect(text.contains("## Yesterday"))
        #expect(text.contains("- Shipped the exporter"))
        // Empty template sections are skipped like every other empty section.
        #expect(!text.contains("## Blockers"))
    }
}
