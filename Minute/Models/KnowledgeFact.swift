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

@Model
final class KnowledgeFact {
    var id: UUID
    /// User-editable display text.
    var text: String
    /// Verbatim extractor output — never mutated by edits. ALL dedup runs
    /// against this (or its fingerprint once rejected).
    var originalText: String
    var statusRaw: String
    /// Plain UUID on purpose — no relationship; UI must tolerate deleted meetings.
    var sourceMeetingID: UUID
    /// Only set when validated as a fuzzy substring of the transcript.
    var sourceQuote: String?
    /// The source meeting's date — facts are timestamped observations.
    var capturedAt: Date
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

    var status: FactStatus {
        get { FactStatus(rawValue: statusRaw) ?? .suggested }
        set { statusRaw = newValue.rawValue }
    }

    init(
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
        self.id = id
        self.text = text
        self.originalText = originalText
        self.statusRaw = status.rawValue
        self.sourceMeetingID = sourceMeetingID
        self.sourceQuote = sourceQuote
        self.capturedAt = capturedAt
        self.entity = entity
        self.createdAt = createdAt
    }
}
