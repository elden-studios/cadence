# Phase 5 — Reports & CSV correctness (design)

**Date:** 2026-05-31
**Program:** Cadence product-review fix program (Phases 1–4 shipped: #16/#17/#18/#19, main `a610460`).
**Source backlog:** `docs/reviews/2026-05-31-cadence-verified-backlog.md` — items NEW-S4-1..5.
**Branch:** `feature/phase5-reports-correctness` (worktree off `origin/main` `a610460`).

## Scope & constraint

Five verified Reports/CSV **correctness/consistency** defects. **Hard constraint (program-wide): no net-new features** — only restructure / relabel / fix existing behavior. All five are presentation + small aggregator scoping/labeling fixes: **no schema/migration, no money-math change to tracked/invoiced/collected, no Pro-gating change.**

Files touched (verified paths):
- `App/Sources/Features/Reports/ReportsView.swift`
- `Packages/BillableCore/Sources/BillableCore/Reporting/ReportsAggregator.swift`
- `Packages/BillableCore/Sources/BillableCore/Reporting/CSVExporter.swift`
- `App/Sources/Features/Paywall/PaywallView.swift`
- BillableCore tests (`Packages/BillableCore/Tests/BillableCoreTests/`)

## Design validation

The four design forks were validated by a 5-agent workflow (4 independent per-fork assessments + 1 synthesis), each grounded in best practices and how comparable products (Harvest, FreshBooks, QuickBooks, Toggl, Bonsai, Wave, Xero) behave, and **code-verified against the real files.** My initial picks were **A/A/A/A**; the locked set is **A/B/A/A** — one substantive reversal (S4-2) plus two refinements that became **gating requirements**.

---

## S4-1 — AR "GET PAID" card is as-of-now but sits among range-scoped tiles  ·  **LOCK: A + required aggregator fix**

**Problem.** `ReportsAggregator.arSummary` computes outstanding/overdue/aging over **all** `.sent` invoices using `now` (unscoped), but the card renders directly *below* the segmented range picker between range-scoped tiles. Switching Week→Month→Year freezes the headline figure + aging bar — reads as a stale/buggy tile, explained only by a tiny `.tertiary` "as of today" caption that a 34pt headline visually dominates.

**Decision.** Move the AR card **above** the range picker as a persistent "what you're owed right now" header; the picker then visibly governs only what is beneath it. An AR balance is a point-in-time *stock*, not a windowed *flow* — range-scoping it (option C) is the conceptual error (and is impossible for default ranges whose period-end is in the future, and unsupported by the 3-state `draft/sent/paid` model which stores no historical per-date status). This matches every comparable AR-led product (FreshBooks/QBO/Harvest lead with a live balance; only Xero offers dated aging and only as a *separate* report, never the dashboard headline).

**What to build (`ReportsView.swift`):**
1. **Reorder `body`** (currently `rangePicker → moneyLenses → arCard → …`): new top-to-bottom order **`arCard → rangePicker → moneyLenses → performanceTiles → (empty/charts) → footnote`**. Keep `arCard` inside `if let snapshot` (it reads `snapshot.ar` / `hasAnyBilledInvoice`).
2. **Relabel for an unmissable split:** keep the punchy **`GET PAID`** title; promote the existing "as of today" caption from `.caption2/.tertiary` to `.secondary` and place it adjacent to the figure. Give the range-scoped block beneath the picker its own scope label (reuse `range.label`, e.g. a small "This Month" header on the money lenses) so the boundary is explicit on both sides.
3. **REQUIRED correctness fix (`ReportsAggregator.swift`):** `avgDaysToPay` (in `arSummary`) is currently **range-scoped** via `bounds` while the rest of the card is as-of-now — so the relabel would *lie*. Make `avgDaysToPay` **as-of-now**: compute mean days-to-pay over **all** paid invoices in `curInvoices` (drop the `bounds` filter). Update the BillableCore test that asserts range-scoped `avgDaysToPay`.
4. **Accessibility:** combine the split into one a11y element ("Outstanding, as of today, $X") — don't convey scope by position/color alone.

**Why not B (keep order, bolder caption):** legitimate lighter-touch fallback, but it leaves the figure physically inside the picker's apparent jurisdiction — a caption fighting layout, and layout wins. A removes the structural cause.

---

## S4-2 — "All paid up" contradicts a $0 Collected tile  ·  **LOCK: B (reverses my initial A)**

**Problem.** The `else if ar.outstanding == 0` branch shows "All paid up ✓" with a sub-line `"\(money.collected) collected"` that is **hidden when `money.collected == 0`**. `money.collected` is **range-scoped** (invoices *paid within the range*). So "Week" with a payment last month → the sub-line vanishes, leaving "All paid up" with no figure beside a visible $0 COLLECTED tile.

**Decision.** **Drop the sub-figure** — "All paid up" + `checkmark.seal.fill` becomes the entire body of the branch (optionally a static, **non-numeric** subtitle like "Nothing outstanding"). Delete the `if snapshot.money.collected > 0 { … }` block (`ReportsView.swift`). No aggregator change, no new metric.

**Why B over my initial A (always show lifetime collected) — the reversal:**
- **Code-verified premise correction:** the AR sub-line and the COLLECTED tile read the **identical** value `snapshot.money.collected` — they are not "opposite" figures; the real defect is the conditional hide.
- A would add a **net-new `lifetimeCollected` metric** → brushes the no-new-features hard constraint.
- Worse, with the COLLECTED tile staying range-scoped (no tile rescope is in this phase), A would render a **large lifetime figure beside a $0 COLLECTED tile** on short ranges — a *louder* same-screen contradiction than today's blank.
- B is least code, adds no metric, and matches Wave/QuickBooks "all caught up" empty-states that carry no dollar figure. **Reinforces S4-1:** removing the range-scoped sub-line leaves the AR card with *zero* period-scoped content, honoring the as-of-now framing.
- C ("$0 collected this period") is rejected — it stamps a $0 on the success card and re-introduces period-scoping into a card S4-1 just declared as-of-now.

---

## S4-3 — CSV export ignores the selected range  ·  **LOCK: A**

**Problem.** `exportCSV()` feeds the unbounded `allEntries` `@Query` to `CSVExporter.rows`, ignoring `range`, while every on-screen figure is range-filtered. A user viewing "Week" who taps Share silently gets an all-time dump.

**Decision.** Filter the CSV to the active range's bounds — **what you see is what you export.** `.allTime` already returns `distantPast...distantFuture`, so it exports everything **for free** (no special-case). Matches Harvest/Toggl/FreshBooks/QBO/Xero, which all honor the on-screen date filter; a full dump is a separate "export all data" affordance in those tools, not the share button on a filtered report.

**What to build (`ReportsView.swift` `exportCSV()`):**
- Before `CSVExporter.rows`, compute `let bounds = range.range()` and keep entries where **`startedAt >= bounds.lowerBound && startedAt < bounds.upperBound`**.
- **CRITICAL:** copy the aggregator's **half-open** predicate **verbatim** (`ReportsAggregator.snapshot` uses `>= lower && < upper` even though `TimeRange.range()` returns a `ClosedRange`). Do **NOT** use `ClosedRange.contains` (inclusive upper) — an entry exactly at `upperBound` would land in the CSV but not the on-screen totals, re-introducing a subtler mismatch.
- Filename: replace the fixed `"BillableTimeEntries.csv"` with a **range-tagged** name (e.g. `BillableTimeEntries-Month.csv`) so an accountant knows the window and multi-exports don't overwrite.
- Empty filtered set → `CSVExporter.csv` returns a header-only file (acceptable; existing `emptyRows` test). Optional: a lightweight "No entries in this range" path rather than sharing an empty file.

---

## S4-4 — CSV silently drops client-less "General" time  ·  **LOCK: A**  (ships **with** S4-3)

**Problem.** `CSVExporter.rows` guards on **both** `project` AND `client` (`guard let project = entry.project, let client = project.client`), dropping client-less rows. But `ReportsAggregator.groupings` **keeps** client-less projects (`clientName = project.client?.name ?? ""`), and onboarding's quick-start creates client-less "General" time. So the typical first-run user gets CSV hours < on-screen hours, silently.

**Decision.** Include client-less rows with an **empty client column** — reuse the aggregator's exact `project.client?.name ?? ""` convention so screen and CSV reconcile byte-for-byte (one source of truth for "no client"). **Keep the non-nil project guard.**

**What to build (`CSVExporter.rows`):**
- Change the guard to `guard let project = entry.project else { return nil }` and set `clientName: project.client?.name ?? ""` (exact `?? ""` form, mirroring `ReportsAggregator`).
- **Keep dropping project-nil entries:** `TimeEntry.project` is Optional; a project-less entry has no name/rate/client to populate, and the aggregator's `byProject` grouping *also* drops project-nil — keeping the guard preserves reconciliation (removing it would create the opposite mismatch, CSV > screen).
- Confirm the empty client emits an **empty field** (not a dropped comma) so the column count stays 11 / RFC-4180 valid (`quote("")` already handles this).

**Why A over B ("No client" literal):** B introduces a *second* divergent representation (screen = blank, CSV = label) — itself a consistency defect — and risks collision with a real client named "No client". Harvest/Toggl raw exports use an empty cell.

---

## S4-5 — Reports paywall impression counter over-counts on re-appear  ·  **LOCK: one-shot guard** (clear-cut, no fork)

**Problem.** `ReportsConversionMetrics.recordImpression()` is called **unconditionally** in `PaywallView.onAppear` (line 102) when `trigger == .reports`. The embedded Reports paywall stays mounted (RootView), so `.onAppear` re-fires on every Reports-tab revisit. Conversion is recorded **once** on purchase success → the impressions denominator drifts up, understating the conversion rate in the DEBUG readout.

**Decision.** Gate the impression increment with a **one-shot `@State` flag** so it records once per presentation/mount (matching the once-only conversion counter).

**What to build (`PaywallView.swift`):**
- Add `@State private var didRecordImpression = false`.
- In `.onAppear`, replace the unconditional call with: `if trigger == .reports && !didRecordImpression { ReportsConversionMetrics.recordImpression(); didRecordImpression = true }`.
- **Scope guard:** touch **only** `ReportsConversionMetrics.recordImpression()`. The `PaywallMetrics.record(.paywallView …)` / `.lifetimeOwnedView` funnel over-count is a **separate, parked Phase-6 item** (backlog ~line 208) — out of scope here.

---

## Couplings & invariants (spec-critical)

1. **S4-1 ↔ S4-2.** S4-1 makes the AR card a strictly as-of-now surface; S4-2 = B *honors* that by removing the only range-scoped content inside it. **Invariant to preserve:** after the reorder, **nothing above the picker reacts to range; everything below does.** The only as-of-now consumer is the AR card; `moneyLenses`, `performanceTiles`, `revenueTrend`, `clientBars`, `projectBreakdown`, `excludedCurrencyFootnote` stay below and stay range-scoped. This invariant is only fully true once the **S4-1 `avgDaysToPay` fix lands** — it is the gating item.
2. **S4-3 ↔ S4-4 are the same root bug** (`exportCSV` passes unfiltered `allEntries` into an over-dropping guard) and **must ship together.** S4-3 fixes the row *set* (range); S4-4 fixes row *completeness* (client-less). Either alone leaves "CSV total ≠ screen total." Derive `bounds` once and use it for the export filter; the shared concept is *"the CSV row set must equal `ReportsAggregator`'s in-range, project-non-nil entry set."*
3. **Reconciliation definition-of-done.** After all five: (a) an AR header that is unambiguously as-of-now and internally consistent (S4-1 + S4-2), and (b) a CSV whose hours tie out to the on-screen Hours-by-project/Hours-by-client breakdown for the same range (S4-3 + S4-4); plus (c) an honest impression denominator (S4-5).

## Implementation caveats

- **`avgDaysToPay` is a behavior change to the aggregator, not just presentation** — grep BillableCore reporting tests for `avgDaysToPay` expectations and update them in the same change.
- **Above-the-fold:** moving `arCard` up pushes the picker + money tiles down; verify on a small device that the picker stays discoverable. Keep the AR card compact in common states (the overdue state with aging bar + legend is the tall one).
- **`ReportsSampleData` paywall teaser** renders the same `arCard` — verify the reordered layout looks right in the locked/teaser state. `hasReportableData` gating is unaffected (views only move).
- **Timezone/reference-date:** the export must use the same `Calendar.current` / `.now` basis as the displayed snapshot so a midnight/locale edge can't desync file and screen (both use defaults today — keep it that way).

## Test plan

**BillableCore (`swift test`):**
- `avgDaysToPay` ignores range (as-of-now over all paid invoices) — update/replace the existing range-scoped assertion.
- CSV export row set == snapshot's in-range set, identical half-open boundary semantics (boundary entry at `upperBound` excluded by both).
- A client-less project yields a CSV row with an **empty** client column and **non-zero** `worked_hours` (regression lock for the silent-drop).
- (Existing) `emptyRows` header-only behavior still holds for an empty range.

**App build:** app + widget `BUILD SUCCEEDED`.

**Runtime / manual (document on PR):**
- Switch ranges → AR card (now on top) doesn't change; money tiles + charts below do.
- Pay-all-then-view-short-range → "All paid up ✓" with no orphaned/contradictory figure.
- Export on Week vs All → file contents match the on-screen range; filename reflects the range; client-less "General" rows present with a blank client cell; totals tie out to the on-screen breakdown.
- Reports tab revisited N times → DEBUG impressions increments once per app launch, not per revisit.

## Out of scope (parked)

- COLLECTED-tile rescope/relabel (would unlock S4-2 option A) — not needed; B stands alone.
- `PaywallMetrics.paywallView` / `lifetimeOwnedView` funnel over-count + owned-view timing (backlog ~208) — Phase 6 paywall polish.
- Any net-new Reports metric, chart, or export column.

## Build / sequencing plan

Two cohesive work-streams (subagent-driven TDD, each build- + test-gated):
- **WS-A — AR card (S4-1 + S4-2):** `ReportsAggregator.avgDaysToPay` as-of-now + test update; `ReportsView` reorder + relabel + drop "All paid up" sub-figure + a11y.
- **WS-B — CSV (S4-3 + S4-4):** `ReportsView.exportCSV` range-filter (half-open verbatim) + range-tagged filename; `CSVExporter.rows` guard relax + empty-client column; two new tests.
- **WS-C — metric (S4-5):** `PaywallView` one-shot impression guard.

Then: two-stage review (spec-compliance + Opus code-quality) → full test + build gate → PR off `origin/main` → Gemini round (assess findings with agents, apply clear-cut, decline false positives) → user merges → cleanup.
