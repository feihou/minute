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

        let dates = Dictionary(
            ((try? context.fetch(FetchDescriptor<Meeting>())) ?? []).map { ($0.id, $0.createdAt) },
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
