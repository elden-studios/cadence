# Phase 2 — Today / Activation & the Uninvoiced Loop (design)

**Date:** 2026-05-31
**Status:** Draft (design); pending user spec review → implementation plan
**Baseline:** real `main` = `origin/main` `c7b9889` (Phase 1 merged). Branch `feature/phase2-today-activation` (worktree `.worktrees/phase2-today-activation`).
**Source:** verified backlog `docs/reviews/2026-05-31-cadence-verified-backlog.md` — items F45, F46, F20/F47, F23/F34/F50, F15, NEW-S3-1, NEW-S3-2. Phase 2 of the 4-phase program (Phase 1 shipped in PR #16).

Phase 2 makes the home screen surface the core value: the **track** verb is reachable, the **uninvoiced** hero number is an on-ramp to invoicing (closing the track→invoice loop), the money readout is scope-labelled and trustworthy, and the dashboard is clean (no dev control, no per-second over-fetch) with the new get-started guidance behaving correctly.

All target code is on `main` as of `c7b9889`. Surfaces: `TodayView.swift`, `GetStartedSection.swift`, `Today/TodayGuidance.swift`, `Widgets/Sources/TodaySummaryWidget.swift`, `ProjectDetailView.swift` (for the per-project label), plus reuse of existing `StartTimerSheet` and `InvoiceGeneratorView`.

---

## Scope (7 items)

| # | Item | Source | Priority |
|---|------|--------|----------|
| 1 | Start-timer affordance on Today (`+` menu + empty-recents CTA) | F45 | High |
| 2 | UninvoicedTile → tappable on-ramp into the invoice generator | F46 | High |
| 3 | "UNINVOICED" scope labels (Today / ProjectDetail / widget) | F20, F47 | High |
| 4 | Bound the per-second unbounded fetch on Today (+ widget) | F15 | Medium |
| 5 | Gate "Seed demo" behind `#if DEBUG` | F23, F34, F50 | Medium |
| 6 | GetStartedSection stops lingering after in-app completion | NEW-S3-1 | Medium |
| 7 | GetStartedSection header copy correct when a client exists | NEW-S3-2 | Medium |

**Non-goals:** Phases 3–4; the Reports/Paywall/ProjectDetail-sessions items (parked Phases 5–8); any new feature. Reuse existing `StartTimerSheet` / `InvoiceGeneratorView` / `ManualEntrySheet` — do not build new screens.

---

## Item 1 — Start-timer affordance on Today (F45)

### Problem
Today's prominent toolbar `+` opens `ManualEntrySheet` ("Add past entry", `TodayView.swift:43-50`). The only live-timer start paths are the `JumpBackInSection` per-project play buttons — which render nothing when there are no recent projects in the 60-day window (`:234`) — and `GetStartedSection`, which only appears during the get-started window (`:102-115`). So an established user with no recent projects (back from a break, or recents aged out) has **no way to start a live timer from Today**, and the core "track" verb is never the prominent action.

### Design (decision: BOTH `+` menu + empty-recents CTA)
- **Toolbar `+` → Menu.** Replace the single `+` button with a `Menu` labelled `+` containing, in order: **"Start timer"** (`systemImage: "play.fill"`) → presents the existing `StartTimerSheet`; **"Add past entry"** (`systemImage: "clock.arrow.circlepath"`) → presents `ManualEntrySheet`. Start-timer is first so the core verb leads.
- **Empty-recents body CTA.** When `JumpBackInSection`'s `recents` is empty AND the guidance element is not `.getStarted` (so we don't double up with the get-started card), render a single low-chrome "Start a timer" button in the body (where Jump-back-in would be) that presents the same `StartTimerSheet`. (When recents exist, the play buttons already cover it; when in get-started, that card already has a "Start a timer now" action — don't duplicate.)
- Add `@State private var showingStartTimer = false`; present `StartTimerSheet` from a single `.sheet`. Confirm `StartTimerSheet`'s initializer/dismissal works when presented from Today (it's already the Start/Switch picker used elsewhere).

### Testing
Build + manual: with no recent projects and onboarding/get-started complete, Today shows a "Start a timer" CTA and the `+` menu offers Start timer first; tapping either opens the project picker and starts a live timer. With recents present, the menu still offers both; the body CTA is absent (play buttons present).

---

## Item 2 — UninvoicedTile becomes the on-ramp to invoicing (F46)

### Problem
`UninvoicedTile` (`TodayView.swift:382-401`) is a plain non-interactive `VStack`. The "what am I owed" hero number never connects to the action that converts it to cash; the track→invoice loop is never demonstrated from Today (TodayView has zero `InvoiceGeneratorView` references).

### Design
Make the tile a control when `amount > 0`: tapping presents the **global** `InvoiceGeneratorView()` (the multi-client variant, as launched from `InvoicesView`) as a sheet. When `amount == 0`, the tile stays non-interactive (nothing to invoice). Add `@State private var showingGenerator = false` on `TodaySummarySection` (or lift to `TodayView` and pass a closure) and a `.sheet`. Keep the visual design; add a subtle affordance cue (e.g. a chevron) only if it reads cleanly — otherwise leave the visual as-is and rely on tap.

### Testing
Manual: with uninvoiced > 0, tapping the tile opens the invoice generator (client+range picker); with $0.00 it does nothing. Generating an invoice from here reduces the uninvoiced number (loop closed).

---

## Item 3 — "UNINVOICED" scope labels (F20/F47)

### Problem
`TodayView.UninvoicedTile` shows all-time/all-project money under a bare "UNINVOICED" caption; `ProjectDetailView`'s tile shows one-project money under the **same** bare "UNINVOICED" label; the `TodaySummaryWidget` shows an all-time uninvoiced figure with no label beside a today-scoped "EARNED" — so the same word silently changes scope across surfaces. (The "Outstanding"→"Unpaid" half was already fixed in Phase 1 / F21.)

