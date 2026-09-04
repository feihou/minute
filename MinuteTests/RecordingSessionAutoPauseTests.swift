import Foundation
import Testing
@testable import Minute

/// A route change now restarts capture in place, and only a *failed* restart
/// falls back to the auto-pause a phone call also lands on. Telling that user
/// "a call or Siri" sends them looking at their phone for a pause their headset
/// caused — the one thing they could actually act on goes unmentioned.
@MainActor
struct RecordingSessionAutoPauseTests {
    @Test func eachAutoPauseCauseIsExplainedInItsOwnWords() {
        let interruption = RecordingSession.autoPauseNotice(for: .interruption)
        let restartFailed = RecordingSession.autoPauseNotice(for: .restartFailed)

        #expect(interruption == "Recording was paused by the system (a call or Siri). Tap resume to continue.")
        #expect(restartFailed == "Recording paused — the audio device changed and capture couldn't restart. Tap resume to continue.")
        #expect(restartFailed.contains("call or Siri") == false)
    }

    /// Both notices stay up until the user acts, so both have to name the
    /// action: the recorder is paused, not stopped, and everything captured so
    /// far is still on disk and saveable.
    @Test func everyAutoPauseNoticeNamesTheWayOut() {
        for cause in AutoPauseCause.allCases {
            #expect(RecordingSession.autoPauseNotice(for: cause).contains("Tap resume to continue."))
        }
    }
}
