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
