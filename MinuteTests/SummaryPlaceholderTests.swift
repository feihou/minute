import Foundation
import Testing
@testable import Minute

/// The "Not specified" contract. Both engines funnel owner/deadline through
/// SummarizationService.normalizedField, and it is the only thing standing
/// between a model that paraphrased the literal it was told to write and a
/// detail caption (or an exported notes.md) that reads as if someone named
/// "TBD" owned the task.
struct SummaryPlaceholderTests {
    @Test func realValuesSurviveNormalization() {
        #expect(SummarizationService.normalizedField("  Maria  ") == "Maria")
        #expect(SummarizationService.normalizedField("Friday") == "Friday")
        // A real name that merely contains a placeholder word is a real name.
        #expect(SummarizationService.normalizedField("Nobody Jones") == "Nobody Jones")
        #expect(SummarizationService.normalizedField("None of the above team") == "None of the above team")
    }

    @Test func englishPlaceholdersBecomeTheLiteral() {
        let values = [
            "", "   ", "Not specified", "not specified.", "NONE", "unknown",
            "N/A", "n/a.", "na", "TBD", "tba", "Unspecified", "Not stated",
            "not mentioned", "Not given", "not assigned", "Nobody", "no one",
            "No owner", "no deadline", "not applicable", "to be determined",
            "-", "—", "…", "\"Not specified\"",
        ]
        for value in values {
            #expect(SummarizationService.normalizedField(value) == ActionItem.notSpecified, "\(value)")
        }
    }

    @Test func localizedPlaceholdersBecomeTheLiteral() {
        // One per Summary Language option, in the order the picker lists them:
        // a language override makes the model answer in that language, and its
        // placeholder comes along.
        let values = [
            "Not specified",     // English
            "No especificado",   // Spanish
            "Non spécifié",      // French
            "Nicht angegeben",   // German
            "Non specificato",   // Italian
            "Não especificado",  // Portuguese
            "未定",               // Japanese
            "미정",               // Korean
            "待定",               // Chinese
        ]
        #expect(values.count == AppSettings.summaryLanguageOptions.count)
        for value in values {
            #expect(SummarizationService.normalizedField(value) == ActionItem.notSpecified, "\(value)")
        }
        // Wrapped in the punctuation a model likes to add.
        #expect(SummarizationService.normalizedField("「未定」") == ActionItem.notSpecified)
        #expect(SummarizationService.normalizedField("Sin asignar.") == ActionItem.notSpecified)
    }
}
