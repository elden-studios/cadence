import Foundation
import Testing
@testable import BillableCore

@Suite("CSVExporter")
struct CSVExporterTests {
    @Test("Header row is the documented schema")
    func headerIsStable() {
        #expect(CSVExporter.header == "date,client,project,start,end,duration_hours,hourly_rate,amount,billable,invoice_number,notes")
    }

    @Test("Quotes wrap values containing commas, quotes, and newlines")
    func quotesEscaping() {
        let row = CSVExporter.Row(
            date: Date(timeIntervalSince1970: 1_700_000_000),
            clientName: "Acme, Inc.",
            projectName: "Quote\"in\"name",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_003_600),
            durationHours: 1,
            hourlyRate: 100,
            amount: 100,
            isBillable: true,
            invoiceNumber: nil,
            notes: "line1\nline2"
        )
        let csv = CSVExporter.csv(for: [row])
        // Don't split on \n — the notes field intentionally contains a newline
        // inside quotes. Just check the whole CSV blob.
        #expect(csv.contains("\"Acme, Inc.\""))
        #expect(csv.contains("\"Quote\"\"in\"\"name\""))
        #expect(csv.contains("\"line1\nline2\""))
    }

    @Test("Decimals use POSIX format (no commas, dot separator)")
    func decimalFormatting() {
        let row = CSVExporter.Row(
            date: Date(timeIntervalSince1970: 1_700_000_000),
            clientName: "Test",
            projectName: "Test",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: nil,
            durationHours: Decimal(string: "1.5")!,
            hourlyRate: 1234,
            amount: Decimal(string: "1851.5")!,
            isBillable: true,
            invoiceNumber: "INV-0001",
            notes: nil
        )
        let csv = CSVExporter.csv(for: [row])
        #expect(csv.contains("1.5,1234,1851.5"))
    }

    @Test("Empty row list returns just the header")
    func emptyRows() {
        let csv = CSVExporter.csv(for: [])
        #expect(csv == CSVExporter.header + "\n")
    }
}
