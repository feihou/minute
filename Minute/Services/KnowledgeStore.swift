import Foundation
import OSLog
import SwiftData

/// Removes the knowledge a meeting produced when that meeting goes away.
///
/// `KnowledgeFact.sourceMeetingID` is a plain UUID rather than a SwiftData
/// relationship — entity pages are built to tolerate a deleted source meeting —
/// so no delete rule cascades here and the cleanup has to be explicit.
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
        // Rejected facts are tombstones: the text is already cleared and only a
        // salted fingerprint remains, whose whole job is to stop a claim the
        // user rejected from reappearing via a different meeting. They hold no
        // meeting content, so they stay — unless their entity goes entirely.
        let removable = facts.filter { $0.status != .rejected }
        // Nothing actually being removed means nothing to tidy. Bailing here is
        // what stops the launch sweep from re-touching an entity every time it
        // re-selects a retained tombstone whose source meeting is long gone,
        // which would discard and regenerate that entity's narrative on every
        // single launch.
        guard !removable.isEmpty else { return true }

        let removedIDs = Set(removable.map(\.id))
        // Derived from `removable`, not from every matched fact: an entity is
        // only affected by facts that are actually going away.
        var touched: [UUID: KnowledgeEntity] = [:]
        for fact in removable {
            if let entity = fact.entity {
                touched[entity.id] = entity
            }
        }
        for fact in removable {
            context.delete(fact)
        }

        var doomed: [UUID: KnowledgeEntity] = [:]
        for entity in touched.values {
            // Judged against `removedIDs` rather than re-reading `entity.facts`,
            // which still lists rows that are deleted-pending until the save.
            let survives = entity.visibleFacts.contains { !removedIDs.contains($0.id) }
            if survives {
                // The narrative was written over a set that included the facts
                // going away, so it can still describe the deleted meeting.
                // Clearing it makes the entity page rewrite from what is left.
                entity.synthesis = nil
                entity.synthesizedFactCount = nil
            } else if entity.redirectTo == nil {
                // Nothing left to show. The name itself was learned from the
                // meeting, so an empty page would keep meeting-derived personal
                // data alive.
                doomed[entity.id] = entity
            }
        }
        addInboundTombstones(to: &doomed, context: context)
        for entity in doomed.values {
            context.delete(entity)
        }

        do {
            try context.save()
        } catch {
            logger.error("Failed to remove the knowledge from a deleted meeting: \(error.localizedDescription)")
            return false
        }
        return true
    }

    /// A merged-away entity exists only to point at the entity that won the
    /// merge. Once that winner is being removed the tombstone leads nowhere,
    /// and resolution falling back to the tombstone itself would attach newly
    /// extracted facts to an entity every Brain surface filters out. It holds
    /// no facts of its own and its name came from the same meetings, so it goes
    /// with its destination. Walks the chain, since a winner may itself have
    /// been merged away.
    private static func addInboundTombstones(
        to doomed: inout [UUID: KnowledgeEntity],
        context: ModelContext
    ) {
        guard !doomed.isEmpty,
              let all = try? context.fetch(FetchDescriptor<KnowledgeEntity>()) else { return }
        var queue = Array(doomed.keys)
        while let destination = queue.popLast() {
            for entity in all where entity.redirectTo == destination && doomed[entity.id] == nil {
                doomed[entity.id] = entity
                queue.append(entity.id)
            }
        }
    }
}
