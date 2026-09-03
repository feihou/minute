import Foundation
import Testing
@testable import Minute

/// The title a recording saves, and the default it is later compared against
/// when the model suggests a better one. Both must come from the same
/// string the New Meeting sheet showed: the default has minute resolution,
/// so regenerating it at save time drifted whenever the sheet stayed open
/// across a minute boundary, and the suggested title was then never adopted.
@MainActor
struct RecordingSessionTitleTests {
    @Test func untouchedDraftSavesAsItsOwnDefault() {
        let saved = RecordingSession.savedTitles(
            draft: "Meeting Sep 2, 2026 at 9:30 AM",
            prefilledDefault: "Meeting Sep 2, 2026 at 9:30 AM"
        )
        #expect(saved.title == saved.defaultTitle)
    }

    @Test func emptyDraftFallsBackToThePrefilledDefault() {
        let saved = RecordingSession.savedTitles(draft: "   ", prefilledDefault: "Meeting Sep 2, 2026 at 9:30 AM")
        #expect(saved.title == "Meeting Sep 2, 2026 at 9:30 AM")
        #expect(saved.defaultTitle == "Meeting Sep 2, 2026 at 9:30 AM")
    }

    @Test func customDraftIsTrimmedAndStillRecordsThePrefilledDefault() {
        let saved = RecordingSession.savedTitles(draft: "  Q3 roadmap  ", prefilledDefault: "Meeting Sep 2, 2026 at 9:30 AM")
        #expect(saved.title == "Q3 roadmap")
        #expect(saved.defaultTitle == "Meeting Sep 2, 2026 at 9:30 AM")
    }

    @Test func sessionKeepsThePrefilledDefaultItWasCreatedWith() {
        let session = RecordingSession(title: "Meeting Sep 2, 2026 at 9:30 AM", prefilledDefaultTitle: "Meeting Sep 2, 2026 at 9:30 AM")
        #expect(session.prefilledDefaultTitle == "Meeting Sep 2, 2026 at 9:30 AM")
    }
}
