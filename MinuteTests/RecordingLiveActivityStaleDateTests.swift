import Foundation
import Testing
@testable import Minute

/// Every ActivityContent used to carry `staleDate: nil`, so a process that
/// died mid-recording left the lock screen claiming live capture — timer
/// ticking — until the next launch. A short stale date the live session keeps
/// pushing forward makes a dead session visible within minutes.
@MainActor
struct RecordingLiveActivityStaleDateTests {
    @Test func staleDateIsThreeMinutesAfterTheContentIsSent() {
        let now = Date(timeIntervalSince1970: 1_000_000)

        #expect(RecordingLiveActivityController.staleDate(from: now) == now.addingTimeInterval(180))
    }

    @Test func theStaleWindowIsSeveralRefreshesWide() {
        // The session pushes the date forward on a timer. If the window were
        // not comfortably wider than that interval, one late refresh would
        // brand a healthy recording as dead.
        #expect(RecordingLiveActivityController.staleAfter > RecordingSession.liveActivityRefreshInterval * 2)
    }
}
