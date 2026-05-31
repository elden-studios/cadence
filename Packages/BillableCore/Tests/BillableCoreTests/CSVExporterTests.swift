import Foundation
import SwiftData
import Testing
@testable import BillableCore

@Suite("CSVExporter")
struct CSVExporterTests {
    @Test("Header row is the documented schema")
    func headerIsStable() {
        #expect(CSVExporter.header == "date,client,project,start,end,worked_hours,hourly_rate,amount,billable,invoice_number,notes")
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

@Suite("ReportsAggregator.entriesInRange")
@MainActor
struct EntriesInRangeTests {
    @Test("Uses the same half-open predicate as the snapshot (upperBound excluded)")
    func halfOpen() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11-14
        let container = try BillableModelContainer.inMemory()
        let context = ModelContext(container)
        let p = Project(name: "Alpha", hourlyRate: 100, isBillable: true)
        context.insert(p)
        let bounds = ReportsAggregator.TimeRange.thisMonth.range(asOf: now, calendar: cal)
        let inside  = TimeEntry(startedAt: cal.date(byAdding: .day, value: -2, to: now)!,
                                endedAt: now, isManual: true, project: p, accumulatedSeconds: 3600)
        let before  = TimeEntry(startedAt: cal.date(byAdding: .day, value: -40, to: now)!,
                                endedAt: now, isManual: true, project: p, accumulatedSeconds: 3600)
        let atUpper = TimeEntry(startedAt: bounds.upperBound,
                                endedAt: bounds.upperBound, isManual: true, project: p, accumulatedSeconds: 3600)
        context.insert(inside); context.insert(before); context.insert(atUpper)
        try context.save()
        let all = try context.fetch(FetchDescriptor<TimeEntry>())

        let scoped = ReportsAggregator.entriesInRange(all, range: .thisMonth, asOf: now, calendar: cal)
        #expect(scoped.contains { $0 === inside })
        #expect(!scoped.contains { $0 === before })
        #expect(!scoped.contains { $0 === atUpper })   // half-open: upperBound EXCLUDED
    }
}

@Suite("CSVExporter.rows(from:)")
@MainActor
struct CSVExporterRowsTests {
    @Test("Client-less entries are kept with an empty client column")
    func clientlessRowsKept() throws {
        let container = try BillableModelContainer.inMemory()
        let context = ModelContext(container)
        let client = Client(name: "Acme")
        let withClient = Project(name: "Alpha", hourlyRate: 100, isBillable: true, client: client)
        let general    = Project(name: "General", hourlyRate: 100, isBillable: true)  // client-less
        context.insert(client); context.insert(withClient); context.insert(general)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let e1 = TimeEntry(startedAt: start, endedAt: start.addingTimeInterval(7200),
                           isManual: true, project: withClient, accumulatedSeconds: 7200)
        let e2 = TimeEntry(startedAt: start, endedAt: start.addingTimeInterval(3600),
                           isManual: true, project: general, accumulatedSeconds: 3600)
        context.insert(e1); context.insert(e2)
        try context.save()
        let entries = try context.fetch(FetchDescriptor<TimeEntry>())

        let rows = CSVExporter.rows(from: entries, invoiceLookup: [:])
        #expect(rows.count == 2)                                   // client-less row NOT dropped
        let generalRow = rows.first { $0.projectName == "General" }
        #expect(generalRow != nil)
        #expect(generalRow?.clientName == "")                      // empty client column
        #expect((generalRow?.durationHours ?? 0) > 0)             // non-zero worked_hours
    }
}
