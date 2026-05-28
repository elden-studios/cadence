import Foundation
import Testing
import SwiftData
@testable import BillableCore

@Suite("ProjectStats.compute")
@MainActor
struct ProjectStatsTests {
    /// Fixture: an in-memory store with one billable project at $60/h.
    private func fixture(billable: Bool = true) throws -> (ModelContext, Project) {
        let container = try BillableModelContainer.inMemory()
        let context = ModelContext(container)
        let client = Client(name: "Acme")
        let project = Project(name: "Site", hourlyRate: 60, isBillable: billable, client: client)
        context.insert(client)
        context.insert(project)
        try context.save()
        return (context, project)
    }

    /// Adds a finished entry of `hours` on `day`, optionally invoiced.
    @discardableResult
    private func addEntry(_ context: ModelContext, _ project: Project,
                          start: Date, hours: Double, invoiced: Bool = false) throws -> TimeEntry {
        let end = start.addingTimeInterval(hours * 3600)
        let entry = TimeEntry(startedAt: start, endedAt: end, isManual: true,
                              project: project, accumulatedSeconds: hours * 3600)
        if invoiced { entry.invoiceID = UUID() }
        context.insert(entry)
        try context.save()
        return entry
    }

    private let day1 = Date(timeIntervalSince1970: 1_779_793_200) // 2026-05-21 ~12:00 UTC

    @Test("sums hours and current-rate value across this project's entries")
    func totals() throws {
        let (context, project) = try fixture()
        try addEntry(context, project, start: day1, hours: 2)               // 2h
        try addEntry(context, project, start: day1.addingTimeInterval(86_400), hours: 3) // next day, 3h
        let stats = ProjectStats.compute(for: project, asOf: day1.addingTimeInterval(200_000))
        #expect(stats.lifetimeSeconds == 5 * 3600)
        #expect(stats.lifetimeValue == Decimal(5 * 60))        // 5h * $60
        #expect(stats.sessionCount == 2)
    }

    @Test("uninvoicedAmount excludes entries already on an invoice")
    func uninvoiced() throws {
        let (context, project) = try fixture()
        try addEntry(context, project, start: day1, hours: 2, invoiced: true) // billed
        try addEntry(context, project, start: day1, hours: 1, invoiced: false)
        let stats = ProjectStats.compute(for: project, asOf: day1.addingTimeInterval(200_000))
        #expect(stats.lifetimeValue == Decimal(3 * 60))      // all 3h valued
        #expect(stats.uninvoicedAmount == Decimal(1 * 60))   // only the un-invoiced hour
    }

    @Test("activeDayCount counts distinct calendar days, not sessions")
    func dayCount() throws {
        let (context, project) = try fixture()
        let cal = Calendar(identifier: .gregorian)
        try addEntry(context, project, start: day1, hours: 1)                       // day A
        try addEntry(context, project, start: day1.addingTimeInterval(3 * 3600), hours: 1) // same day A
        try addEntry(context, project, start: day1.addingTimeInterval(2 * 86_400), hours: 1) // day B
        let stats = ProjectStats.compute(for: project, asOf: day1.addingTimeInterval(300_000), calendar: cal)
        #expect(stats.activeDayCount == 2)
        #expect(stats.sessionCount == 3)
    }

    @Test("firstTrackedDay is the earliest startedAt; nil with no entries")
    func firstDay() throws {
        let (context, project) = try fixture()
        #expect(ProjectStats.compute(for: project, asOf: day1).firstTrackedDay == nil)
        let later = day1.addingTimeInterval(5 * 86_400)
        try addEntry(context, project, start: later, hours: 1)
        try addEntry(context, project, start: day1, hours: 1) // earlier
        let stats = ProjectStats.compute(for: project, asOf: later.addingTimeInterval(10_000))
        #expect(stats.firstTrackedDay == day1)
    }

    @Test("non-billable project: hours retained, value and uninvoiced are zero")
    func nonBillable() throws {
        let (context, project) = try fixture(billable: false)
        try addEntry(context, project, start: day1, hours: 4)
        let stats = ProjectStats.compute(for: project, asOf: day1.addingTimeInterval(50_000))
        #expect(stats.lifetimeSeconds == 4 * 3600)
        #expect(stats.lifetimeValue == 0)
        #expect(stats.uninvoicedAmount == 0)
    }

    @Test("lifetimeValue follows the CURRENT rate, not a snapshot")
    func rateChange() throws {
        let (context, project) = try fixture()
        try addEntry(context, project, start: day1, hours: 2)
        let asOf = day1.addingTimeInterval(50_000)
        #expect(ProjectStats.compute(for: project, asOf: asOf).lifetimeValue == Decimal(2 * 60))
        project.hourlyRate = 90
        try context.save()
        #expect(ProjectStats.compute(for: project, asOf: asOf).lifetimeValue == Decimal(2 * 90))
    }
}
