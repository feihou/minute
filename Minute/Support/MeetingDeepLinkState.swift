import Foundation

struct MeetingDeepLinkState {
    private(set) var pendingMeetingID: UUID?

    mutating func receive(_ deepLink: MinuteDeepLink) {
        switch deepLink {
        case .newMeeting:
            pendingMeetingID = nil
        case .meeting(let id):
            pendingMeetingID = id
        }
    }

    mutating func resolve(availableMeetingIDs: [UUID]) -> UUID? {
        guard let pendingMeetingID, availableMeetingIDs.contains(pendingMeetingID) else {
            return nil
        }
        self.pendingMeetingID = nil
        return pendingMeetingID
    }
}

extension MeetingDeepLinkState {
    /// What the list should do with a link that just arrived, given what is
    /// already on screen. Pure and static so the "already the requested
    /// state" rules can be tested without a view.
    enum Action: Equatable {
        /// Present the New Meeting sheet.
        case presentNewMeeting
        /// Push the meeting the link named, once the query can see it.
        case openMeeting
        /// Do nothing: the app is already in the state the link asks for.
        case ignore
    }

    static func action(
        for deepLink: MinuteDeepLink,
        isRecording: Bool,
        isShowingNewMeeting: Bool
    ) -> Action {
        switch deepLink {
        case .newMeeting:
            // A running recording already IS a new meeting. And the sheet
            // already asks for the title the link would reset — presenting it
            // again resets the draft title in place and throws away what the
            // user typed there before they were interrupted.
            if isRecording || isShowingNewMeeting { return .ignore }
            return .presentNewMeeting
        case .meeting:
            return .openMeeting
        }
    }
}
