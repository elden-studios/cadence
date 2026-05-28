import Foundation
import Testing
import SwiftData
@testable import BillableCore

@Suite("InvoiceDateRange presets")
struct InvoicePresetTests {
    @Test("thisWeek covers the calendar week containing the reference date")
    func thisWeek() throws {
        let cal = Calendar(identifier: .gregorian)
        // A known Thursday: 2026-05-21 12:00 UTC
        let ref = Date(timeIntervalSince1970: 1_779_793_200)
        let range = try #require(InvoicePeriodPreset.thisWeek.range(asOf: ref, calendar: cal))
        #expect(range.contains(ref))
        #expect(range.end > range.start)
        // The week interval is 7 days for Gregorian
        let weekSeconds = range.end.timeIntervalSince(range.start)
        #expect(weekSeconds == 7 * 24 * 3600)
    }

    @Test("lastMonth is the calendar month before the reference")
    func lastMonth() throws {
        let cal = Calendar(identifier: .gregorian)
        let ref = Date(timeIntervalSince1970: 1_779_793_200) // 2026-05-21
        let range = try #require(InvoicePeriodPreset.lastMonth.range(asOf: ref, calendar: cal))
        let comp = cal.dateComponents([.year, .month], from: range.start)
        #expect(comp.year == 2026)
        #expect(comp.month == 4)
    }

    @Test("custom returns nil — caller provides own range")
    func customNoRange() {
        #expect(InvoicePeriodPreset.custom.range() == nil)
    }
}

@Suite("InvoiceBuilder.eligibleEntries")
@MainActor
struct EligibleEntriesTests {
    private func fixture() throws -> (ModelContext, Client, Project, Project) {
        let container = try BillableModelContainer.inMemory()
        let context = ModelContext(container)
        let client = Client(name: "Acme")
        let billable = Project(name: "Site", hourlyRate: 100, isBillable: true, client: client)
        let nonBillable = Project(name: "Admin", hourlyRate: 0, isBillable: false, client: client)
        context.insert(client)
        context.insert(billable)
        context.insert(nonBillable)
        try context.save()
        return (context, client, billable, nonBillable)
    }

    @Test("Includes only billable, completed, uninvoiced entries inside the range")
    func includesOnlyEligible() throws {
        let (context, client, billable, nonBillable) = try fixture()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let inRange = start.addingTimeInterval(3600)
        let endRange = start.addingTimeInterval(7200)

        // In range, billable, completed → included
        let eligible = TimeEntry(startedAt: inRange, endedAt: inRange.addingTimeInterval(1800), project: billable)
        // In range, NON-billable → excluded
        let nb = TimeEntry(startedAt: inRange, endedAt: inRange.addingTimeInterval(900), project: nonBillable)
        // Still running → excluded
        let running = TimeEntry(startedAt: inRange, endedAt: nil, project: billable)
        // Already invoiced → excluded
        let invoiced = TimeEntry(startedAt: inRange, endedAt: inRange.addingTimeInterval(900), project: billable)
        invoiced.invoiceID = UUID()
        // Out of range → excluded
        let outBefore = TimeEntry(startedAt: start.addingTimeInterval(-3600), endedAt: start.addingTimeInterval(-1800), project: billable)
        let outAfter  = TimeEntry(startedAt: endRange.addingTimeInterval(60),  endedAt: endRange.addingTimeInterval(900), project: billable)
        [eligible, nb, running, invoiced, outBefore, outAfter].forEach(context.insert)
        try context.save()

        let range = InvoiceDateRange(start: start, end: endRange)
        let result = InvoiceBuilder.eligibleEntries(for: client, in: range, context: context)
        #expect(result.count == 1)
        #expect(result.first?.persistentModelID == eligible.persistentModelID)
    }
}

