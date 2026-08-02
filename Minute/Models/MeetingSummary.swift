import Foundation

struct MeetingSummary: Codable, Hashable, Sendable {
    var overview: String
    var keyPoints: [String]
    var decisions: [String]
    var actionItems: [ActionItem]
    var openQuestions: [String]
    var generatedAt: Date
    /// Model-suggested meeting title; applied only while the meeting still
    /// has its default "Meeting <date>" title. Optional so older stored
    /// summaries keep decoding.
    var suggestedTitle: String? = nil
    /// Template-defined sections (e.g. Yesterday/Today/Blockers). Nil for
    /// standard-template summaries, which use the fixed fields above.
    var sections: [SummarySection]? = nil
}

struct SummarySection: Codable, Hashable, Sendable {
    var title: String
    var items: [String]
}

struct ActionItem: Codable, Hashable, Sendable {
    /// Canonical placeholder when the transcript never named an owner or deadline.
    static let notSpecified = "Not specified"

    var task: String
    var owner: String
    var deadline: String
}
