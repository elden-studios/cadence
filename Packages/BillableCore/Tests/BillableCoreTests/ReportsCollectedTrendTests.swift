import Testing
import Foundation
@testable import BillableCore

@Suite("ReportsAggregator.collectedMonthlyTrend")
struct ReportsCollectedTrendTests {

    // Fixed reference instant used across the BillableCore reporting suites for determinism.
    // 1_700_000_000 == 2023-11-14 22:13:20 UTC.
    private let asOf = Date(timeIntervalSince1970: 1_700_000_000)
    private var gregorian: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// Builds a paid/sent/draft invoice with a single line item summing to `total` (taxRate 0 by default).
    private func makeInvoice(
        total: Decimal,
        status: InvoiceStatus,
        issued: Date,
        paid: Date?,
        currency: String = "USD",
        taxRate: Decimal = 0
    ) -> Invoice {
        // FULL required-param Invoice.init (matches the canonical helper in
        // ReportsSnapshotIntegrationTests.swift:17) + a threaded taxRate so Task 19
        // can assert a tax-inclusive total. One line item at hours:1 × rate:total
        // ⇒ subtotal == total; status is passed to the init (not set after).
        let inv = Invoice(
            number: "INV-1", issuedAt: issued, dueAt: issued, status: status,
            clientNameSnapshot: "C", issuerNameSnapshot: "Me", issuerAddressSnapshot: "",
            issuerEmailSnapshot: "", paymentTermsSnapshot: "", taxLabelSnapshot: "",
            taxRateSnapshot: taxRate, currencyCodeSnapshot: currency,
            lineItems: [InvoiceLineItem(description: "work", hours: 1, hourlyRate: total)]
        )
        inv.paidAt = paid
        return inv
    }

    /// First instant of the calendar month `monthsAgo` months before the asOf month.
    private func monthStart(_ monthsAgo: Int) -> Date {
        let thisMonth = gregorian.dateInterval(of: .month, for: asOf)!.start
        return gregorian.date(byAdding: .month, value: -monthsAgo, to: thisMonth)!
    }

    @Test("returns exactly monthsBack points, oldest→newest, ids == month starts ending asOf month")
    func returnsGapFilledWindow() {
        let points = ReportsAggregator.collectedMonthlyTrend(
            invoices: [],
            activeCurrency: "USD",
            monthsBack: 6,
            asOf: asOf,
            calendar: gregorian
        )

        #expect(points.count == 6)
        // Oldest first (5 months ago) … newest last (current month).
        let expectedStarts = (0..<6).reversed().map { monthStart($0) }
        #expect(points.map(\.bucketStart) == expectedStarts)
        #expect(points.map(\.id) == expectedStarts)
        // Empty input → all zero buckets (gap-filled, not an empty array).
        #expect(points.allSatisfy { $0.amount == 0 })
    }

    // MARK: - Task 17: paidAt-bucketing (behavior lock)

    @Test("a paid invoice sums into the bucket of its paidAt month at invoice.total")
    func paidInvoiceLandsInPaidMonth() {
        // Paid 2 months ago.
        let paidDate = gregorian.date(byAdding: .day, value: 3, to: monthStart(2))!
        let inv = makeInvoice(total: 500, status: .paid, issued: paidDate, paid: paidDate)

        let points = ReportsAggregator.collectedMonthlyTrend(
            invoices: [inv], activeCurrency: "USD", monthsBack: 6, asOf: asOf, calendar: gregorian
        )

        // Index 3 == "2 months ago" in a 6-bucket oldest→newest window (0:−5 … 5:−0).
        #expect(points[3].bucketStart == monthStart(2))
        #expect(points[3].amount == 500)
        // Every other bucket stays zero.
        #expect(points.enumerated().filter { $0.offset != 3 }.allSatisfy { $0.element.amount == 0 })
    }

    @Test("an invoice issued in an earlier month but paid in a later in-window month lands in the PAID month")
    func bucketsByPaidAtNotIssuedAt() {
        let issued = gregorian.date(byAdding: .day, value: 2, to: monthStart(4))!   // issued 4 months ago
        let paid = gregorian.date(byAdding: .day, value: 5, to: monthStart(1))!     // paid 1 month ago
        let inv = makeInvoice(total: 750, status: .paid, issued: issued, paid: paid)

        let points = ReportsAggregator.collectedMonthlyTrend(
            invoices: [inv], activeCurrency: "USD", monthsBack: 6, asOf: asOf, calendar: gregorian
        )

        // Lands in the PAID month (index 4 == 1 month ago), NOT the issued month (index 1 == 4 months ago).
        #expect(points[4].amount == 750)
        #expect(points[1].amount == 0)
    }

    // MARK: - Task 18: Exclusions + same-month aggregation (behavior lock)

