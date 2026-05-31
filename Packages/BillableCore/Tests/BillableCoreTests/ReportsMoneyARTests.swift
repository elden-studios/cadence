import Testing
import Foundation
@testable import BillableCore

/// Build an invoice with one line item summing to `total` (pre-tax), tax 0.
/// Mirrors the full `Invoice.init`; shared across the money / AR / perf / trend suites.
private func makeInvoice(total: Decimal, status: InvoiceStatus, issued: Date, due: Date,
                         paid: Date? = nil, currency: String = "USD") -> Invoice {
    let inv = Invoice(
        number: "INV-1", issuedAt: issued, dueAt: due, status: status,
        clientNameSnapshot: "C", issuerNameSnapshot: "Me", issuerAddressSnapshot: "",
        issuerEmailSnapshot: "", paymentTermsSnapshot: "", taxLabelSnapshot: "",
        taxRateSnapshot: 0, currencyCodeSnapshot: currency,
        lineItems: [InvoiceLineItem(description: "work", hours: 1, hourlyRate: total)]
    )
    inv.paidAt = paid
    return inv
}

@Suite("ReportsAggregator money")
struct ReportsMoneySummaryTests {

    @Test("Invoiced counts non-draft issued in range; Collected counts paid-in-range; currency filtered")
    func moneySummary() {
        let cal = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_700_000_000) // fixed
        let inMonth = cal.date(byAdding: .day, value: -3, to: now)!
        let lastMonth = cal.date(byAdding: .day, value: -40, to: now)!

        let invoices = [
            makeInvoice(total: 100, status: .sent, issued: inMonth, due: now),                 // invoiced, not collected
            makeInvoice(total: 200, status: .paid, issued: inMonth, due: now, paid: inMonth),    // invoiced + collected
            makeInvoice(total: 50,  status: .draft, issued: inMonth, due: now),                  // excluded (draft)
            makeInvoice(total: 999, status: .paid, issued: lastMonth, due: lastMonth, paid: lastMonth), // out of range
            makeInvoice(total: 77,  status: .sent, issued: inMonth, due: now, currency: "EUR"),  // excluded (currency)
        ]

        let snap = ReportsAggregator.snapshot(
            entries: [], invoices: invoices, in: .thisMonth,
            activeCurrency: "USD", referenceDate: now, calendar: cal)

        #expect(snap.money.invoiced == 300)        // 100 + 200
        #expect(snap.money.collected == 200)       // the paid-in-range one
        #expect(snap.money.tracked == 0)           // no entries
        #expect(snap.excludedCurrencyCount == 1)   // the EUR invoice
    }
}

@Suite("ReportsAggregator AR")
struct ReportsARSummaryTests {
    @Test("Aging buckets by days past due; overdue excludes paid/draft; avg days-to-pay")
    func arSummary() {
        let cal = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func daysAgo(_ n: Int) -> Date { cal.date(byAdding: .day, value: -n, to: now)! }
        func daysAhead(_ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: now)! }

        let invoices = [
            makeInvoice(total: 100, status: .sent, issued: daysAgo(10), due: daysAhead(5)),   // current (not due)
            makeInvoice(total: 200, status: .sent, issued: daysAgo(40), due: daysAgo(10)),    // overdue 10d → 1–30
            makeInvoice(total: 300, status: .sent, issued: daysAgo(80), due: daysAgo(45)),    // overdue 45d → 31–60
            makeInvoice(total: 400, status: .sent, issued: daysAgo(120), due: daysAgo(90)),   // overdue 90d → 60+
            makeInvoice(total: 500, status: .paid, issued: daysAgo(30), due: daysAgo(15), paid: daysAgo(5)), // paid (not AR); 25d to pay
            makeInvoice(total: 999, status: .draft, issued: daysAgo(3), due: daysAhead(20)),  // draft (ignored)
        ]
        let snap = ReportsAggregator.snapshot(entries: [], invoices: invoices, in: .allTime,
                                              activeCurrency: "USD", referenceDate: now, calendar: cal)
        #expect(snap.ar.aging.current == 100)
        #expect(snap.ar.aging.d1to30 == 200)
        #expect(snap.ar.aging.d31to60 == 300)
        #expect(snap.ar.aging.d60plus == 400)
        #expect(snap.ar.outstanding == 1000)         // 100+200+300+400
        #expect(snap.ar.overdue == 900)              // 200+300+400
        #expect(snap.ar.overdueCount == 3)
        #expect(snap.ar.avgDaysToPay == 25)          // only the one paid invoice
    }

    @Test("avgDaysToPay is as-of-now: a paid invoice outside the selected range still counts")
    func avgDaysToPayAsOfNow() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func daysAgo(_ n: Int) -> Date { cal.date(byAdding: .day, value: -n, to: now)! }
        // Paid 40 days ago — OUTSIDE 'this week'. issued→paid = 10 days.
        let invoices = [
            makeInvoice(total: 500, status: .paid, issued: daysAgo(50), due: daysAgo(45), paid: daysAgo(40))
        ]
        let snap = ReportsAggregator.snapshot(entries: [], invoices: invoices, in: .thisWeek,
                                              activeCurrency: "USD", referenceDate: now, calendar: cal)
        // Range-scoped (old) would exclude it → nil. As-of-now (fixed) includes it → 10.
        #expect(snap.ar.avgDaysToPay == 10)
    }
}

@Suite("ReportsAggregator performance")
struct ReportsPerformanceTests {
    @Test("effective rate = tracked/totalHours; utilization = billable/total; nil-guard at zero hours")
    func performance() {
        let perf = ReportsAggregator.performanceSummary(tracked: 800, totalHours: 10, billableHours: 8)
        #expect(perf.effectiveRate == 80)            // 800 / 10
        #expect(perf.utilization == 0.8)             // 8 / 10
        let zero = ReportsAggregator.performanceSummary(tracked: 0, totalHours: 0, billableHours: 0)
        #expect(zero.effectiveRate == nil)
        #expect(zero.utilization == nil)
    }
}

@Suite("ReportsAggregator trend")
struct ReportsTrendTests {
    @Test("Year range buckets invoiced totals by month")
    func trendByMonth() {
        let cal = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func monthsAgo(_ n: Int) -> Date { cal.date(byAdding: .month, value: -n, to: now)! }
        let invoices = [
            makeInvoice(total: 100, status: .sent, issued: now, due: now),
            makeInvoice(total: 50,  status: .paid, issued: now, due: now, paid: now),
            makeInvoice(total: 200, status: .sent, issued: monthsAgo(2), due: monthsAgo(2)),
            makeInvoice(total: 999, status: .draft, issued: now, due: now), // excluded
        ]
        let snap = ReportsAggregator.snapshot(entries: [], invoices: invoices, in: .thisYear,
                                              activeCurrency: "USD", referenceDate: now, calendar: cal)
        #expect(snap.trendBucket == .month)
        // current month bucket = 150 (100 + 50), the draft excluded
        let thisMonthBucket = snap.revenueTrend.first { cal.isDate($0.bucketStart, equalTo: now, toGranularity: .month) }
        #expect(thisMonthBucket?.amount == 150)
    }
}
