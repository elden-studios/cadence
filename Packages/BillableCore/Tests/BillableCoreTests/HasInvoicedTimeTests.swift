import Foundation
import Testing
import SwiftData
@testable import BillableCore

@Suite("hasInvoicedTime guards")
@MainActor
struct HasInvoicedTimeTests {

    // MARK: - Project

    @Test("projectFalseWhenAllEntriesUninvoiced: entry with nil invoiceID → false")
    func projectFalseWhenAllEntriesUninvoiced() throws {
        let container = try BillableModelContainer.inMemory()
        let context = ModelContext(container)

        let client = Client(name: "Acme")
        let project = Project(name: "Site", hourlyRate: 100, client: client)
        let entry = TimeEntry(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_003_600),
            isManual: true,
            project: project,
            accumulatedSeconds: 3600
        )
        // invoiceID intentionally left nil

        context.insert(client)
        context.insert(project)
        context.insert(entry)
        try context.save()

        #expect(project.hasInvoicedTime == false)
    }

    @Test("projectTrueWhenAnyEntryInvoiced: entry with non-nil invoiceID → true")
    func projectTrueWhenAnyEntryInvoiced() throws {
        let container = try BillableModelContainer.inMemory()
        let context = ModelContext(container)

        let client = Client(name: "Acme")
        let project = Project(name: "Site", hourlyRate: 100, client: client)
        let entry = TimeEntry(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_003_600),
            isManual: true,
            project: project,
            accumulatedSeconds: 3600
        )
        entry.invoiceID = UUID()

        context.insert(client)
        context.insert(project)
        context.insert(entry)
        try context.save()

        #expect(project.hasInvoicedTime == true)
    }

    // MARK: - Client

    @Test("clientTrueIffAnyProjectProtected: one invoiced project makes client true")
    func clientTrueIffAnyProjectProtected() throws {
        let container = try BillableModelContainer.inMemory()
        let context = ModelContext(container)

        let client = Client(name: "Acme")

        // Clean project — no invoiced entries
        let cleanProject = Project(name: "Clean Work", hourlyRate: 100, client: client)
        let cleanEntry = TimeEntry(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_003_600),
            isManual: true,
            project: cleanProject,
            accumulatedSeconds: 3600
        )
        // cleanEntry.invoiceID stays nil

        // Protected project — has an invoiced entry
        let protectedProject = Project(name: "Invoiced Work", hourlyRate: 150, client: client)
        let invoicedEntry = TimeEntry(
            startedAt: Date(timeIntervalSince1970: 1_700_007_200),
            endedAt: Date(timeIntervalSince1970: 1_700_010_800),
            isManual: true,
            project: protectedProject,
            accumulatedSeconds: 3600
        )
        invoicedEntry.invoiceID = UUID()

        context.insert(client)
        context.insert(cleanProject)
        context.insert(protectedProject)
        context.insert(cleanEntry)
        context.insert(invoicedEntry)
        try context.save()

        #expect(client.hasInvoicedTime == true)
    }
}
