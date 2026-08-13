import Foundation
import SwiftData

/// What an entity page is about. Raw values are persisted — keep them stable.
enum EntityKind: String, Codable, CaseIterable {
    case person, project, topic, me
}

@Model
final class KnowledgeEntity {
    var id: UUID
    var name: String
    /// Raw so #Predicate can filter; use `kind` in code.
    var kindRaw: String
    /// Alternate names resolving to this entity — grown by review reassignment
    /// and merges. Codable array (aliases are only ever read whole).
    var aliases: [String]
    /// FM-generated 2–3 sentence narrative; generated in milestone 2.
    var synthesis: String?
    var createdAt: Date
    /// Set when merged away; resolution follows this to the winner (m2).
    var redirectTo: UUID?
    /// Visible-fact count synthesis was last generated from; the narrative
    /// is stale when the live count differs. Nil = never synthesized.
    /// ponytail: count-based staleness misses same-count text edits; m2b's
    /// review actions clear this field to force a refresh.
    var synthesizedFactCount: Int?
    @Relationship(deleteRule: .cascade, inverse: \KnowledgeFact.entity)
    var facts: [KnowledgeFact]

    var kind: EntityKind {
        get { EntityKind(rawValue: kindRaw) ?? .topic }
        set { kindRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        name: String,
        kind: EntityKind,
        aliases: [String] = [],
        synthesis: String? = nil,
        createdAt: Date = .now,
        redirectTo: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.kindRaw = kind.rawValue
        self.aliases = aliases
        self.synthesis = synthesis
        self.createdAt = createdAt
        self.redirectTo = redirectTo
        self.facts = []
    }
}

extension KnowledgeEntity {
    /// Facts shown on entity pages and fed to synthesis: everything except
    /// tombstones and superseded history, newest meeting first.
    var visibleFacts: [KnowledgeFact] {
        facts
            .filter { $0.status == .autoCaptured || $0.status == .approved || $0.status == .suggested }
            .sorted { $0.capturedAt > $1.capturedAt }
    }
}
