import Foundation
import Testing
@testable import Minute

struct TimeFormattingTests {
    @Test func formatsZero() {
        #expect(TimeInterval(0).clockString == "0:00")
    }

    @Test func formatsMinutesAndSeconds() {
        #expect(TimeInterval(65).clockString == "1:05")
    }

    @Test func formatsHours() {
        #expect(TimeInterval(3725).clockString == "1:02:05")
    }

    @Test func roundsFractionalSeconds() {
        #expect(TimeInterval(59.6).clockString == "1:00")
    }
}
