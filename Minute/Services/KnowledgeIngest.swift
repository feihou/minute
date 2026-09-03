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

        // Idempotent re-run: this meeting's unreviewed statements are wholly
        // superseded by this extraction (spec §2), and so is its support for
        // anything another meeting also states. Both fall out of one pass now
        // that support is a single list.
        //
        // ponytail: fetch-all then filter in memory — #Predicate cannot look
        // inside a codable array.
        let allFacts = try context.fetch(FetchDescriptor<KnowledgeFact>())
        // context.delete doesn't save immediately, so deleted-but-unsaved facts
        // stay visible in entity.facts until try context.save() below.
        // Dedup/contradiction scans over entity.facts must skip these IDs or a
        // replacement fact with matching text "duplicates" the very fact it is
        // replacing, and the meeting ends up with zero facts.
        var staleIDs: Set<UUID> = []
        // Entities whose fact set changes here get their synthesis marker
        // cleared below: a re-extraction can swap facts one-for-one, so
        // count-based staleness alone would miss the content change.
        var touched: [UUID: KnowledgeEntity] = [:]
        for fact in allFacts where fact.sourceMeetingIDs.contains(meetingID) {
            if fact.sources.count > 1 {
                // Other meetings state this too, so the row stays. Whether THIS
                // meeting still states it is decided by its new transcript, so
                // its entry goes and the loop below re-adds it if the claim
                // survives — a re-transcribed meeting must stop vouching for
                // something it no longer says.
                fact.removeSource(meetingID: meetingID)
                if let entity = fact.entity { touched[entity.id] = entity }
            } else if fact.status == .suggested {
                staleIDs.insert(fact.id)
                if let entity = fact.entity { touched[entity.id] = entity }
                context.delete(fact)
            }
            // An approved or auto-captured row this meeting alone states
            // survives re-extraction untouched (spec §2).
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
            // first(where:), not contains: the matched row is needed below to
            // record that this meeting says the same thing.
            let duplicate = entity.facts.first { existing in
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
                // sourceMeetingIDs, not sourceMeetingID: an earlier candidate
                // in this same run may have corroborated this row, which makes
                // a later paraphrase a within-meeting repeat rather than a
                // cross-meeting one worth sending to review.
                if existing.sourceMeetingIDs.contains(meetingID) { return true }
                crossMeetingNearDuplicate = true
                return false
            }
            if let duplicate {
                // Dropping the candidate leaves that one row as the only record
                // of a claim both meetings make, and this meeting is about to be
                // stamped as extracted, so it will never be read again. Note the
                // corroboration, or deleting the first meeting would discard
                // knowledge this one still supports. Tombstones are excluded:
                // they exist to keep a rejected claim out, not to hold sources.
                // Only on evidence as strong as the fact itself: the same
                // statement token-for-token in order, and a quote that actually
                // validated against this transcript. A looser match is still a
                // fair reason to drop the candidate — it is not a reason to let
                // this meeting inherit the fact once the original source goes.
                if duplicate.status != .rejected,
                   let quote = candidate.validatedQuote,
                   KnowledgeText.statesTheSame(duplicate.originalText, candidate.fact) {
                    // The restatement brings its own quote now, so the row no
                    // longer depends on one meeting's phrasing to explain it.
                    let newestBefore = duplicate.capturedAt
                    duplicate.addSource(FactSource(
                        meetingID: meetingID, quote: quote, capturedAt: meeting.createdAt
                    ))
                    // A dated source can make this fact the entity's newest,
                    // and synthesis is fed newest-first with "prefer the newer
                    // on conflict" — the count-based freshness marker cannot
                    // see a reorder, so mark the entity for a rebuild.
                    if duplicate.capturedAt != newestBefore, let entity = duplicate.entity {
                        touched[entity.id] = entity
                    }
                }
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
        // A re-extraction can empty an entity: a new entity only ever gets
        // `.suggested` facts, and this meeting's still-suggested facts were
        // deleted above. Nothing later would remove it — reconcile only
        // examines entities whose facts lost a source — so its name (learned
        // from this meeting) would stay on disk with nothing to show and no
        // delete path. Remove it now; a merge tombstone pointing at it, or
        // the Me entity, is left alone.
        let redirectTargets = Set(known.compactMap(\.redirectTo))
        for entity in touched.values where entity.kind != .me {
            guard entity.redirectTo == nil, !redirectTargets.contains(entity.id) else { continue }
            let remaining = entity.facts.filter { !staleIDs.contains($0.id) }
            if remaining.isEmpty {
                context.delete(entity)
            }
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
