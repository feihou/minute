import Foundation
import OSLog
import SwiftData

/// Removes the knowledge a meeting produced when that meeting goes away.
///
/// `KnowledgeFact.sourceMeetingID` is a plain UUID rather than a SwiftData
/// relationship — entity pages are built to tolerate a deleted source meeting —
/// so no delete rule cascades here and the cleanup has to be explicit.
///
/// "Produced" means facts no surviving meeting still supports. A fact another
/// meeting restated word for word is re-pointed at that meeting instead of
/// being deleted, because dedup collapsed both statements into this one row.
enum KnowledgeStore {
    private static let logger = Logger(subsystem: "com.minuteapp.Minute", category: "KnowledgeStore")

    /// Removes every fact extracted from `meetingID`, then tidies the entities
    /// left behind. Returns false when the store could not be saved; the launch
    /// sweep is the backstop for that case.
    @discardableResult
    static func purgeFacts(fromMeeting meetingID: UUID, context: ModelContext) -> Bool {
        let descriptor = FetchDescriptor<KnowledgeFact>(
            predicate: #Predicate { $0.sourceMeetingID == meetingID }
        )
        guard let facts = try? context.fetch(descriptor) else {
            logger.error("Could not fetch the facts belonging to a deleted meeting")
            return false
        }
        return remove(facts, context: context)
    }

    /// Removes facts whose source meeting no longer exists. Covers two cases a
    /// per-delete purge cannot: meetings deleted by a build that predates the
    /// purge, and a purge whose save failed.
    @discardableResult
    static func sweepOrphanedFacts(liveMeetingIDs: Set<UUID>, context: ModelContext) -> Bool {
        // ponytail: fetch-all then filter in memory — #Predicate cannot express
        // "not in this set". Facts are per-meeting small; move to a batched
        // fetch if a large library ever makes this scan noticeable.
        guard let all = try? context.fetch(FetchDescriptor<KnowledgeFact>()) else {
            logger.error("Could not fetch facts for the orphan sweep")
            return false
        }
        return remove(all.filter { !liveMeetingIDs.contains($0.sourceMeetingID) }, context: context)
    }

    private static func remove(_ facts: [KnowledgeFact], context: ModelContext) -> Bool {
        guard !facts.isEmpty else { return true }

        // A fact several meetings state identically exists as one row: dedup
        // drops the repeats and stamps their meetings as extracted, so they are
        // never read again. Deleting the row's source must therefore hand the
        // fact to a meeting that is still here rather than discard a claim the
        // library still supports.
        //
        // A failed read must never be mistaken for "the library is empty": that
        // would leave every fact without a surviving source and delete the lot,
        // turning a transient error into permanent knowledge loss.
        let liveMeetings: [Meeting]
        let allEntities: [KnowledgeEntity]
        do {
            liveMeetings = try context.fetch(FetchDescriptor<Meeting>())
            allEntities = try context.fetch(FetchDescriptor<KnowledgeEntity>())
        } catch {
            logger.error("Could not read the store while removing knowledge, so nothing was removed: \(error.localizedDescription)")
            return false
        }
        let liveDates = Dictionary(liveMeetings.map { ($0.id, $0.createdAt) }, uniquingKeysWith: { first, _ in first })
        let liveIDs = Set(liveDates.keys)

        // Rejected facts are tombstones: the text is already cleared and only a
        // salted fingerprint remains, whose whole job is to stop a claim the
        // user rejected from reappearing via a different meeting. They are never
        // removed on their own — but they cannot keep an otherwise-empty
        // entity's learned name alive either, so they still count toward the
        // emptiness check below.
        var removable: [KnowledgeFact] = []
        var promoted = 0
        var candidates: [UUID: KnowledgeEntity] = [:]
        var lostAFact: Set<UUID> = []
        for fact in facts {
            if let entity = fact.entity {
                candidates[entity.id] = entity
            }
            guard fact.status != .rejected else { continue }
            if let survivor = fact.sourceMeetingIDs.first(where: { liveIDs.contains($0) }),
               let date = liveDates[survivor] {
                fact.promoteSource(to: survivor, capturedAt: date, liveMeetingIDs: liveIDs)
                promoted += 1
            } else {
                removable.append(fact)
                if let entity = fact.entity {
                    lostAFact.insert(entity.id)
                }
            }
        }
        let removedIDs = Set(removable.map(\.id))
        for fact in removable {
            context.delete(fact)
        }

        var doomed: [UUID: KnowledgeEntity] = [:]
        for entity in candidates.values {
            // Judged against `removedIDs` rather than re-reading `entity.facts`,
            // which still lists rows that are deleted-pending until the save.
            if entity.visibleFacts.contains(where: { !removedIDs.contains($0.id) }) {
                // Only an entity that actually lost a fact needs its narrative
                // rewritten. Re-selecting a retained tombstone on a later sweep
                // must not churn one that is still accurate.
                if lostAFact.contains(entity.id) {
                    entity.synthesis = nil
                    entity.synthesizedFactCount = nil
                }
            } else if entity.redirectTo == nil {
                // Nothing left to show — including an entity holding only
                // tombstones, whose name was still learned from these meetings.
                doomed[entity.id] = entity
            }
        }
        settleInboundRedirects(to: &doomed, among: allEntities, removedIDs: removedIDs)
        for entity in doomed.values {
            context.delete(entity)
        }

        guard !removable.isEmpty || promoted > 0 || !doomed.isEmpty else { return true }
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
