import Foundation
import SwiftData

@Model
final class Meeting {
    var id: UUID
    var title: String
    /// The exact auto-generated title this meeting was created with, so
    /// "user never renamed it" can be checked without re-deriving the string
    /// from locale-dependent date formatting. Nil for meetings created
    /// before this field existed or titled from another source (imports).
    var defaultTitle: String?
    var createdAt: Date
    var duration: TimeInterval
    var audioFileName: String?
    var segments: [TranscriptSegment]
    var summary: MeetingSummary?
    /// User-chosen names per speaker index; empty entries fall back to
    /// "Speaker N". Nil until speakers are identified (and for meetings
    /// stored before this field existed).
    var speakerNames: [String]?
    /// When knowledge extraction last processed this meeting; nil = pending.
    /// The catch-up loop's cursor (spec §5).
    var knowledgeExtractedAt: Date?

    init(
        id: UUID = UUID(),
        title: String,
        defaultTitle: String? = nil,
        createdAt: Date = .now,
        duration: TimeInterval = 0,
        audioFileName: String? = nil,
        segments: [TranscriptSegment] = [],
        summary: MeetingSummary? = nil,
        speakerNames: [String]? = nil
    ) {
        self.id = id
        self.title = title
        self.defaultTitle = defaultTitle
        self.createdAt = createdAt
        self.duration = duration
        self.audioFileName = audioFileName
        self.segments = segments
        self.summary = summary
        self.speakerNames = speakerNames
    }

    var transcriptText: String {
        segments.map(\.text).joined(separator: "\n")
    }

    /// Transcript with one "[mm:ss] Name: text" line per segment — the
    /// summarizer's input, so the model can follow the meeting's flow across
    /// chunks and attribute ideas to speakers when they've been identified.
    var timestampedTranscriptText: String {
        segments.map { segment in
            let name = segment.speaker.map { "\(speakerName(for: $0)): " } ?? ""
            return "[\(segment.start.clockString)] \(name)\(segment.text)"
        }
        .joined(separator: "\n")
    }

    var hasTranscript: Bool {
        !segments.isEmpty
    }

    var hasSpeakers: Bool {
        segments.contains { $0.speaker != nil }
    }

    /// Display name for a speaker index: the user's rename when set,
    /// otherwise "Speaker N".
    func speakerName(for index: Int) -> String {
        if let names = speakerNames, names.indices.contains(index) {
            let trimmed = names[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return "Speaker \(index + 1)"
    }
}

extension Meeting {
    /// The title to store when the user finishes editing the detail
    /// masthead. A title is an identifier as much as a label — it heads the
    /// library row, the Home Screen widget, the exported and mirrored
    /// notes.md, and the iCloud Drive folder name — so an emptied field must
    /// not be written through: it falls back to the meeting's own default.
    /// Newlines fold into spaces rather than being trimmed off the ends,
    /// because a pasted two-line string would otherwise turn "# title" into a
    /// heading plus a stray body line in every export. Splitting on the whole
    /// `.newlines` set does that in one pass: CRLF, a blank line and the
    /// Unicode separators a paste from a word processor carries (U+2028,
    /// U+2029) all collapse to the single space a reader expects, rather than
    /// to a doubled space or — for the separators a per-character replace
    /// never listed — to a break that survives into the exported file.
    static func committedTitle(draft: String, fallback: String) -> String {
        let flattened = draft
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return flattened.isEmpty ? fallback : flattened
    }

    /// The title to write back when a pending masthead edit is committed, or
    /// `nil` when there is nothing to write. The edit is committed from every
    /// way out of the field — the keyboard being dismissed, the screen being
    /// left, the app going to the background — so the commits after the first
    /// one, and a visit that only focused the field, must not dirty the model:
    /// that write would rewrite the widget snapshot and remirror the meeting
    /// for a title nobody changed.
    static func titleCommit(draft: String, current: String, fallback: String) -> String? {
        let committed = committedTitle(draft: draft, fallback: fallback)
        return committed == current ? nil : committed
    }

    /// What the title reverts to when the field is emptied: the exact
    /// auto-generated title this meeting was created with, or — for meetings
    /// stored before that field existed, and for imports — the same string
    /// regenerated from the creation date, so the fallback is never empty.
    var titleFallback: String {
        defaultTitle ?? RecordingSession.defaultTitle(for: createdAt)
    }

    /// Whether writing `name` as speaker `index`'s display name would actually
    /// change this meeting.
    ///
    /// Asked before the write because the write is expensive in a way the
    /// gesture does not suggest: `MeetingJobs.applySpeakerName` resets
    /// `knowledgeExtractedAt`, which re-queues the entire meeting for on-device
    /// extraction — one LLM pass per chunk — and nudges the catch-up loop. That
    /// is the right price for a real rename, because the Brain reads the
    /// transcript with names in it, and no price at all for opening the Rename
    /// Speaker alert and tapping Save without typing.
    ///
    /// Trimmed the same way the write trims before it stores, and an index the
    /// array does not reach yet counts as the empty name that its padding would
    /// have written there.
    func speakerRenameChangesAnything(at index: Int, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing: String
        if let names = speakerNames, names.indices.contains(index) {
            existing = names[index]
        } else {
            existing = ""
        }
        return trimmed != existing
    }
}
