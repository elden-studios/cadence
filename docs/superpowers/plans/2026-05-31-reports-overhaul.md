# Reports Overhaul Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the Pro Reports screen into an AR-led financial dashboard backed by real money from invoices, with a sell-in-place pre-subscribe page.

**Architecture:** Pure roll-up logic lives in `BillableCore.ReportsAggregator` (TDD-tested, no SwiftData). `ReportsView` renders Layout A from a memoized snapshot. `PaywallView` gains a Reports-contextual header over a shared "Everything in Pro" core and renders in place on the locked Reports tab. No data migration — every metric derives from existing `TimeEntry`/`Invoice` fields.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI + Swift Charts, SwiftData, StoreKit 2, XCTest/Swift Testing in `BillableCore`.

**Spec:** `docs/superpowers/specs/2026-05-31-reports-overhaul-design.md`

**House gotchas:**
- New **App-target** source files need explicit `Billable.xcodeproj/project.pbxproj` registration (PBXBuildFile + PBXFileReference + group child + Sources build-phase entry, fresh 24-hex IDs). **BillableCore** sources auto-include — no pbxproj edit.
- Enums stored as raw `String` + computed accessor (`Invoice.statusRaw`/`status`).
- Run BillableCore tests with `cd Packages/BillableCore && swift test`. Build the app with `xcodebuild -scheme Billable -destination 'platform=iOS Simulator,name=iPhone 16'`.
- Money values are `Decimal`. Hours are `Decimal` (hours, not seconds). Don't introduce `Double` money.

---

## Shared types (defined in Task 1, referenced everywhere)

These are the canonical signatures. Later tasks must match them exactly.

```swift
// In ReportsAggregator
public struct MoneySummary: Sendable, Equatable {
    public let tracked: Decimal     // billable time-value in range (hours × current rate)
    public let invoiced: Decimal    // Σ total of non-draft invoices issued in range
    public let collected: Decimal   // Σ total of paid invoices paid in range
}

public struct Aging: Sendable, Equatable {
    public let current: Decimal     // sent, not yet due
    public let d1to30: Decimal
    public let d31to60: Decimal
    public let d60plus: Decimal
    public var overdue: Decimal { d1to30 + d31to60 + d60plus }
    public var outstanding: Decimal { current + overdue }
}

public struct ARSummary: Sendable, Equatable {
    public let aging: Aging
    public let overdueCount: Int
    public let avgDaysToPay: Double?   // mean(paidAt − issuedAt) in days, over paid-in-range; nil if none
    public var outstanding: Decimal { aging.outstanding }
    public var overdue: Decimal { aging.overdue }
}

public struct Performance: Sendable, Equatable {
    public let effectiveRate: Decimal?  // tracked ÷ totalHours ($/h); nil when totalHours == 0
    public let utilization: Double?     // billableHours ÷ totalHours (0...1); nil when totalHours == 0
}

public struct TrendPoint: Identifiable, Sendable, Equatable {
    public let id: Date
    public let bucketStart: Date
    public let amount: Decimal       // invoiced total in this bucket
}

public enum TrendBucket: Sendable { case day, week, month }  // x-axis granularity for the chart
```

The reshaped `Snapshot` (Task 5 assembles it):

```swift
public struct Snapshot: Sendable {
    public let money: MoneySummary
    public let ar: ARSummary
    public let performance: Performance
    public let totalHours: Decimal
    public let billableHours: Decimal
    public let nonBillableHours: Decimal
    public let clientHours: [ClientHours]    // unchanged type
    public let projectHours: [ProjectHours]  // unchanged type
    public let revenueTrend: [TrendPoint]
    public let trendBucket: TrendBucket
    public let excludedCurrencyCount: Int     // invoices skipped for non-matching currency
    public let currencyCode: String
    public var hasReportableData: Bool { totalHours > 0 || !revenueTrend.isEmpty || ar.outstanding > 0 || money.invoiced > 0 }
}
```

---

## Task 1: MoneySummary (Tracked / Invoiced / Collected) + currency filtering

