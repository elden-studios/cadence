import Foundation
import Testing
@testable import BillableCore

/// Regression (Gemini r5): the AR card's "No invoices yet" state must key on an
/// as-of-now signal (any non-draft invoice exists), NOT the range-scoped
/// `money.invoiced`. Otherwise a user with paid invoices OUTSIDE the selected
/// range wrongly sees "No invoices yet" instead of "All paid up".
@Suite("ReportsAggregator AR empty-state signal")
struct ReportsARStateTests {

    private func makeInvoice(status: InvoiceStatus, issued: Date, paid: Date?) -> Invoice {
        let inv = Invoice(
            number: "INV-1", issuedAt: issued, dueAt: issued, status: status,
            clientNameSnapshot: "C", issuerNameSnapshot: "Me", issuerAddressSnapshot: "",
            issuerEmailSnapshot: "", paymentTermsSnapshot: "", taxLabelSnapshot: "",
            taxRateSnapshot: 0, currencyCodeSnapshot: "USD",
            lineItems: [InvoiceLineItem(description: "work", hours: 1, hourlyRate: 100)])
        inv.paidAt = paid
        return inv
    }

    @Test("a paid invoice outside the range still makes hasAnyBilledInvoice true")
    func paidOutsideRange() {
        let cal = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let lastYear = cal.date(byAdding: .month, value: -14, to: now)!
        let inv = makeInvoice(status: .paid, issued: lastYear, paid: lastYear)
        let snap = ReportsAggregator.snapshot(
            entries: [], invoices: [inv], in: .thisMonth,
            activeCurrency: "USD", referenceDate: now, calendar: cal)
        #expect(snap.money.invoiced == 0)          // nothing issued THIS month
        #expect(snap.ar.outstanding == 0)          // it's paid
        #expect(snap.hasAnyBilledInvoice == true)  // → AR shows "All paid up", not "No invoices yet"
    }

    @Test("no invoices → false; a lone draft doesn't count as billed")
    func noneOrDraft() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let none = ReportsAggregator.snapshot(
            entries: [], invoices: [], in: .allTime, activeCurrency: "USD", referenceDate: now)
        #expect(none.hasAnyBilledInvoice == false)

        let draft = makeInvoice(status: .draft, issued: now, paid: nil)
        let withDraft = ReportsAggregator.snapshot(
            entries: [], invoices: [draft], in: .allTime, activeCurrency: "USD", referenceDate: now)
        #expect(withDraft.hasAnyBilledInvoice == false)
    }
}
