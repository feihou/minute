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

    @Test func onlyStandardUsesFixedSchema() {
        #expect(SummaryTemplate.standard.isStandard)
        for template in SummaryTemplate.all where template.id != SummaryTemplate.standard.id {
            #expect(!template.isStandard)
            #expect(template.sections.count >= 3)
        }
    }
}
