import Foundation
import Testing
import SwiftData
@testable import BillableCore

/// End-to-end check that a single `snapshot(...)` call wires every block
/// together — money, AR, performance, trend, per-client/-project groupings,
/// currency exclusion, and `hasReportableData` — from one mixed dataset of
/// real (in-memory) `TimeEntry` rows plus `Invoice`s. The per-block suites in
/// `ReportsMoneyARTests` exercise each piece in isolation with empty entries;
/// this one asserts they integrate coherently with live billable time.
@Suite("ReportsAggregator integration")
@MainActor
struct ReportsSnapshotIntegrationTests {

    /// Build an invoice with one line item summing to `total` (pre-tax), tax 0.
    private func makeInvoice(total: Decimal, status: InvoiceStatus, issued: Date, due: Date,
                             paid: Date? = nil, currency: String = "USD") -> Invoice {
        let inv = Invoice(
            number: "INV-1", issuedAt: issued, dueAt: due, status: status,
            clientNameSnapshot: "C", issuerNameSnapshot: "Me", issuerAddressSnapshot: "",
            issuerEmailSnapshot: "", paymentTermsSnapshot: "", taxLabelSnapshot: "",
            taxRateSnapshot: 0, currencyCodeSnapshot: currency,
            lineItems: [InvoiceLineItem(description: "work", hours: 1, hourlyRate: total)]
        )
        inv.paidAt = paid
        return inv
    }

    /// In-memory store with one billable project under one client, at $100/h.
    private func fixture() throws -> (ModelContext, Project) {
        let container = try BillableModelContainer.inMemory()
        let context = ModelContext(container)
        let client = Client(name: "Acme")
        let alpha = Project(name: "Alpha", hourlyRate: 100, isBillable: true, client: client)
        context.insert(client)
        context.insert(alpha)
        try context.save()
        return (context, alpha)
    }

    @discardableResult
    private func addEntry(_ context: ModelContext, _ project: Project,
                          start: Date, hours: Double) throws -> TimeEntry {
        let end = start.addingTimeInterval(hours * 3600)
        let entry = TimeEntry(startedAt: start, endedAt: end, isManual: true,
                              project: project, accumulatedSeconds: hours * 3600)
        context.insert(entry)
        try context.save()
        return entry
    }

    @Test("One snapshot integrates money + AR + performance + trend + groupings from mixed data")
    func integratedSnapshot() throws {
        let cal = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func daysAgo(_ n: Int) -> Date { cal.date(byAdding: .day, value: -n, to: now)! }
        func daysAhead(_ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: now)! }

        let (context, alpha) = try fixture()
        // 6h + 4h billable this month on Alpha → 10h total, all billable.
        try addEntry(context, alpha, start: daysAgo(2), hours: 6)
        try addEntry(context, alpha, start: daysAgo(1), hours: 4)
        let entries = try context.fetch(FetchDescriptor<TimeEntry>())

        // NOTE: the fixed `now` is 2023-11-14, so `daysAgo(3)`/`daysAgo(10)` stay inside
        // November (this month) while `daysAgo(40)` lands in October (out of month).
        let invoices = [
            // Issued this month → Invoiced; sent & not yet due → Outstanding "current".
            makeInvoice(total: 800, status: .sent, issued: daysAgo(3), due: daysAhead(10)),
            // Issued + paid this month → Invoiced + Collected; issued→paid = 8 days.
            makeInvoice(total: 1200, status: .paid, issued: daysAgo(10), due: daysAgo(2), paid: daysAgo(2)),
            // Issued last month, sent, overdue 10d → 1–30 aging bucket, overdue.
            // Out of this-month range → NOT in Invoiced, but AR is as-of-now so it counts.
            makeInvoice(total: 500, status: .sent, issued: daysAgo(40), due: daysAgo(10)),
            // Draft → excluded everywhere.
            makeInvoice(total: 9_999, status: .draft, issued: daysAgo(2), due: daysAhead(5)),
            // Wrong currency → excluded + counted.
            makeInvoice(total: 333, status: .sent, issued: daysAgo(2), due: daysAhead(5), currency: "EUR"),
        ]

        let snap = ReportsAggregator.snapshot(
            entries: entries, invoices: invoices, in: .thisMonth,
            activeCurrency: "USD", referenceDate: now, calendar: cal)

        // --- Money: tracked = 10h × $100; invoiced = 800 + 1200 (issued in month, non-draft, USD);
        //     collected = 1200 (paid in month). The 500 was issued last month → not in Invoiced. ---
        #expect(snap.money.tracked == 1000)
        #expect(snap.money.invoiced == 2000)
        #expect(snap.money.collected == 1200)

        // --- Currency exclusion (the EUR invoice). ---
        #expect(snap.excludedCurrencyCount == 1)

        // --- AR (as-of-now, not range-scoped): current = 800; overdue = 500 (10d → 1–30). ---
        #expect(snap.ar.aging.current == 800)
        #expect(snap.ar.aging.d1to30 == 500)
        #expect(snap.ar.outstanding == 1300)
        #expect(snap.ar.overdue == 500)
        #expect(snap.ar.overdueCount == 1)
        #expect(snap.ar.avgDaysToPay == 8)    // the single paid invoice: paidAt − issuedAt = 8d

        // --- Performance: effective rate = 1000 / 10h = 100/h; utilization = 10/10 = 1.0. ---
        #expect(snap.performance.effectiveRate == 100)
        #expect(snap.performance.utilization == 1.0)

        // --- Hours roll-up. ---
        #expect(snap.totalHours == 10)
        #expect(snap.billableHours == 10)
        #expect(snap.nonBillableHours == 0)

        // --- Groupings: one project (10h) under one client (10h), both billable-rated. ---
        #expect(snap.projectHours.count == 1)
        #expect(snap.projectHours.first?.projectName == "Alpha")
        #expect(snap.projectHours.first?.hours == 10)
        #expect(snap.projectHours.first?.amount == 1000)
        #expect(snap.clientHours.count == 1)
        #expect(snap.clientHours.first?.clientName == "Acme")
        #expect(snap.clientHours.first?.hours == 10)

        // --- Trend (Month → weekly buckets); the in-month USD invoiced totals (800 + 1200)
        //     appear across buckets; the draft + EUR are excluded. Sum over buckets == Invoiced. ---
        #expect(snap.trendBucket == .week)
        let trendSum = snap.revenueTrend.reduce(Decimal(0)) { $0 + $1.amount }
        #expect(trendSum == 2000)

        // --- Reportable. ---
        #expect(snap.currencyCode == "USD")
        #expect(snap.hasReportableData == true)
    }
}
