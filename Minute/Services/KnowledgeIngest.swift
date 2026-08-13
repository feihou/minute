import Foundation
import SwiftData

/// Applies extracted candidates to the knowledge store: resolves entities in
/// code (the prompt's hint list is only a hint — spec §2), dedups against
/// everything already seen including tombstones, assigns trust status
/// (spec §3), and replaces the meeting's still-suggested facts so
/// re-extraction is idempotent.
@MainActor
enum KnowledgeIngest {
    /// At or above: same fact, drop. (spec §3)
    static let nearDuplicateThreshold = 0.8
    /// In [contradiction, nearDuplicate): potential update → review.
    static let contradictionThreshold = 0.4

    struct Result {
        var autoCaptured = 0
        var suggested = 0
        var duplicatesDropped = 0
    }

    @discardableResult
    static func apply(
        _ candidates: [KnowledgeCandidate],
        from meeting: Meeting,
        context: ModelContext
    ) throws -> Result {
        var result = Result()
        let meetingID = meeting.id
        // Known entities snapshot, extended as this batch creates new ones so
        // a name mentioned twice in one meeting lands on one entity.
        var known = try context.fetch(FetchDescriptor<KnowledgeEntity>())

        // Idempotent re-run: this meeting's unreviewed facts are wholly
        // superseded by this extraction (spec §2).
        let stale = try context.fetch(FetchDescriptor<KnowledgeFact>(
            predicate: #Predicate { $0.sourceMeetingID == meetingID && $0.statusRaw == "suggested" }
        ))
        // context.delete doesn't save immediately, so deleted-but-unsaved
        // facts stay visible in entity.facts until try context.save() below.
        // Dedup/contradiction scans over entity.facts must skip these IDs or
        // a replacement fact with matching text "duplicates" the very fact
        // it's replacing, and the meeting ends up with zero facts.
        let staleIDs = Set(stale.map(\.id))
        // Entities whose fact set changes here get their synthesis marker
        // cleared below: a re-extraction can swap facts one-for-one, so
        // count-based staleness alone would miss the content change.
        var touched: [UUID: KnowledgeEntity] = [:]
        for fact in stale {
            if let entity = fact.entity { touched[entity.id] = entity }
            context.delete(fact)
        }

        for candidate in candidates {
            let resolved = resolve(candidate, in: &known, context: context)
            let entity = resolved.entity

            // Dedup (spec §2): tombstone fingerprints and exact normalized
            // repeats drop from any meeting; fuzzy near-dupes drop only
            // within the same meeting (re-extraction paraphrases). A fuzzy
            // near-dupe from a DIFFERENT meeting is never silently dropped —
            // it routes to review below, so "Bob joined"/"Bob left"-class
            // pairs can't merge unseen.
            let candidateFingerprint = KnowledgeText.fingerprint(candidate.fact, entityID: entity.id)
            let candidateNormalized = KnowledgeText.normalized(candidate.fact)
            var crossMeetingNearDuplicate = false
            let isDuplicate = entity.facts.contains { existing in
                if staleIDs.contains(existing.id) { return false }
                if existing.status == .rejected {
                    return existing.fingerprint == candidateFingerprint
                }
                if KnowledgeText.normalized(existing.originalText) == candidateNormalized {
                    return true
                }
                guard KnowledgeText.tokenOverlap(existing.originalText, candidate.fact) >= nearDuplicateThreshold else {
                    return false
                }
                if existing.sourceMeetingID == meetingID { return true }
                crossMeetingNearDuplicate = true
                return false
            }
            if isDuplicate {
                result.duplicatesDropped += 1
                continue
            }

            let contradictsApproved = entity.facts.contains { existing in
                // Stale facts are always `.suggested`, so this can't trigger
                // today — filtered anyway to keep the invariant explicit.
                !staleIDs.contains(existing.id)
                    && (existing.status == .approved || existing.status == .autoCaptured)
                    && KnowledgeText.tokenOverlap(existing.originalText, candidate.fact) >= contradictionThreshold
            }

            // Trust rules (spec §3): auto-capture needs a validated quote, a
            // resolved (pre-existing, non-Me) entity, and no contradiction.
            let status: FactStatus
            if resolved.isNew || entity.kind == .me || contradictsApproved
                || crossMeetingNearDuplicate || candidate.validatedQuote == nil {
                status = .suggested
                result.suggested += 1
            } else {
                status = .autoCaptured
                result.autoCaptured += 1
            }

            context.insert(KnowledgeFact(
                text: candidate.fact,
                originalText: candidate.fact,
                status: status,
                sourceMeetingID: meetingID,
                sourceQuote: candidate.validatedQuote,
                capturedAt: meeting.createdAt,
                entity: entity
            ))
            touched[entity.id] = entity
        }
        for entity in touched.values {
            entity.synthesizedFactCount = nil
        }
        try context.save()
        return result
    }

    /// Deterministic post-extraction resolution: exact normalized match on
    /// any name or alias wins (following merge redirects); otherwise a new
    /// entity is created and added to `known`. Near-miss "possible duplicate"
    /// cards are m2 UI — a new entity's facts land in review either way.
    private static func resolve(
        _ candidate: KnowledgeCandidate,
        in known: inout [KnowledgeEntity],
        context: ModelContext
    ) -> (entity: KnowledgeEntity, isNew: Bool) {
        let needle = KnowledgeText.normalized(candidate.entityName)
        if let match = known.first(where: { entity in
            ([entity.name] + entity.aliases).contains { KnowledgeText.normalized($0) == needle }
        }) {
            let resolved = match.redirectTo.flatMap { id in known.first { $0.id == id } } ?? match
            return (resolved, false)
        }
        let fresh = KnowledgeEntity(name: candidate.entityName, kind: candidate.entityKind)
        context.insert(fresh)
        known.append(fresh)
        return (fresh, true)
    }
}
