import Foundation
import OSLog
import SwiftData

/// Removes the knowledge a meeting produced when that meeting goes away.
///
/// A fact's sources are a codable list rather than a SwiftData relationship —
/// entity pages are built to tolerate a deleted source meeting — so no delete
/// rule cascades here and the cleanup has to be explicit.
///
/// "Produced" means facts no surviving meeting still supports. Deleting a
/// meeting drops its entry from every fact's source list; a fact other meetings
/// also state simply keeps theirs, and its date and quote follow on their own
/// because both are derived.
enum KnowledgeStore {
    private static let logger = Logger(subsystem: "com.minuteapp.Minute", category: "KnowledgeStore")

    /// Brings the knowledge base back in line with the meetings that exist.
    ///
    /// Call after deleting a meeting, and once at launch — the launch pass also
    /// covers meetings deleted by a build that predates this and any earlier
    /// call whose save failed. Returns false when the store could not be read
    /// or saved, in which case nothing was changed.
    ///
    /// Deliberately takes no meeting: with sources a uniform list, reconciling
    /// after one deletion and reconciling the whole library are the same work,
    /// and a parameter would only invite the two to drift apart.
    @discardableResult
    static func reconcile(context: ModelContext) -> Bool {
        reconcileStore(context: context)
    }

    /// Drops deleted meetings' support from every fact, then clears up what is
    /// left behind. Both entry points funnel here because, once sources are a
    /// uniform list, "this meeting was deleted" and "these meetings are gone"
    /// are the same operation.
    ///
    /// A failed read must never be mistaken for "the library is empty": that
    /// would strip every fact of its support and delete the lot, turning a
    /// transient error into permanent knowledge loss.
    private static func reconcileStore(context: ModelContext) -> Bool {
        let liveMeetings: [Meeting]
        let allEntities: [KnowledgeEntity]
        let allFacts: [KnowledgeFact]
        do {
            liveMeetings = try context.fetch(FetchDescriptor<Meeting>())
            allEntities = try context.fetch(FetchDescriptor<KnowledgeEntity>())
            allFacts = try context.fetch(FetchDescriptor<KnowledgeFact>())
        } catch {
            logger.error("Could not read the store while removing knowledge, so nothing was removed: \(error.localizedDescription)")
            return false
        }
        let liveIDs = Set(liveMeetings.map(\.id))

        // One pass replaces the old promote-or-delete branch and the separate
        // corroboration prune. A fact keeps whatever support survives, and its
        // date and quote follow on their own because both are derived — nothing
        // is re-pointed, so nothing can be re-pointed wrongly.
        var removable: [KnowledgeFact] = []
        // Entities to re-check for emptiness: anything that lost support at all.
        var changedEntities: Set<UUID> = []
        // Entities whose narrative must be rebuilt: only those where a fact the
        // narrative is written from lost support. A tombstone contributes
        // nothing to it, so re-checking one must not churn an accurate summary.
        var lostVisibleSupport: Set<UUID> = []
        var changed = false
        for fact in allFacts {
            let before = fact.sources
            fact.sources.removeAll { !liveIDs.contains($0.meetingID) }
            guard fact.sources.count != before.count else { continue }
            changed = true
            if let entity = fact.entity {
                changedEntities.insert(entity.id)
                if fact.status != .rejected {
                    // Losing a source can change which statement is newest, and
                    // synthesis is fed newest-first and told to prefer the newer
                    // fact on conflict — so its narrative has to be rebuilt.
                    lostVisibleSupport.insert(entity.id)
                }
            }
            // A tombstone holds no meeting content, only a salted fingerprint
            // keeping a rejected claim out. It is never removed for lack of
            // support; it goes only with its entity.
            if fact.sources.isEmpty, fact.status != .rejected {
                removable.append(fact)
            }
        }
        let removedIDs = Set(removable.map(\.id))
        for fact in removable {
            context.delete(fact)
        }

        var doomed: [UUID: KnowledgeEntity] = [:]
        for entity in allEntities where changedEntities.contains(entity.id) {
            // Judged against `removedIDs` rather than re-reading `entity.facts`,
            // which still lists rows that are deleted-pending until the save.
            if entity.visibleFacts.contains(where: { !removedIDs.contains($0.id) }) {
                guard lostVisibleSupport.contains(entity.id) else { continue }
                entity.synthesis = nil
                entity.synthesizedFactCount = nil
            } else if entity.redirectTo == nil {
                // Nothing left to show. An entity holding only tombstones goes
                // too, since its name was still learned from these meetings —
                // unless one of those tombstones came from a meeting that is
                // still here. A rejection fingerprint is salted with the
                // entity's id, so deleting the entity and letting a later
                // extraction recreate it under a fresh id would quietly
                // un-reject a claim the user threw out.
                let backedByALiveMeeting = entity.facts.contains { fact in
                    !removedIDs.contains(fact.id)
                        && fact.sourceMeetingIDs.contains(where: liveIDs.contains)
                }
                if !backedByALiveMeeting {
                    doomed[entity.id] = entity
                }
            }
        }
        settleInboundRedirects(to: &doomed, among: allEntities, removedIDs: removedIDs)
        for entity in doomed.values {
            context.delete(entity)
        }

        guard changed || !doomed.isEmpty else { return true }
        do {
            try context.save()
        } catch {
            logger.error("Failed to remove the knowledge from a deleted meeting: \(error.localizedDescription)")
            return false
        }
        return true
    }

    /// A merged-away entity exists only to point at the entity that won the
    /// merge. Once that winner is being removed the tombstone leads nowhere, and
    /// resolution falling back to the tombstone itself would attach newly
    /// extracted facts to an entity every Brain surface filters out.
    ///
    /// One that still holds knowledge of its own is not disposable, though —
    /// deleting it would cascade to facts a kept meeting still supports. It
    /// stops being a tombstone instead and stands on its own name. Empty ones go
    /// with their destination, following the chain, since a winner may itself
    /// have been merged away.
    private static func settleInboundRedirects(
        to doomed: inout [UUID: KnowledgeEntity],
        among all: [KnowledgeEntity],
        removedIDs: Set<UUID>
    ) {
        guard !doomed.isEmpty else { return }
        var queue = Array(doomed.keys)
        while let destination = queue.popLast() {
            for entity in all where entity.redirectTo == destination && doomed[entity.id] == nil {
                if entity.visibleFacts.contains(where: { !removedIDs.contains($0.id) }) {
                    entity.redirectTo = nil
                } else {
                    doomed[entity.id] = entity
                    queue.append(entity.id)
                }
            }
        }
    }
}
