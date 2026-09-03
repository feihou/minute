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

    @Test func committedTitleKeepsAnOrdinaryTitleExactly() {
        #expect(Meeting.committedTitle(draft: "Q3 Board Review", fallback: "Meeting Sep 2") == "Q3 Board Review")
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
