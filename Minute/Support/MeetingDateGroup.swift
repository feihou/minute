import Foundation

/// Buckets meeting dates into the human-readable section titles the home list
/// groups by: Today, Yesterday, This Week, This Month, then "March 2026".
enum MeetingDateGroup {
    static func title(for date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return "Today"
        }
        if isYesterday(date, now: now, calendar: calendar) {
            return "Yesterday"
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
            return "This Week"
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .month) {
            return "This Month"
        }
        return date.formatted(.dateTime.month(.wide).year())
    }

    /// The timestamp a row shows beneath its title. The section header already
    /// names the day for today and yesterday, so those rows print only a time
    /// rather than repeating "Aug 3, 2026 at" on every line. Sections that span
    /// several days keep the date, and other years keep the year.
    static func rowTimestamp(for date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) || isYesterday(date, now: now, calendar: calendar) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        }
        return date.formatted(.dateTime.year().month(.abbreviated).day())
    }

    private static func isYesterday(_ date: Date, now: Date, calendar: Calendar) -> Bool {
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else { return false }
        return calendar.isDate(date, inSameDayAs: yesterday)
    }
}
