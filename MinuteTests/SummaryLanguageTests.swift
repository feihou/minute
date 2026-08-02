import Testing
@testable import Minute

struct SummaryLanguageTests {
    @Test func defaultRulesFollowTheMeetingLanguage() {
        let rules = SummarizationService.groundingRules(language: nil)
        #expect(rules.contains("language the meeting is mainly spoken in"))
    }

    @Test func overrideRulesNameTheLanguage() {
        let rules = SummarizationService.groundingRules(language: "Spanish")
        #expect(rules.contains("Write the notes in Spanish."))
        #expect(!rules.contains("mainly spoken in"))
    }

    @Test func everyPickerOptionProducesValidRules() {
        for language in AppSettings.summaryLanguageOptions {
            #expect(SummarizationService.groundingRules(language: language).contains("Write the notes in \(language)."))
        }
    }
}
