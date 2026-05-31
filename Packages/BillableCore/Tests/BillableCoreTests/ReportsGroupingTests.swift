import Foundation
import Testing
import SwiftData
@testable import BillableCore

/// Regression: per-client / per-project grouping must key on the full per-object
/// `persistentModelID`, not `.storeIdentifier` (which is shared by every object in
/// the store and collapsed all projects/clients into one bucket).
@Suite("ReportsAggregator grouping")
@MainActor
struct ReportsGroupingTests {

    private let day = Date(timeIntervalSince1970: 1_779_793_200) // 2026-05-26 11:00 UTC

    @Test("multiple projects under one client → distinct project rows + a single aggregated client row")
    func multiProjectGrouping() throws {
        let container = try BillableModelContainer.inMemory()
        let context = ModelContext(container)
        let client = Client(name: "Acme")
        let alpha = Project(name: "Alpha", hourlyRate: 60, isBillable: true, client: client)
        let beta  = Project(name: "Beta",  hourlyRate: 60, isBillable: true, client: client)
        context.insert(client); context.insert(alpha); context.insert(beta)
        try context.save()

        func addEntry(_ project: Project, start: Date, hours: Double) throws {
            let entry = TimeEntry(startedAt: start, endedAt: start.addingTimeInterval(hours * 3600),
                                  isManual: true, project: project, accumulatedSeconds: hours * 3600)
            context.insert(entry)
            try context.save()
        }
        try addEntry(alpha, start: day, hours: 2)                          // Alpha 2h
        try addEntry(beta,  start: day.addingTimeInterval(3600), hours: 3) // Beta  3h
        try addEntry(alpha, start: day.addingTimeInterval(7200), hours: 1) // Alpha +1h → 3h

        let entries = try context.fetch(FetchDescriptor<TimeEntry>())
        let snap = ReportsAggregator.snapshot(
            entries: entries, invoices: [], in: .allTime,
            activeCurrency: "USD", referenceDate: day.addingTimeInterval(200_000))

        // Two DISTINCT project rows (the bug collapsed them into one).
        #expect(snap.projectHours.count == 2)
        #expect(snap.projectHours.first { $0.projectName == "Alpha" }?.hours == 3) // 2 + 1
        #expect(snap.projectHours.first { $0.projectName == "Beta" }?.hours == 3)

        // One client row aggregating both projects (6h).
        #expect(snap.clientHours.count == 1)
        #expect(snap.clientHours.first?.clientName == "Acme")
        #expect(snap.clientHours.first?.hours == 6)
    }
}
