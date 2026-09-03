import Foundation
import Testing
@testable import Minute

/// F39: the masthead bound its TextField straight to `meeting.title`, so the
/// user could clear it or press Return into it and `saveQuietly()` persisted
/// the result. An empty or multi-line title then heads the library row, the
/// widget snapshot, the exported notes.md and the iCloud Drive folder name.
@MainActor
struct MeetingTitleTests {
    @Test func committedTitleTrimsSurroundingWhitespace() {
        #expect(Meeting.committedTitle(draft: "  Board Review  ", fallback: "Meeting Sep 2") == "Board Review")
    }

    @Test func committedTitleFallsBackWhenTheFieldIsEmptied() {
        #expect(Meeting.committedTitle(draft: "", fallback: "Meeting Sep 2") == "Meeting Sep 2")
        #expect(Meeting.committedTitle(draft: "   \n  ", fallback: "Meeting Sep 2") == "Meeting Sep 2")
    }

    @Test func committedTitleFoldsPastedNewlinesIntoOneLine() {
        #expect(Meeting.committedTitle(draft: "Board Review\nQ3 budget", fallback: "Meeting Sep 2") == "Board Review Q3 budget")
        #expect(Meeting.committedTitle(draft: "Board Review\r\nQ3 budget", fallback: "Meeting Sep 2") == "Board Review Q3 budget")
    }

    /// A paste is as likely to carry a blank line or a Unicode line/paragraph
    /// separator (what Pages, Word and some web editors emit) as a plain LF —
    /// each has to fold to exactly one space, not to a doubled space and not
    /// to a separator that survives into the "# title" line of every export.
    @Test func committedTitleFoldsBlankLinesAndUnicodeSeparatorsIntoOneSpace() {
        #expect(Meeting.committedTitle(draft: "Board Review\n\nQ3 budget", fallback: "Meeting Sep 2") == "Board Review Q3 budget")
        #expect(Meeting.committedTitle(draft: "Board Review\u{2028}Q3 budget", fallback: "Meeting Sep 2") == "Board Review Q3 budget")
        #expect(Meeting.committedTitle(draft: "Board Review\u{2029}Q3 budget", fallback: "Meeting Sep 2") == "Board Review Q3 budget")
        #expect(Meeting.committedTitle(draft: "Board Review \n Q3 budget", fallback: "Meeting Sep 2") == "Board Review Q3 budget")
    }

    @Test func committedTitleKeepsAnOrdinaryTitleExactly() {
        #expect(Meeting.committedTitle(draft: "Q3 Board Review", fallback: "Meeting Sep 2") == "Q3 Board Review")
    }

    /// The masthead commits its draft from every way out of the field — the
    /// keyboard being dismissed, the screen being left, the app going to the
    /// background — so a commit that changes nothing has to write nothing:
    /// the model write it would otherwise make rewrites the widget snapshot
    /// and remirrors the meeting for a title the user never edited.
    @Test func titleCommitWritesNothingWhenTheDraftMatchesTheStoredTitle() {
        #expect(Meeting.titleCommit(draft: "Q3 Board Review", current: "Q3 Board Review", fallback: "Meeting Sep 2") == nil)
        #expect(Meeting.titleCommit(draft: "  Q3 Board Review\n", current: "Q3 Board Review", fallback: "Meeting Sep 2") == nil)
    }

    @Test func titleCommitWritesTheCommittedTitleWhenTheDraftDiffers() {
        #expect(Meeting.titleCommit(draft: "  Board Review  ", current: "Q3 Board Review", fallback: "Meeting Sep 2") == "Board Review")
    }

    /// Emptying the field commits the fallback, not the empty string — and if
    /// the meeting is already sitting on its fallback title, that is again a
    /// commit with nothing to write.
    @Test func titleCommitFallsBackWhenTheFieldWasEmptied() {
        #expect(Meeting.titleCommit(draft: "   ", current: "Renamed", fallback: "Meeting Sep 2") == "Meeting Sep 2")
        #expect(Meeting.titleCommit(draft: "", current: "Meeting Sep 2", fallback: "Meeting Sep 2") == nil)
    }

    @Test func titleFallbackPrefersTheTitleTheMeetingWasCreatedWith() {
        let meeting = Meeting(title: "Renamed", defaultTitle: "Meeting Jan 1, 2026 at 9:00 AM")
        #expect(meeting.titleFallback == "Meeting Jan 1, 2026 at 9:00 AM")
    }

    /// Meetings stored before `defaultTitle` existed (and imports) have none,
    /// so the fallback is regenerated from the creation date — never empty.
    @Test func titleFallbackRebuildsTheDefaultWhenTheMeetingHasNone() {
        let createdAt = Date(timeIntervalSince1970: 1_767_243_600)
        let meeting = Meeting(title: "Renamed", createdAt: createdAt)

        #expect(meeting.titleFallback == RecordingSession.defaultTitle(for: createdAt))
        #expect(!meeting.titleFallback.isEmpty)
    }
}
