import Foundation
import Testing
@testable import BillableCore

@Suite("Invoice tax ID snapshots")
struct InvoiceTaxIDSnapshotTests {

    @Test("Invoice with no explicit tax ID snapshot args has empty snapshots")
    func defaultsAreEmpty() {
        let invoice = Invoice(
            number: "INV-0001",
            dueAt: Date(timeIntervalSince1970: 0),
            clientNameSnapshot: "Acme",
            issuerNameSnapshot: "Studio",
            issuerAddressSnapshot: "123 Main",
            issuerEmailSnapshot: "hi@studio.example",
            paymentTermsSnapshot: "Net 14",
            taxLabelSnapshot: "Tax",
            taxRateSnapshot: 0,
            currencyCodeSnapshot: "USD"
        )
        #expect(invoice.issuerTaxIDLabelSnapshot == "")
        #expect(invoice.issuerTaxIDNumberSnapshot == "")
    }

    @Test("Invoice preserves explicit tax ID snapshots")
    func explicitSnapshotsPreserved() {
        let invoice = Invoice(
            number: "INV-0001",
            dueAt: Date(timeIntervalSince1970: 0),
            clientNameSnapshot: "Acme",
            issuerNameSnapshot: "Studio",
            issuerAddressSnapshot: "123 Main",
            issuerEmailSnapshot: "hi@studio.example",
            issuerTaxIDLabelSnapshot: "VAT",
            issuerTaxIDNumberSnapshot: "GB123456789",
            paymentTermsSnapshot: "Net 14",
            taxLabelSnapshot: "Tax",
            taxRateSnapshot: 0,
            currencyCodeSnapshot: "USD"
        )
        #expect(invoice.issuerTaxIDLabelSnapshot == "VAT")
        #expect(invoice.issuerTaxIDNumberSnapshot == "GB123456789")
    }
}
