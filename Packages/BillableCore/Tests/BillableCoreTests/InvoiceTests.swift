import Foundation
import Testing
@testable import BillableCore

@Suite("Invoice money math")
struct InvoiceMoneyMathTests {
    private func makeInvoice(
        lineItems: [InvoiceLineItem],
        taxRate: Decimal
    ) -> Invoice {
        Invoice(
            number: "INV-0001",
            dueAt: Date(timeIntervalSince1970: 1_700_000_000),
            clientNameSnapshot: "Acme",
            issuerNameSnapshot: "Studio Lina",
            issuerAddressSnapshot: "123 Studio Way",
            issuerEmailSnapshot: "hello@studiolina.example",
            paymentTermsSnapshot: "Net 14",
            taxLabelSnapshot: "Tax",
            taxRateSnapshot: taxRate,
            currencyCodeSnapshot: "USD",
            lineItems: lineItems
        )
    }

    @Test("Subtotal sums line item amounts")
    func subtotal() {
        let invoice = makeInvoice(
            lineItems: [
                InvoiceLineItem(description: "A", hours: 1, hourlyRate: 100),
                InvoiceLineItem(description: "B", hours: Decimal(string: "2.5")!, hourlyRate: 80),
            ],
            taxRate: 0
        )
        #expect(invoice.subtotal == 300)
    }

    @Test("Tax amount = subtotal * rate")
    func tax() {
        let invoice = makeInvoice(
            lineItems: [InvoiceLineItem(description: "A", hours: 10, hourlyRate: 100)],
            taxRate: Decimal(string: "0.1")!
        )
        #expect(invoice.subtotal == 1000)
        #expect(invoice.taxAmount == 100)
        #expect(invoice.total == 1100)
    }

    @Test("Zero tax leaves total = subtotal")
    func zeroTax() {
        let invoice = makeInvoice(
            lineItems: [InvoiceLineItem(description: "A", hours: 3, hourlyRate: 75)],
            taxRate: 0
        )
        #expect(invoice.total == invoice.subtotal)
        #expect(invoice.total == 225)
    }

    @Test("Line items survive Codable round-trip via lineItemsData")
    func lineItemsRoundTrip() {
        let items = [
            InvoiceLineItem(description: "Hero section", hours: Decimal(string: "1.5")!, hourlyRate: 120),
            InvoiceLineItem(description: "Logo exploration", hours: 2, hourlyRate: 95),
        ]
        let invoice = makeInvoice(lineItems: items, taxRate: 0)
        let roundTripped = invoice.lineItems
        #expect(roundTripped.count == 2)
        #expect(roundTripped[0].description == "Hero section")
        #expect(roundTripped[1].amount == 190)
    }
}

@Suite("Invoice status machine")
struct InvoiceStatusMachineTests {
    private func draftInvoice() -> Invoice {
        Invoice(
            number: "INV-0001",
            dueAt: .now.addingTimeInterval(86_400 * 14),
            clientNameSnapshot: "Acme",
            issuerNameSnapshot: "Studio Lina",
            issuerAddressSnapshot: "",
            issuerEmailSnapshot: "",
            paymentTermsSnapshot: "Net 14",
            taxLabelSnapshot: "Tax",
            taxRateSnapshot: 0,
            currencyCodeSnapshot: "USD"
        )
    }

    @Test("Draft -> Sent records sentAt and advances status")
    func markSentFromDraft() throws {
        let invoice = draftInvoice()
        let sentDate = Date(timeIntervalSince1970: 1_700_000_000)
        try invoice.markSent(at: sentDate)
        #expect(invoice.status == .sent)
        #expect(invoice.sentAt == sentDate)
    }

    @Test("Sent -> Paid records paidAt")
    func markPaidFromSent() throws {
        let invoice = draftInvoice()
        try invoice.markSent(at: .now)
        let paidDate = Date(timeIntervalSince1970: 1_700_000_000)
        try invoice.markPaid(at: paidDate)
        #expect(invoice.status == .paid)
        #expect(invoice.paidAt == paidDate)
    }

    @Test("Cannot mark Paid directly from Draft")
    func cannotJumpDraftToPaid() {
        let invoice = draftInvoice()
        #expect(throws: InvoiceTransitionError.self) {
            try invoice.markPaid()
        }
    }

    @Test("Cannot re-send an already Sent invoice")
    func cannotResend() throws {
        let invoice = draftInvoice()
        try invoice.markSent()
        #expect(throws: InvoiceTransitionError.self) {
            try invoice.markSent()
        }
    }

    @Test("Cannot re-pay an already Paid invoice")
    func cannotRepay() throws {
        let invoice = draftInvoice()
        try invoice.markSent()
        try invoice.markPaid()
        #expect(throws: InvoiceTransitionError.self) {
            try invoice.markPaid()
        }
    }

    @Test("Overdue is derived from status + dueAt + clock")
    func overdueDerivation() throws {
        let invoice = draftInvoice()
        invoice.dueAt = Date(timeIntervalSince1970: 1_700_000_000)
        let beforeDue = invoice.dueAt.addingTimeInterval(-3600)
        let afterDue = invoice.dueAt.addingTimeInterval(3600)

        // Draft is never overdue, even past due
        #expect(invoice.isOverdue(asOf: afterDue) == false)

        try invoice.markSent()
        #expect(invoice.isOverdue(asOf: beforeDue) == false)
        #expect(invoice.isOverdue(asOf: afterDue) == true)

        // Paid is never overdue
        try invoice.markPaid()
        #expect(invoice.isOverdue(asOf: afterDue) == false)
    }
}
