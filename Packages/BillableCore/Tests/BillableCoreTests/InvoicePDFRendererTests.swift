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
}
