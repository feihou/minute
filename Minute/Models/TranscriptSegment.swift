import Foundation

/// One finalized stretch of transcribed speech with its position in the audio.
struct TranscriptSegment: Codable, Hashable, Sendable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}
