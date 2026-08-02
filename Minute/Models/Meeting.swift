import Foundation
import SwiftData

@Model
final class Meeting {
    var id: UUID
    var title: String
    var createdAt: Date
    var duration: TimeInterval
    var audioFileName: String?
    var segments: [TranscriptSegment]
    var summary: MeetingSummary?

    init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = .now,
        duration: TimeInterval = 0,
        audioFileName: String? = nil,
        segments: [TranscriptSegment] = [],
        summary: MeetingSummary? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.audioFileName = audioFileName
        self.segments = segments
        self.summary = summary
    }

    var transcriptText: String {
        segments.map(\.text).joined(separator: "\n")
    }

    var hasTranscript: Bool {
        !segments.isEmpty
    }
}
