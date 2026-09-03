import Foundation
import SwiftData

/// Applies extracted candidates to the knowledge store: resolves entities in
/// code (the prompt's hint list is only a hint — spec §2), dedups against
/// everything already seen including tombstones, assigns trust status
/// (spec §3), and replaces the meeting's still-suggested facts so
/// re-extraction is idempotent — unless the caller says this pass read only
/// part of the transcript, in which case it can only add.
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

    /// - Parameter replacingExisting: whether these candidates are the
    ///   meeting's whole extraction. True — every fully read transcript —
    ///   makes this a replacement, so a re-read decides afresh and repeated
    ///   extraction is idempotent. False is for a pass the guardrails refused
    ///   part of: it speaks only for what it read, so it may only add. A retry
    ///   that is refused a *different* chunk would otherwise delete the facts
    ///   an earlier pass found in the passage this one never reached — and a
    ///   partly read meeting is never stamped, so that trimming would repeat
    ///   on every launch until nothing was left. Merging is safe because the
    ///   dedup loop already reads an exact repeat of a fact this meeting still
    ///   supports as a within-meeting duplicate. The known trade: a fact the
    ///   old transcript stated and the new one does not outlives the edit
    ///   until some pass is refused nothing and replaces the lot — which the
    ///   unstamped meeting keeps trying for, on every launch.
    @discardableResult
    static func apply(
        _ candidates: [KnowledgeCandidate],
        from meeting: Meeting,
        context: ModelContext,
        replacingExisting: Bool = true
    ) throws -> Result {
        var result = Result()
        let meetingID = meeting.id
        // Known entities snapshot, extended as this batch creates new ones so
        // a name mentioned twice in one meeting lands on one entity.
        var known = try context.fetch(FetchDescriptor<KnowledgeEntity>())

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
        // Facts this meeting vouched for before this re-extraction. The
        // pre-loop strips this meeting from them so the new transcript decides
        // afresh, which two things below have to undo. A paraphrase of one must
        // still count as a within-meeting repeat, or it routes to review as a
        // "cross-meeting" near-duplicate and the entity page shows the same
        // claim twice; and the entry itself has to come back when the claim
        // survives, or deleting the other source prunes a fact this transcript
        // still states.
        var previouslySupported: Set<UUID> = []
        // Idempotent re-run: this meeting's unreviewed statements are wholly
        // superseded by this extraction (spec §2), and so is its support for
        // anything another meeting also states. Both fall out of one pass now
        // that support is a single list. Skipped entirely for a partial pass,
        // which has no standing to supersede anything: see `replacingExisting`.
        //
        // ponytail: fetch-all then filter in memory — #Predicate cannot look
        // inside a codable array.
        if replacingExisting {
            let allFacts = try context.fetch(FetchDescriptor<KnowledgeFact>())
            for fact in allFacts where fact.sourceMeetingIDs.contains(meetingID) {
                if fact.sources.count > 1 {
                    // Other meetings state this too, so the row stays. Whether
                    // THIS meeting still states it is decided by its new
                    // transcript, so its entry goes and the loop below re-adds
                    // it if the claim survives — a re-transcribed meeting must
                    // stop vouching for something it no longer says.
                    previouslySupported.insert(fact.id)
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
                if existing.sourceMeetingIDs.contains(meetingID) || previouslySupported.contains(existing.id) { return true }
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
                //
                // Two bars, on deliberately different evidence. Inheriting a row
                // this meeting never sourced takes evidence as strong as the
                // fact itself: the same statement token-for-token in order, and
                // a quote that validated against this transcript. Keeping an
                // entry the pre-loop stripped takes only the match that dropped
                // the candidate — the meeting already vouched for this and still
                // does, and demanding more would record its statement nowhere at
                // all, so deleting the other meeting would prune a fact this
                // transcript states.
                //
                // A reordering is not "still does": `KnowledgeText.statesTheSame`
                // documents why sorted tokens cannot be read as agreement. The
                // entry stays revoked rather than going back to a transcript
                // that says the opposite.
                let sameStatement = KnowledgeText.statesTheSame(duplicate.originalText, candidate.fact)
                let isReordering = !sameStatement
                    && KnowledgeText.normalized(duplicate.originalText) == candidateNormalized
                let keptItsOwnEntry = previouslySupported.contains(duplicate.id) && !isReordering
                let inheritsIt = sameStatement && candidate.validatedQuote != nil
                if duplicate.status != .rejected, keptItsOwnEntry || inheritsIt {
                    // Only a candidate that states the same thing can ground
                    // this row. A retained paraphrase — or a reversal wide
                    // enough to land in the fuzzy band, where `isReordering`
                    // cannot see it — would otherwise file words saying
                    // something else as this fact's evidence, and `sourceQuote`
                    // would display them. Falling back to the entry this meeting
                    // already has keeps a quote an earlier candidate in the same
                    // run validated: `addSource` replaces the meeting's entry,
                    // so without it whichever chunk came out last would decide
                    // alone. The pre-loop stripped every pre-run entry for a
                    // `previouslySupported` fact, so that fallback can only see
                    // this run's own work, never a quote belonging to the
                    // transcript this one replaced.
                    let quote = (sameStatement ? candidate.validatedQuote : nil)
                        ?? duplicate.sources.first { $0.meetingID == meetingID }?.quote
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
