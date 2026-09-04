import Testing
@testable import Minute

/// A2: the rename write resets the extraction cursor, which re-queues the whole
/// meeting for on-device extraction — an LLM pass per chunk — and nudges the
/// catch-up loop. Opening Rename Speaker and tapping Save without typing must
/// not buy that, so the detail view asks first.
@MainActor
struct SpeakerRenameGuardTests {
    private func meeting() -> Meeting {
        let meeting = Meeting(title: "m")
        meeting.speakerNames = ["Priya", "Diego"]
        meeting.knowledgeExtractedAt = .now
        return meeting
    }

    @Test func aRenameToTheStoredNameChangesNothing() {
        let meeting = meeting()
        #expect(!meeting.speakerRenameChangesAnything(at: 1, to: "Diego"))
        // Trimmed the same way the write trims, or Save on an untouched field
        // whose text picked up a stray space would still cost a full pass.
        #expect(!meeting.speakerRenameChangesAnything(at: 1, to: "  Diego "))
    }

    @Test func aRenameToADifferentNameChanges() {
        let meeting = meeting()
        #expect(meeting.speakerRenameChangesAnything(at: 1, to: "Sarah Chen"))
        // Clearing a name is a change too: it sends the speaker back to
        // "Speaker 2" everywhere the transcript is read.
        #expect(meeting.speakerRenameChangesAnything(at: 1, to: ""))
    }

    /// An index the array does not reach yet — the common case, since
    /// `speakerNames` is nil until someone renames a speaker. Padding writes
    /// empty entries, so an empty name for an unnamed speaker is a no-op while
    /// a real name is not.
    @Test func anIndexWithNoEntryYetCountsAsTheEmptyName() {
        let meeting = Meeting(title: "m")
        #expect(meeting.speakerRenameChangesAnything(at: 2, to: "Mei"))
        #expect(!meeting.speakerRenameChangesAnything(at: 2, to: "   "))
        meeting.speakerNames = ["Priya"]
        #expect(!meeting.speakerRenameChangesAnything(at: 4, to: ""))
    }

    /// What the guard is actually protecting, spelled out: the unguarded write
    /// clears the cursor even when the name is identical.
    @Test func theUnguardedWriteIsWhatResetsTheExtractionCursor() {
        let meeting = meeting()

        MeetingJobs.applySpeakerName("  Diego ", at: 1, to: meeting)

        #expect(meeting.speakerNames == ["Priya", "Diego"])
        #expect(meeting.knowledgeExtractedAt == nil)
    }
}
