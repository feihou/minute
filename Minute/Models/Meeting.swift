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
    /// heading plus a stray body line in every export.
    static func committedTitle(draft: String, fallback: String) -> String {
        let flattened = draft
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flattened.isEmpty ? fallback : flattened
    }

    /// What the title reverts to when the field is emptied: the exact
    /// auto-generated title this meeting was created with, or — for meetings
    /// stored before that field existed, and for imports — the same string
    /// regenerated from the creation date, so the fallback is never empty.
    var titleFallback: String {
        defaultTitle ?? RecordingSession.defaultTitle(for: createdAt)
    }
}
