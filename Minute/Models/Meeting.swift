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
