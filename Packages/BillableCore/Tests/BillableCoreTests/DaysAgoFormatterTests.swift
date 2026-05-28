import Foundation
import Testing
@testable import BillableCore

@Suite("DaysAgoFormatter")
struct DaysAgoFormatterTests {

    /// Fixed-timezone calendar so the calendar-day math (startOfDay) is
    /// deterministic regardless of the machine/CI timezone. All test dates
    /// below are built and compared through THIS calendar.
    private static func fixedCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal
    }

    /// Build a concrete date in the fixed calendar's timezone.
    private static func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 12, _ mi: Int = 0) -> Date {
        var comps = DateComponents()
        comps.year = y; comps.month = mo; comps.day = d; comps.hour = h; comps.minute = mi
        return fixedCalendar().date(from: comps)!
    }

    @Test("Returns prefix + 'today' for same calendar day")
    func sameDay() {
        let cal = Self.fixedCalendar()
        let now = Self.date(2026, 5, 28, 13, 0)
        let sameDayEarlier = Self.date(2026, 5, 28, 9, 0)
        #expect(DaysAgoFormatter.string(for: sameDayEarlier, prefix: "Last invoice: ", now: now, calendar: cal)
                == "Last invoice: today")
    }

    @Test("Returns prefix + 'yesterday' for 1 calendar day ago")
    func yesterday() {
        let cal = Self.fixedCalendar()
        let now = Self.date(2026, 5, 28, 12, 0)
        let oneDayAgo = Self.date(2026, 5, 27, 12, 0)
        #expect(DaysAgoFormatter.string(for: oneDayAgo, prefix: "Last invoice: ", now: now, calendar: cal)
                == "Last invoice: yesterday")
    }

    @Test("Returns prefix + 'N days ago' for 2+ calendar days")
    func multipleDays() {
        let cal = Self.fixedCalendar()
        let now = Self.date(2026, 5, 28, 12, 0)
        let twelveDaysAgo = Self.date(2026, 5, 16, 12, 0)
        #expect(DaysAgoFormatter.string(for: twelveDaysAgo, prefix: "Last invoice: ", now: now, calendar: cal)
                == "Last invoice: 12 days ago")
    }

    @Test("Future-dated invoices (clock skew edge case) still read as 'today'")
    func futureDated() {
        let cal = Self.fixedCalendar()
        let now = Self.date(2026, 5, 28, 12, 0)
        let futureInvoice = Self.date(2026, 5, 28, 13, 0)
        #expect(DaysAgoFormatter.string(for: futureInvoice, prefix: "Last invoice: ", now: now, calendar: cal)
                == "Last invoice: today")
    }

    @Test("Empty prefix yields just the relative portion")
    func emptyPrefix() {
        let cal = Self.fixedCalendar()
        let now = Self.date(2026, 5, 28, 12, 0)
        let oneDayAgo = Self.date(2026, 5, 27, 12, 0)
        #expect(DaysAgoFormatter.string(for: oneDayAgo, prefix: "", now: now, calendar: cal) == "yesterday")
    }

    // MARK: - Calendar-day vs 24-hour regression (Gemini PR #5 finding)

    @Test("Crossing midnight counts as 'yesterday' even when < 24h apart")
    func crossesMidnightUnder24Hours() {
        // Sent yesterday 11:00 PM, viewed today 9:00 AM — only 10 hours apart.
        // The previous raw-date dateComponents([.day]) math returned 0 ("today");
        // calendar-day semantics correctly return 1 ("yesterday").
        let cal = Self.fixedCalendar()
        let sentAt = Self.date(2026, 5, 27, 23, 0)
        let now = Self.date(2026, 5, 28, 9, 0)
        #expect(DaysAgoFormatter.string(for: sentAt, prefix: "", now: now, calendar: cal) == "yesterday")
    }

    @Test("Same-day evening + next morning still 'today' within one calendar day")
    func sameCalendarDayWideSpread() {
        // 8:00 AM and 11:30 PM same day — 15.5 hours apart but same calendar day.
        let cal = Self.fixedCalendar()
        let earlier = Self.date(2026, 5, 28, 8, 0)
        let now = Self.date(2026, 5, 28, 23, 30)
        #expect(DaysAgoFormatter.string(for: earlier, prefix: "", now: now, calendar: cal) == "today")
    }

    @Test("Two calendar days across a < 48h span reads as '2 days ago'")
    func twoCalendarDaysUnder48Hours() {
        // Sent Monday 11:00 PM, viewed Wednesday 1:00 AM — ~26 hours but spans
        // 3 distinct calendar days boundaries → 2 calendar days difference.
        let cal = Self.fixedCalendar()
        let sentAt = Self.date(2026, 5, 25, 23, 0)
        let now = Self.date(2026, 5, 27, 1, 0)
        #expect(DaysAgoFormatter.string(for: sentAt, prefix: "", now: now, calendar: cal) == "2 days ago")
    }
}
