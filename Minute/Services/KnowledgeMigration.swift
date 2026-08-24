import Foundation
import OSLog
import SwiftData

/// Fills in `KnowledgeFact.sources` for rows written before it existed.
///
/// The lightweight migration keeps the old columns but cannot build the new
/// list from them, so this runs once at launch. Everything downstream reads
/// `sources` only, which is why it has to happen before the first read.
@MainActor
enum KnowledgeMigration {
    private static let logger = Logger(subsystem: "com.minuteapp.Minute", category: "KnowledgeMigration")

    /// Idempotent: a fact that already has sources is left alone, so this is
    /// safe to call on every launch and cheap once there is nothing to do.
    @discardableResult
    static func backfillSources(context: ModelContext) -> Bool {
        guard let facts = try? context.fetch(FetchDescriptor<KnowledgeFact>()) else {
            logger.error("Could not read facts to build their sources")
            return false
        }
        let pending = facts.filter(\.sources.isEmpty)
        guard !pending.isEmpty else { return true }

        // A failed read must never be mistaken for an empty library: writing
        // sources built from an empty date map would stamp every corroborator
        // with the primary's date, and the now-nonempty list blocks any retry.
        // Same rule as KnowledgeStore.reconcile — fail, change nothing, retry
        // next launch.
        let meetings: [Meeting]
        do {
            meetings = try context.fetch(FetchDescriptor<Meeting>())
        } catch {
            logger.error("Could not read meetings to date fact sources, so nothing was built: \(error.localizedDescription)")
            return false
        }
        let dates = Dictionary(
            meetings.map { ($0.id, $0.createdAt) },
            uniquingKeysWith: { first, _ in first }
        )
        for fact in pending {
            var rebuilt = [FactSource(
                meetingID: fact.legacySourceMeetingID,
                quote: fact.legacySourceQuote,
                capturedAt: fact.legacyCapturedAt
            )]
            // A corroborating meeting never carried a date of its own — the old
            // shape had nowhere to put one. Its real date is better than
            // inheriting the primary's, and it is available right here.
            for id in fact.legacyCorroboratedByMeetingIDs ?? [] where id != fact.legacySourceMeetingID {
                rebuilt.append(FactSource(
                    meetingID: id,
                    quote: nil,
                    capturedAt: dates[id] ?? fact.legacyCapturedAt
                ))
            }
            fact.sources = rebuilt
            // The quote and corroborator list were just copied into `sources`,
            // which every read now consults instead. Left behind, the quote is
            // a second copy of transcript content that deletion would have to
            // remember to scrub — clearing it here means deletion never has to.
            fact.legacySourceQuote = nil
            fact.legacyCorroboratedByMeetingIDs = nil
        }
        do {
            try context.save()
        } catch {
            logger.error("Could not save rebuilt fact sources: \(error.localizedDescription)")
            return false
        }
        logger.info("Built sources for \(pending.count) fact(s) written before the sources list existed")
        return true
    }
}
