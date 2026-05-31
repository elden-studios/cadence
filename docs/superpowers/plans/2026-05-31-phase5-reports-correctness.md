# Phase 5 — Reports & CSV correctness — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix five verified Reports/CSV correctness defects (NEW-S4-1..5) so the AR card reads as as-of-now, the "All paid up" state stops contradicting the COLLECTED tile, the CSV matches the on-screen range and stops dropping client-less time, and the paywall impression counter stops over-counting.

**Architecture:** Presentation + small aggregator scoping fixes only — no schema/migration, no money-math change, no Pro-gating change, no net-new feature. The AR card becomes a strictly as-of-now surface moved above the range picker; CSV export reuses a new single-source `ReportsAggregator.entriesInRange(...)` (same half-open predicate the snapshot uses) so the file row-set equals the dashboard row-set.

**Tech Stack:** Swift, SwiftUI, SwiftData; BillableCore Swift package; swift-testing (`import Testing`, `@Test`, `#expect`); `BillableModelContainer.inMemory()` for model tests.

**Spec:** `docs/superpowers/specs/2026-05-31-phase5-reports-correctness-design.md` (locked A/B/A/A + one-shot guard).

**Commands:**
- Unit tests: `swift test --package-path Packages/BillableCore`
- App + widget build: `xcodebuild -project Billable.xcodeproj -scheme Billable -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build/DerivedData build`

---

## File Structure

- **Modify** `Packages/BillableCore/Sources/BillableCore/Reporting/ReportsAggregator.swift` — make `avgDaysToPay` as-of-now (drop range filter); add public `entriesInRange(...)`; route `snapshot`'s in-range filter through it (single source).
- **Modify** `Packages/BillableCore/Sources/BillableCore/Reporting/CSVExporter.swift` — relax the `rows(from:)` guard so client-less entries export with an empty client column.
- **Modify** `App/Sources/Features/Reports/ReportsView.swift` — move AR card above the picker; promote "as of today"; add a range-scope caption; drop the "All paid up" collected sub-figure; range-scope + range-tag the CSV export.
- **Modify** `App/Sources/Features/Paywall/PaywallView.swift` — one-shot `@State` guard on the Reports impression increment.
- **Test (modify)** `Packages/BillableCore/Tests/BillableCoreTests/ReportsMoneyARTests.swift` — add the as-of-now `avgDaysToPay` regression test.
- **Test (modify)** `Packages/BillableCore/Tests/BillableCoreTests/CSVExporterTests.swift` — add `entriesInRange` half-open test + client-less `rows(from:)` test.

Task order: **Task 1** (aggregator avgDaysToPay) → **Task 2** (AR card view: S4-1 + S4-2) → **Task 3** (CSV: S4-3 + S4-4, ships together) → **Task 4** (paywall S4-5).

---

## Task 1: `avgDaysToPay` as-of-now (ReportsAggregator)

**Files:**
- Modify: `Packages/BillableCore/Sources/BillableCore/Reporting/ReportsAggregator.swift` (`arSummary`, ~239-266; call site ~169)
- Test: `Packages/BillableCore/Tests/BillableCoreTests/ReportsMoneyARTests.swift` (add to `ReportsARSummaryTests`)

**Context:** `arSummary`'s paid filter is range-scoped (`$0.paidAt` within `bounds`) while every other figure in the card is as-of-now. After the S4-1 relabel that's a lie. Make it as-of-now (mean days-to-pay over **all** paid invoices). The two existing `avgDaysToPay` assertions (`== 25` in `.allTime`, `== 8` with the paid invoice in-month) are **unaffected** — their paid invoices are already in range. `range`/`bounds` become unused in `arSummary`, so drop them from the signature + call site.

- [ ] **Step 1: Write the failing test**

Add inside `struct ReportsARSummaryTests` (after `func arSummary()`), in `ReportsMoneyARTests.swift`:

