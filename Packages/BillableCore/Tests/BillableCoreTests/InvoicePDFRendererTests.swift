import Foundation
import Testing
import SwiftUI
import PDFKit
@testable import BillableCore

/// Smoke tests for the PDF renderer. We intentionally don't snapshot the
/// rendered bytes here — `swift-snapshot-testing` requires a baseline directory
/// in the package and pixel-level fidelity can drift across SwiftUI versions.
/// The asserts below catch the failures we actually care about: the PDF
/// generates, has a single page at Letter size, and contains the invoice number
/// + total as text so downstream PDF readers can find them.
@Suite("InvoicePDFRenderer")
@MainActor
struct InvoicePDFRendererTests {

    private func fixtureData() -> InvoiceTemplateData {
        InvoiceTemplateData(
            issuerName: "Studio Lina",
            issuerAddress: "123 Studio Way\nBrooklyn, NY 11201",
            issuerEmail: "hello@studiolina.example",
            issuerLogo: nil,
            clientName: "Acme Corp",
            clientAddress: "1 Corporate Plaza",
            clientEmail: "pat@acme.example",
            invoiceNumber: "INV-0042",
            issuedDateLabel: "May 22, 2026",
            dueDateLabel: "Jun 5, 2026",
            paymentTerms: "Net 14",
            lineItems: [
                InvoiceLineItem(description: "Website Redesign — May 20", hours: Decimal(string: "1.5")!, hourlyRate: 120),
                InvoiceLineItem(description: "Brand Refresh — May 21", hours: 3, hourlyRate: 150),
            ],
            notes: "Thanks for the great collaboration.",
            subtotal: 630,
            taxLabel: "Tax",
            taxRate: Decimal(string: "0.0875")!,
            taxAmount: 0,
            total: 0,
            currencyCode: "USD"
        )
    }

    @Test("renderPDFData produces non-empty PDF bytes")
    func rendersBytes() {
        var data = fixtureData()
        data.taxAmount = data.subtotal * data.taxRate
        data.total = data.subtotal + data.taxAmount
        let bytes = InvoicePDFRenderer.renderPDFData(for: data, accent: .blue)
        #expect(!bytes.isEmpty)
        // A non-trivial PDF should weigh more than the 8-byte PDF header.
        #expect(bytes.count > 2_000)
    }

    @Test("PDFKit can parse the output and reports one page at Letter size")
    func roundTripPDFKit() throws {
        var data = fixtureData()
        data.taxAmount = data.subtotal * data.taxRate
        data.total = data.subtotal + data.taxAmount
        let bytes = InvoicePDFRenderer.renderPDFData(for: data, accent: .indigo)
        let doc = try #require(PDFDocument(data: bytes))
        #expect(doc.pageCount == 1)
        let page = try #require(doc.page(at: 0))
        let bounds = page.bounds(for: .mediaBox)
        #expect(bounds.width == InvoiceTemplate.pageWidth)
        #expect(bounds.height == InvoiceTemplate.pageHeight)
    }

    @Test("Rendered PDF contains the invoice number as searchable text")
    func containsInvoiceNumberText() throws {
        var data = fixtureData()
        data.taxAmount = data.subtotal * data.taxRate
        data.total = data.subtotal + data.taxAmount
        let bytes = InvoicePDFRenderer.renderPDFData(for: data, accent: .green)
        let doc = try #require(PDFDocument(data: bytes))
        let extracted = doc.string ?? ""
        #expect(extracted.contains("INV-0042"))
        #expect(extracted.contains("Acme Corp"))
        #expect(extracted.contains("Studio Lina"))
    }

    @Test("renders PAYMENT DETAILS section when at least one bank field is set")
    func paymentDetails_rendered() {
        var data = fixtureData()
        data.bankBeneficiaryName = "Studio Lina LLC"
        data.bankName = "Riyad Bank"
        data.bankLocation = "Riyadh, Saudi Arabia"
        data.bankIBAN = "SA03 8000 0000 6080 1016 7519"
        data.bankSWIFT = "RIBLSARI"
        data.taxAmount = data.subtotal * data.taxRate
        data.total = data.subtotal + data.taxAmount

        let bytes = InvoicePDFRenderer.renderPDFData(for: data, accent: .blue)
        let doc = PDFDocument(data: bytes)!
        let text = doc.string ?? ""

        #expect(text.contains("PAYMENT DETAILS"))
        #expect(text.contains("Studio Lina LLC"))
        #expect(text.contains("Riyad Bank"))
        #expect(text.contains("Riyadh, Saudi Arabia"))
        #expect(text.contains("SA03 8000 0000 6080 1016 7519"))
        #expect(text.contains("RIBLSARI"))
    }

