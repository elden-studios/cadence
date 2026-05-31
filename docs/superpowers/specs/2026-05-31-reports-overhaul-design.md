# Reports Overhaul — Design Spec

**Date:** 2026-05-31
**Status:** Design — pending spec review → implementation plan
**Branch:** `feature/reports-overhaul` (off `main` @ `0cbf521`)
**Initiative:** #1 of the approved "Pro value" backlog (see `project_cadence_monetization_reports_assessment`).
**Inputs:** `docs/assessments/2026-05-31-reports-value-design.md`, `…-market-benchmark.md`, `…-monetization-paywall-lifetime.md`. Visual mockups: `design/brainstorm/{reports-layout-options,reports-teaser-options,paywall-ia}.html`.

## Problem

`ReportsView` is **time-only**. `ReportsAggregator.snapshot(...)` accepts an `invoiceLookup` parameter and **uses it for nothing** (`ReportsAggregator.swift:91`); `ReportsView` never even passes invoices into it (`ReportsView.swift:19-24`). So the entire invoice/payment half of the product — what's been **billed, collected, outstanding, overdue** — is absent from the one paid feature meant to justify Pro. Worse, "Earned" = tracked hours × the project's **current** rate (`TimeEntry.amount(asOf:)`), so historical earnings silently rewrite when a rate changes. For an app whose promise is *track → invoice → get paid*, Reports covers only the first third.

## Goal

Make Reports genuinely *worth paying for*: an **AR-led** financial dashboard that answers "what did I earn, what am I owed, and when will I get paid," backed by **real money from invoices** (not theoretical time-value). Plus replace the cold Pro-lock with a sell-in-place pre-subscribe page that shows the value and the price on one screen.

## Locked decisions (from brainstorming)

1. **Positioning: balanced, AR-led** — the get-paid layer is the hero; performance metrics support it.
2. **Money model: real money from invoices** — headline figures are **Invoiced** (billed) and **Collected** (paid). Tracked time-value is a secondary "potential" lens.
3. **v1 scope: Focused** — money + AR core, effective-rate & utilization KPIs, the existing hours/client/trend charts kept & made range-aware, CSV export, and the pre-subscribe page. Delight extras deferred (see §10).
4. **Dashboard layout: A** ("money lenses → AR card → performance → charts"; mockup `reports-layout-options.html`).
5. **Paywall: one paywall, contextual top + shared core** (mockup `paywall-ia.html`); the Reports header is the **crisp-taste** style (mockup `reports-teaser-options.html`, option ②), purchase completing in place.

> **No data migration.** Every metric below is derived from data already stored on `TimeEntry`, `Project`, `Client`, and `Invoice`.

## Data model (confirmed against source)

- `InvoiceStatus`: `draft` / `sent` / `paid` — **whole-invoice, no partial payments** (`Invoice.swift:4-8`). AR is therefore whole-invoice math.
- Dates: `issuedAt`, `dueAt`, `sentAt?`, `paidAt?` (`Invoice.swift:19-22`).
- `total` = `subtotal + taxAmount`, computed from line items (`Invoice.swift:181-191`).
- `isOverdue(asOf:)` = `status == .sent && dueAt < now` (`Invoice.swift:159-161`).
- `currencyCodeSnapshot` is **per-invoice** (`Invoice.swift:50`) → mixed-currency books are possible; see §8.
- `TimeEntry.invoiceID` links an entry to the invoice it was billed on; `amount(asOf:)` = billable time × current rate.

## §1 — Metric definitions & date semantics

`activeCurrency = profiles.first?.currencyCode ?? "USD"`. **Money sums include only invoices whose `currencyCodeSnapshot == activeCurrency`** (others are excluded and counted; see §8).

### Range-scoped (follow the Week / Month / Year / All picker — existing `TimeRange`)

