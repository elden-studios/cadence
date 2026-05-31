import Foundation
import Testing
import SwiftData
@testable import BillableCore

@Suite("InvoiceTemplateData watermark helper")
@MainActor
struct InvoiceWatermarkHelperTests {

    private func makeInvoice(context: ModelContext) -> Invoice {
        let invoice = Invoice(
            number: "INV-0001",
            dueAt: Date(timeIntervalSince1970: 1_700_000_000),
            clientNameSnapshot: "Acme",
            issuerNameSnapshot: "Studio Lina",
            issuerAddressSnapshot: "123 Studio Way",
            issuerEmailSnapshot: "hello@studiolina.example",
            paymentTermsSnapshot: "Net 14",
            taxLabelSnapshot: "Tax",
            taxRateSnapshot: 0,
            currencyCodeSnapshot: "USD"
        )
        context.insert(invoice)
        return invoice
    }

    @Test("watermarked: true stamps the constant")
    func watermarkedTrueStampsTheConstant() throws {
        let container = try BillableModelContainer.inMemory()
        let context = ModelContext(container)
        let invoice = makeInvoice(context: context)
        let data = InvoiceTemplateData.from(invoice, watermarked: true)
        #expect(data.watermark == InvoiceTemplateData.watermarkText)
    }

    @Test("watermarked: false leaves watermark nil")
    func watermarkedFalseLeavesNil() throws {
        let container = try BillableModelContainer.inMemory()
        let context = ModelContext(container)
        let invoice = makeInvoice(context: context)
        let data = InvoiceTemplateData.from(invoice, watermarked: false)
        #expect(data.watermark == nil)
    }
}