**Files:**
- Modify: `Packages/BillableCore/Sources/BillableCore/Reporting/ReportsAggregator.swift`
- Test: `Packages/BillableCore/Tests/BillableCoreTests/ReportsMoneyARTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `ReportsMoneyARTests.swift`. Use the existing test helpers' style (look at `ReportsAggregatorTests.swift` if present for how `TimeEntry`/`Project`/`Invoice`/`Client` are constructed in-memory; mirror it). Invoices are built with the full `Invoice.init` — write a local `makeInvoice` helper (mirror the one used in onboarding's invoice tests).

```swift
import Testing
import Foundation
@testable import BillableCore

@Suite("ReportsAggregator money")
struct ReportsMoneySummaryTests {

    /// Build an invoice with one line item summing to `total` (pre-tax), tax 0.
    private func makeInvoice(total: Decimal, status: InvoiceStatus, issued: Date, due: Date,
                             paid: Date? = nil, currency: String = "USD") -> Invoice {
        let inv = Invoice(
            number: "INV-1", issuedAt: issued, dueAt: due, status: status,
            clientNameSnapshot: "C", issuerNameSnapshot: "Me", issuerAddressSnapshot: "",
            issuerEmailSnapshot: "", paymentTermsSnapshot: "", taxLabelSnapshot: "",
            taxRateSnapshot: 0, currencyCodeSnapshot: currency,
            lineItems: [InvoiceLineItem(detail: "work", quantity: 1, unitPrice: total)]
        )
        inv.paidAt = paid
        return inv
    }

    @Test("Invoiced counts non-draft issued in range; Collected counts paid-in-range; currency filtered")
    func moneySummary() {
        let cal = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_700_000_000) // fixed
        let inMonth = cal.date(byAdding: .day, value: -3, to: now)!
        let lastMonth = cal.date(byAdding: .day, value: -40, to: now)!

        let invoices = [
            makeInvoice(total: 100, status: .sent, issued: inMonth, due: now),                 // invoiced, not collected
            makeInvoice(total: 200, status: .paid, issued: inMonth, due: now, paid: inMonth),    // invoiced + collected
            makeInvoice(total: 50,  status: .draft, issued: inMonth, due: now),                  // excluded (draft)
            makeInvoice(total: 999, status: .paid, issued: lastMonth, due: lastMonth, paid: lastMonth), // out of range
            makeInvoice(total: 77,  status: .sent, issued: inMonth, due: now, currency: "EUR"),  // excluded (currency)
        ]

        let snap = ReportsAggregator.snapshot(
            entries: [], invoices: invoices, in: .thisMonth,
            activeCurrency: "USD", referenceDate: now, calendar: cal)

