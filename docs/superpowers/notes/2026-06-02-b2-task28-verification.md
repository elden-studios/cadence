---
# B2 Task 28 Verification Record
# Locked teaser + CloudKit single-hop NOTE
# Date: 2026-06-02
# Author: code-inspection-verified (Simulator not available in subagent session)
---

## Simulator observation checklist (code-inspection verified)

Each bullet from the Task 28 spec was verified by reading the implementation.
A Simulator run is required before merge — see the BLOCKING note at the end.

### (Step 1 — headline single-line)
PASS (inspection): `crispTasteHeader` renders `trigger.headline` with `.lineLimit(1)`
(PaywallView.swift line 199-200). `Trigger.reports.headline` is `"Know what you're owed."`
(line 27) — 24 characters, well within a single line at any iPhone width.

### (Step 2 — lock eyebrow)
PASS (inspection): `teaserChartHero` leads with an `HStack` containing
`Image(systemName: "lock.fill")` + `Text("Your Reports preview")`, `.foregroundStyle(.tint)`
(lines 331-337). Always rendered regardless of real-vs-sample state.

### (Step 3 — 6 green bars)
PASS (inspection): `ReportsSampleData.collectedLast6Months` is a 6-element array
`[1800, 2200, 1950, 2600, 3100, 2400]` (ReportsSampleData.swift line 18).
`sampleCollectedSeries()` maps these onto 6 calendar-derived month starts.
`Chart(model.collectedSeries) { BarMark(...).foregroundStyle(Color.green.gradient) }`
(lines 343-349). Bar color is `Color.green.gradient` — owner-confirmed (2026-06-02).

### (Step 4 — month abbreviations)
PASS (inspection): `AxisValueLabel(format: .dateTime.month(.abbreviated))` (line 353).
`AxisMarks(values: .stride(by: .month))` ensures one label per bar.

### (Step 5 — "Sample preview" watermark)
PASS (inspection): `if model.isSample && !isPlaceholder { Text("Sample preview") … }`
(lines 206-209). For an empty data store (no paid invoices), `makeTeaserModel()` returns
`isSample: true` via the `!(snap.hasReportableData && collectedHistoryOK)` fallback
(lines 303-315). Watermark is shown. Caption style `.caption2`/`.tertiary`.

### (Step 6 — accessibility-hidden chart block)
PASS (inspection): `teaserChartHero(model).accessibilityHidden(true)` (line 204).
VoiceOver cannot land inside the chart/stat block; the surrounding value props and CTA
remain reachable.

---

## CloudKit single-hop posture (code-inspection verified)

`collectedMonthlyTrend` reads ONLY these Invoice scalar fields:
- `currencyCodeSnapshot` (filter)
- `status` (filter: `.paid` only)
- `paidAt` (bucket key; nil → excluded via unwalked nil key in Dictionary)
- `total` (sum)

It NEVER traverses `invoice.project`, `invoice.client`, or any nested keypath.
The existing `@Query private var reportInvoices: [Invoice]` in PaywallView has no
`relationshipKeyPathsForPrefetching`, so the PR #25 nested-keypath trap
(`\.project?.client` → `Schema.KeyPathCache` crash) CANNOT occur by construction.

Code evidence: `ReportsAggregator.collectedMonthlyTrend` (ReportsAggregator.swift,
the `// MARK: - Collected monthly trend (paywall teaser)` section) and the comment
block in `makeTeaserModel()` (PaywallView.swift lines 282-288).

---

## BLOCKING pre-merge checklist

The following CANNOT be verified by Simulator or unit tests and MUST be done on a
real CloudKit-backed device before this PR is merged:

- [ ] Open the locked Reports tab on a device signed into iCloud with synced invoices.
      Confirm: (a) no crash on launch/navigation, (b) chart renders (real or sample),
      (c) "Sample preview" watermark appears when <2 months of paid invoices exist.
- [ ] With >=2 months of real paid invoices: confirm the watermark is GONE and the
      last bar agrees with the COLLECTED tile value.
- [ ] Optional but recommended: run on a fresh install (no synced data) to confirm
      the sample path renders correctly.

Rationale: Simulator + unit tests use the local-store fallback and MISS CloudKit-only
crashes. Although the single-hop posture is verified above, device smoke-test is
the standing policy per the CloudKit device smoke-test feedback note.