    @Test("draft and sent invoices contribute 0 (only .paid counts)")
    func nonPaidStatusesExcluded() {
        let when = gregorian.date(byAdding: .day, value: 3, to: monthStart(2))!
        let draft = makeInvoice(total: 999, status: .draft, issued: when, paid: nil)
        let sent  = makeInvoice(total: 888, status: .sent,  issued: when, paid: nil)

        let points = ReportsAggregator.collectedMonthlyTrend(
            invoices: [draft, sent], activeCurrency: "USD", monthsBack: 6, asOf: asOf, calendar: gregorian
        )
        #expect(points.allSatisfy { $0.amount == 0 })
    }

    @Test("a .paid invoice with paidAt == nil is excluded")
    func paidWithNilPaidAtExcluded() {
        let when = gregorian.date(byAdding: .day, value: 3, to: monthStart(2))!
        let inv = makeInvoice(total: 600, status: .paid, issued: when, paid: nil)

        let points = ReportsAggregator.collectedMonthlyTrend(
            invoices: [inv], activeCurrency: "USD", monthsBack: 6, asOf: asOf, calendar: gregorian
        )
        #expect(points.allSatisfy { $0.amount == 0 })
    }

    @Test("paid OLDER than the window, and paid in a FUTURE month, are both excluded")
    func outOfWindowExcluded() {
        let tooOld = gregorian.date(byAdding: .day, value: 3, to: monthStart(7))!   // 7 months ago (window is 6)
        let future = gregorian.date(byAdding: .month, value: 2, to: asOf)!          // 2 months ahead
        let oldInv = makeInvoice(total: 400, status: .paid, issued: tooOld, paid: tooOld)
        let futInv = makeInvoice(total: 300, status: .paid, issued: future, paid: future)

        let points = ReportsAggregator.collectedMonthlyTrend(
            invoices: [oldInv, futInv], activeCurrency: "USD", monthsBack: 6, asOf: asOf, calendar: gregorian
        )
        #expect(points.allSatisfy { $0.amount == 0 })
    }

    @Test("an invoice in a non-matching currency contributes 0 (currency guard)")
    func currencyGuardExcludes() {
        let when = gregorian.date(byAdding: .day, value: 3, to: monthStart(2))!
        let foreign = makeInvoice(total: 5000, status: .paid, issued: when, paid: when, currency: "EUR")

        let points = ReportsAggregator.collectedMonthlyTrend(
            invoices: [foreign], activeCurrency: "USD", monthsBack: 6, asOf: asOf, calendar: gregorian
        )
        #expect(points.allSatisfy { $0.amount == 0 })
    }

    @Test("two paid invoices in the same month aggregate into one bucket")
    func sameMonthAggregates() {
        let d1 = gregorian.date(byAdding: .day, value: 2,  to: monthStart(3))!
        let d2 = gregorian.date(byAdding: .day, value: 20, to: monthStart(3))!
        let a = makeInvoice(total: 200, status: .paid, issued: d1, paid: d1)
        let b = makeInvoice(total: 350, status: .paid, issued: d2, paid: d2)

        let points = ReportsAggregator.collectedMonthlyTrend(
            invoices: [a, b], activeCurrency: "USD", monthsBack: 6, asOf: asOf, calendar: gregorian
        )
        // Index 2 == 3 months ago.
        #expect(points[2].amount == 550)
    }

    // MARK: - Task 19: Month-boundary instant + tax-inclusive total (behavior lock)

    @Test("paidAt exactly at a month's first instant lands in that month, not the prior one")
    func monthBoundaryInstant() {
        let boundary = monthStart(2)   // 00:00:00 on the first of the month, 2 months ago
        let inv = makeInvoice(total: 100, status: .paid, issued: boundary, paid: boundary)

        let points = ReportsAggregator.collectedMonthlyTrend(
            invoices: [inv], activeCurrency: "USD", monthsBack: 6, asOf: asOf, calendar: gregorian
        )
        // Index 3 == 2 months ago; index 4 == 1 month ago (the would-be "prior month" error bucket).
        #expect(points[3].amount == 100)
        #expect(points[4].amount == 0)
    }

    @Test("amount equals tax-inclusive total (subtotal + tax), not subtotal")
    func amountIsTaxInclusive() {
        let when = gregorian.date(byAdding: .day, value: 3, to: monthStart(2))!
        // subtotal 1000, taxRate 0.15 → total 1150.
        let inv = makeInvoice(total: 1000, status: .paid, issued: when, paid: when, taxRate: 0.15)

        let points = ReportsAggregator.collectedMonthlyTrend(
            invoices: [inv], activeCurrency: "USD", monthsBack: 6, asOf: asOf, calendar: gregorian
        )
        #expect(points[3].amount == Decimal(1150))
    }

    // MARK: - collectedMonthlyTrend: monthsBack:0 guard path

    @Test("collectedMonthlyTrend with monthsBack:0 returns empty array")
    func monthsBackZeroReturnsEmpty() {
        let result = ReportsAggregator.collectedMonthlyTrend(
            invoices: [],
            activeCurrency: "USD",
            monthsBack: 0,
            asOf: asOf,
            calendar: gregorian
        )
        #expect(result == [])
    }

    // MARK: - collectedThisYear