@Suite("InvoiceBuilder.buildLineItems")
@MainActor
struct BuildLineItemsTests {
    @Test("Per-entry creates one line per TimeEntry with project rate")
    func perEntry() throws {
        let container = try BillableModelContainer.inMemory()
        let context = ModelContext(container)
        let client = Client(name: "Acme")
        let p = Project(name: "Site", hourlyRate: 120, client: client)
        context.insert(client)
        context.insert(p)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let e1 = TimeEntry(startedAt: t0, endedAt: t0.addingTimeInterval(3600), project: p)
        let e2 = TimeEntry(startedAt: t0.addingTimeInterval(7200), endedAt: t0.addingTimeInterval(9000), project: p)
        context.insert(e1)
        context.insert(e2)
        try context.save()

        let items = InvoiceBuilder.buildLineItems(from: [e1, e2], grouping: .perEntry)
        #expect(items.count == 2)
        #expect(items[0].hours == 1)
        #expect(items[0].hourlyRate == 120)
        #expect(items[1].hours == Decimal(string: "0.5")!)
    }

    @Test("Per-project collapses entries into one line summing hours")
    func perProject() throws {
        let container = try BillableModelContainer.inMemory()
        let context = ModelContext(container)
        let client = Client(name: "Acme")
        let p = Project(name: "Site", hourlyRate: 120, client: client)
        context.insert(client)
        context.insert(p)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let e1 = TimeEntry(startedAt: t0, endedAt: t0.addingTimeInterval(3600), project: p)
        let e2 = TimeEntry(startedAt: t0.addingTimeInterval(7200), endedAt: t0.addingTimeInterval(9000), project: p)
        context.insert(e1)
        context.insert(e2)
        try context.save()

        let items = InvoiceBuilder.buildLineItems(from: [e1, e2], grouping: .perProject)
        #expect(items.count == 1)
        #expect(items[0].hours == Decimal(string: "1.5")!)
        #expect(items[0].amount == 180)
    }

    @Test("Zero-duration entries are dropped")
    func zeroDurationDropped() throws {
        let container = try BillableModelContainer.inMemory()
        let context = ModelContext(container)
        let client = Client(name: "Acme")
        let p = Project(name: "Site", hourlyRate: 120, client: client)
        context.insert(client)
        context.insert(p)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let e = TimeEntry(startedAt: t0, endedAt: t0, project: p)
        context.insert(e)
        try context.save()

        let items = InvoiceBuilder.buildLineItems(from: [e], grouping: .perEntry)
        #expect(items.isEmpty)
    }
}

@Suite("InvoiceBuilder.finalizeAndSend")
@MainActor
struct FinalizeAndSendTests {
    @Test("finalizeAndSend advances invoice number, sends, and stamps source entries with invoiceID")
    func finalize() throws {
        let container = try BillableModelContainer.inMemory()
        let context = ModelContext(container)
        let profile = BusinessProfile(invoiceNumberPrefix: "INV-", nextInvoiceNumber: 12)
        let client = Client(name: "Acme")
        let p = Project(name: "Site", hourlyRate: 100, client: client)
        context.insert(profile)
        context.insert(client)
        context.insert(p)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let e = TimeEntry(startedAt: t0, endedAt: t0.addingTimeInterval(3600), project: p)
        context.insert(e)
        try context.save()

        let items = InvoiceBuilder.buildLineItems(from: [e], grouping: .perEntry)
        let invoice = try InvoiceBuilder.createDraft(for: client, lineItems: items, profile: profile, context: context)

        #expect(invoice.status == .draft)
        #expect(invoice.number == "INV-0012")

        try InvoiceBuilder.finalizeAndSend(invoice, sourceEntries: [e], profile: profile, context: context)

        #expect(invoice.status == .sent)
        #expect(invoice.number == "INV-0012")
        #expect(profile.nextInvoiceNumber == 13)
        #expect(e.invoiceID == invoice.uuid)
    }
}

@Suite("InvoiceBuilder tax ID propagation")
@MainActor
struct InvoiceBuilderTaxIDTests {

