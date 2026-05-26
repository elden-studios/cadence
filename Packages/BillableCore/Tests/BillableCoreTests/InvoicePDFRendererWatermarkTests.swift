import Testing
import Foundation
import PDFKit
import SwiftUI
@testable import BillableCore

@Suite("InvoicePDFRenderer watermark")
@MainActor
struct InvoicePDFRendererWatermarkTests {

    private func sampleData(watermark: String?) -> InvoiceTemplateData {
        InvoiceTemplateData(
            issuerName: "Elden Studios",
            issuerAddress: "Riyadh, KSA",
            issuerEmail: "test@example.com",
            issuerLogo: nil,
            clientName: "Acme Co",
            clientAddress: nil,
            clientEmail: nil,
            invoiceNumber: "INV-0001",
            issuedDateLabel: "26 May 2026",
            dueDateLabel: "9 Jun 2026",
            paymentTerms: "Net 14",
            lineItems: [
                InvoiceLineItem(
                    description: "Time on General · 1.0h × SAR 100.00",
                    hours: 1,
                    hourlyRate: 100
                )
            ],
            notes: nil,
            subtotal: 100,
            taxLabel: "VAT",
            taxRate: 0.15,
            taxAmount: 15,
            total: 115,
            currencyCode: "SAR",
            watermark: watermark
        )
    }

    @Test("renderer produces non-empty PDF with no watermark")
    func renderWithoutWatermark() {
        let pdfData = InvoicePDFRenderer.renderPDFData(for: sampleData(watermark: nil), accent: .blue)
        #expect(!pdfData.isEmpty)
        guard let document = PDFDocument(data: pdfData) else {
            Issue.record("Expected valid PDFDocument")
            return
        }
        let fullText = (0..<document.pageCount)
            .compactMap { document.page(at: $0)?.string }
            .joined(separator: "\n")
        #expect(!fullText.contains("Sent with Cadence"),
                "PDF without watermark must NOT contain watermark string")
    }

    @Test("renderer includes 'Sent with Cadence' watermark when set")
    func renderWithWatermark() {
        let pdfData = InvoicePDFRenderer.renderPDFData(
            for: sampleData(watermark: "Sent with Cadence"),
            accent: .blue
        )
        #expect(!pdfData.isEmpty)
        guard let document = PDFDocument(data: pdfData) else {
            Issue.record("Expected valid PDFDocument")
            return
        }
        let fullText = (0..<document.pageCount)
            .compactMap { document.page(at: $0)?.string }
            .joined(separator: "\n")
        #expect(fullText.contains("Sent with Cadence"),
                "PDF with watermark must contain 'Sent with Cadence' in extracted text")
    }
}
