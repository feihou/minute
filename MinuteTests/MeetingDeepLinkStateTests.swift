import Foundation
import Testing
@testable import Minute

struct MeetingDeepLinkStateTests {
    private let firstID = UUID(uuidString: "9BB2079D-B182-47E2-BE2C-06903ED058AC")!
    private let secondID = UUID(uuidString: "63FB1517-EFA5-4F56-B225-04A24B2CE449")!

    @Test func unavailableMeetingRemainsPendingUntilItAppears() {
        var state = MeetingDeepLinkState()
        state.receive(.meeting(firstID))

        #expect(state.resolve(availableMeetingIDs: []) == nil)
        #expect(state.pendingMeetingID == firstID)

        #expect(state.resolve(availableMeetingIDs: [secondID, firstID]) == firstID)
        #expect(state.pendingMeetingID == nil)
    }

    @Test func availableMeetingResolvesImmediately() {
        var state = MeetingDeepLinkState()
        state.receive(.meeting(firstID))

        #expect(state.resolve(availableMeetingIDs: [firstID]) == firstID)
        #expect(state.pendingMeetingID == nil)
    }

    @Test func newMeetingCancelsPendingMeeting() {
        var state = MeetingDeepLinkState()
        state.receive(.meeting(firstID))

        state.receive(.newMeeting)

        #expect(state.pendingMeetingID == nil)
        #expect(state.resolve(availableMeetingIDs: [firstID]) == nil)
    }

    @Test func newerMeetingLinkReplacesPendingMeeting() {
        var state = MeetingDeepLinkState()
        state.receive(.meeting(firstID))

        state.receive(.meeting(secondID))

        #expect(state.resolve(availableMeetingIDs: [firstID]) == nil)
        #expect(state.pendingMeetingID == secondID)
        #expect(state.resolve(availableMeetingIDs: [secondID]) == secondID)
    }
}
