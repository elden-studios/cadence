# Phase 6 — Paywall & conversion polish (design)

**Date:** 2026-06-01
**Program:** Cadence product-review fix program (Phases 1–5 shipped; `main` = `3da4b0a`).
**Source:** paywall/conversion cluster of `docs/reviews/2026-05-31-cadence-verified-backlog.md`, **re-baselined against current `main`** by an 11-agent workflow (some backlog items were already fixed by Phases 1–5).
**Branch:** `feature/phase6-paywall-polish` (worktree off `origin/main` `3da4b0a`).

## Scope & constraint

Paywall & conversion **polish** — correctness, consistency, and honest copy/metrics on the existing paywall. **Hard constraint (program-wide): no net-new features.** The one product fork (#4) was decided **toward correcting the spec** rather than adding gates, so Phase 6 stays purely within that constraint.

**Re-baseline result:** of 11 candidate items, **1 is already fixed** and dropped; **10 are open**, all **Low/Medium** (no High survives):
- **Dropped — F28/#3** (no upgrade nudge on the sent-invoice screen): **fixed by Phase 1** — `InvoiceDetailView.swift:60-62` already renders the shared `WatermarkUpgradeBanner` (guarded `!canRemoveWatermark, status != .draft`) → `PaywallView(trigger: .removeWatermark)`.

**Files:** `App/Sources/Features/Paywall/PaywallView.swift` (primary), `App/Sources/Features/Settings/SettingsView.swift`, `FEATURES.md`. **No BillableCore source changes** → verification is **app build + runtime**; the 344 BillableCore unit tests stay green (nothing in the package changes).

## Locked decisions

- **#4 → Option B (correct the spec, watermark-only model).** Doc + paywall-copy reconciliation; do NOT add `createInvoice`/`extraClient` gates. (Enforcing gates would be net-new monetization work → a separate feature initiative, out of this program's scope.)
- **F31 → Option A (alert in the paywall).** Surface restore/purchase outcomes via SwiftUI alert; **no** `SubscriptionManager.restore()` throw refactor (deferred).
- **F48 `.reports` subhead** → lead-with-context **and** enumerate the full unlock; rename the lead value-bullet title so it can't read as "invoicing is Pro".
- **Owned-Lifetime footer (NEW-S1-4)** → collapse to **Terms + Privacy only** for owners.
- **Monthly caption (F33)** → restate the price, **mirroring the yearly caption** pattern.

---

## Work-streams (build units)

### WS-A — Spec reconciliation + paywall copy (#4 = B, F48)  ·  Med/Low

**`FEATURES.md`:**
- §6 (~:133) "Paywall fires if the user is not Pro" → describe the **watermark-only** model: free users fully create/finalize/send invoices (watermarked "Sent with Cadence"); Pro removes the watermark and unlocks Reports + CSV export.
- §10 tier table: **drop** the "Up to 2 active clients ✅ | —" row; change "Create + send invoices — | ✅" → **"Watermark-free invoices — | ✅"**; correct the stale prices (~:304-305 `$5.99/$34.99` → **`$3.99` / `$39.99`**) and **add the `$99.99` Lifetime tier**; remove/replace the documented `.createInvoice`/`.extraClient` trigger copy (~:309-312) — those triggers don't exist — with the actual `.removeWatermark` / `.reports` / `.settings` copy; reconcile the §10 reports/settings headline copy (~:311-312) with `PaywallView`.

**`PaywallView.swift`:**
- Align the `.reports` `Trigger` subhead (~L29) to name all three Pro values while keeping the Reports-contextual lead, e.g. *"Full Reports dashboard, watermark-free invoices, and CSV export — all in one upgrade."* (The `.settings` and `.removeWatermark` subheads already enumerate; only `.reports` is the outlier — rule: **lead with context, then enumerate the full unlock**.)
- Rename the lead `valueBullets` title (~L336) "Watermark-free PDF invoices" → **"Clean, professional invoices"**; keep the body "Send polished invoices without 'Sent with Cadence' in the footer."

### WS-B — Paywall in-flight & metric correctness (NEW-S1-1, NEW-S1-2, NEW-S1-4)  ·  Med/Low  ·  one commit, all `PaywallView.swift`

- **NEW-S1-1 (Med):** add `.disabled(isProcessing)` to the toolbar close (X) `Button` (~L96-97). Pairs with the existing `.interactiveDismissDisabled(isProcessing)` (L130) so a tap-X can't `dismiss()` mid-`await` and double-fire success metrics. Mirrors the `purchaseButton` guard (L602).
- **NEW-S1-2 (Low):** add `@State private var didRecordLifetimeOwned = false`; keep the existing `.onAppear` fast-path (set the flag when it records) and add `.onChange(of: manager.ownsLifetime) { owned in guard owned, !didRecordLifetimeOwned else { return }; didRecordLifetimeOwned = true; PaywallMetrics.record(.lifetimeOwnedView, variant: PricingConfig.variant, trigger: trigger.metricKey, tier: "lifetime") }` beside the existing `.onChange` modifiers (L120-121). Fixes the cold-present race where `ownsLifetime` is still default-`false` at `onAppear`.
- **NEW-S1-4 (Low):** gate `secondaryActions` + `finePrint` so that when `manager.ownsLifetime` they collapse to a **Terms + Privacy-only** footer (extract a `termsPrivacyLinks` view from the two existing `Link`s in `secondaryActions` ~L714-717). Leave `lifetimeAffordance` (already owned-aware, ~L673-675). Removes the no-op "Restore purchases" and the irrelevant "Subscriptions auto-renew…" fine print for a one-time Lifetime owner.

### WS-C — Restore feedback (F31 = A)  ·  Med

- `PaywallView`: add `@State private var restoreNotice: String?` + a dedicated `.alert("Restore purchases", isPresented:)` (clean copy, separate from the purchase-error alert). In `restore()` (~L772), add the missing `else`: on `restored == false` set `restoreNotice = "No active purchases were found for your Apple ID."`; on success keep the `dismiss()` (the view flips to Pro). (No `SubscriptionManager` change — the empty/error distinction is deferred per Option A.)
- `SettingsView` (~L91): surface the restore result instead of `_ = await …` — reuse the same neutral message (a small alert) rather than discarding it.

### WS-D — Settings cleanup (F32)  ·  Low  ·  `SettingsView.swift` L78-95

- Remove the trailing `Image(systemName: "chevron.right")` from the "Upgrade to Pro" row (~L83-86) — its action presents a `.sheet`, so the push chevron is a false affordance.
- Move the "Restore purchases" `Button` (~L90-95) **inside** the non-Pro `else` branch (the `else` closes at ~L89) so a Pro subscriber no longer sees "Active" + "Manage subscription" + "Restore purchases" stacked.
- (Pairs with WS-C's Settings restore-feedback edit — same region, do together.)

### WS-E — Copy/display polish (F33, NEW-S1-3)  ·  Low  ·  `PaywallView.swift`

- **F33:** in `perCycleLabel(for:product:)` (~L567-583) replace the `.monthly` bare `"Billed every month"` (~L578) with a price-restating caption mirroring the yearly pattern (price + cadence), and update the `mockPlanRow` twin string (~L366, used under `--mock-paywall-prices`) to match.
- **NEW-S1-3:** in `savingsPill` (~L548-555), guard that the monthly and yearly products share a currency before rendering the badge (compare `manager.yearly` vs `manager.monthly` `priceFormatStyle.locale.currency`); render nothing when they diverge, so the badge can't annotate a value with a mismatched currency code. (Single-storefront unaffected.)

## Coupling (build order)

1. **#4 ↔ F48 (WS-A):** both edit `FEATURES.md` §10 and the watermark-only narrative — one change. (Resolved: Option B.)
2. **NEW-S1-2 ↔ NEW-S1-4 (WS-B):** both live in the `PaywallView` `ownsLifetime` region / react to the same async signal — one pass.
3. **F32 ↔ F31-Settings-tail (WS-D):** same `SettingsView` region — one edit.
4. **NEW-S1-1, NEW-S1-3, F33:** independent, self-contained.

Suggested order: **WS-B, WS-D, WS-E in parallel** (independent, Low/Med, no fork) → **WS-C** → **WS-A** (doc + copy). All ship in one PR.

## Test plan

- App + widget build `** BUILD SUCCEEDED **` after every work-stream and at the end.
- BillableCore `swift test` stays green (**344**) — no package source change (regression check only).
- **Runtime (seeded sim screenshots):** paywall value copy consistent across the three triggers; Settings shows no chevron on Upgrade and "Restore" only for non-Pro; monthly/yearly captions symmetric; savings badge renders.
- **Manual / StoreKit-config QA (document on PR — not gesture-automatable here):** X disabled during an in-flight purchase; empty-restore shows the "No purchases found" alert; owned-Lifetime state shows Terms+Privacy-only footer (needs a Lifetime-owned entitlement); `lifetimeOwnedView` fires once on a cold present for an owner.

## Out of scope (parked)

- **Enforcing free-tier gates (#4 Option A)** — net-new monetization; separate feature initiative if ever wanted.
- **`SubscriptionManager.restore()` throw refactor (F31 Option C)** — deferred; empty-vs-error distinction not surfaced this phase.
- **Phases 7–8** (ProjectDetail/sessions, Onboarding/entity polish).
