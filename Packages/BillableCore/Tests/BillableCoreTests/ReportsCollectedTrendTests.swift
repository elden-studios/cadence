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
}
