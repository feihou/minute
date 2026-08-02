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

extension MeetingSummary {
    /// True when any field the app presents as the meeting's notes contains
    /// the query — including template sections.
    func matches(_ query: String) -> Bool {
        var fields = [overview] + keyPoints + decisions + openQuestions
            + actionItems.flatMap { [$0.task, $0.owner, $0.deadline] }
        for section in sections ?? [] {
            fields.append(section.title)
            fields.append(contentsOf: section.items)
        }
        return fields.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

struct ActionItem: Codable, Hashable, Sendable {
    /// Canonical placeholder when the transcript never named an owner or deadline.
    static let notSpecified = "Not specified"

    var task: String
    var owner: String
    var deadline: String
}
