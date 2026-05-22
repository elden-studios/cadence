import SwiftUI
import CoreGraphics
import PDFKit

/// Renders an `InvoiceTemplate` to a PDF Data blob.
///
/// Uses SwiftUI's `ImageRenderer` to capture the template at the page's native
/// 72dpi size, then writes a single-page PDF via Core Graphics. Single-page in
/// v1; multi-page splitting comes later if invoice line counts demand it.
public enum InvoicePDFRenderer {

    @MainActor
    public static func renderPDFData(
        for data: InvoiceTemplateData,
        accent: Color
    ) -> Data {
        let view = InvoiceTemplate(data: data, accent: accent)
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(
            width: InvoiceTemplate.pageWidth,
            height: InvoiceTemplate.pageHeight
        )
        // High-resolution rendering — the PDF is vector when possible but the
        // renderer falls back to high-DPI bitmaps for some layers.
        renderer.scale = 2.0

        let mediaBox = CGRect(
            x: 0, y: 0,
            width: InvoiceTemplate.pageWidth,
            height: InvoiceTemplate.pageHeight
        )

        let pdf = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdf),
              let context = CGContext(consumer: consumer, mediaBox: [mediaBox], nil) else {
            return Data()
        }
        renderer.render { size, render in
            var box = mediaBox
            context.beginPage(mediaBox: &box)
            // Center the rendered content within the page in case the proposed
            // size produced something smaller than the media box.
            let dx = (mediaBox.width - size.width) / 2
            let dy = (mediaBox.height - size.height) / 2
            context.translateBy(x: dx, y: dy)
            render(context)
            context.endPage()
        }
        context.closePDF()
        return pdf as Data
    }

    /// Convenience that wraps `renderPDFData` in a `PDFDocument`.
    @MainActor
    public static func renderDocument(
        for data: InvoiceTemplateData,
        accent: Color
    ) -> PDFDocument? {
        let bytes = renderPDFData(for: data, accent: accent)
        return PDFDocument(data: bytes)
    }
}