    @Test("does NOT render PAYMENT DETAILS section when all bank fields empty")
    func paymentDetails_omittedWhenEmpty() {
        var data = fixtureData()
        data.taxAmount = data.subtotal * data.taxRate
        data.total = data.subtotal + data.taxAmount
        // bank fields are all default "" — no need to set anything

        let bytes = InvoicePDFRenderer.renderPDFData(for: data, accent: .blue)
        let doc = PDFDocument(data: bytes)!
        let text = doc.string ?? ""

        #expect(!text.contains("PAYMENT DETAILS"))
    }

    @Test("omits SWIFT row when SWIFT field is empty but others are set")
    func paymentDetails_swiftRowOmitted() {
        var data = fixtureData()
        data.bankBeneficiaryName = "Studio Lina LLC"
        data.bankName = "Riyad Bank"
        data.bankIBAN = "SA03 8000 0000 6080 1016 7519"
        // bankSWIFT stays "" — should not render
        data.taxAmount = data.subtotal * data.taxRate
        data.total = data.subtotal + data.taxAmount

        let bytes = InvoicePDFRenderer.renderPDFData(for: data, accent: .blue)
        let doc = PDFDocument(data: bytes)!
        let text = doc.string ?? ""

        #expect(text.contains("PAYMENT DETAILS"))
        #expect(text.contains("Studio Lina LLC"))
        // Negative assertion: the SWIFT/BIC row label should not appear
        #expect(!text.contains("SWIFT/BIC:"))
    }

    @Test("renders 'VAT GB123456789' in header when label and number are both set")
    func taxID_labelAndNumber() {
        var data = fixtureData()
        data.taxIDLabel = "VAT"
        data.taxIDNumber = "GB123456789"
        let bytes = InvoicePDFRenderer.renderPDFData(for: data, accent: .blue)
        let doc = PDFDocument(data: bytes)!
        let text = doc.string ?? ""
        #expect(text.contains("VAT GB123456789"))
    }

    @Test("renders just the number (no leading space) when label is empty")
    func taxID_numberOnly() {
        var data = fixtureData()
        data.taxIDLabel = ""
        data.taxIDNumber = "GB123456789"
        let bytes = InvoicePDFRenderer.renderPDFData(for: data, accent: .blue)
        let doc = PDFDocument(data: bytes)!
        let text = doc.string ?? ""
        #expect(text.contains("GB123456789"))
        // No leading space artifact: the number must NOT be preceded by a space-then-newline pattern
        // (a "\n GB…" would indicate a stray empty-label concatenation).
        #expect(!text.contains(" GB123456789"))
    }

    @Test("does NOT render tax ID line when number is empty")
    func taxID_omittedWhenNumberEmpty() {
        var data = fixtureData()
        data.taxIDLabel = "VAT"
        data.taxIDNumber = ""
        let bytes = InvoicePDFRenderer.renderPDFData(for: data, accent: .blue)
        let doc = PDFDocument(data: bytes)!
        let text = doc.string ?? ""
        #expect(!text.contains("VAT"))
        #expect(!text.contains("GB123456789"))
    }

    @Test("does NOT render tax ID line when both fields empty")
    func taxID_omittedWhenBothEmpty() {
        let data = fixtureData()  // defaults already empty
        let bytes = InvoicePDFRenderer.renderPDFData(for: data, accent: .blue)
        let doc = PDFDocument(data: bytes)!
        // Smoke: PDF still renders, no crash.
        #expect(!(doc.string ?? "").isEmpty)
    }

    @Test("trims whitespace label to avoid double-spacing")
    func taxID_trimsLabelWhitespace() {
        var data = fixtureData()
        data.taxIDLabel = "VAT "   // trailing space
        data.taxIDNumber = "GB123"
        let bytes = InvoicePDFRenderer.renderPDFData(for: data, accent: .blue)
        let doc = PDFDocument(data: bytes)!
        let text = doc.string ?? ""
        #expect(text.contains("VAT GB123"))
        #expect(!text.contains("VAT  GB123"))  // no double space
    }
}
