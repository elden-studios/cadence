# Cadence UX overhaul — first-run, paywall, and start-timer motion

- **Date:** 2026-06-02
- **Status:** Design — REVISED after a 5-agent QA review (code-verified). For final approval.
- **Origin:** First-run walkthrough surfaced 7 UX/design concerns. Investigated + brainstormed, then independently QA'd against the real code.
- **Build baseline (corrected):** `main` is well ahead of v1.3.0. This work was drafted in the worktree on the crash-fix branch (`fix/swiftdata-cloudkit-prefetch-crash`, PR #25). **Implementation must start from a fresh worktree off the latest `main` AFTER PR #25 merges**, so that PR B inherits the CloudKit nested-keypath crash fix (it constrains B2 — see M-5). Verify line numbers below against that checkout before editing.

## Overview

Seven concerns, three independent sub-projects → **three separate PRs** (A → B → C; B/C can follow A in parallel).

| # | Concern | Sub-project | Effort |
|---|---------|-------------|--------|
| C2 | "Get started" leads with a timer that makes un-billable time | A · First-run | M |
| — | "+" toolbar sheets dead-end with zero projects (bug found in review) | A · First-run | S |
| C1 | Profile-completion guidance only ever pushes "address" | A · First-run | S |
| C3 | All-time "Uninvoiced" tile sits under a "Today" header | A · First-run | S |
| C5 | Lifetime $99.99 missing / a buried link | B · Paywall | S code + ASC dep |
| C6 | Plan-card "save" badge washed-out green-on-blue; selection inconsistent | B · Paywall | S |
| C4 | Reports paywall showcase reads as real data, not a Pro benefit | B · Paywall | **M** (new aggregation) |
| C7 | Settings "Timer motion" picker (the start-timer animation) | C · Motion | S |

---

## Sub-project A — First-run / activation (Today screen)

Coupled: share `TodayView.swift` + `TodayGuidance.swift`. Design/ship together.

### A1 (C2) — Get-started block: setup-first

**Current (verified):** `GetStartedSection.swift` leads with a filled "Start a timer now" that calls `fetchOrCreateGeneralProject()` (creates a clientless, $0-rate "General" and starts a timer); the "Add a client / Create a project" checklist is secondary. `fetchOrCreateGeneralProject` / `GeneralRateSheet` / `GetStartedNewProjectSheet` are all private to `GetStartedSection.swift`; the only caller of `GetStartedSection` is `TodayView.swift`. `stampFirstSetupIfReached` already excludes a clientless General, so removing the creation path preserves the block's self-dismissal.

**Decision:** First-run is **setup-first**.
- Empty-state block leads with **"Add your first client"** (PRIMARY) → **"Create a project"**.
- **Remove the "Start a timer now" quick-start** and any track-now escape from the empty first-run. The timer is reachable the normal way **once a project exists** (verified: `ProjectDetailView` start button, the Today "+" menu, Jump-back-in).
- **Retire the now-unused "General" creation machinery:** `fetchOrCreateGeneralProject()` + `GeneralRateSheet` (+ the get-started `GetStartedNewProjectSheet` if unused after the redesign).

**Scope correction (QA — was overstated):** Removing the quick-start prevents **new** orphan $0 projects on **fresh installs only**. Existing clientless "General" projects on already-installed devices remain and **stay startable** via Jump-back-in and the timer-sheet "recents" — because `RecentProjects.rank` filters only archived / client-archived projects, not clientless ones.
- **Resolution (default):** **Leave existing Generals startable** — don't disrupt current users; the goal is fresh-install correctness. State the claim accordingly ("no *new* orphan $0 projects").
- **Optional follow-up (owner decision — see open question):** also exclude clientless projects from `RecentProjects.rank` / Jump-back-in / timer recents, and/or add an "assign to a client" prompt for orphaned General time.

**Downstream cleanup (QA — don't strand these):**
- `ActivationMetrics.FirstTimerKind.quickStart` becomes unreachable for new users. **Keep it** (DEBUG-only metric) for legacy/installed-base data; document it as now-legacy.
- `stampFirstSetupIfReached`'s "General doesn't count" special-casing: logic stays correct; update its rationale comment.
- Fix the stale `WorkView` comment that calls the no-client bucket "load-bearing for the quickStart General." Keep the bucket for legacy data.

**Tests (QA — delete, don't "update"):** In `GetStartedChecklistUITests`, **delete test A** entirely (it asserts the quick-start button, General creation, and the "Timer running" reframe — all removed). **Keep test B** (add-client advances / enables rows). **Add:** (1) empty Today leads with "Add your first client" + no timer CTA; (2) timer reachable after a project exists; (3) per the B-1 resolution, a clientless General with recent entries behaves as decided.

**Files:** `App/Sources/Features/Today/GetStartedSection.swift`, `TodayView.swift`, `Packages/BillableCore/.../Today/TodayGuidance.swift` (no precedence change), `App/BillableUITests/GetStartedChecklistUITests.swift`; touch-points: `ActivationMetrics.swift`, `WorkView.swift` (comment), `BusinessProfileStore.swift` (comment).

### A1b (cross-cutting bug) — Fix the "+" empty-states

**Current (verified):** with zero projects, `StartTimerSheet` renders a bare `List` (no empty state) and `ManualEntrySheet` has `canSave` permanently false with an empty picker. Both dead-end. **After A1, these become the *only* first-run on-ramp — load-bearing for activation, not polish.**

**Decision:** Give both sheets an empty state when **no project** exists, with a CTA that **branches on client count**:
- **No clients** → "Add your first client" → presents `ClientEditorView`.
- **≥1 client, no project** → "Create a project" → the project flow.
- Specify the **sheet choreography** (QA): the "+" sheets are presented from `TodayView`; the empty-state CTA presents `ClientEditorView` / the project editor as a **nested sheet within the existing `NavigationStack`** (push), or dismisses and routes to the get-started block — pick the nested-push and define the save→pop handoff so there are no orphaned/double sheets.

**Files:** `StartTimerSheet.swift`, `ManualEntrySheet.swift`.

### A2 (C1) — Profile-completion guidance (decoupled)

**Current (verified):** `isProfileEnriched` = **name + address only** gates exactly three nudge sites: `SettingsView.swift:43` ("Incomplete"), the Today enrichment nudge (`TodayView` → `TodayGuidance`), and `InvoiceGeneratorView.swift:262`. Bank/logo don't feed it. (A prior Phase-8 broadening caused stale nags and was reverted.)

**Decision:** **Decouple "blocks payment" from "enriched."**
- **Do NOT touch `isProfileEnriched`** (stays name + address) → push-nudges don't re-arm for blank bank/logo, and `BusinessProfileEntityTests` stays green.
- Add a **new computed `missingProfileFields`** on `BusinessProfile` over: **name, address, `hasBankDetails`, `logoData != nil`** (tax excluded).
- **Settings only:** replace the bare "Incomplete" with an indicator that names the missing fields from `missingProfileFields` (pull, not push → no fatigue).
- Lightly broaden the existing Today enrichment nudge **copy** to mention bank & logo (copy-only; trigger unchanged — still fires on `!isProfileEnriched`).

**Files:** `Packages/BillableCore/.../Models/BusinessProfile.swift` (new computed prop; `hasBankDetails`/`logoData` already exist), `SettingsView.swift`, `TodayView.swift` (copy).

### A3 (C3) — Today summary tiles

**Current (verified):** `TodaySummarySection` shows Hours (today), Earnings (today), and an all-time "UNINVOICED · ALL PROJECTS" tile under one "Today" heading. The uninvoiced tile **already suppresses its tap at $0** (`onTap: uninvoiced > 0 ? …`) but still renders an inert "$0.00". It's the only **free** invoice on-ramp (Reports is Pro-gated). NOT a Reports duplicate (pre-invoice vs post-invoice).

**Correction (QA):** there is **no vocabulary mismatch** to fix — both this tile and `ProjectDetailView`'s already render "UNINVOICED". The real change is **heading/placement + hide-at-$0**, not the noun.

**Decision:**
- Keep **Hours + Earnings** under "Today" (strictly today). **They remain visible even at $0** on a fresh account (they're legitimately today-scoped and quickly become non-zero) — only the uninvoiced card is conditionally hidden.
- Move the all-time uninvoiced tile under its **own "Ready to invoice" heading**, keeping the tap-to-generate on-ramp. **Drop/shorten the in-tile "· ALL PROJECTS" caption** so it doesn't duplicate the new heading.
- **Hide the "Ready to invoice" card entirely when the amount is $0** (currently it renders an inert $0.00 tile).
- `ProjectDetailView` needs **no change** (label already "Uninvoiced").

**Files:** `TodayView.swift` (`TodaySummarySection`).

---

## Sub-project B — Paywall + Reports

All in `PaywallView.swift` (+ pricing/subscription/sample/reports). **Must land on top of the merged crash fix** (PR #25).

### B1 (C5 + C6) — Plan cards: three equal tiers + badge fix

**Current (verified):** the picker renders only Yearly + Monthly (`planRow(.yearly/.monthly)`); Lifetime is the separate `lifetimeAffordance` (a demoted link, hidden when the product is nil). Only the Yearly hero shows a checkmark; Monthly shows no selection affordance. The savings pill is `Color.green.opacity(0.18)` on the blue hero (washed out), and the same green-on-blue is hardcoded in the **mock twin** (`mockPlanRow`). The body wraps the picker + CTA in `if !manager.ownsLifetime`, and `lifetimeAffordance` also renders the **owned-state label** ("You own Cadence Pro forever") that doubles as the double-buy guard.

**Decision (Direction A — three equal tiers):**
- Present **Monthly / Yearly / Lifetime** as three peer rows. **Yearly** stays the visual hero (filled, default-selected) with a **single "BEST VALUE" pill** (clean white-on-accent); the saving moves into the price sub-line: **"Just $X/mo · 2 months free"**. **Lifetime** is a first-class peer ("PAY ONCE", gold accent, "$99.99 once").
- **Consistent selection affordance** on all three rows.
- **CTA adapts:** "Start 7-day free trial" for a subscription; **"Buy Lifetime — $99.99"** for Lifetime (no trial).
- **Preserve the `ownsLifetime` collapse (QA):** when the user already owns Lifetime, suppress all three purchase rows + the CTA and show only the owned label + terms links (current behavior). Reproduce this branch in the new picker.
- **Mock path (QA):** add a **mock Lifetime row** to `mockPlanRow` / the `--mock-paywall-prices` branch (currently yearly+monthly only) and handle the mock CTA/disabled-state for `selection == .lifetime`, or App Store screenshots will show 2 tiers vs the shipped 3.
- **Badge fix in BOTH paths (QA):** update the live `savingsPill` **and** the static mock string; don't leave green-on-blue in either.
- **Currency (QA):** the "$X/mo · 2 months free" sub-line must be **computed per-locale** from `manager.yearly.price / 12` via the existing locale-aware formatter, and hidden when products aren't loaded or currencies mismatch (as `savingsPill` already guards). The dollar figures in this spec are **illustrative** — no USD literals in the live path (app ships 175 countries).

**Revenue note:** promoting Lifetime can pull from the higher-LTV recurring funnel (why it was demoted). Yearly stays visually dominant to hedge. Deliberate, owner-approved override of PR #14.

**Files:** `PaywallView.swift` (`pricePicker`, `planRow`, fold `lifetimeAffordance` in while preserving owned-state, `savingsPill`, `mockPlanRow`, `purchaseButtonTitle`/CTA), `PricingConfig.swift`.

### B2 (C4) — Reports paywall header + showcase

**Current (verified):** headline "Know what you've earned — and what you're owed." (47 chars; wraps/shrinks). The showcase is metric tiles (`teaserARCard`/`teaserTileRow`) fed by the user's real data when present (else sample), with only a tiny `.caption2` "Sample preview" tag shown for the sample case. **`ReportsSampleData` is an App-target file** (`App/Sources/Features/Reports/`), not in BillableCore.

**Decision:**
- **Shorten the headline** to one line: **"Know what you're owed."** (`lineLimit(1)`, drop the shrink factor).
- **Frame as a locked Pro preview:** an always-on "🔒 Your Reports preview" eyebrow + a tinted/bordered container with a lock, for both real- and sample-data states. Keep `.accessibilityHidden(true)`.
- **Lead with a chart, not tiles** — a "Collected · last 6 months" bar chart + a compact stat line (Owed / This year / Effective rate).

**Correction + new scope (QA — this is the riskiest item):**
- **NOT "reuse ReportsAggregator series."** `ReportsAggregator` exposes only an **8-week billable-earnings** series (`earningsTrend`) — there is **no monthly series and no "collected" series**. A **new monthly-collected aggregation** must be written. This makes B2 **M effort**, not S.
- **Define the sample monthly series explicitly**, and specify **real-data behavior with <2 months of history**: fall back to a clearly **labeled/watermarked "Sample"** chart so a sparse or declining real trend never renders as "your numbers."
- **CloudKit constraint (QA, hard):** the paywall already runs `ReportsAggregator.snapshot` over the user's live `@Query` data, and the aggregator traverses `entry.project?.client`. Any new fetch/series for the chart **must use single-hop `relationshipKeyPathsForPrefetching` (`[\.project]` only — never `\.project?.client`)** and be **verified on a real CloudKit device**, or it re-triggers the nested-keypath crash PR #25 fixes (Simulator/tests won't catch it).

**Files:** `PaywallView.swift` (`crispTasteHeader`, replace `teaserARCard`/`teaserTileRow` with a chart hero + stat line; always-on locked eyebrow), `App/Sources/Features/Reports/ReportsSampleData.swift` (sample monthly series), new monthly-collected aggregation (App↔Core boundary — confirm where it lives).

### B3 (C5) — Lifetime loading hardening + ASC dependency

**Current (verified):** `lifetimeAffordance` renders nothing when `manager.lifetime` is nil; `lifetimeDisplayPrice` returns nil off-mock. The StoreKit config is attached **only** to the Launch (Debug) action; Release/Archive have none — so TestFlight has no local config and relies on ASC.

**Decision:**
- **Dependency (owner):** create the ASC non-consumable `com.eldenstudios.billable.pro.lifetime` @ $99.99, approved. The only real unblock for Lifetime off-Simulator. (Assistant will guide.)
- **Code guard:** when other products load but `manager.lifetime` is nil, log a DEBUG diagnostic (optional DEBUG-only "unavailable" state) so a missing product can't silently blank the tier. Never show a purchasable price the store can't transact.
- **Do NOT attach the StoreKit config to Release/Archive (QA — unsafe):** that would make production read the bundled local config. At most attach to **Profile** for local profiling; leave Release/Archive clean.

**Files:** `PaywallView.swift` (`lifetimeDisplayPrice`), `SubscriptionManager.swift`, `Billable.xcscheme` (Profile only, if at all).

---

## Sub-project C — Start-timer motion (C7)

**Current (verified):** `TimerMotionStyle` (`spring`/`fadeScale`/`heroMorph`); default `.spring`. `heroMorph` = `.spring(response: 0.5, dampingFraction: 0.66)` + scale-from-0.6 + offset bloom (confirmed exact). The Settings picker is `#if DEBUG` (never ships). `ProjectDetailView` consumes the style **abstractly** (`motionStyle.transition()/animation()`), never by case — so trimming cases is safe for the consumer.

**Decision:**
- **Ship `heroMorph` as the default** at its current ~0.5s bouncy feel (no smoothing/slowing). Remove the DEBUG picker.

**Correction (QA — NOT "just one @AppStorage default"):** there are **two** `@AppStorage` defaults (`SettingsView` + `ProjectDetailView`) **plus a hardcoded `?? .spring` decode fallback**. To make Hero Morph the default *everywhere*:
- Change the `@AppStorage` default → `.heroMorph` **and** the decode fallback `?? .spring` → `?? .heroMorph` (in `ProjectDetailView`).
- **Delete (not edit)** the entire `#if DEBUG` `@AppStorage` declaration + picker section in `SettingsView` so no orphan declaration with a stale `.spring` default lingers. After this, `ProjectDetailView` is the sole reader of the key.
- If trimming `.spring`/`.fadeScale` cases, the fallback edit is **mandatory** (compile-breaking otherwise). Keep `.heroMorph`.
- Note: DEBUG/internal testers with a persisted key keep their old motion after picker removal (low impact; reset the key if needed). Production users never wrote the key.

**Files:** `SettingsView.swift`, `RunningTimerCard.swift` (`TimerMotionStyle`), `ProjectDetailView.swift`. (Verify exact lines on the target checkout.)

---

## Out of scope / non-goals

- No SwiftData model changes beyond the new `missingProfileFields` computed prop (A2) and the new monthly-collected aggregation (B2).
- No pricing changes ($3.99 / $39.99 / $99.99 unchanged).
- No change to tracking/invoice/Reports calculations beyond the new B2 aggregation.
- Existing DEBUG activation instrumentation is left in place; note the `quickStart` arm goes effectively legacy-only after A1 (by design).

## Open dependencies & decisions

- **ASC Lifetime product** (B3) — owner; gates Lifetime off-Simulator. Everything else ships without it.
- **B-1 — DECIDED: leave existing clientless "General" projects startable** (don't disrupt current users; the goal is fresh-install correctness). Filtering clientless projects from recents / an "assign to a client" prompt is a noted **optional future enhancement, not in scope**.

## Recommended phasing

1. **PR A — First-run** (A1 + A1b + A2 + A3).
2. **PR B — Paywall + Reports** (B1 + B2 + B3 code; ASC product in parallel). **Branch off the merged crash fix.** B2 is the heaviest/riskiest (new aggregation + CloudKit-safe fetch + device verification).
3. **PR C — Start-timer motion** (tiny; independent).

## Testing notes

- A1: empty Today leads with "Add your first client", no timer CTA; timer reachable after a project; **delete** `GetStartedChecklistUITests` test A; per B-1, a clientless General behaves as decided.
- A1b: zero-clients → "Add a client" CTA; ≥1 client → "Create a project"; no blank lists; no orphaned/double sheets.
- A2: the three push-nudge sites stay name+address-gated (no regression); Settings names missing bank/logo via `missingProfileFields`.
- A3: "Ready to invoice" hidden at $0; Hours/Earnings still shown at $0; on-ramp tappable when > $0; no caption/heading duplication.
- B1: all three tiers render with consistent selection; CTA swaps for Lifetime; **owned-Lifetime → no purchase rows/CTA**; mock path shows three tiers.
- B2: chart never shows a misleading "your trend" for <2-month users (labeled sample fallback); **verified on a real CloudKit device**; new fetch uses single-hop prefetch only.
- B3: missing Lifetime is logged, never a dead buy button; Release/Archive carry no StoreKit config.
- C7: Hero Morph is the default in a release-config run (key absent); DEBUG picker gone; `?? .heroMorph` fallback.