    @Test("collectedThisYear sums paid invoices whose paidAt is in the reference year")
    func collectedThisYearSumsPaidInYear() {
        // asOf == 2023-11-14; year interval is 2023-01-01 …< 2024-01-01.
        let inYear  = gregorian.date(byAdding: .day, value: 3, to: monthStart(2))!  // Nov 2023, within the year
        let inv1 = makeInvoice(total: 500, status: .paid, issued: inYear, paid: inYear)
        let inv2 = makeInvoice(total: 300, status: .paid, issued: inYear, paid: inYear)

        let result = ReportsAggregator.collectedThisYear(
            invoices: [inv1, inv2],
            activeCurrency: "USD",
            asOf: asOf,
            calendar: gregorian
        )
        #expect(result == 800)
    }

    @Test("collectedThisYear excludes paid invoices whose paidAt is in a different year")
    func collectedThisYearExcludesPriorYear() {
        // Build a date in 2022 (prior year relative to asOf 2023).
        let priorYear = gregorian.date(from: DateComponents(year: 2022, month: 6, day: 1))!
        let inv = makeInvoice(total: 999, status: .paid, issued: priorYear, paid: priorYear)

        let result = ReportsAggregator.collectedThisYear(
            invoices: [inv],
            activeCurrency: "USD",
            asOf: asOf,
            calendar: gregorian
        )
        #expect(result == 0)
    }

    @Test("collectedThisYear is year-boundary-precise: first instant of asOf year IN, last instant of prior year OUT")
    func collectedThisYearYearBoundaryInstants() {
        // asOf == 2023-11-14 → year interval is [2023-01-01 00:00:00, 2024-01-01 00:00:00).
        let firstInstantThisYear = gregorian.date(from: DateComponents(year: 2023, month: 1, day: 1))!
        // One second before the year start == the last instant of the prior (2022) year.
        let lastInstantPriorYear = firstInstantThisYear.addingTimeInterval(-1)

        let included = makeInvoice(total: 500, status: .paid, issued: firstInstantThisYear, paid: firstInstantThisYear)
        let excluded = makeInvoice(total: 999, status: .paid, issued: lastInstantPriorYear, paid: lastInstantPriorYear)

        let result = ReportsAggregator.collectedThisYear(
            invoices: [included, excluded],
            activeCurrency: "USD",
            asOf: asOf,
            calendar: gregorian
        )
        // Only the first-instant-of-year invoice counts; the prior-year one is excluded.
        #expect(result == 500)
    }

    @Test("collectedThisYear excludes draft and sent invoices")
    func collectedThisYearExcludesNonPaid() {
        let when = gregorian.date(byAdding: .day, value: 3, to: monthStart(2))!
        let draft = makeInvoice(total: 999, status: .draft, issued: when, paid: nil)
        let sent  = makeInvoice(total: 888, status: .sent,  issued: when, paid: nil)

        let result = ReportsAggregator.collectedThisYear(
            invoices: [draft, sent],
            activeCurrency: "USD",
            asOf: asOf,
            calendar: gregorian
        )
        #expect(result == 0)
    }

    @Test("collectedThisYear excludes a paid invoice with nil paidAt")
    func collectedThisYearExcludesNilPaidAt() {
        let when = gregorian.date(byAdding: .day, value: 3, to: monthStart(2))!
        let inv = makeInvoice(total: 600, status: .paid, issued: when, paid: nil)

        let result = ReportsAggregator.collectedThisYear(
            invoices: [inv],
            activeCurrency: "USD",
            asOf: asOf,
            calendar: gregorian
        )
        #expect(result == 0)
    }

    @Test("collectedThisYear excludes invoices in a non-matching currency")
    func collectedThisYearExcludesWrongCurrency() {
        let when = gregorian.date(byAdding: .day, value: 3, to: monthStart(2))!
        let foreign = makeInvoice(total: 5000, status: .paid, issued: when, paid: when, currency: "EUR")

        let result = ReportsAggregator.collectedThisYear(
            invoices: [foreign],
            activeCurrency: "USD",
            asOf: asOf,
            calendar: gregorian
        )
        #expect(result == 0)
    }

    // MARK: - Task 20: hasEnoughCollectedHistory gate (red → Task 21)

    @Test("hasEnoughCollectedHistory requires ≥2 distinct months with positive collected amount")
    func enoughHistoryPredicate() {
        let zero = (0..<6).reversed().map { ReportsAggregator.TrendPoint(id: monthStart($0), bucketStart: monthStart($0), amount: 0) }
        #expect(ReportsAggregator.hasEnoughCollectedHistory(zero) == false)

        // Exactly one positive month → still not enough.
        var one = zero
        one[3] = ReportsAggregator.TrendPoint(id: one[3].id, bucketStart: one[3].bucketStart, amount: 500)
        #expect(ReportsAggregator.hasEnoughCollectedHistory(one) == false)

        // Two positive months → enough.
        var two = one
        two[5] = ReportsAggregator.TrendPoint(id: two[5].id, bucketStart: two[5].bucketStart, amount: 200)
        #expect(ReportsAggregator.hasEnoughCollectedHistory(two) == true)
    }
}
