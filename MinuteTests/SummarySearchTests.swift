import Testing
@testable import Minute

struct SummarySearchTests {
    private let templated = MeetingSummary(
        overview: "Daily sync about the release.",
        keyPoints: [],
        decisions: [],
        actionItems: [ActionItem(task: "Ship the exporter", owner: "Maria", deadline: ActionItem.notSpecified)],
        openQuestions: [],
        generatedAt: .now,
        sections: [
            SummarySection(title: "Blockers", items: ["Waiting on app icons from design"]),
            SummarySection(title: "Growth & Career", items: []),
        ]
    )

    @Test func matchesTemplateSectionItems() {
        #expect(templated.matches("app icons"))
        #expect(templated.matches("blockers"))
    }

    @Test func matchesFixedFieldsAndActionItems() {
        #expect(templated.matches("release"))
        #expect(templated.matches("maria"))
    }

    @Test func emptySectionsAreInvisibleToSearch() {
        // The UI hides empty sections, so their titles must not match either.
        #expect(!templated.matches("growth"))
    }

    @Test func rejectsNonMatches() {
        #expect(!templated.matches("budget"))
    }
}