### Design
Add an explicit scope qualifier so the word never silently changes meaning:
- Today `UninvoicedTile`: label → `UNINVOICED · ALL PROJECTS` (keep the existing "Hours you've tracked but haven't invoiced yet." caption).
- `ProjectDetailView` uninvoiced tile: label → `UNINVOICED · THIS PROJECT`.
- `TodaySummaryWidget`: add a short caption to the uninvoiced figure (matching the "EARNED"/"HOURS" label treatment) so the two adjacent numbers read as distinct horizons.
Pure copy/label change; no behavior change.

### Testing
Snapshot/manual: the three surfaces show the scope-qualified labels; widget's two figures are each labelled.

---

## Item 4 — Bound the per-second fetch (F15)

### Problem
`TodaySummarySection` declares `@Query private var allEntries` with **no predicate** (`TodayView.swift:308-315`) and, inside a `TimelineView(.periodic by: 1)`, every second filters `allEntries` for today AND reduces the all-time uninvoiced amount (`:326-337`). Cost is proportional to total lifetime entries, re-run every second while Today is visible. The widget (`TodaySummaryWidget`) similarly fetches all entries at each refresh.

### Design
Bound the queries:
- Replace the single unpredicated `@Query` with **two** descriptors: a **today-bounded** one for the Hours/Earnings tiles (a `startedAt >= startOfToday` predicate — computed once; note the `@Query`-captures-descriptor-at-init caveat already handled by the recents pattern, so use a `startOfToday` floor that's stable enough, or a relationship-free predicate as `eligibleEntries` does), and an `invoiceID == nil`-bounded one for the uninvoiced amount.
- The per-second `TimelineView` still recomputes the live-accruing amounts (a running entry's amount legitimately ticks), but only over the small bounded sets, not the whole store. The all-time uninvoiced reduction now runs over only uninvoiced entries.
- For the widget, bound its fetch the same way (today + uninvoiced predicates) rather than fetch-all. (Note from the original review: the widget needs at least a 30-day bound, not just today, if it surfaces recents — confirm the widget's actual needs when implementing.)

This is an internal optimization; no UI/behavior change. Verify numbers are identical before/after on seeded data.

### Testing
BillableCore/unit where extractable; otherwise build + manual: today's Hours/Earnings and the uninvoiced total match the pre-change values on seeded data; a running timer still ticks both today's earnings and uninvoiced live.

---

## Item 5 — Gate "Seed demo" behind `#if DEBUG` (F23/F34/F50)

### Problem
`TodayView.swift:51-57` renders a "Seed demo" toolbar button whenever `allClients.isEmpty`, with no `#if DEBUG` guard, calling `SampleData.seedDemo` against the live store — so a genuine new user sees it at their first-impression empty state and can pollute their real data.

### Design
Wrap the `ToolbarItem` (and the `Button`) in `#if DEBUG … #endif` so it never ships in a release build. The real empty state is already handled by `GetStartedSection` / the guidance system. Pure deletion from production.

### Testing
Build the Debug config (button present) and confirm via `#if DEBUG` that a Release build excludes it (grep/inspect). No new user sees it.

---

## Item 6 — GetStartedSection stops lingering after in-app completion (NEW-S3-1)

### Problem
The get-started latch (`firstSetupCompletedAt` / the `guidanceElement` inputs) is only re-derived from the profile on launch/foreground, so when the user completes the checklist *in-app* (e.g. starts their first timer), `GetStartedSection` lingers for the rest of the session instead of disappearing immediately.

### Design
Make the guidance re-evaluate reactively when its inputs change in-session. Drive `guidanceElement` off observed state (the `@Query`'d profile + a live signal for "has the user now started tracking / completed setup") so completing the step in-app flips the section away without needing a relaunch. Confirm the exact completion signal in `GetStartedSection`/`TodayGuidance` at plan time and wire the view to observe it (e.g. an `@Query` count of entries, or the profile's `firstSetupCompletedAt` being set the moment setup completes).

### Testing
Manual: complete the get-started action in-app → the section disappears immediately (same session), not on next launch.

---

## Item 7 — GetStartedSection header copy when a client exists (NEW-S3-2)

### Problem
The "Timer running" / get-started header tells users to "Add a client" even when a client already exists (the copy assumes the zero-client state).

### Design
Condition the header/sub-copy on whether `clients` is non-empty (the section already receives `clients`). When a client exists, the copy should reflect the actual next step (e.g. "Start your first timer") rather than "Add a client". Verify the exact strings/branches in `GetStartedSection.swift` at plan time and make the copy state-accurate.

### Testing
Manual: with ≥1 client present, the get-started copy no longer says "Add a client"; with zero clients it still does.

---

## Cross-item notes
- **One PR.** Most changes are in `TodayView.swift` + `GetStartedSection.swift` + the widget; the per-project label touches `ProjectDetailView.swift`. Items 1, 2, 4, 5 cluster in `TodayView`/`TodaySummarySection`.
- **Reuse, don't build:** `StartTimerSheet` (Item 1), `InvoiceGeneratorView` (Item 2), existing guidance system (Items 6/7). No new screens.
- **Test command:** `xcodebuild -project Billable.xcodeproj -scheme Billable -configuration Debug -destination 'platform=iOS Simulator,id=A946AE5D-C969-4EB2-8384-001B3451A6A4' -derivedDataPath build/DerivedData build`; `swift test --package-path Packages/BillableCore` for any extracted logic.
- **TDD:** any logic pulled into BillableCore (e.g. a today/uninvoiced bounding helper, or a guidance-input change) gets a failing test first; view changes are build- + manually-verified.