```
Tracked   = Σ entry.amount(asOf: now)            for entries with startedAt ∈ range AND project.isBillable
Invoiced  = Σ invoice.total                       for invoices status ∈ {sent, paid}, issuedAt ∈ range, currency match
Collected = Σ invoice.total                       for invoices status == paid,        paidAt   ∈ range, currency match
totalHours, billableHours, nonBillableHours       (existing, entries ∈ range)
EffectiveRate = Tracked / totalHours              (blended incl. non-billable; nil if totalHours == 0)
Utilization   = billableHours / totalHours        (nil if totalHours == 0)
RevenueTrend  = per bucket: Σ invoice.total where status ∈ {sent, paid} AND issuedAt ∈ bucket
                bucket size by range: Week→daily, Month→weekly, Year→monthly, All→monthly
HoursByClient / HoursByProject / billable mix     (existing, entries ∈ range)
```

### As-of-now snapshots (NOT range-scoped — "what's owed *right now*")

```
Outstanding   = Σ invoice.total where status == sent (currency match)
Overdue       = Σ invoice.total where isOverdue(asOf: now);  OverdueCount = count of those
Aging (of the status==sent set, bucket by daysPastDue = days(now − dueAt)):
   Current = dueAt >= now            (sent, not yet due)
   1–30    = 1 … 30 days past dueAt
   31–60   = 31 … 60
   60+     = > 60
AvgDaysToPay  = mean(days(paidAt − issuedAt)) over invoices status==paid with paidAt ∈ range
                (range == All → all-time);  nil if none
```

**The three confirmed choices:** (a) AR (Outstanding/Overdue/Aging) is **as-of-now**, not range-scoped; (b) RevenueTrend shows **Invoiced**; (c) AvgDaysToPay is scoped to the selected range (all-time on "All").

## §2 — Dashboard layout (A) & section order

`ReportsView`, top to bottom:

