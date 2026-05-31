# Changelog

Notable features and changes to **Cadence** (the Billable app — freelancer time-tracking + invoicing).

Detailed design specs and implementation plans for each feature live in
[`docs/superpowers/specs/`](docs/superpowers/specs/) and
[`docs/superpowers/plans/`](docs/superpowers/plans/).

---

## Pending production gates (merged in code, not yet live)

- **Lifetime IAP + new prices** — the code, StoreKit config, and tests are merged, but the new ladder is not live until **App Store Connect** is updated:
  1. Create the non-consumable IAP `com.eldenstudios.billable.pro.lifetime` at **$99.99** (submit attached to the next build).
  2. Change subscription prices to **Monthly $3.99 / Yearly $39.99** (preserve existing subscribers' price).
  - Until then, `Billable.storekit` drives local / Xcode StoreKit-Testing only.
- **Queued (not started):** paywall polish (watermark reframe, trust line, stale `PaywallView` doc-comment, swallowed restore-error TODO), recurring-invoices → Pro A/B test, the get-started "Start a timer now" revisit, widget `#Predicate` perf bound (two fetch-all `TimeEntry` queries).

---

## 2026-05-31

### Lifetime purchase + pricing-ladder reset (PR #14)
- Added a **$99.99 one-time Lifetime** purchase (StoreKit **non-consumable**). Lifetime is terminal Pro — it wins over any subscription state and restores across devices via `Transaction.currentEntitlements`.
- Reset the ladder: **Monthly $3.99 / Yearly $39.99** (was $5.99 / $34.99). The annual savings badge is now **computed** from live prices ("SAVE $7.89 · about 2 months free") rather than a hardcoded "SAVE 51%".
- **Conversion-optimized paywall** (after a 6-lens CRO assessment): Yearly is the visual hero; **Lifetime is a demoted "or pay once — $99.99" affordance below the trial CTA** (not a co-equal third tier — co-equal tiers were found to suppress conversion); the trial reassurance is promoted out of fine print; an owned-state ("You own Pro forever ✓") doubles as the double-buy guard.
- **On-device, variant-keyed funnel metrics** (`PaywallMetrics`, no third-party SDK) so paywall conversion is measurable and future price/layout tests are a config flip.
- New BillableCore helpers (all unit-tested): `SubscriptionManager.resolveEntitlement`, `PricingDisplay`, `PaywallMetrics`; plus `PricingConfig`.
- Spec: `docs/superpowers/specs/2026-05-31-lifetime-pricing-design.md` · Plan: `docs/superpowers/plans/2026-05-31-lifetime-pricing.md`

### Project-detail IA redesign + timer animation (PR #13)
- **Project detail:** "Complete / Restore" + "Edit" moved into a **⋯ toolbar menu** (no longer buried below the session list); the sessions preview is **capped at the 5 most recent** with a "See all N ›" push to a new full-history **`ProjectSessionsView`**; the timer area moved up.
- **Timer:** animated **Start ↔ Running** transition driven by one stable `TimelineView` (Spring Pop default; a DEBUG **Settings → "Timer motion"** picker switches styles). Honors Reduce Motion.
- Demo seed: "Website Refresh" now has ~12 sessions so the "See all" affordance is demonstrable.
- Spec: `docs/superpowers/specs/2026-05-29-project-detail-ia-redesign-design.md`

### Reports overhaul + new paywall IA (PR #12)
- Reports is now an **AR-led money dashboard**: Invoiced / Collected / Outstanding / Overdue + invoice aging + average days-to-pay, plus **effective-rate** and **utilization** KPIs and a range-aware revenue trend (previously time-only).
- New **contextual paywall** rendered in-place on the locked Reports tab (no bounce to a sheet), with a shared "Everything in Pro" core and a real-or-sample teaser.
- Spec: `docs/superpowers/specs/2026-05-31-reports-overhaul-design.md` · Plan: `docs/superpowers/plans/2026-05-31-reports-overhaul.md`

## 2026-05-30

### Onboarding entity-type redesign (PR #11)
- Freelancer / Organization onboarding paths, an entity-aware project/business editor, and Today "get started" guidance.
- Spec: `docs/superpowers/specs/2026-05-30-onboarding-entity-type-design.md`

## Earlier (2026-05-28/29)

- **Per-project detail screen** + **project-first navigation** (Today "Jump back in" recents; Work tab replaces Clients) — PR #8, #10.
- **Per-project invoicing** — PR #7.
- **Timer redesign** (Break/Resume/Done; Running timer card) — PR #6.
- Home-screen **widgets**.

---

## Engineering notes

- **Stack:** Swift 6 (strict concurrency = complete), SwiftUI + `@Observable` + SwiftData/CloudKit, StoreKit 2, `xcodegen`-managed project (`project.yml`, folder-based sources — run `xcodegen generate` after adding files; never hand-edit `project.pbxproj`).
- **Testable logic** lives in the `BillableCore` Swift package (300+ tests; `swift test`).
- **Process:** features go through brainstorm → spec → plan → (subagent-driven) build → PR → Gemini review (each finding independently assessed before applying) → merge. Specs/plans are committed under `docs/superpowers/`.
- **Market:** US-first; ships globally. English-only App Store copy.
