import Foundation
import SwiftData
import Testing
@testable import Minute

@MainActor
struct KnowledgeCatchUpWiringTests {
    /// retranscribe rewrites the transcript, so the extraction cursor must
    /// reset — the catch-up loop then re-extracts and idempotently replaces
    /// this meeting's suggested facts.
    @Test func applyNewTranscriptClearsTheExtractionStamp() throws {
        let meeting = Meeting(
            title: "m",
            segments: [TranscriptSegment(text: "old", start: 0, end: 1)]
        )
        meeting.knowledgeExtractedAt = .now

        MeetingJobs.applyNewTranscript(
            [TranscriptSegment(text: "new", start: 0, end: 1)],
            to: meeting
        )

        #expect(meeting.segments.map(\.text) == ["new"])
        #expect(meeting.speakerNames == nil)
        #expect(meeting.knowledgeExtractedAt == nil)
    }
}
