import Foundation
import Testing
@testable import BillableCore

/// Regression: `hasReportableData` must be FALSE for a brand-new user with no
/// entries/invoices, so the Reports paywall teaser falls back to sample data
/// instead of rendering empty $0.00 figures. (It used to test `!revenueTrend.isEmpty`,
/// which is always non-empty because the trend emits zero-amount buckets.)
@Suite("ReportsAggregator hasReportableData")
struct ReportsHasReportableDataTests {

    @Test("no entries or invoices → hasReportableData is false")
    func emptyIsFalse() {
        let snap = ReportsAggregator.snapshot(
            entries: [], invoices: [], in: .thisMonth, activeCurrency: "USD")
        #expect(snap.hasReportableData == false)
        // The trend is non-empty (zero-amount buckets) — guarding against the old bug.
        #expect(snap.revenueTrend.isEmpty == false)
    }

    @Test("a sent invoice makes hasReportableData true")
    func withInvoiceIsTrue() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let inv = Invoice(
            number: "INV-1", issuedAt: now, dueAt: now, status: .sent,
            clientNameSnapshot: "C", issuerNameSnapshot: "Me", issuerAddressSnapshot: "",
            issuerEmailSnapshot: "", paymentTermsSnapshot: "", taxLabelSnapshot: "",
            taxRateSnapshot: 0, currencyCodeSnapshot: "USD",
            lineItems: [InvoiceLineItem(description: "work", hours: 1, hourlyRate: 100)])
        let snap = ReportsAggregator.snapshot(
            entries: [], invoices: [inv], in: .thisMonth, activeCurrency: "USD", referenceDate: now)
        #expect(snap.hasReportableData == true)
    }
}
