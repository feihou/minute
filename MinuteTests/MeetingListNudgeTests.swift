import Testing
@testable import Minute

/// The two skips in the save-time Brain nudge, which are the whole content of
/// the decision and were previously locked inside a private view method. Each
/// one is load-bearing and silent when wrong, so each gets a case here.
@MainActor
struct MeetingListNudgeTests {
    /// A silent save, or an import whose transcription failed: there is nothing
    /// to read, and nudging spends the meeting's one chance — the catch-up loop
    /// skip-lists it for the rest of the process, so the transcript a later
    /// Re-transcribe Audio produces would never be extracted. That job nudges
    /// the loop itself when it lands, so nothing is lost by waiting.
    @Test func aMeetingWithNoTranscriptIsNotNudged() {
        #expect(!MeetingListView.shouldNudgeBrain(hasTranscript: false, destinationAutoSummarizes: false))
        #expect(!MeetingListView.shouldNudgeBrain(hasTranscript: false, destinationAutoSummarizes: true))
    }

    /// With Auto-Summarize on, the summary starting on the next screen nudges
    /// the loop when it ends, however it ends. Nudging now would only make
    /// extraction and that summary contend for the single on-device model.
    @Test func anAutoSummarizingDestinationIsLeftToItsOwnJobsEnd() {
        #expect(!MeetingListView.shouldNudgeBrain(hasTranscript: true, destinationAutoSummarizes: true))
    }

    /// The default configuration, and the reason this nudge exists at all: with
    /// Auto-Summarize off, no job is coming, so without this the meeting goes
    /// unread until the app is backgrounded and reopened.
    @Test func aTranscribedMeetingWithNoSummaryComingIsNudgedNow() {
        #expect(MeetingListView.shouldNudgeBrain(hasTranscript: true, destinationAutoSummarizes: false))
    }
}
