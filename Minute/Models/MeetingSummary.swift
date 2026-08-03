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
    /// How many transcript parts failed and were left out of these notes.
    /// Nil/zero when the whole meeting was summarized.
    var skippedParts: Int? = nil
    /// Each speaker's own ideas and positions; present only when the
    /// transcript carried speaker labels. Optional so older stored
    /// summaries keep decoding.
    var speakerPerspectives: [SpeakerPerspective]? = nil
}

struct SpeakerPerspective: Codable, Hashable, Sendable {
    var speaker: String
    var points: [String]
}

struct SummarySection: Codable, Hashable, Sendable {
    var title: String
    var items: [String]
}

extension MeetingSummary {
    /// True when any field the app presents as the meeting's notes contains
    /// the query — including template sections. Empty sections are excluded:
    /// they aren't rendered anywhere, so their titles shouldn't match either.
    func matches(_ query: String) -> Bool {
        var fields = [overview] + keyPoints + decisions + openQuestions
            + actionItems.flatMap { [$0.task, $0.owner, $0.deadline] }
        for section in sections ?? [] where !section.items.isEmpty {
            fields.append(section.title)
            fields.append(contentsOf: section.items)
        }
        for perspective in speakerPerspectives ?? [] where !perspective.points.isEmpty {
            fields.append(perspective.speaker)
            fields.append(contentsOf: perspective.points)
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
