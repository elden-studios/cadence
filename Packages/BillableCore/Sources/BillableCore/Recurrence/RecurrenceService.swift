import Foundation
import SwiftData
import OSLog

@MainActor
public enum RecurrenceService {
    private static let log = Logger(subsystem: "com.eldenstudios.billable", category: "RecurrenceService")

    /// 8:00am local, the fixed v1.1 fire-of-day slot.
    public static let fireHour = 8

    /// Compute the next fire date STRICTLY AFTER `from`. Always returns a date
    /// greater than `from`. Handles monthly day-of-month clamping for short months
    /// and weekly/biweekly walk to the next target weekday.
    public static func computeNextFireDate(
        cadence: RecurrenceCadence,
        after from: Date,
        calendar: Calendar = .current
    ) -> Date {
        switch cadence {
        case .monthly(let day):
            return nextMonthlyDate(dayOfMonth: day, after: from, calendar: calendar)
        case .weekly(let weekday):
            return nextWeekdayDate(weekday: weekday, after: from, calendar: calendar, weeksOffset: 1)
        case .biweekly(let weekday):
            return nextWeekdayDate(weekday: weekday, after: from, calendar: calendar, weeksOffset: 2)
        }
    }

    // MARK: - Internal

    private static func nextMonthlyDate(dayOfMonth: Int, after from: Date, calendar: Calendar) -> Date {
        // Try the current month, then the next, then the one after — in case the
        // target day in the current month is in the past relative to `from`.
        for monthsAhead in 0...2 {
            let advanced = calendar.date(byAdding: .month, value: monthsAhead, to: from)!
            let components = calendar.dateComponents([.year, .month], from: advanced)
            let candidateComponents = DateComponents(
                year: components.year, month: components.month,
                day: clampedDayOfMonth(dayOfMonth, in: advanced, calendar: calendar),
                hour: fireHour, minute: 0, second: 0
            )
            if let candidate = calendar.date(from: candidateComponents), candidate > from {
                return candidate
            }
        }
        // Defensive fallback — should be unreachable for sane inputs.
        return calendar.date(byAdding: .month, value: 1, to: from)!
    }

    private static func clampedDayOfMonth(_ day: Int, in date: Date, calendar: Calendar) -> Int {
        let range = calendar.range(of: .day, in: .month, for: date) ?? 1..<29
        return min(day, range.upperBound - 1)
    }

    private static func nextWeekdayDate(
        weekday: RecurrenceCadence.Weekday,
        after from: Date,
        calendar: Calendar,
        weeksOffset: Int
    ) -> Date {
        let targetWeekday = weekday.calendarComponent
        var components = DateComponents()
        components.weekday = targetWeekday
        components.hour = fireHour
        components.minute = 0
        // For biweekly (weeksOffset == 2): search from a point 14 days out so we land
        // on the first target weekday that is at least two full weeks away.
        // weeksOffset=1 → no shift (weekly), weeksOffset=2 → shift 14 days (biweekly).
        let searchBase: Date
        if weeksOffset > 1 {
            searchBase = calendar.date(byAdding: .day, value: weeksOffset * 7, to: from)!
        } else {
            searchBase = from
        }
        // Find the next occurrence of the target weekday at 8am STRICTLY after searchBase.
        return calendar.nextDate(
            after: searchBase, matching: components, matchingPolicy: .nextTime
        )!
    }
}
