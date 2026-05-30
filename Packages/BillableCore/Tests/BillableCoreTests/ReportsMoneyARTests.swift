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
