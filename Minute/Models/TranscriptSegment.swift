import Foundation

/// One finalized stretch of transcribed speech with its position in the audio.
struct TranscriptSegment: Codable, Hashable, Sendable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
    /// Diarized speaker index (0-based, ordered by first appearance in the
    /// meeting), or nil when speakers haven't been identified. Display names
    /// live on the meeting so a rename never rewrites every segment.
    var speaker: Int? = nil
}
