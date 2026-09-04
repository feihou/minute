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

    // MARK: - What to do with a link, given what is already on screen

    /// F40: `beginNewMeeting()` resets `draftTitle` unconditionally, so a
    /// widget tap while the sheet is up wiped the title the user had typed
    /// into it. The sheet already IS the state the link asks for.
    @Test func aNewMeetingLinkIsIgnoredWhileTheSheetIsAlreadyOpen() {
        #expect(MeetingDeepLinkState.action(
            for: .newMeeting,
            isRecording: false,
            isShowingNewMeeting: true
        ) == .ignore)
    }

    @Test func aNewMeetingLinkIsIgnoredWhileARecordingIsRunning() {
        #expect(MeetingDeepLinkState.action(
            for: .newMeeting,
            isRecording: true,
            isShowingNewMeeting: false
        ) == .ignore)
    }

    @Test func aNewMeetingLinkPresentsTheSheetWhenNothingIsInTheWay() {
        #expect(MeetingDeepLinkState.action(
            for: .newMeeting,
            isRecording: false,
            isShowingNewMeeting: false
        ) == .presentNewMeeting)
    }

    /// F64: a meeting link is always honored — the list dismisses whatever is
    /// covering the stack first, rather than pushing the detail behind it.
    @Test func aMeetingLinkAlwaysOpensTheMeeting() {
        #expect(MeetingDeepLinkState.action(
            for: .meeting(firstID),
            isRecording: true,
            isShowingNewMeeting: true
        ) == .openMeeting)
        #expect(MeetingDeepLinkState.action(
            for: .meeting(firstID),
            isRecording: false,
            isShowingNewMeeting: false
        ) == .openMeeting)
    }
}
