import Foundation

/// Buckets meeting dates into the human-readable section titles the home list
/// groups by: Today, Yesterday, This Week, This Month, then "March 2026".
enum MeetingDateGroup {
    static func title(for date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return "Today"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
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
}
