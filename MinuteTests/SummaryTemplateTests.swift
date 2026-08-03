import Testing
@testable import Minute

struct SummaryTemplateTests {
    @Test func templateIDsAreUnique() {
        let ids = SummaryTemplate.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func lookupFallsBackToStandard() {
        #expect(SummaryTemplate.template(for: "nonsense") == .standard)
        #expect(SummaryTemplate.template(for: "") == .standard)
    }

    @Test func lookupFindsEveryTemplate() {
        for template in SummaryTemplate.all {
            #expect(SummaryTemplate.template(for: template.id) == template)
        }
    }

    @Test func reconcileRestoresTemplateOrderAndFillsMissingSections() {
        let returned = [
            SummarySection(title: "blockers", items: ["Waiting on icons"]),
            SummarySection(title: "Yesterday", items: ["Shipped exporter"]),
        ]
        let sections = SummarizationService.reconciledSections(returned, with: .standup)

        #expect(sections.map(\.title) == ["Yesterday", "Today", "Blockers"])
        #expect(sections[0].items == ["Shipped exporter"])
        #expect(sections[1].items.isEmpty)
        #expect(sections[2].items == ["Waiting on icons"])
    }

    @Test func reconcileMergesDuplicatesAndKeepsExtrasWithContent() {
        let returned = [
            SummarySection(title: "Today", items: ["Settings page"]),
            SummarySection(title: "today", items: ["API review"]),
            SummarySection(title: "Random Extra", items: ["Off-template note"]),
            SummarySection(title: "Empty Extra", items: []),
        ]
        let sections = SummarizationService.reconciledSections(returned, with: .standup)

        #expect(sections.map(\.title) == ["Yesterday", "Today", "Blockers", "Random Extra"])
        #expect(sections[1].items == ["Settings page", "API review"])
    }

    @Test func reconcileEmptyModelOutputStillYieldsTemplateSections() {
        let sections = SummarizationService.reconciledSections([], with: .retrospective)
        #expect(sections.map(\.title) == SummaryTemplate.retrospective.sections.map(\.name))
        #expect(sections.allSatisfy { $0.items.isEmpty })
    }

    @Test func onlyStandardUsesFixedSchema() {
        #expect(SummaryTemplate.standard.isStandard)
        for template in SummaryTemplate.all where template.id != SummaryTemplate.standard.id {
            #expect(!template.isStandard)
            #expect(template.sections.count >= 3)
        }
    }
}