```swift
    @Test("avgDaysToPay is as-of-now: a paid invoice outside the selected range still counts")
    func avgDaysToPayAsOfNow() {
        let cal = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func daysAgo(_ n: Int) -> Date { cal.date(byAdding: .day, value: -n, to: now)! }
        // Paid 40 days ago — OUTSIDE 'this week'. issued→paid = 10 days.
        let invoices = [
            makeInvoice(total: 500, status: .paid, issued: daysAgo(50), due: daysAgo(45), paid: daysAgo(40))
        ]
        let snap = ReportsAggregator.snapshot(entries: [], invoices: invoices, in: .thisWeek,
                                              activeCurrency: "USD", referenceDate: now, calendar: cal)
        // Range-scoped (old) would exclude it → nil. As-of-now (fixed) includes it → 10.
        #expect(snap.ar.avgDaysToPay == 10)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Packages/BillableCore --filter avgDaysToPayAsOfNow`
Expected: FAIL — `snap.ar.avgDaysToPay` is `nil` (the paid invoice's `paidAt` is outside the `.thisWeek` bounds), so `nil == 10` is false.

- [ ] **Step 3: Make `avgDaysToPay` as-of-now + drop the now-dead params**

In `ReportsAggregator.swift`, change the `arSummary` signature (was `arSummary(_ invoices:, range:, bounds:, asOf now:, calendar:)`):

```swift
    private static func arSummary(_ invoices: [Invoice], asOf now: Date,
                                  calendar: Calendar) -> ARSummary {
```

Change the paid filter (was `let paid = invoices.filter { $0.status == .paid && ($0.paidAt.map { $0 >= bounds.lowerBound && $0 < bounds.upperBound } ?? false) }`) to:

```swift
        // avgDaysToPay is an as-of-now stat (matches the rest of the AR card):
        // mean days-to-pay over ALL paid invoices, not range-scoped. (Phase 5 / S4-1.)
        let paid = invoices.filter { $0.status == .paid }
```

Update the call site (was `let ar = arSummary(curInvoices, range: range, bounds: bounds, asOf: referenceDate, calendar: calendar)`):

```swift
        let ar = arSummary(curInvoices, asOf: referenceDate, calendar: calendar)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path Packages/BillableCore`
Expected: PASS — the new `avgDaysToPayAsOfNow` (== 10) plus the unchanged `arSummary` (== 25) and `integratedSnapshot` (== 8) all green; whole BillableCore suite green.

- [ ] **Step 5: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Reporting/ReportsAggregator.swift Packages/BillableCore/Tests/BillableCoreTests/ReportsMoneyARTests.swift
git commit -m "Phase 5 (S4-1): avgDaysToPay is as-of-now, not range-scoped"
```

---

## Task 2: AR card — move above picker, relabel, drop sub-figure (ReportsView)

**Files:**
- Modify: `App/Sources/Features/Reports/ReportsView.swift` (`body` ~50-102; `arCard` ~150-207; add `rangeScopeCaption`)

**Context:** S4-1 (move AR card above the range picker so the picker visibly governs only what's below; promote "as of today"; label the range-scoped block) + S4-2 (drop the range-scoped "X collected" sub-line that contradicts the COLLECTED tile). Pure SwiftUI; verified by build + runtime. No unit test.

- [ ] **Step 1: Reorder `body` so the AR card renders above the picker**

In `ReportsView.body`, replace the `VStack(alignment: .leading, spacing: 22) { … }` content (currently `rangePicker` first, then `if let snapshot { moneyLenses; arCard; performanceTiles; … }`) with:

```swift
                VStack(alignment: .leading, spacing: 22) {
                    if let snapshot {
                        arCard(snapshot)            // as-of-now — ABOVE the picker (S4-1)
                    }
                    rangePicker
                    Text(rangeScopeCaption)         // labels what the picker governs (S4-1)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let snapshot {
                        moneyLenses(snapshot)
                        performanceTiles(snapshot)
                        if !snapshot.hasReportableData {
                            emptyState
                        } else {
                            revenueTrendChart(snapshot)
                            clientBars(snapshot)
                            projectBreakdown(snapshot)
                        }
                        if snapshot.excludedCurrencyCount > 0 {
                            excludedCurrencyFootnote(snapshot.excludedCurrencyCount)
                        }
                    }
                }
