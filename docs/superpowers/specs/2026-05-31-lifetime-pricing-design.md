# Lifetime IAP + Pricing-Ladder Reset

**Date:** 2026-05-31
**Status:** Approved (design + CRO assessment); pending implementation plan
**Branch:** `feature/lifetime-pricing` (off `origin/main` @ `8ddbd8a`, post-PR #12 paywall)

## Problem

Cadence Pro ships two auto-renewing tiers — Monthly **$5.99** and Yearly **$34.99** (51% off 12× monthly) — each with a 1-week free trial. Three gaps:

1. **No one-time option.** A real segment is subscription-averse and will never tap "Subscribe," but *will* pay once to own the app. That revenue is left on the table.
2. **The yearly discount is too steep and its badge lies in wait.** 51% off is more margin than the owner wants to give, and the badge is a hardcoded `Text("SAVE 51%")` (`PaywallView.swift:467`) that silently goes stale on any price change.
3. **The paywall under-converts.** A 6-lens conversion assessment found the funnel leaves conversion on the table (flat tier hierarchy, weak savings framing, trial reassurance buried, a stale "Lifetime when it lands" bullet, no funnel measurement).

## Goals

1. Add a **Lifetime** one-time purchase to the paywall and entitlement system.
2. Reset the ladder so the annual discount is modest, not half-off.
3. Restructure the paywall for **maximum free→paid conversion** per the CRO assessment.
4. Make the savings badge **computed** so it can never be wrong again.
5. Add **light, on-device, variant-keyed funnel metrics** so conversion is measurable and iterable.
6. Reuse the existing `SubscriptionManager` entitlement model and `PaywallView`; no new architecture, no 3rd-party SDK.

## Pricing decisions (owner-approved 2026-05-31)

| Tier | Now | New | Notes |
|------|-----|-----|-------|
| Monthly | $5.99/mo | **$3.99/mo** | the transient / "trying it out" option |
| Yearly | $34.99/yr | **$39.99/yr** | the **hero**; 12×$3.99=$47.88 → save **$7.89 ≈ "about 2 months free"** (computed) |
| Lifetime | — | **$99.99 once** | non-consumable; demoted **below** the subs as an "own it forever" anchor |

- US-first; USD primary (App Store Connect auto-maps other storefronts).
- The 1-week free trial stays on **Monthly + Yearly only** — non-consumables cannot carry an intro offer (reviewed and deliberately held).
- **Badge framing:** lead with the tangible **"SAVE $7.89 · about 2 months free"** rather than a bare "16%" (16% reads as "barely worth it"; the dollars/months framing converts the same price far better). Value is computed from live prices; hidden until both products load. Pinning to a literal "15%/16%" is a one-line constant if ever wanted, but the default is computed + months-free copy.

## Conversion decisions (from the 6-lens CRO assessment, 2026-05-31)

Adopted (fold into this spec):
- **Yearly is the visual hero**, not a co-equal peer — Lifetime is **demoted to a secondary "or pay once" affordance** below the subscription cards (3 lenses + the prior `docs/assessments/2026-05-31-monetization-paywall-lifetime.md` + market benchmark agree co-equal 3-tier suppresses conversion).
- Savings reframed as **dollars / months-free**.
- **Trial reassurance promoted** out of fine print.
- **One badge** on Yearly (drop the aversion-priming "NO SUBSCRIPTION" capsule).
- **Light funnel metrics**, variant-keyed; **centralized PricingConfig**.

Owner-confirmed pricing: Annual **$39.99** (kept; reframed, not raised — market shows it's already the most competitive annual in the category), Lifetime **$99.99** (kept; 2.5× annual is fine once demoted), trial **1 week** (kept).

Deferred to the separate **paywall-polish** PR (hook points noted, not built here): the invoice-send soft paywall trigger, a release-safe internal metrics readout screen, "what you get" bullet compaction, "best for…" self-segmentation microcopy, annual-LTV win-back gating.

## Design

### 1. Products (`App/Resources/Billable.storekit` + App Store Connect)

- Edit existing subs' `displayPrice`: monthly `5.99 → 3.99`, yearly `34.99 → 39.99`.
- Add a **non-consumable** to the `.storekit` `products` array (NOT a subscription group):
  - `productID`: `com.eldenstudios.billable.pro.lifetime`
  - `type`: `NonConsumable`, `displayPrice`: `99.99`, `familyShareable`: false
  - displayName "Billable Pro — Lifetime", description "Pay once. Own Pro forever."
- The `.storekit` drives local/simulator testing only. **Production requires the owner to mirror these in App Store Connect** (see Human-only gates).

### 2. Entitlement model (`SubscriptionManager`, BillableCore)

Current: `entitlement: Entitlement {.free, .trial, .pro}` drives `isPro`. `refreshProducts()` loads `[monthlyProductID, yearlyProductID]`; the `Transaction.currentEntitlements` loop only counts those two IDs.

Changes:
- Add `public static let lifetimeProductID = "com.eldenstudios.billable.pro.lifetime"`.
- Add `public private(set) var lifetime: Product?`; load it alongside the subs in `refreshProducts()` (same `Product.products(for:)` call; filter by ID).
- **Ownership:** add `public private(set) var ownsLifetime: Bool`, set from `Transaction.currentEntitlements` when an unrevoked `transaction.productID == lifetimeProductID` exists. To avoid an ordering bug in the loop, compute `ownsLifetime` first, then set the final `entitlement = ownsLifetime ? .pro : <subscription-derived state>` — **lifetime always takes precedence** (terminal `.pro`, never `.trial`, never downgrades).
- `isPro` keeps its shape (reads `entitlement`) but now returns true for lifetime owners too.
- **Restore:** existing `restore()` (AppStore sync → re-read `currentEntitlements`) already covers non-consumables; verify it re-resolves lifetime. No separate path.
- **Updates listener:** already iterates `Transaction.updates`; a lifetime purchase/refund flips `entitlement` live once the loop accepts the lifetime ID.

### 3. Paywall UI (`PaywallView.swift`) — Yearly-hero, Lifetime-below

**Tier cards (two, in fixed order):**
1. **Yearly — the hero.** Taller card, **solid accent fill (not 10% opacity)**, **white price text**, a **radio/checkmark** affordance, the single **"BEST VALUE"** badge, and the savings subtitle **"Save $7.89 · about 2 months free"** + "$3.33/mo, billed yearly". Pre-selected by default.
2. **Monthly — recedes.** Smaller, `secondarySystemBackground`, no fill, no checkmark, "$3.99/mo · billed monthly".

**Primary CTA (trial-led, dominant):**
- When trial-eligible and a subscription tier is selected: **"Try Pro Free for 7 Days"**, with an immediately-below, **higher-contrast** reassurance line: **"No charge today. We'll remind you before your trial ends. Cancel anytime."** (StoreKit sends its own trial-ending receipt — "we'll remind you" is truthful, no new infra.) Render for both Monthly and Yearly.
- Selection defaults to `.yearly`; the trial CTA is the happy path (single tap).

**Lifetime — demoted affordance (below the CTA, separated):**
- A divider, then an ownership-framed line: **"Prefer to pay once? Own Cadence Pro forever — $99.99 ›"**.
- Tapping it is a deliberate act that swaps the primary CTA to **"Buy Lifetime — $99.99"** with **no trial line**; tapping a sub tier swaps it back. Lifetime **never silently becomes the active selection** on load.
- Keeps the visible $99.99 as the anchor that makes $39.99/yr look cheap, captures the subscription-averse segment, and protects high-LTV trial/annual conversion.

**Plan model:** extend the `Plan` enum with `.lifetime`, but it is reachable only via the affordance, not a default-rendered tier card. Default selection stays `.yearly`.

**Computed savings badge:** replace hardcoded `Text("SAVE 51%")` with a value derived from `manager.yearly`/`manager.monthly`, rendered as the dollars/months-free copy; hidden until both products load. Mirror into the `--mock-paywall-prices` path.

**Owned state + double-buy guard:** when `manager.ownsLifetime`, the body shows **"You own Cadence Pro forever ✓"** instead of tiers + CTA (Restore still available); this *is* the double-buy guard.

**Active-sub + lifetime nudge:** after a lifetime purchase made while a subscription is active, show a one-time note: "You're set forever. You may want to cancel your subscription in Settings to avoid future charges." (We can't cancel it programmatically.)

**Bug fixes this work must include:**
- **Remove the stale "Lifetime — when it lands / on the way for subscribers" benefit bullet** (`PaywallView.swift:310-311`) — Lifetime ships in THIS paywall, so that copy now contradicts the visible affordance.
- **Lock tier order** (Yearly hero on top, Monthly second, Lifetime affordance below) in both spec and code; today the code renders Yearly-then-Monthly while the prose said otherwise.
- Keep exactly **one** green signal (the savings) and **one** badge ("BEST VALUE"); no "NO SUBSCRIPTION" capsule.

### 4. Pricing config + light funnel metrics

- **`PricingConfig`** — one surface holding the tier order, the layout/variant id (`"ladder_2026_05_v1"`, layout `"yearly_hero_lifetime_below"`), and any display copy currently scattered as literals in `PaywallView`. Kills the stale-literal bug class and makes a future price/layout test a config flip.
- **Funnel metrics** — extend the existing `ReportsConversionMetrics` (or a sibling `PaywallMetrics`) into on-device, aggregate, **no-SDK** counters, **stamped with the variant id + trigger + tier**:
  - `paywall_view`, `tier_selected` (incl. the lifetime affordance), `purchase_start`, `purchase_success`, `purchase_failure`, `trial_start`, `restore_tapped`, plus `lifetime_owned_view`.
  - `tier_selected` is the #1 missing signal today — without it the owner can't see whether anyone considers Lifetime vs default-Yearly.
  - Privacy-clean (on-device aggregate, no identifiers, no network) — preserves the no-tracking posture.

### 5. "What you get" block

The under-the-CTA benefits list stays (entitlement-wide, tier-agnostic). Compacting it to a 3-row strip + leading non-Reports doorways with "get paid / see what you're owed" value is **deferred to the polish PR**.

## Data flow

- `refreshProducts()` loads 3 products → `monthly/yearly/lifetime` populated → paywall renders prices, computed badge, and the lifetime affordance.
- `purchase(_:)` is product-agnostic (`product.purchase()`), so the lifetime non-consumable flows through the existing method; the entitlement loop reclassifies the user to `.pro`.
- `isPro`/`canAccessReports`/`canRemoveWatermark` gates unchanged — they read `isPro`, now true for lifetime owners.
- Each paywall interaction emits a variant-keyed metric counter.

## Edge cases / error handling

- **Owns lifetime, opens paywall:** owned state; no buy path (double-buy guard).
- **Subscribed, then buys lifetime:** succeeds; `.pro` (terminal); show cancel-your-sub nudge; no auto-refund (Apple disallows programmatic cancel).
- **Lifetime refunded** (`Transaction.updates` revocation): re-resolves; if no active sub → `.free`.
- **Restore on a new device:** `restore()` → `currentEntitlements` → `.pro`.
- **Products fail to load:** badge + lifetime affordance hidden; tiers show `ProgressView` (existing behavior).
- **Family Sharing:** lifetime `familyShareable: false` for v1 (matches subs).

## Testing (BillableCore `_fetchProducts`/entitlement hooks already exist)

- `ownsLifetime` true → `entitlement == .pro` → `isPro`/`canAccessReports`/`canRemoveWatermark` true.
- Lifetime **wins over** sub state: lifetime + expired sub → `.pro`; lifetime + active sub → `.pro`.
- No lifetime, no sub → `.free`. Lifetime revoked → falls back to sub state or `.free`.
- Restore resolves lifetime ownership.
- Savings helper: `(monthly 3.99, yearly 39.99) → $7.89 / "~2 months free"`; guards divide-by-zero / missing products (returns nil → badge hidden).
- Metrics: a `tier_selected(.lifetime)` and a `purchase_success(.yearly, variant)` increment the right variant-keyed counter; counters are aggregate-only (no identifiers).
- Paywall (mock-prices path): Yearly renders as hero (selected), Monthly recedes, Lifetime affordance present below the CTA with no trial line; owned state hides the buy button.

## Human-only App Store Connect gates (owner)

1. Create the **non-consumable** IAP `com.eldenstudios.billable.pro.lifetime` at the **$99.99** US tier; localized name/description; submit attached to the build.
2. Edit subscription prices: Monthly → **$3.99**, Yearly → **$39.99** (choose "preserve existing subscribers' price" to avoid churn).
3. Paywall screenshot + review notes (generated once the UI is built).

These cannot be done from code; the `.storekit` change only enables local testing until ASC is updated and approved.

## Out of scope / non-goals (separate initiatives)

- **Paywall-polish PR:** invoice-send soft paywall trigger, internal metrics readout screen, "what you get" compaction, "best for…" microcopy, annual-LTV win-back gating.
- Recurring-invoice → Pro A/B test.
- Promo/launch discount on lifetime, win-back offers, family sharing, live A/B experimentation engine, any 3rd-party analytics SDK.
- Changing trial length or the free-tier feature gates.
