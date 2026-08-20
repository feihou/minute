// Minute/Support/KnowledgeBrief.swift
import Foundation

/// Pure selectors behind the two surfaces where the brain shows up without
/// being visited: the pre-meeting "What you know" brief (spec §6 — the
/// delivery route) and the Brain tab's "Recently learned" stream.
enum KnowledgeBrief {
    /// Facts shown per matched participant in the brief.
    static let factsPerEntity = 3

    /// The facts worth showing before a meeting: settled knowledge from
    /// OTHER meetings. Facts extracted from this same meeting are excluded —
    /// "what you know" must not echo the recording that produced it — and so
    /// are unreviewed drafts, which the entity page badges but this compact
    /// surface can't (spec §3: drafts are visible AS drafts or not at all).
    static func briefFacts(for entity: KnowledgeEntity, excludingMeetingID meetingID: UUID) -> [KnowledgeFact] {
        Array(
            entity.settledFacts
                // Full source set, not just the primary: a fact this meeting
                // restated was deduped onto another meeting's row, and showing
                // it as prior knowledge would credit this meeting's own words
                // to a surface that promises what you knew beforehand.
                .filter { !$0.sourceMeetingIDs.contains(meetingID) }
                .prefix(factsPerEntity)
        )
    }

    /// People whose name or alias matches one of this meeting's speaker
    /// names (normalized: case, diacritics, token order). "Speaker N"
    /// placeholders never match because no entity carries that name.
    static func matchedEntities(speakerNames: [String]?, entities: [KnowledgeEntity]) -> [KnowledgeEntity] {
        guard let speakerNames else { return [] }
        let needles = Set(
            speakerNames
                .map(KnowledgeText.normalized)
                .filter { !$0.isEmpty }
        )
        guard !needles.isEmpty else { return [] }
        return entities.filter { entity in
            entity.redirectTo == nil && entity.kind == .person
                && ([entity.name] + entity.aliases).contains { needles.contains(KnowledgeText.normalized($0)) }
        }
    }

    /// The newest auto-captured facts across the whole brain — provenance
    /// plus cheap reversibility is the trust mechanism, and this stream is
    /// where auto-captured facts stay noticeable (spec §3). Insertion time
    /// orders it; m1-era rows fall back to their meeting date.
    static func recentlyLearned(from entities: [KnowledgeEntity], limit: Int = 5) -> [KnowledgeFact] {
        entities
            .filter { $0.redirectTo == nil }
            .flatMap { $0.facts.filter { $0.status == .autoCaptured } }
            .sorted { ($0.createdAt ?? $0.capturedAt) > ($1.createdAt ?? $1.capturedAt) }
            .prefix(limit)
            .map { $0 }
    }
}