1. **Range picker** (segmented Week/Month/Year/All) — drives only range-scoped sections.
2. **Money lenses** — three labeled tiles **Tracked · Invoiced · Collected**. **No connecting arrows** — they are three independent lenses, not a subtractive funnel (Tracked and Invoiced cover different periods and need not reconcile). [Finding #3]
3. **AR card** ("get paid") — Outstanding (lead figure), Overdue + count (red), AvgDaysToPay, and the 30/60/90 aging bar. Header carries an **"as of today"** label so it reads as a live snapshot, visually distinct from the range-scoped sections above/below. [Finding #2]
4. **Performance KPIs** — Effective rate · Utilization (two tiles).
5. **Revenue trend** — range-aware Invoiced bar/line chart (replaces the always-8-weeks chart).
6. **Hours by client** — existing chart (range-aware).
7. **Project breakdown** — existing list.

### Graceful / light-data behavior [Finding #4]

The AR card adapts to how much receivable data exists, so a solo user with 1–2 clients never sees an empty hero:

- **No sent-or-paid invoices at all** → AR card collapses to a single friendly line: *"No invoices yet — track time, then invoice to see what you're owed."*
- **Outstanding == 0** (everything paid) → *"All paid up ✓"* with the Collected figure; aging bar hidden.
- **Outstanding > 0, none overdue** → show Outstanding + "on track"; aging shown as a single "Current" bar (no empty 30/60/90 segments).
- **Has overdue** → full aging bar + overdue emphasis.

Existing empty state (no tracked time in range) is kept for the range-scoped sections.

## §3 — Paywall information architecture

**One paywall, three doorways** (mockup `paywall-ia.html`). The existing `PaywallView` already has the bones: a `Trigger` enum (`.reports` / `.settings` / `.removeWatermark`) with a contextual headline over shared value bullets + price + CTA. We evolve it:

- **Contextual hook (top, varies by entry):** `.reports` → a **crisp taste** (a real slice of the Layout-A dashboard: the AR card + Invoiced/Collected/Rate) + the headline *"Know what you've earned — and what you're owed"* + 2–3 reports-specific bullets.
- **Shared core (identical for every trigger):** the **full** "Everything in Pro" list (watermark-free invoices · full Reports & insights · CSV export · *Lifetime — when it lands*) + the price picker + CTA + trial terms + restore/legal. This guarantees that subscribing from Reports visibly unlocks **all** of Pro, not just Reports.
- **In place, no bounce:** when the Reports tab is locked it renders **this paywall directly** (contextual = reports), completing the purchase inline. The current cold `ReportsLockedView` (`RootView.swift:129-159`) that shows one sentence and pushes a separate sheet is **retired**.

### Empty-data teaser fallback [Finding #1]

Invoicing is free, so many non-Pro users *do* have real invoices/time → the taste shows **their** numbers. For users with no reportable data yet, the crisp-taste header renders a **sample slice** (clearly representative demo figures, same layout) so the pitch never shows empty zeros at the exact moment it needs to sell. Rule: real slice when `hasReportableData` (≥1 sent/paid invoice **or** ≥1 time entry), else sample.

### Coordination note

This initiative edits `PaywallView` for the contextual header + in-place rendering. The separate **"Paywall polish"** initiative (SAVE-51% pill, trial-terms line, trust line, watermark reframe) also edits `PaywallView`. To avoid a merge collision, the directly-coupled bits (the trial-terms line under the CTA, the SAVE-51% pill) are folded **here**; the unrelated watermark-banner reframe stays with the polish initiative. Sequencing is the owner's call at plan time.

## §4 — Architecture & components

### `ReportsAggregator` (BillableCore, pure)

- **Use invoices.** Replace the dead `invoiceLookup` param with a real `invoices: [Invoice]` input and `activeCurrency: String`.
- **Factor the Snapshot** into focused sub-structs for clarity/maintainability:
  - `MoneySummary { tracked, invoiced, collected }`
  - `ARSummary { outstanding, overdue, overdueCount, aging: Aging, avgDaysToPay: TimeInterval? }` with `Aging { current, d1to30, d31to60, d60plus }`
  - `Performance { effectiveRate: Decimal?, utilization: Decimal? }`
  - keep existing `clientHours`, `projectHours`, `billable/nonBillableHours`, `totalHours`
  - `revenueTrend: [Trend Point]` (range-aware, invoiced)
  - `excludedCurrencyCount: Int` (invoices skipped for non-matching currency)
- All computations pure & deterministic (inject `referenceDate`/`calendar`), no SwiftData dependence — fully unit-testable.

### `ReportsView` (App)

- Re-lay to §2. Pass `allInvoices` + `activeCurrency` into the aggregator (it already `@Query`s invoices — currently only for CSV).
- New subviews: `MoneyLensRow`, `ARCard` + `AgingBar`, `PerformanceTiles`. Reuse existing chart code for trend/client/mix.
- **Memoize the snapshot [Finding #5].** Today `snapshot` is a **computed property recomputed on every `body` evaluation** (`ReportsView.swift:19-25`). Replace with a cached `@State` snapshot recomputed only when its inputs change — the selected `range` or the `@Query` results (SwiftData republishes those only on actual data change) — rather than on every `body` evaluation. The recompute trigger must capture **content** changes (an invoice marked paid, a rate edited), not merely collection counts.

### `PaywallView` (App) & Reports lock

- Add the `.reports` crisp-taste contextual header (real-or-sample slice) + ensure the shared "Everything in Pro" core always renders.
- Render the paywall in place on the locked Reports tab (`RootView.reportsTab`), retiring `ReportsLockedView`.

### Export

- **CSV kept**, and its current **silent failure is surfaced** (the `catch {}` at `ReportsView.swift:266-268` becomes a user-visible alert/toast). Export remains all-entries for now (range-scoping export is fast-follow).
- **Branded PDF export is deferred** to a fast-follow [Finding #6] — it's a market-standard paid export (per the benchmark), explicitly committed as the next Reports increment, not part of v1.

### Performance scaling note

`@Query` for `allEntries`/`allInvoices` is unbounded. Memoization (above) removes the per-render cost. Bounding the fetches (date-predicate) is **fast-follow** — "All time" can't be date-bounded, and correctness is unaffected; this is the same class as the queued widget-predicate-perf follow-up and is noted, not solved, in v1.

## §5 — Measurement (privacy-pure) [Finding #7]

We must be able to tell whether the overhaul actually converts. Staying within the established **privacy-pure** posture (on-device Tier-1 + ASC Tier-0; no opt-in telemetry):

- On-device counters (UserDefaults, never transmitted): `reportsPaywallImpressions`, `subscribedFromReports` (incremented when a purchase completes with `Trigger.reports`). Surfaced in the existing `#if DEBUG` `ActivationMetricsView` readout.
- Rely on **App Store Connect** paywall/subscription analytics for store-side conversion (the Tier-0 baseline already snapshotted before release).

## §6 — Edge cases & resilience

- **Mixed currency:** sum only `currencyCodeSnapshot == activeCurrency`; if `excludedCurrencyCount > 0`, show a subtle footnote ("N invoices in other currencies aren't included"). No FX conversion in v1.
- **Drafts** never count toward Invoiced/Outstanding/AR (only `sent`/`paid`).
- **Deleted/renamed clients:** invoices carry `clientNameSnapshot` (safe); entry-based hours-by-client uses the live relationship and already buckets a nil client as "No client."
- **Overdue uses the clock:** recompute `isOverdue(asOf: .now)` on appearance; never store.
- **Divide-by-zero:** EffectiveRate/Utilization are `nil` when `totalHours == 0` → render "—".
- **Zero states:** no invoices → AR collapsed line (§2); no tracked time in range → existing empty state.

## §7 — Testing

**BillableCore unit tests (pure, deterministic):**
- Invoiced/Collected selection by date-in-range; currency filtering + `excludedCurrencyCount`.
- Outstanding / Overdue / OverdueCount.
- Aging bucket boundaries (due today, +1, +30, +31, +60, +61 days).
- AvgDaysToPay (range-scoped vs all-time on "All"; nil when none).
- EffectiveRate / Utilization incl. zero-hours guard.
- RevenueTrend bucket sizing per range.
- Graceful AR state selection (no-invoices / all-paid / outstanding-not-overdue / overdue).

**App-level:**
- Light UI/snapshot check: locked Reports tab renders the in-place paywall with the crisp taste (assert **both** real-data and sample-fallback paths) + the full Pro core + price.
- Regression: existing hours/client/billable-mix behavior preserved.

## §8 — Open assumptions (confirm at plan time)

1. Single **active currency** for all money sums (the profile's); mixed-currency invoices are excluded + footnoted, not converted.
2. **Invoiced** = non-draft by `issuedAt`; **Collected** = paid by `paidAt`. (Alternative anchors — `sentAt` for invoiced — rejected: `issuedAt` is the invoice's own date and always present.)
3. Reports remains **Pro-gated** (unchanged).
4. `PaywallView` edits coordinate with the separate Paywall-polish initiative (§3 note).

## §9 — Findings resolved (traceability)

| # | Finding | Resolution | Section |
|---|---|---|---|
| 1 | Teaser breaks on empty data | Sample-slice fallback when no reportable data | §3 |
| 2 | Range vs as-of-now confusion | AR block separated + "as of today" label | §2 |
| 3 | Funnel implies subtraction | Three labeled lenses, no arrows | §2 |
| 4 | AR thin for light users | Graceful collapse states | §2 |
| 5 | Snapshot recompute + unbounded fetch | Memoize on input change; bounding = fast-follow | §4 |
| 6 | PDF is table-stakes | Deferred but committed as the next increment | §4, §10 |
| 7 | Can't measure "worth paying for" | Privacy-pure on-device counters + ASC | §5 |

## §10 — Out of scope (fast-follow / later)

- **Branded PDF export** (committed fast-follow).
- Day-of-week / time-of-day patterns; income projection / run-rate; per-project profitability (needs cost rates); budgets vs actual; custom date ranges; range-scoped export. (These were the "Comprehensive v1" extras — deferred.)
- Partial payments (model doesn't support); multi-currency consolidation/FX.
