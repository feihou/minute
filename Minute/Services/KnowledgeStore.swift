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
        guard !facts.isEmpty else { return true }

        // Rejected facts are tombstones: the text is already cleared and only a
        // salted fingerprint remains, whose whole job is to stop a claim the
        // user rejected from reappearing via a different meeting. They hold no
        // meeting content, so they stay — unless their entity goes entirely.
        let removable = facts.filter { $0.status != .rejected }
        let removedIDs = Set(removable.map(\.id))
        var touched: [UUID: KnowledgeEntity] = [:]
        for fact in facts {
            if let entity = fact.entity {
                touched[entity.id] = entity
            }
        }
        for fact in removable {
            context.delete(fact)
        }

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
                // data alive. A merge tombstone (`redirectTo` set) is kept so
                // resolution through it cannot dangle.
                context.delete(entity)
            }
        }

        do {
            try context.save()
        } catch {
            logger.error("Failed to remove the knowledge from a deleted meeting: \(error.localizedDescription)")
            return false
        }
        return true
    }
}
