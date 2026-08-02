import Foundation

/// A notes layout for a kind of meeting. The standard template uses the fixed
/// key-points/decisions/open-questions schema; the others define their own
/// sections and share the same overview, title, and action items.
struct SummaryTemplate: Identifiable, Hashable, Sendable {
    struct SectionPlan: Hashable, Sendable {
        /// Section name shown in the notes and requested from the model.
        let name: String
        /// What belongs in the section — injected into the generation prompt.
        let definition: String
    }

    let id: String
    let name: String
    /// Empty for the standard template, which uses the fixed schema.
    let sections: [SectionPlan]

    var isStandard: Bool { sections.isEmpty }

    static let standard = SummaryTemplate(id: "standard", name: "Standard Meeting", sections: [])

    static let standup = SummaryTemplate(id: "standup", name: "Daily Standup", sections: [
        SectionPlan(name: "Yesterday",
                    definition: "work completed since the last standup, one item per person or topic, naming who did it when stated"),
        SectionPlan(name: "Today",
                    definition: "work planned next, one item per person or topic"),
        SectionPlan(name: "Blockers",
                    definition: "impediments or risks raised, naming who is blocked and what they need"),
    ])

    static let retrospective = SummaryTemplate(id: "retrospective", name: "Retrospective", sections: [
        SectionPlan(name: "What Went Well",
                    definition: "successes and positives the team called out"),
        SectionPlan(name: "What Didn't Go Well",
                    definition: "problems, misses, and pain points raised"),
        SectionPlan(name: "Improvements",
                    definition: "changes and experiments the team agreed to try"),
    ])

    static let oneOnOne = SummaryTemplate(id: "one-on-one", name: "One-on-One", sections: [
        SectionPlan(name: "Updates",
                    definition: "progress and status shared by either person"),
        SectionPlan(name: "Feedback",
                    definition: "feedback exchanged in either direction"),
        SectionPlan(name: "Growth & Career",
                    definition: "development goals, aspirations, and growth topics discussed"),
        SectionPlan(name: "Concerns",
                    definition: "worries or issues raised"),
    ])

    static let salesCall = SummaryTemplate(id: "sales-call", name: "Sales Call", sections: [
        SectionPlan(name: "Customer Needs",
                    definition: "problems, requirements, and goals the customer stated"),
        SectionPlan(name: "Product Discussion",
                    definition: "what was presented or demoed and how the customer reacted"),
        SectionPlan(name: "Objections & Concerns",
                    definition: "pushback, risks, and competitor mentions"),
        SectionPlan(name: "Next Steps",
                    definition: "agreed follow-ups and timeline"),
    ])

    static let all: [SummaryTemplate] = [standard, standup, retrospective, oneOnOne, salesCall]

    /// Falls back to the standard template for unknown ids.
    static func template(for id: String) -> SummaryTemplate {
        all.first { $0.id == id } ?? .standard
    }
}
