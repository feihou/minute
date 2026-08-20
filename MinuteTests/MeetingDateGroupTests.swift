import Foundation
import Testing
@testable import Minute

struct MeetingDateGroupTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 1
        return calendar
    }()

    // Friday, August 14, 2026, noon UTC.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: 14, hour: 12))!
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @Test func sameDayIsToday() {
        #expect(MeetingDateGroup.title(for: date(2026, 8, 14), now: now, calendar: calendar) == "Today")
    }

    @Test func previousDayIsYesterday() {
        #expect(MeetingDateGroup.title(for: date(2026, 8, 13), now: now, calendar: calendar) == "Yesterday")
    }

    @Test func earlierSameWeekIsThisWeek() {
        // Monday of the same Sunday-started week.
        #expect(MeetingDateGroup.title(for: date(2026, 8, 10), now: now, calendar: calendar) == "This Week")
    }

    @Test func earlierSameMonthIsThisMonth() {
        #expect(MeetingDateGroup.title(for: date(2026, 8, 3), now: now, calendar: calendar) == "This Month")
    }

    @Test func olderDatesUseMonthAndYear() {
        let older = date(2026, 3, 10)
        let title = MeetingDateGroup.title(for: older, now: now, calendar: calendar)
        #expect(title == older.formatted(.dateTime.month(.wide).year()))
        #expect(title.contains("2026"))
    }

    @Test func todayRowShowsTimeOnly() {
        let today = date(2026, 8, 14, hour: 16)
        let stamp = MeetingDateGroup.rowTimestamp(for: today, now: now, calendar: calendar)
        // The "Today" header already names the day, so the row omits it.
        #expect(stamp == today.formatted(date: .omitted, time: .shortened))
        #expect(!stamp.contains("2026"))
    }

    @Test func yesterdayRowShowsTimeOnly() {
        let yesterday = date(2026, 8, 13, hour: 16)
        #expect(MeetingDateGroup.rowTimestamp(for: yesterday, now: now, calendar: calendar)
            == yesterday.formatted(date: .omitted, time: .shortened))
    }

    @Test func olderRowThisYearKeepsTheDayButNotTheYear() {
        let older = date(2026, 3, 10)
        let stamp = MeetingDateGroup.rowTimestamp(for: older, now: now, calendar: calendar)
        #expect(stamp == older.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
        #expect(!stamp.contains("2026"))
    }

    @Test func rowFromAnotherYearKeepsTheYear() {
        let ancient = date(2024, 11, 2)
        let stamp = MeetingDateGroup.rowTimestamp(for: ancient, now: now, calendar: calendar)
        #expect(stamp == ancient.formatted(.dateTime.year().month(.abbreviated).day()))
        #expect(stamp.contains("2024"))
    }
}

struct AudioQualityTests {
    @Test func encoderQualityMapping() {
        #expect(AudioQuality.high.encoderQuality == .max)
        #expect(AudioQuality.standard.encoderQuality == .medium)
        #expect(AudioQuality.compact.encoderQuality == .min)
    }
}