        #expect(snap.money.invoiced == 300)        // 100 + 200
        #expect(snap.money.collected == 200)       // the paid-in-range one
        #expect(snap.money.tracked == 0)           // no entries
        #expect(snap.excludedCurrencyCount == 1)   // the EUR invoice
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/BillableCore && swift test --filter ReportsMoneySummaryTests`
Expected: FAIL — `snapshot(entries:invoices:in:activeCurrency:…)` signature doesn't exist yet (current signature takes `invoiceLookup`/`currencyCode`).

- [ ] **Step 3: Reshape the aggregator signature + add the money block**

In `ReportsAggregator.swift`, add `MoneySummary` (from Shared types) above `Snapshot`, and reshape `Snapshot` to the new struct. Replace the `snapshot(...)` signature and compute the money block. Lift the existing client/project grouping into a `groupings(_:asOf:)` helper. Add `arSummary`, `performanceSummary`, and `revenueTrend` as zero-returning stubs so the file compiles now — Tasks 2–4 give them real bodies + tests, and Task 5 asserts the integrated result. (Note: the **App** target won't compile until Task 6 updates `ReportsView` to the new `Snapshot` fields — that's expected; this BillableCore phase is verified by `swift test` alone.) Use this body:

```swift
public static func snapshot(
    entries: [TimeEntry],
    invoices: [Invoice],
    in range: TimeRange,
    activeCurrency: String,
    referenceDate: Date = .now,
    calendar: Calendar = .current
) -> Snapshot {
    let bounds = range.range(asOf: referenceDate, calendar: calendar)
    func inRange(_ d: Date) -> Bool { d >= bounds.lowerBound && d < bounds.upperBound }

    // ---- currency-filtered invoice set ----
    let curInvoices = invoices.filter { $0.currencyCodeSnapshot == activeCurrency }
    let excludedCurrencyCount = invoices.count - curInvoices.count

    // ---- entries in range (existing behaviour) ----
    let inRangeEntries = entries.filter { inRange($0.startedAt) }
    var totalSeconds: TimeInterval = 0, billableSeconds: TimeInterval = 0, nonBillableSeconds: TimeInterval = 0
    var tracked = Decimal(0)
    for entry in inRangeEntries {
        let s = entry.duration(asOf: referenceDate)
        totalSeconds += s
        if entry.project?.isBillable == true { billableSeconds += s; tracked += entry.amount(asOf: referenceDate) }
        else { nonBillableSeconds += s }
    }

    // ---- MoneySummary ----
    let invoiced = curInvoices
        .filter { $0.status != .draft && inRange($0.issuedAt) }
        .reduce(Decimal(0)) { $0 + $1.total }
    let collected = curInvoices
        .filter { $0.status == .paid && ($0.paidAt.map(inRange) ?? false) }
        .reduce(Decimal(0)) { $0 + $1.total }
    let money = MoneySummary(tracked: tracked, invoiced: invoiced, collected: collected)

    // ---- AR (Task 2), Performance (Task 3), Trend (Task 4) ----
    let ar = arSummary(curInvoices, range: range, bounds: bounds, asOf: referenceDate, calendar: calendar)
    let performance = performanceSummary(tracked: tracked, totalHours: Decimal(totalSeconds/3600), billableHours: Decimal(billableSeconds/3600))
    let trend = revenueTrend(curInvoices, range: range, bounds: bounds, asOf: referenceDate, calendar: calendar)

    // ---- per-client / per-project (existing, keep) ----
    let (clientHours, projectHours) = groupings(inRangeEntries, asOf: referenceDate)

    return Snapshot(
        money: money, ar: ar, performance: performance,
        totalHours: Decimal(totalSeconds/3600),
        billableHours: Decimal(billableSeconds/3600),
        nonBillableHours: Decimal(nonBillableSeconds/3600),
        clientHours: clientHours, projectHours: projectHours,
        revenueTrend: trend.points, trendBucket: trend.bucket,
        excludedCurrencyCount: excludedCurrencyCount, currencyCode: activeCurrency)
}
```

Add private helpers `arSummary`, `performanceSummary`, `revenueTrend`, `groupings` as stubs that compile now and get real bodies/tests in Tasks 2–4. For `groupings`, lift the existing client/project grouping code from the current `snapshot` into a `private static func groupings(_:asOf:) -> ([ClientHours],[ProjectHours])`. For the three stubs, return empty/zero values **only long enough to compile**; their real implementations + tests land in Tasks 2–4, and Task 5 asserts the integrated result.

Update the `Snapshot` struct to the reshaped version (Shared types). Remove the old fields (`totalEarnings`, `uninvoicedAmount`, `earningsTrend`, `WeeklyPoint`) — Task 6 updates `ReportsView` to the new fields, and the old report tests get migrated in Task 5.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Packages/BillableCore && swift test --filter ReportsMoneySummaryTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Reporting/ReportsAggregator.swift Packages/BillableCore/Tests/BillableCoreTests/ReportsMoneyARTests.swift
git commit -m "feat(reports): MoneySummary (tracked/invoiced/collected) + currency filter"
```

---

## Task 2: ARSummary (outstanding / overdue / aging / days-to-pay)

**Files:**
- Modify: `Packages/BillableCore/Sources/BillableCore/Reporting/ReportsAggregator.swift`
- Test: `Packages/BillableCore/Tests/BillableCoreTests/ReportsMoneyARTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `ReportsMoneyARTests.swift` (reuse the `makeInvoice` helper — extract it to a fileprivate free function so both suites share it):

```swift
@Suite("ReportsAggregator AR")
struct ReportsARSummaryTests {
    @Test("Aging buckets by days past due; overdue excludes paid/draft; avg days-to-pay")
    func arSummary() {
        let cal = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func daysAgo(_ n: Int) -> Date { cal.date(byAdding: .day, value: -n, to: now)! }
        func daysAhead(_ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: now)! }

