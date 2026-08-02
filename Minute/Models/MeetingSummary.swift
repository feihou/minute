import Foundation

struct MeetingSummary: Codable, Hashable, Sendable {
    var overview: String
    var keyPoints: [String]
    var decisions: [String]
    var actionItems: [ActionItem]
    var openQuestions: [String]
    var generatedAt: Date
}

struct ActionItem: Codable, Hashable, Sendable {
    /// Canonical placeholder when the transcript never named an owner or deadline.
    static let notSpecified = "Not specified"

    var task: String
    var owner: String
    var deadline: String
}
