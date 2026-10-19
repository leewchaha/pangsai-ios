import Foundation

/// A local calendar day.
public struct DayKey: Hashable, Codable, Comparable, Sendable, CustomStringConvertible {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init(_ date: Date, calendar: Calendar) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }

    public func startDate(calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? Date(timeIntervalSince1970: 0)
    }

    public func adding(days: Int, calendar: Calendar) -> DayKey {
        let d = calendar.date(byAdding: .day, value: days, to: startDate(calendar: calendar)) ?? startDate(calendar: calendar)
        return DayKey(d, calendar: calendar)
    }

    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }

    public static func < (lhs: DayKey, rhs: DayKey) -> Bool {
        if lhs.year != rhs.year { return lhs.year < rhs.year }
        if lhs.month != rhs.month { return lhs.month < rhs.month }
        return lhs.day < rhs.day
    }
}

public struct MonthKey: Hashable, Codable, Comparable, Sendable {
    public var year: Int
    public var month: Int

    public init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }

    public init(_ date: Date, calendar: Calendar) {
        let c = calendar.dateComponents([.year, .month], from: date)
        self.init(year: c.year ?? 1970, month: c.month ?? 1)
    }

    public func adding(months: Int) -> MonthKey {
        var total = year * 12 + (month - 1) + months
        if total < 0 { total = 0 }
        return MonthKey(year: total / 12, month: total % 12 + 1)
    }

    public static func < (lhs: MonthKey, rhs: MonthKey) -> Bool {
        lhs.year != rhs.year ? lhs.year < rhs.year : lhs.month < rhs.month
    }
}

public enum CalendarMath {
    /// Gregorian calendar in the current time zone, weeks starting Monday.
    public static func standard(timeZone: TimeZone = .current) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        c.firstWeekday = 2
        c.minimumDaysInFirstWeek = 4
        return c
    }

    /// Month grid, Monday first. Leading/trailing cells outside the month are nil; length is a multiple of 7.
    public static func monthGrid(_ month: MonthKey, calendar: Calendar) -> [DayKey?] {
        guard let first = calendar.date(from: DateComponents(year: month.year, month: month.month, day: 1)),
              let range = calendar.range(of: .day, in: .month, for: first) else { return [] }
        let weekday = calendar.component(.weekday, from: first) // 1 = Sunday
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        var cells: [DayKey?] = Array(repeating: nil, count: leading)
        for d in range { cells.append(DayKey(year: month.year, month: month.month, day: d)) }
        while cells.count % 7 != 0 { cells.append(nil) }
        return cells
    }

    /// Current streak (alive if the last logged day is today or yesterday) and longest streak.
    public static func streaks(days: Set<DayKey>, today: DayKey, calendar: Calendar) -> (current: Int, longest: Int) {
        guard !days.isEmpty else { return (0, 0) }
        let sorted = days.sorted()
        var longest = 1
        var run = 1
        if sorted.count > 1 {
            for i in 1..<sorted.count {
                if sorted[i - 1].adding(days: 1, calendar: calendar) == sorted[i] {
                    run += 1
                } else {
                    run = 1
                }
                longest = max(longest, run)
            }
        }
        var current = 0
        var cursor = days.contains(today) ? today : today.adding(days: -1, calendar: calendar)
        while days.contains(cursor) {
            current += 1
            cursor = cursor.adding(days: -1, calendar: calendar)
        }
        return (current, longest)
    }

    public static func dayInterval(_ date: Date, calendar: Calendar) -> DateInterval {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        return DateInterval(start: start, end: end)
    }

    /// Monday-start week containing `date`.
    public static func weekInterval(_ date: Date, calendar: Calendar) -> DateInterval {
        if let i = calendar.dateInterval(of: .weekOfYear, for: date) { return i }
        return dayInterval(date, calendar: calendar)
    }

    public static func monthInterval(_ date: Date, calendar: Calendar) -> DateInterval {
        if let i = calendar.dateInterval(of: .month, for: date) { return i }
        return dayInterval(date, calendar: calendar)
    }

    public static func minutesFromMidnight(_ date: Date, calendar: Calendar) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
}