        let invoices = [
            makeInvoice(total: 100, status: .sent, issued: daysAgo(10), due: daysAhead(5)),   // current (not due)
            makeInvoice(total: 200, status: .sent, issued: daysAgo(40), due: daysAgo(10)),    // overdue 10d → 1–30
            makeInvoice(total: 300, status: .sent, issued: daysAgo(80), due: daysAgo(45)),    // overdue 45d → 31–60
            makeInvoice(total: 400, status: .sent, issued: daysAgo(120), due: daysAgo(90)),   // overdue 90d → 60+
            makeInvoice(total: 500, status: .paid, issued: daysAgo(30), due: daysAgo(15), paid: daysAgo(5)), // paid (not AR); 25d to pay
            makeInvoice(total: 999, status: .draft, issued: daysAgo(3), due: daysAhead(20)),  // draft (ignored)
        ]
        let snap = ReportsAggregator.snapshot(entries: [], invoices: invoices, in: .allTime,
                                              activeCurrency: "USD", referenceDate: now, calendar: cal)
        #expect(snap.ar.aging.current == 100)
        #expect(snap.ar.aging.d1to30 == 200)
        #expect(snap.ar.aging.d31to60 == 300)
        #expect(snap.ar.aging.d60plus == 400)
        #expect(snap.ar.outstanding == 1000)         // 100+200+300+400
        #expect(snap.ar.overdue == 900)              // 200+300+400
        #expect(snap.ar.overdueCount == 3)
        #expect(snap.ar.avgDaysToPay == 25)          // only the one paid invoice
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/BillableCore && swift test --filter ReportsARSummaryTests`
Expected: FAIL — `arSummary` stub returns zeros.

- [ ] **Step 3: Implement `arSummary`**

Replace the `arSummary` stub:

```swift
private static func arSummary(_ invoices: [Invoice], range: TimeRange,
                              bounds: ClosedRange<Date>, asOf now: Date,
                              calendar: Calendar) -> ARSummary {
    var current = Decimal(0), d1 = Decimal(0), d2 = Decimal(0), d3 = Decimal(0)
    var overdueCount = 0
    for inv in invoices where inv.status == .sent {
        if inv.dueAt >= now { current += inv.total; continue }
        overdueCount += 1
        let days = calendar.dateComponents([.day], from: inv.dueAt, to: now).day ?? 0
        switch days {
        case ...30: d1 += inv.total
        case 31...60: d2 += inv.total
        default: d3 += inv.total
        }
    }
    let aging = Aging(current: current, d1to30: d1, d31to60: d2, d60plus: d3)

    let paid = invoices.filter { $0.status == .paid && ($0.paidAt.map { $0 >= bounds.lowerBound && $0 < bounds.upperBound } ?? false) }
    let avg: Double? = paid.isEmpty ? nil : Double(
        paid.compactMap { inv in inv.paidAt.map { calendar.dateComponents([.day], from: inv.issuedAt, to: $0).day ?? 0 } }.reduce(0, +)
    ) / Double(paid.count)

    return ARSummary(aging: aging, overdueCount: overdueCount, avgDaysToPay: avg)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Packages/BillableCore && swift test --filter ReportsARSummaryTests`
Expected: PASS. Also run `swift test --filter ReportsMoneySummaryTests` to confirm no regression.

- [ ] **Step 5: Commit**

```bash
git add Packages/BillableCore
git commit -m "feat(reports): ARSummary — aging buckets, overdue, days-to-pay"
```

---

## Task 3: Performance (effective rate / utilization)

**Files:**
- Modify: `Packages/BillableCore/Sources/BillableCore/Reporting/ReportsAggregator.swift`
- Test: `Packages/BillableCore/Tests/BillableCoreTests/ReportsMoneyARTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
@Suite("ReportsAggregator performance")
struct ReportsPerformanceTests {
    @Test("effective rate = tracked/totalHours; utilization = billable/total; nil-guard at zero hours")
    func performance() {
        let perf = ReportsAggregator.performanceSummary(tracked: 800, totalHours: 10, billableHours: 8)
        #expect(perf.effectiveRate == 80)            // 800 / 10
        #expect(perf.utilization == 0.8)             // 8 / 10
        let zero = ReportsAggregator.performanceSummary(tracked: 0, totalHours: 0, billableHours: 0)
        #expect(zero.effectiveRate == nil)
        #expect(zero.utilization == nil)
    }
}
```

(Make `performanceSummary` `internal` — not `private` — so the test reaches it. It's a pure helper; that's fine.)

- [ ] **Step 2: Run to verify it fails**

Run: `cd Packages/BillableCore && swift test --filter ReportsPerformanceTests`
Expected: FAIL — stub returns nils.

- [ ] **Step 3: Implement**

```swift
static func performanceSummary(tracked: Decimal, totalHours: Decimal, billableHours: Decimal) -> Performance {
    guard totalHours > 0 else { return Performance(effectiveRate: nil, utilization: nil) }
    let rate = tracked / totalHours
    let util = (billableHours as NSDecimalNumber).doubleValue / (totalHours as NSDecimalNumber).doubleValue
    return Performance(effectiveRate: rate, utilization: util)
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd Packages/BillableCore && swift test --filter ReportsPerformanceTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/BillableCore
git commit -m "feat(reports): Performance — effective rate + utilization"
```

---

## Task 4: Range-aware revenue trend (Invoiced per bucket)

**Files:**
- Modify: `Packages/BillableCore/Sources/BillableCore/Reporting/ReportsAggregator.swift`
- Test: `Packages/BillableCore/Tests/BillableCoreTests/ReportsMoneyARTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
@Suite("ReportsAggregator trend")
struct ReportsTrendTests {
    @Test("Year range buckets invoiced totals by month")
    func trendByMonth() {
        let cal = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func monthsAgo(_ n: Int) -> Date { cal.date(byAdding: .month, value: -n, to: now)! }
        let invoices = [
            makeInvoice(total: 100, status: .sent, issued: now, due: now),
            makeInvoice(total: 50,  status: .paid, issued: now, due: now, paid: now),
            makeInvoice(total: 200, status: .sent, issued: monthsAgo(2), due: monthsAgo(2)),
            makeInvoice(total: 999, status: .draft, issued: now, due: now), // excluded
        ]
        let snap = ReportsAggregator.snapshot(entries: [], invoices: invoices, in: .thisYear,
                                              activeCurrency: "USD", referenceDate: now, calendar: cal)
        #expect(snap.trendBucket == .month)
        // current month bucket = 150 (100 + 50), the draft excluded
        let thisMonthBucket = snap.revenueTrend.first { cal.isDate($0.bucketStart, equalTo: now, toGranularity: .month) }
        #expect(thisMonthBucket?.amount == 150)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd Packages/BillableCore && swift test --filter ReportsTrendTests`
Expected: FAIL — trend stub empty.

- [ ] **Step 3: Implement `revenueTrend`**

```swift
private static func revenueTrend(_ invoices: [Invoice], range: TimeRange,
                                 bounds: ClosedRange<Date>, asOf now: Date,
                                 calendar: Calendar) -> (points: [TrendPoint], bucket: TrendBucket) {
    let bucket: TrendBucket = {
        switch range { case .thisWeek: return .day; case .thisMonth: return .week
                       case .thisYear, .allTime: return .month }
    }()
    let comp: Calendar.Component = (bucket == .day) ? .day : (bucket == .week ? .weekOfYear : .month)

    let billed = invoices.filter { $0.status != .draft }
    // For allTime, span earliest issued → now; else span the range bounds.
    let lower = (range == .allTime) ? (billed.map(\.issuedAt).min() ?? now) : bounds.lowerBound
    let upper = (range == .allTime) ? now : min(bounds.upperBound, now)
    guard lower <= upper,
          let firstStart = calendar.dateInterval(of: comp, for: lower)?.start else { return ([], bucket) }

    var points: [TrendPoint] = []
    var cursor = firstStart
    var guardCount = 0
    while cursor <= upper && guardCount < 400 {
        guard let next = calendar.date(byAdding: comp, value: 1, to: cursor) else { break }
        let amount = billed
            .filter { $0.issuedAt >= cursor && $0.issuedAt < next }
            .reduce(Decimal(0)) { $0 + $1.total }
        points.append(TrendPoint(id: cursor, bucketStart: cursor, amount: amount))
        cursor = next; guardCount += 1
    }
    return (points, bucket)
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd Packages/BillableCore && swift test --filter ReportsTrendTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/BillableCore
git commit -m "feat(reports): range-aware invoiced revenue trend"
```

---

## Task 5: Integrate + migrate existing report tests + full suite green

**Files:**
- Modify: `Packages/BillableCore/Sources/BillableCore/Reporting/ReportsAggregator.swift` (finalize `groupings`)
- Modify: existing `Packages/BillableCore/Tests/BillableCoreTests/ReportsAggregator*Tests.swift` (migrate to new Snapshot shape)

- [ ] **Step 1: Find existing report tests that reference removed fields**

Run: `cd Packages/BillableCore && grep -rn "totalEarnings\|uninvoicedAmount\|earningsTrend\|\.snapshot(" Tests/`
Expected: a list of call-sites using the old signature/fields.

- [ ] **Step 2: Migrate each call-site**

For each: change `snapshot(entries:in:currencyCode:)` → `snapshot(entries:invoices:in:activeCurrency:)` (pass `invoices: []` where the test only exercised time), and replace `snapshot.totalEarnings` → `snapshot.money.tracked`, `snapshot.uninvoicedAmount` → drop or assert via AR, `snapshot.earningsTrend` → `snapshot.revenueTrend`. Confirm `groupings(_:asOf:)` returns the same `clientHours`/`projectHours` ordering as before (sorted by hours desc) so those assertions still hold.

- [ ] **Step 3: Run the FULL BillableCore suite**

Run: `cd Packages/BillableCore && swift test 2>&1 | tail -15`
Expected: all suites pass (the prior count + the new money/AR/perf/trend tests).

- [ ] **Step 4: Commit**

```bash
git add Packages/BillableCore
git commit -m "refactor(reports): migrate report tests to reshaped Snapshot; full suite green"
```

---

## Task 6: ReportsView — Layout A, memoized snapshot, graceful AR, CSV fix

**Files:**
- Modify: `App/Sources/Features/Reports/ReportsView.swift`

- [ ] **Step 1: Memoize the snapshot**

Replace the computed `snapshot` property with cached `@State` recomputed on input change (NOT every body eval):

```swift
@State private var snapshot: ReportsAggregator.Snapshot?

private func recompute() {
    snapshot = ReportsAggregator.snapshot(
        entries: allEntries, invoices: allInvoices, in: range,
        activeCurrency: profiles.first?.currencyCode ?? "USD")
}
```

Attach to the `ScrollView`: `.onAppear { recompute() }`, `.onChange(of: range) { recompute() }`, `.onChange(of: allEntries) { recompute() }`, `.onChange(of: allInvoices) { recompute() }`. Guard the body on `if let snapshot`. (SwiftData republishes `allEntries`/`allInvoices` only on real data change, so this won't churn per render.)

- [ ] **Step 2: Re-lay the body to Layout A**

Replace the section stack with the Layout-A order. Build these subviews in this file (mirror the existing `tile(...)` / `sectionHeader(...)` helpers and the existing Charts code for trend/client/mix):

1. `rangePicker` (unchanged).
2. **`moneyLenses`** — three `tile`s in an `HStack`: "TRACKED" (`snapshot.money.tracked`, `.secondary`), "INVOICED" (`.blue`), "COLLECTED" (`.green`). **No arrows between them.**
3. **`arCard`** — a card with an "as of today" caption header. Lead figure = `snapshot.ar.outstanding`; an overdue pill (red) showing `snapshot.ar.overdue` + `overdueCount` when `> 0`; `avgDaysToPay` line ("~N days to pay") when non-nil; an `agingBar` (stacked segments Current/1–30/31–60/60+) shown only when `overdue > 0`. Apply the **graceful states** from spec §2:
   - `!hasReportableData`-ish for AR (`ar.outstanding == 0 && money.invoiced == 0`) → single line "No invoices yet — track time, then invoice to see what you're owed."
   - `outstanding == 0 && money.collected > 0` → "All paid up ✓".
   - `outstanding > 0 && overdue == 0` → outstanding + "on track", single Current bar.
4. **`performanceTiles`** — two tiles: "EFFECTIVE RATE" (`effectiveRate` formatted `…/h`, or "—" when nil), "UTILIZATION" (`utilization` as `%`, or "—").
5. **`revenueTrendChart`** — Swift Charts `BarMark` over `snapshot.revenueTrend` (`x: bucketStart` with `.chartXAxis` unit derived from `snapshot.trendBucket`; `y: amount`). Title "Revenue".
6. `clientBars` (existing, reads `snapshot.clientHours`).
7. `projectBreakdown` (existing, reads `snapshot.projectHours`).

Add a footnote under the content when `snapshot.excludedCurrencyCount > 0`: "N invoices in other currencies aren't included." Keep `emptyState` for `snapshot.totalHours == 0 && snapshot.revenueTrend.isEmpty`.

- [ ] **Step 3: Fix the CSV silent failure**

In `exportCSV()`, replace the empty `catch { }` (`ReportsView.swift:266-268`) with a user-visible error. Add `@State private var exportError: String?` and an `.alert("Couldn't export", isPresented:)` bound to it; set it in the catch.

- [ ] **Step 4: Build**

Run: `xcodebuild -scheme Billable -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED. (No pbxproj change — `ReportsView.swift` already in the project.)

- [ ] **Step 5: Commit**

```bash
git add App/Sources/Features/Reports/ReportsView.swift
git commit -m "feat(reports): Layout A dashboard — money lenses, AR card, performance, range-aware trend; memoized; CSV error surfaced"
```

---

## Task 7: Reports sample data + PaywallView crisp-taste header + shared core

**Files:**
- Create: `App/Sources/Features/Reports/ReportsSampleData.swift` (**pbxproj registration required**)
- Modify: `App/Sources/Features/Paywall/PaywallView.swift`

- [ ] **Step 1: Create the sample slice**

`ReportsSampleData.swift` — a pure struct of representative demo figures for the teaser when the user has no data:

```swift
import Foundation

/// Representative demo numbers for the Reports paywall teaser when the user
/// has no reportable data yet. Never persisted; display-only.
enum ReportsSampleData {
    static let outstanding = Decimal(1200)
    static let overdue = Decimal(450)
    static let overdueCount = 2
    static let avgDaysToPay = 14
    static let invoiced = Decimal(3600)
    static let collected = Decimal(2400)
    static let effectiveRate = Decimal(78)
}
```

- [ ] **Step 2: Register in pbxproj**

Add `ReportsSampleData.swift` to `Billable.xcodeproj/project.pbxproj`: a PBXFileReference, a PBXBuildFile, a child entry in the `Reports` group, and a Sources-build-phase entry — fresh unique 24-hex IDs (mirror how `ReportsView.swift` is registered; copy that block and swap name + IDs).

- [ ] **Step 3: Add the `.reports` crisp-taste header + ensure shared core**

In `PaywallView.swift`:
- Give the `.reports` trigger a `crispTasteHeader` view: the AR card + an Invoiced/Collected/Rate tile row, fed from the user's real snapshot when `hasReportableData`, else `ReportsSampleData`. To get the real slice, compute a snapshot from `@Query` entries/invoices (or accept an injected `Snapshot?`). Keep it lightweight — a static visual, `accessibilityHidden(true)` on the decorative chart, with a real headline above.
- Ensure the **shared core** (the `valueBullets` at `PaywallView.swift:93-115` + price + CTA) renders for **every** trigger including `.reports` (today `.reports` shows a subhead but the same shared bullets — verify all of: watermark-free invoices · full Reports · CSV · "Lifetime — when it lands" placeholder bullet). Add the **trial-terms line** under the CTA ("7 days free, then $34.99/year · Cancel anytime") and a **"SAVE 51%"** pill on the yearly row (these two are folded here per spec §3; the watermark-banner reframe stays with the separate paywall-polish initiative).

- [ ] **Step 4: Build**

Run: `xcodebuild -scheme Billable -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED (fails here = pbxproj not registered → fix Step 2).

- [ ] **Step 5: Commit**

```bash
git add App/Sources/Features/Reports/ReportsSampleData.swift App/Sources/Features/Paywall/PaywallView.swift Billable.xcodeproj/project.pbxproj
git commit -m "feat(paywall): reports crisp-taste header (real-or-sample) + shared Pro core + trial line/savings pill"
```

---

## Task 8: Render paywall in place on the locked Reports tab; retire ReportsLockedView

**Files:**
- Modify: `App/Sources/App/RootView.swift`

- [ ] **Step 1: Swap the locked branch**

In `RootView.reportsTab` (`RootView.swift:117-124`): when `!subscriptions.isPro`, render `PaywallView(trigger: .reports)` **in place** (embedded in the tab's `NavigationStack`, not as a pushed/presented sheet) instead of `ReportsLockedView`. Delete `ReportsLockedView` (`RootView.swift:129-159`) and any now-unused references.

- [ ] **Step 2: Verify purchase completes in place**

Confirm `PaywallView`'s purchase path updates `SubscriptionManager` entitlement (it does via `Transaction.updates`), so on success the tab re-renders to the real `ReportsView` without a manual dismiss (there's no sheet to dismiss now).

- [ ] **Step 3: Build**

Run: `xcodebuild -scheme Billable -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add App/Sources/App/RootView.swift
git commit -m "feat(paywall): render Reports paywall in place on locked tab; retire ReportsLockedView"
```

---

## Task 9: Privacy-pure conversion counters + DEBUG readout

**Files:**
- Create: `App/Sources/Features/Paywall/ReportsConversionMetrics.swift` (**pbxproj registration required**)
- Modify: `App/Sources/Features/Paywall/PaywallView.swift` (increment on impression + purchase)
- Modify: `App/Sources/Features/Settings/ActivationMetricsView.swift` (show counters)

- [ ] **Step 1: Counter helper**

```swift
import Foundation

/// On-device-only, privacy-pure conversion counters for the Reports paywall.
/// UserDefaults; never transmitted. Read in the DEBUG ActivationMetrics readout.
enum ReportsConversionMetrics {
    private static let impressionsKey = "reports.paywall.impressions"
    private static let conversionsKey = "reports.paywall.conversions"
    static func recordImpression() { bump(impressionsKey) }
    static func recordConversion() { bump(conversionsKey) }
    static var impressions: Int { UserDefaults.standard.integer(forKey: impressionsKey) }
    static var conversions: Int { UserDefaults.standard.integer(forKey: conversionsKey) }
    private static func bump(_ k: String) { UserDefaults.standard.set(UserDefaults.standard.integer(forKey: k) + 1, forKey: k) }
}
```

- [ ] **Step 2: Register in pbxproj** (same procedure as Task 7 Step 2, Paywall group).

- [ ] **Step 3: Wire calls**

In `PaywallView`: call `ReportsConversionMetrics.recordImpression()` in `.onAppear` when `trigger == .reports`; call `recordConversion()` in the purchase-success path when `trigger == .reports`.

- [ ] **Step 4: Surface in DEBUG readout**

In `ActivationMetricsView` (already `#if DEBUG`), add a row: "Reports paywall: \(impressions) seen · \(conversions) converted".

- [ ] **Step 5: Build + commit**

Run: `xcodebuild -scheme Billable -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5` → BUILD SUCCEEDED.

```bash
git add App/Sources/Features/Paywall/ReportsConversionMetrics.swift App/Sources/Features/Paywall/PaywallView.swift App/Sources/Features/Settings/ActivationMetricsView.swift Billable.xcodeproj/project.pbxproj
git commit -m "feat(reports): privacy-pure paywall conversion counters + DEBUG readout"
```

---

## Task 10: Regression gate

**Files:** none (verification only)

- [ ] **Step 1: Full BillableCore suite**

Run: `cd Packages/BillableCore && swift test 2>&1 | tail -8`
Expected: all suites pass.

- [ ] **Step 2: Debug + Release app build**

Run: `xcodebuild -scheme Billable -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -3` → SUCCEEDED.
Run: `xcodebuild -scheme Billable -configuration Release -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -3` → SUCCEEDED.

- [ ] **Step 3: Confirm `--pretend-pro` reaches the new Reports + locked state shows the in-place paywall**

Boot sim, install, launch with `--pretend-pro --seed-marketing` → Reports tab shows the new Layout A. Relaunch without `--pretend-pro` → Reports tab shows the in-place paywall with the crisp taste. (Manual visual confirmation; screenshot each.)

- [ ] **Step 4: Final commit (if any cleanup)** — otherwise done.

---

## Self-review notes

- **Spec coverage:** §1 metrics → Tasks 1–4; §2 Layout A + graceful AR → Task 6; §3 paywall IA + sample fallback → Tasks 7–8; §4 architecture/memoization/CSV → Tasks 5–6; §5 measurement → Task 9; §6 edge cases (currency/zero-guards/drafts) → Tasks 1–3 + 6; §7 testing → Tasks 1–5 + 10. PDF (§10) intentionally out of scope.
- **Type consistency:** `Snapshot.money/ar/performance/revenueTrend/trendBucket/excludedCurrencyCount/hasReportableData` are used identically in Tasks 5–9. `performanceSummary` is `internal` (Task 3) for testability; `arSummary`/`revenueTrend`/`groupings` are `private`.
- **pbxproj:** flagged on every new App file (Tasks 7, 9). BillableCore files (Tasks 1–5) need none.