    @Test("createDraft snapshots profile.taxIDLabel and taxIDNumber onto the Invoice")
    func taxIDSnapshot() throws {
        let container = try ModelContainer(
            for: BusinessProfile.self, Client.self, Project.self,
                 TimeEntry.self, Invoice.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let profile = BusinessProfile(
            name: "Studio",
            email: "hi@studio.example",
            taxIDLabel: "VAT",
            taxIDNumber: "GB123456789"
        )
        context.insert(profile)
        let client = Client(name: "Acme", color: .blue)
        context.insert(client)

        let lineItems = [InvoiceLineItem(description: "Work", hours: 1, hourlyRate: 100)]
        let invoice = try InvoiceBuilder.createDraft(
            for: client,
            lineItems: lineItems,
            profile: profile,
            context: context
        )

        #expect(invoice.issuerTaxIDLabelSnapshot == "VAT")
        #expect(invoice.issuerTaxIDNumberSnapshot == "GB123456789")
    }

    @Test("createDraft snapshots empty tax ID when profile has empty fields")
    func emptyTaxIDSnapshot() throws {
        let container = try ModelContainer(
            for: BusinessProfile.self, Client.self, Project.self,
                 TimeEntry.self, Invoice.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let profile = BusinessProfile(name: "Studio", email: "hi@studio.example")
        context.insert(profile)
        let client = Client(name: "Acme", color: .blue)
        context.insert(client)

        let invoice = try InvoiceBuilder.createDraft(
            for: client,
            lineItems: [InvoiceLineItem(description: "Work", hours: 1, hourlyRate: 100)],
            profile: profile,
            context: context
        )

        #expect(invoice.issuerTaxIDLabelSnapshot == "")
        #expect(invoice.issuerTaxIDNumberSnapshot == "")
    }

    @Test("createDraft continues to snapshot profile.logoData (A1 regression guard)")
    func logoSnapshotRegression() throws {
        let container = try ModelContainer(
            for: BusinessProfile.self, Client.self, Project.self,
                 TimeEntry.self, Invoice.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let logoBytes = Data([0xFF, 0xD8, 0xFF, 0xE0])  // arbitrary non-empty
        let profile = BusinessProfile(name: "Studio", email: "hi@studio.example", logoData: logoBytes)
        context.insert(profile)
        let client = Client(name: "Acme", color: .blue)
        context.insert(client)

        let invoice = try InvoiceBuilder.createDraft(
            for: client,
            lineItems: [InvoiceLineItem(description: "Work", hours: 1, hourlyRate: 100)],
            profile: profile,
            context: context
        )

        #expect(invoice.issuerLogoSnapshot == logoBytes)
    }
}

@Suite("InvoiceBuilder per-project")
@MainActor
struct PerProjectEligibleTests {
    private func fixture() throws -> (ModelContext, Client, Project, Project) {
        let container = try BillableModelContainer.inMemory()
        let context = ModelContext(container)
        let client = Client(name: "Acme")
        let a = Project(name: "Site", hourlyRate: 100, isBillable: true, client: client)
        let b = Project(name: "Brand", hourlyRate: 150, isBillable: true, client: client)
        context.insert(client); context.insert(a); context.insert(b)
        try context.save()
        return (context, client, a, b)
    }

    @Test("eligibleEntries(for: project) returns only that project's entries")
    func filtersByProject() throws {
        let (context, _, a, b) = try fixture()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let ea = TimeEntry(startedAt: t0, endedAt: t0.addingTimeInterval(3600), project: a)
        let eb = TimeEntry(startedAt: t0, endedAt: t0.addingTimeInterval(3600), project: b)
        [ea, eb].forEach(context.insert); try context.save()

        let range = InvoiceDateRange(start: t0.addingTimeInterval(-60), end: t0.addingTimeInterval(7200))
        let result = InvoiceBuilder.eligibleEntries(for: a, in: range, context: context)
        #expect(result.count == 1)
        #expect(result.first?.persistentModelID == ea.persistentModelID)
    }

    @Test("eligibleEntries(for: project) excludes non-billable / running / invoiced")
    func excludesIneligible() throws {
        let (context, _, a, _) = try fixture()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let ok = TimeEntry(startedAt: t0, endedAt: t0.addingTimeInterval(1800), project: a)
        let running = TimeEntry(startedAt: t0, endedAt: nil, project: a)
        let invoiced = TimeEntry(startedAt: t0, endedAt: t0.addingTimeInterval(900), project: a)
        invoiced.invoiceID = UUID()
        [ok, running, invoiced].forEach(context.insert); try context.save()

        let range = InvoiceDateRange(start: t0.addingTimeInterval(-60), end: t0.addingTimeInterval(7200))
        let result = InvoiceBuilder.eligibleEntries(for: a, in: range, context: context)
        #expect(result.count == 1)
        #expect(result.first?.persistentModelID == ok.persistentModelID)
    }
}
