import Foundation

/// One diarized stretch of audio: which voice (cluster) spoke, and when.
struct SpeakerRange: Hashable, Sendable {
    var speaker: Int
    var start: TimeInterval
    var end: TimeInterval
}

/// Pure logic that turns diarization output into speaker labels on the
/// transcript. Kept free of any diarization-engine types so the engine can
/// be swapped (or replaced by a native Apple API) without touching this.
enum SpeakerAssignment {
    /// Labels each segment with the speaker whose ranges overlap it most,
    /// then renumbers speakers 0, 1, 2… by first appearance so "Speaker 1"
    /// is whoever talks first. Segments no range overlaps keep nil.
    static func apply(_ ranges: [SpeakerRange], to segments: [TranscriptSegment]) -> [TranscriptSegment] {
        let labeled = segments.map { segment in
            var copy = segment
            copy.speaker = dominantSpeaker(for: segment, in: ranges)
            return copy
        }
        return renumberedByFirstAppearance(labeled)
    }

    private static func dominantSpeaker(for segment: TranscriptSegment, in ranges: [SpeakerRange]) -> Int? {
        var overlaps: [Int: TimeInterval] = [:]
        for range in ranges {
            let overlap = min(segment.end, range.end) - max(segment.start, range.start)
            if overlap > 0 {
                overlaps[range.speaker, default: 0] += overlap
            }
        }
        if let best = overlaps.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }) {
            return best.key
        }
        // Zero-length segments exist (kept volatile text gets start == end),
        // so fall back to whichever range contains the segment's start.
        return ranges.first { segment.start >= $0.start && segment.start < $0.end }?.speaker
    }

    private static func renumberedByFirstAppearance(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var mapping: [Int: Int] = [:]
        return segments.map { segment in
            var copy = segment
            if let raw = segment.speaker {
                if mapping[raw] == nil {
                    mapping[raw] = mapping.count
                }
                copy.speaker = mapping[raw]
            }
            return copy
        }
    }
}