```

- [ ] **Step 2: Add the `rangeScopeCaption` helper**

In `ReportsView` (near the other computed helpers, e.g. above `currencyCode`), add:

```swift
    /// Label for the range-scoped block beneath the picker, so the as-of-now AR
    /// card above the picker reads as a separate temporal scope. (S4-1)
    private var rangeScopeCaption: String {
        switch range {
        case .thisWeek:  "THIS WEEK"
        case .thisMonth: "THIS MONTH"
        case .thisYear:  "THIS YEAR"
        case .allTime:   "ALL TIME"
        }
    }
```

- [ ] **Step 3: Promote the "as of today" caption in `arCard`**

In `arCard`, the header `HStack` currently renders `Text("as of today").font(.caption2).foregroundStyle(.tertiary)`. Change that one line to:

```swift
                Text("as of today")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
```

- [ ] **Step 4: Drop the range-scoped collected sub-figure (S4-2)**

In `arCard`, the `else if ar.outstanding == 0` branch currently is the "All paid up" `HStack` followed by `if snapshot.money.collected > 0 { Text("… collected") … }`. Replace the whole branch body with (removing the conditional collected line, adding a static non-numeric subtitle):

```swift
            } else if ar.outstanding == 0 {
                // Everything paid — as-of-now success state, no period figure (S4-2).
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("All paid up")
                        .font(.title2.weight(.bold))
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
                Text("Nothing outstanding")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
```

- [ ] **Step 5: Build to verify it compiles**

Run: `xcodebuild -project Billable.xcodeproj -scheme Billable -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build/DerivedData build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add App/Sources/Features/Reports/ReportsView.swift
git commit -m "Phase 5 (S4-1/S4-2): AR card above picker + range label; drop contradictory collected sub-line"
```

---

## Task 3: CSV — range-scoped + keep client-less rows (ships together)

**Files:**
- Modify: `Packages/BillableCore/Sources/BillableCore/Reporting/ReportsAggregator.swift` (add `entriesInRange`; route `snapshot` through it)
- Modify: `Packages/BillableCore/Sources/BillableCore/Reporting/CSVExporter.swift` (`rows(from:)` guard ~91-93)
- Modify: `App/Sources/Features/Reports/ReportsView.swift` (`exportCSV` ~414-427)
- Test: `Packages/BillableCore/Tests/BillableCoreTests/CSVExporterTests.swift`

**Context:** S4-3 (CSV ignores the range) and S4-4 (CSV drops client-less time) are the same root bug — `exportCSV` feeds the unfiltered `allEntries` into an over-dropping guard. They ship together. A new `entriesInRange(...)` is the single source of the half-open boundary so the file row-set equals the dashboard row-set.

- [ ] **Step 1: Write the failing `entriesInRange` half-open test**

Add to `CSVExporterTests.swift`. First add `import SwiftData` at the top (it currently imports `Foundation`, `Testing`, `@testable BillableCore`). Then add a new suite:

```swift
@Suite("ReportsAggregator.entriesInRange")
@MainActor
struct EntriesInRangeTests {
    @Test("Uses the same half-open predicate as the snapshot (upperBound excluded)")
    func halfOpen() throws {
        let cal = Calendar(identifier: .gregorian)
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
```

- [ ] **Step 2: Run to verify it fails (compile error — function missing)**

Run: `swift test --package-path Packages/BillableCore --filter EntriesInRangeTests`
Expected: FAIL to compile — `type 'ReportsAggregator' has no member 'entriesInRange'`.

- [ ] **Step 3: Add `entriesInRange` and route `snapshot` through it (single source)**

In `ReportsAggregator.swift`, add a public static helper (place it just before `// MARK: - Aggregation`):

```swift
    /// Entries whose `startedAt` falls in `range`, using the SAME half-open
    /// predicate the snapshot uses (`>= lower && < upper`). Single source of the
    /// range boundary so CSV export scopes to exactly what the dashboard shows. (S4-3)
    public static func entriesInRange(_ entries: [TimeEntry], range: TimeRange,
                                      asOf referenceDate: Date = .now,
                                      calendar: Calendar = .current) -> [TimeEntry] {
        let bounds = range.range(asOf: referenceDate, calendar: calendar)
        return entries.filter { $0.startedAt >= bounds.lowerBound && $0.startedAt < bounds.upperBound }
    }
```

In `snapshot(...)`, replace the in-range filter (was `let inRangeEntries = entries.filter { inRange($0.startedAt) }`) so it reuses the helper:

```swift
        let inRangeEntries = entriesInRange(entries, range: range, asOf: referenceDate, calendar: calendar)
```

(The local `inRange(_:)` closure on the prior line stays — it's still used by the money/AR filters. Only the entries filter changes.)

- [ ] **Step 4: Run to verify the half-open test passes**

Run: `swift test --package-path Packages/BillableCore --filter EntriesInRangeTests`
Expected: PASS.

- [ ] **Step 5: Write the failing client-less `rows(from:)` test**

Add a second suite to `CSVExporterTests.swift`:

```swift
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
        let general = rows.first { $0.projectName == "General" }
        #expect(general != nil)
        #expect(general?.clientName == "")                         // empty client column
        #expect((general?.durationHours ?? 0) > 0)                 // non-zero worked_hours
    }
}
```

- [ ] **Step 6: Run to verify it fails**

Run: `swift test --package-path Packages/BillableCore --filter clientlessRowsKept`
Expected: FAIL — `rows.count == 2` is false; the client-less entry is dropped, so `rows.count == 1`.

- [ ] **Step 7: Relax the `rows(from:)` guard (S4-4)**

In `CSVExporter.swift` `rows(from:)`, change the guard + clientName (was `guard let project = entry.project, let client = project.client else { return nil }` and `clientName: client.name`):

```swift
        entries.compactMap { entry in
            guard let project = entry.project else { return nil }   // keep project guard; allow client-less (S4-4)
```

and in the returned `Row`, change the client field to:

```swift
                clientName: project.client?.name ?? "",   // mirror ReportsAggregator → screen/CSV reconcile
```

- [ ] **Step 8: Run to verify the client-less test passes**

Run: `swift test --package-path Packages/BillableCore --filter clientlessRowsKept`
Expected: PASS.

- [ ] **Step 9: Range-scope the CSV export + range-tag the filename (S4-3, view)**

In `ReportsView.swift` `exportCSV()`, replace the body (was `let rows = CSVExporter.rows(from: allEntries, …)` and the fixed `"BillableTimeEntries.csv"`):

```swift
    private func exportCSV() {
        // Match the on-screen range (S4-3): scope to the SAME entries the dashboard
        // shows via the shared half-open helper. .allTime is a natural no-op.
        let scopedEntries = ReportsAggregator.entriesInRange(allEntries, range: range)
        let invoiceLookup = Dictionary(uniqueKeysWithValues: allInvoices.map { ($0.uuid, $0) })
        let rows = CSVExporter.rows(from: scopedEntries, invoiceLookup: invoiceLookup)
        let csv = CSVExporter.csv(for: rows)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BillableTimeEntries-\(range.label).csv")
        do {
            try csv.data(using: .utf8)?.write(to: url, options: .atomic)
            csvURL = url
            showingShareCSV = true
        } catch {
            exportError = error.localizedDescription
        }
    }
```

- [ ] **Step 10: Run full unit suite + app build**

Run: `swift test --package-path Packages/BillableCore`
Expected: PASS (all suites, incl. the two new tests).
Run: `xcodebuild -project Billable.xcodeproj -scheme Billable -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build/DerivedData build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 11: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Reporting/ReportsAggregator.swift Packages/BillableCore/Sources/BillableCore/Reporting/CSVExporter.swift App/Sources/Features/Reports/ReportsView.swift Packages/BillableCore/Tests/BillableCoreTests/CSVExporterTests.swift
git commit -m "Phase 5 (S4-3/S4-4): CSV matches the selected range + keeps client-less rows"
```

---

## Task 4: Paywall impression one-shot guard (PaywallView)

**Files:**
- Modify: `App/Sources/Features/Paywall/PaywallView.swift` (state declarations; `.onAppear` ~99-113)

**Context:** S4-5. `ReportsConversionMetrics.recordImpression()` fires unconditionally in `.onAppear`, which re-fires on Reports-tab revisits (the embedded paywall stays mounted). Gate it with a one-shot `@State` flag so it records once per presentation, matching the once-only conversion counter. Touch ONLY `ReportsConversionMetrics` — the `PaywallMetrics.paywallView` funnel is a separate, parked item. No unit test (view `@State`); verified at runtime via the DEBUG ActivationMetrics readout.

- [ ] **Step 1: Add the one-shot state flag**

In `PaywallView`, add alongside the existing `@State` properties:

```swift
    /// Records the Reports paywall impression only once per presentation/mount —
    /// the embedded tab stays mounted, so .onAppear re-fires on revisits. (S4-5)
    @State private var didRecordImpression = false
```

- [ ] **Step 2: Guard the impression increment**

In `.onAppear`, change the line (was `if trigger == .reports { ReportsConversionMetrics.recordImpression() }`) to:

```swift
                if trigger == .reports && !didRecordImpression {
                    ReportsConversionMetrics.recordImpression()
                    didRecordImpression = true
                }
```

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild -project Billable.xcodeproj -scheme Billable -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build/DerivedData build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add App/Sources/Features/Paywall/PaywallView.swift
git commit -m "Phase 5 (S4-5): record Reports paywall impression once per presentation"
```

---

## Final verification (after all tasks)

- [ ] `swift test --package-path Packages/BillableCore` → all suites pass (≥ 343: 341 baseline + `avgDaysToPayAsOfNow` + `halfOpen` + `clientlessRowsKept`).
- [ ] App + widget `xcodebuild … build` → `** BUILD SUCCEEDED **`.
- [ ] Runtime (seeded sim screenshot): switch ranges → AR card on top is unchanged; money tiles + charts below change; "THIS MONTH"/etc. caption tracks the picker.
- [ ] Runtime: pay-all then view a short range → "All paid up ✓ / Nothing outstanding" with no orphaned figure beside a $0 COLLECTED tile.
- [ ] Runtime: export on Week vs All → filename reflects the range; contents match the on-screen range; a client-less "General" entry appears with a blank client cell; CSV hours tie out to the on-screen Hours-by-project totals.
- [ ] Runtime (DEBUG): revisit the Reports tab N times → ActivationMetrics impressions increments once per launch, not per revisit.

---

## Self-Review

**1. Spec coverage:**
- S4-1 (move + relabel) → Task 2 steps 1-3; S4-1 required `avgDaysToPay` fix → Task 1. ✅
- S4-2 (drop sub-figure) → Task 2 step 4. ✅
- S4-3 (range-scope CSV, half-open verbatim, range-tag filename, `.allTime` no-op) → Task 3 steps 3,9 (`entriesInRange` half-open) + filename. ✅
- S4-4 (keep client-less, empty column, keep project guard) → Task 3 step 7. ✅
- S4-5 (one-shot impression) → Task 4. ✅
- Couplings: S4-1↔S4-2 both in Task 2 + the avgDaysToPay gate in Task 1; S4-3↔S4-4 both in Task 3 (one commit). ✅

**2. Placeholder scan:** No TBD/TODO; every code step shows complete before/after code and exact commands. ✅

**3. Type consistency:** `entriesInRange(_:range:asOf:calendar:)` is defined in Task 3 step 3 and called identically in Task 3 step 9 and the snapshot refactor. `arSummary(_:asOf:calendar:)` new signature (Task 1) matches its new call site. `Row.clientName`/`projectName`/`durationHours`, `Project(name:hourlyRate:isBillable:client:)`, `TimeEntry(startedAt:endedAt:isManual:project:accumulatedSeconds:)`, `Client(name:)`, `BillableModelContainer.inMemory()`, `TimeRange.range(asOf:calendar:)`/`.label` all match the real APIs read from source. ✅

**Note for implementer:** after Task 1, `range`/`bounds` are removed from `arSummary` — confirm no other caller exists (there is only the one call site in `snapshot`). The `inRange(_:)` closure in `snapshot` remains (still used by the money/AR/collected filters); only the *entries* filter is routed through `entriesInRange`.
