import Testing
@testable import Minute

struct SpeakerAssignmentTests {
    private func segment(_ start: Double, _ end: Double) -> TranscriptSegment {
        TranscriptSegment(text: "x", start: start, end: end)
    }

    @Test func labelsSegmentsByOverlapAndRenumbersByFirstAppearance() {
        // Raw diarizer ids (7, 3) must come out renumbered 0, 1.
        let ranges = [
            SpeakerRange(speaker: 7, start: 0, end: 10),
            SpeakerRange(speaker: 3, start: 10, end: 20),
        ]
        let result = SpeakerAssignment.apply(ranges, to: [segment(0, 9), segment(11, 19), segment(1, 8)])
        #expect(result.map(\.speaker) == [0, 1, 0])
    }

    @Test func dominantSpeakerWinsAcrossSplitRanges() {
        // Speaker 1 holds 8s of the segment across two ranges, speaker 2 only 2s.
        let ranges = [
            SpeakerRange(speaker: 1, start: 0, end: 3),
            SpeakerRange(speaker: 2, start: 3, end: 5),
            SpeakerRange(speaker: 1, start: 5, end: 10),
        ]
        let result = SpeakerAssignment.apply(ranges, to: [segment(0, 10), segment(3, 5)])
        #expect(result[0].speaker == 0)
        #expect(result[1].speaker == 1)
    }

    @Test func segmentWithNoOverlapStaysUnlabeled() {
        let ranges = [SpeakerRange(speaker: 0, start: 0, end: 5)]
        let result = SpeakerAssignment.apply(ranges, to: [segment(10, 12)])
        #expect(result[0].speaker == nil)
    }

    @Test func emptyRangesLeaveEverythingUnlabeled() {
        let result = SpeakerAssignment.apply([], to: [segment(0, 5)])
        #expect(result[0].speaker == nil)
    }

    @Test func zeroLengthSegmentFallsBackToContainingRange() {
        // Kept volatile text is appended with start == end and must still
        // pick up the speaker talking at that moment.
        let ranges = [SpeakerRange(speaker: 4, start: 0, end: 10)]
        let result = SpeakerAssignment.apply(ranges, to: [segment(5, 5)])
        #expect(result[0].speaker == 0)
    }

    @Test func existingLabelsAreReplacedNotAccumulated() {
        var relabeled = segment(0, 4)
        relabeled.speaker = 9
        let ranges = [SpeakerRange(speaker: 2, start: 0, end: 4)]
        let result = SpeakerAssignment.apply(ranges, to: [relabeled])
        #expect(result[0].speaker == 0)
    }
}

struct SpeakerNamingTests {
    @Test func speakerNameFallsBackToDefault() {
        let meeting = Meeting(title: "T")
        #expect(meeting.speakerName(for: 0) == "Speaker 1")

        meeting.speakerNames = ["Alice", "   "]
        #expect(meeting.speakerName(for: 0) == "Alice")
        #expect(meeting.speakerName(for: 1) == "Speaker 2")
        #expect(meeting.speakerName(for: 5) == "Speaker 6")
    }

    @Test func timestampedTranscriptIncludesSpeakerNames() {
        let meeting = Meeting(title: "T", segments: [
            TranscriptSegment(text: "hello", start: 0, end: 2, speaker: 0),
            TranscriptSegment(text: "hi there", start: 2, end: 4, speaker: 1),
            TranscriptSegment(text: "unlabeled", start: 4, end: 6),
        ], speakerNames: ["Alice"])

        let lines = meeting.timestampedTranscriptText.split(separator: "\n").map(String.init)
        #expect(lines[0].hasSuffix("Alice: hello"))
        #expect(lines[1].hasSuffix("Speaker 2: hi there"))
        #expect(lines[2].hasSuffix("] unlabeled"))
    }

    @Test func hasSpeakersReflectsLabeledSegments() {
        let meeting = Meeting(title: "T", segments: [
            TranscriptSegment(text: "a", start: 0, end: 1, speaker: 1),
            TranscriptSegment(text: "d", start: 3, end: 4),
        ])
        #expect(meeting.hasSpeakers)
        #expect(!Meeting(title: "empty").hasSpeakers)
    }
}
