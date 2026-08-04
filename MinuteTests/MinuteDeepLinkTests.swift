import Foundation
import Testing
@testable import Minute

struct MinuteDeepLinkTests {
    @Test func newMeetingRoundTrips() {
        let link = MinuteDeepLink.newMeeting
        #expect(link.url.absoluteString == "minute://new-meeting")
        #expect(MinuteDeepLink(url: link.url) == link)
    }

    @Test func meetingRoundTrips() {
        let id = UUID(uuidString: "D2495702-022C-4E72-A955-CB2968EA8B82")!
        let link = MinuteDeepLink.meeting(id)
        #expect(link.url.absoluteString == "minute://meeting/d2495702-022c-4e72-a955-cb2968ea8b82")
        #expect(MinuteDeepLink(url: link.url) == link)
    }

    @Test func malformedAndForeignURLsAreRejected() {
        #expect(MinuteDeepLink(url: URL(string: "other://new-meeting")!) == nil)
        #expect(MinuteDeepLink(url: URL(string: "minute://meeting/not-a-uuid")!) == nil)
        #expect(MinuteDeepLink(url: URL(string: "minute://unknown")!) == nil)
    }
}
