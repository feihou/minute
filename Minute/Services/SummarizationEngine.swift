import Foundation

/// The summarization contract MeetingJobs talks to, instead of a concrete
/// engine: transcript in, MeetingSummary out. Chunking, prompting, and
/// structured-output strategy are each engine's own business.
@MainActor
protocol SummarizationEngine {
    /// Nil when the engine is ready; otherwise a user-facing explanation.
    var availabilityMessage: String? { get }

    func summarize(
        transcript: String,
        template: SummaryTemplate,
        context: String,
        onProgress: (@MainActor @Sendable (String) -> Void)?
    ) async throws -> MeetingSummary
}

/// Picks the engine the user selected in Settings.
@MainActor
enum SummarizationEngines {
    static func current(language: String?) -> any SummarizationEngine {
        switch AppSettings.summarizationEngine {
        case .appleIntelligence: SummarizationService(language: language)
        case .localModel: MLXSummarizationService(language: language)
        }
    }

    /// Warms the selected engine ahead of a likely summarize, so the first
    /// request doesn't also pay the model-load wait. Only Apple Intelligence
    /// supports it; the MLX engine loads its weights lazily.
    static func prewarm(language: String?) {
        if case .appleIntelligence = AppSettings.summarizationEngine {
            SummarizationService.prewarm(language: language)
        }
    }

    /// Availability of the SELECTED engine — the gate every auto-summarize
    /// and capability check reads. Nil means ready.
    static var availabilityMessage: String? {
        switch AppSettings.summarizationEngine {
        case .appleIntelligence: SummarizationService.availabilityMessage
        case .localModel: MLXSummarizationService.availabilityMessage
        }
    }
}
