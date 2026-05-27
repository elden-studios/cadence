import Foundation
import Testing
@testable import BillableCore

@Suite("DaysAgoFormatter")
struct DaysAgoFormatterTests {

    @Test("Returns prefix + 'today' for same calendar day")
    func sameDay() {
        let now = Date(timeIntervalSinceReferenceDate: 760_000_000)
        let sameDayEarlier = now.addingTimeInterval(-3600)
        #expect(DaysAgoFormatter.string(for: sameDayEarlier, prefix: "Last invoice: ", now: now)
                == "Last invoice: today")
    }

    @Test("Returns prefix + 'yesterday' for 1 day ago")
    func yesterday() {
        let now = Date(timeIntervalSinceReferenceDate: 760_000_000)
        let oneDayAgo = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        #expect(DaysAgoFormatter.string(for: oneDayAgo, prefix: "Last invoice: ", now: now)
                == "Last invoice: yesterday")
    }

    @Test("Returns prefix + 'N days ago' for 2+ days")
    func multipleDays() {
        let now = Date(timeIntervalSinceReferenceDate: 760_000_000)
        let twelveDaysAgo = Calendar.current.date(byAdding: .day, value: -12, to: now)!
        #expect(DaysAgoFormatter.string(for: twelveDaysAgo, prefix: "Last invoice: ", now: now)
                == "Last invoice: 12 days ago")
    }

    @Test("Future-dated invoices (clock skew edge case) still read as 'today'")
    func futureDated() {
        let now = Date(timeIntervalSinceReferenceDate: 760_000_000)
        let futureInvoice = now.addingTimeInterval(3600)
        #expect(DaysAgoFormatter.string(for: futureInvoice, prefix: "Last invoice: ", now: now)
                == "Last invoice: today")
    }

    @Test("Empty prefix yields just the relative portion")
    func emptyPrefix() {
        let now = Date(timeIntervalSinceReferenceDate: 760_000_000)
        let oneDayAgo = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        #expect(DaysAgoFormatter.string(for: oneDayAgo, prefix: "", now: now) == "yesterday")
    }
}
