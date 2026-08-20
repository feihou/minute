import Foundation
import SwiftData

/// Lifecycle of one extracted fact. Raw values are persisted — keep stable.
enum FactStatus: String, Codable {
    /// Passed every confidence gate; entered the entity page directly.
    case autoCaptured
    /// Waiting for review (Me facts, contradictions, new entities).
    case suggested
    case approved
    /// Tombstone: text fields cleared, only `fingerprint` remains.
    case rejected
    /// Replaced by a newer fact (`supersededByID`).
    case superseded
}

/// One meeting's support for a fact: which meeting stated it, when, and the
/// phrase from that transcript that validated it.
///
/// Every entry is the same shape. There is no primary source and no lesser
/// one, which is what stops a read from consulting half the list.
struct FactSource: Codable, Hashable, Sendable {
    var meetingID: UUID
    /// Set only when a phrase from that meeting's transcript validated the
    /// claim. Nil means the meeting stated it but nothing could be quoted —
    /// dedup discards a repeat's quote, so restatements usually have none.
    var quote: String?
    /// That meeting's date. Facts are timestamped observations.
    var capturedAt: Date
}

@Model
final class KnowledgeFact {
    var id: UUID
    /// User-editable display text.
    var text: String
    /// Verbatim extractor output — never mutated by edits. ALL dedup runs
    /// against this (or its fingerprint once rejected).
    var originalText: String
    var statusRaw: String
    /// Every meeting that states this fact, one entry each.
    ///
    /// A fact several meetings make identically is one row — dedup drops the
    /// repeats — so its support has to be a list. It was previously a primary
    /// meeting id plus a bare array of corroborating ids, which meant only the
    /// primary carried a quote and a date, every read had to remember to
    /// consult both, and deleting the primary meant mutating the row to look
    /// like one of the others. Uniform entries make those bugs unwriteable:
    /// nothing is promoted, and the date and quote below are derived.
    var sources: [FactSource]
    var reviewedAt: Date?
    var supersededByID: UUID?
    /// Salted hash of (normalized originalText, entity ID). Set on rejection
    /// when the text fields are cleared — all a tombstone retains.
    var fingerprint: String?
    /// When this fact row was created — insertion time, unlike `capturedAt`
    /// (the meeting's date). Nil for rows written before this field existed.
    /// Recently-learned ordering (and m2b's review auto-archive) read this.
    var createdAt: Date?
    var entity: KnowledgeEntity?

    // MARK: - Pre-`sources` storage
    //
    // Read once by `KnowledgeMigration` to build `sources`, then never again.
    // The columns stay so an existing store keeps its data through the
    // lightweight migration; `originalName` preserves the mapping.

    @Attribute(originalName: "sourceMeetingID") var legacySourceMeetingID: UUID
    @Attribute(originalName: "sourceQuote") var legacySourceQuote: String?
    @Attribute(originalName: "capturedAt") var legacyCapturedAt: Date
    @Attribute(originalName: "corroboratedByMeetingIDs") var legacyCorroboratedByMeetingIDs: [UUID]?

    var status: FactStatus {
        get { FactStatus(rawValue: statusRaw) ?? .suggested }
        set { statusRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        text: String,
        originalText: String,
        status: FactStatus,
        sources: [FactSource],
        entity: KnowledgeEntity?,
        createdAt: Date = .now
    ) {
        self.id = id
        self.text = text
        self.originalText = originalText
        self.statusRaw = status.rawValue
        self.sources = sources
        self.entity = entity
        self.createdAt = createdAt
        // Only ever read by the migration, and only for rows that predate
        // `sources`. Seeded so the columns stay non-optional.
        self.legacySourceMeetingID = sources.first?.meetingID ?? UUID()
        self.legacyCapturedAt = sources.first?.capturedAt ?? createdAt
    }

    /// Convenience for the common case: one meeting, one statement.
    convenience init(
        id: UUID = UUID(),
        text: String,
        originalText: String,
        status: FactStatus,
        sourceMeetingID: UUID,
        sourceQuote: String? = nil,
        capturedAt: Date,
        entity: KnowledgeEntity?,
        createdAt: Date = .now
    ) {
        self.init(
            id: id, text: text, originalText: originalText, status: status,
            sources: [FactSource(meetingID: sourceMeetingID, quote: sourceQuote, capturedAt: capturedAt)],
            entity: entity, createdAt: createdAt
        )
    }

    // MARK: - Derived from `sources`
    //
    // Nothing here is stored, so deleting a meeting cannot leave a stale date
    // or a quote belonging to a transcript that no longer exists.

    /// Newest supporting meeting's date. Synthesis is fed newest-first and
    /// "recently learned" orders by it, so the most recent statement wins.
    var capturedAt: Date {
        sources.map(\.capturedAt).max() ?? legacyCapturedAt
    }

    var sourceMeetingIDs: [UUID] { sources.map(\.meetingID) }

    /// The meeting a page links to: the most recent one that states this.
    var newestSource: FactSource? {
        sources.max { $0.capturedAt < $1.capturedAt }
    }

    /// The quote to show, taken from the newest source that has one. A source
    /// without a quote never lends another meeting's words to itself.
    var sourceQuote: String? {
        sources.sorted { $0.capturedAt > $1.capturedAt }.first { $0.quote != nil }?.quote
    }

    /// Records that a meeting states this fact, replacing any entry it already
    /// had so a re-extraction updates rather than duplicates.
    func addSource(_ source: FactSource) {
        sources.removeAll { $0.meetingID == source.meetingID }
        sources.append(source)
    }

    /// Drops a meeting's support. Used when that meeting is deleted, and when
    /// it is re-extracted and may no longer make the claim.
    func removeSource(meetingID: UUID) {
        sources.removeAll { $0.meetingID == meetingID }
    }
}
