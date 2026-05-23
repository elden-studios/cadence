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
        weeksOffset: Int  // 1 = weekly, 2 = biweekly
    ) -> Date {
        var components = DateComponents()
        components.weekday = weekday.calendarComponent
        components.hour = fireHour
        components.minute = 0
        // Find next target weekday strictly after `from`.
        let firstNext = calendar.nextDate(
            after: from, matching: components, matchingPolicy: .nextTime
        )!
        // For biweekly: nudge +7d. This makes both call sites correct:
        // - Creation (Wed Jun 3 → first Fri = Jun 5 → +7 = Jun 12) gives the user
        //   a one-week grace before the first invoice.
        // - Materialization (Fri Jun 5 8am tap → next Fri = Jun 12 → +7 = Jun 19)
        //   correctly produces every-14-days cadence with no drift.
        guard weeksOffset > 1 else { return firstNext }
        return calendar.date(byAdding: .day, value: 7, to: firstNext)!
    }
}
