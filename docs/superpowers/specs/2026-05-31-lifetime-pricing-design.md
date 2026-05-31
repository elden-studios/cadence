# Lifetime IAP + Pricing-Ladder Reset

**Date:** 2026-05-31
**Status:** Approved (design); pending spec review → implementation plan
**Branch:** `feature/lifetime-pricing` (off `origin/main` @ `8ddbd8a`, post-PR #12 paywall)

## Problem

Cadence Pro ships two auto-renewing tiers — Monthly **$5.99** and Yearly **$34.99** (51% off 12× monthly) — each with a 1-week free trial. Two gaps:

1. **No one-time option.** A real segment of buyers is subscription-averse and will never tap "Subscribe," but *will* pay once to own the app. That revenue is currently left on the table.
2. **The yearly discount is too steep and its badge is a lie-in-waiting.** 51% off is more margin than the owner wants to give, and the badge is a hardcoded `Text("SAVE 51%")` (`PaywallView.swift:467`) that silently goes stale the moment any price changes.

## Goals

1. Add a **Lifetime** one-time purchase to the paywall and entitlement system.
2. Reset the ladder so the annual discount is modest, not half-off.
3. Make the savings badge **computed** from live prices so it can never be wrong again.
4. Reuse the existing `SubscriptionManager` entitlement model and `PaywallView` structure; no new architecture.

## Pricing decisions (owner-approved 2026-05-31)

| Tier | Now | New | Notes |
|------|-----|-----|-------|
| Monthly | $5.99/mo | **$3.99/mo** | lowered so the annual discount lands near 15% |
| Yearly | $34.99/yr | **$39.99/yr** | 12×$3.99 = $47.88 → **~16% off** (computed; displayed "SAVE 16%") |
| Lifetime | — | **$99.99 once** | non-consumable; 2.5× annual → breaks even ~2.5 yr, free forever after |

- US-first market; USD primary. App Store Connect auto-maps the chosen US tier to other storefronts.
- The 1-week free trial stays on **Monthly + Yearly only** — non-consumables cannot carry an intro offer.
- Badge math: `1 − (yearly.price / (monthly.price × 12))`, rounded. At $3.99/$39.99 that is 16% (not exactly the owner's "15%"; 16% is both accurate and marginally stronger to show). If the owner later wants it pinned to "15%", that becomes a one-line constant — but the default is computed.

## Design

### 1. Products (`App/Resources/Billable.storekit` + App Store Connect)

- Edit existing subs' `displayPrice`: monthly `5.99 → 3.99`, yearly `34.99 → 39.99`.
- Add a **non-consumable** product to the `.storekit` `products` array (NOT a subscription group):
  - `productID`: `com.eldenstudios.billable.pro.lifetime`
  - `type`: `NonConsumable`, `displayPrice`: `99.99`, `familyShareable`: false
  - displayName "Billable Pro — Lifetime", description "Pay once. Own Pro forever."
- The `.storekit` file drives local/simulator testing only. **Production requires the owner to mirror these in App Store Connect** (see Human-only gates).

### 2. Entitlement model (`SubscriptionManager`, BillableCore)

Current: `entitlement: Entitlement {.free, .trial, .pro}` drives `isPro`. `refreshProducts()` loads `[monthlyProductID, yearlyProductID]`; the `Transaction.currentEntitlements` loop only counts those two IDs.

Changes:
- Add `public static let lifetimeProductID = "com.eldenstudios.billable.pro.lifetime"`.
- Add `public private(set) var lifetime: Product?`; load it alongside the subs in `refreshProducts()` (it returns from the same `Product.products(for:)` call; filter by ID).
- **Ownership:** in the `currentEntitlements` evaluation, accept `transaction.productID == lifetimeProductID` and, when present (and unrevoked), set `entitlement = .pro`. Lifetime is terminal Pro: it is never `.trial`, never downgrades, and **wins over** any subscription state (if both exist, the user is `.pro`).
- `isPro` keeps its current shape (it reads `entitlement`) but now returns true for lifetime owners too, because lifetime resolves the user to `.pro`. To avoid an ordering bug in the `currentEntitlements` loop, compute `ownsLifetime` first, then set the final `entitlement = ownsLifetime ? .pro : <subscription-derived state>` — lifetime always takes precedence.
- **Restore:** the existing `restore()` (AppStore sync → re-read `currentEntitlements`) already covers non-consumables; verify it re-resolves lifetime. No separate path.
- **Transaction updates listener:** already iterates `Transaction.updates`; ensure a lifetime purchase/refund flips `entitlement` live (the same code path, once the loop accepts the lifetime ID).
- Add `public var ownsLifetime: Bool` (derived) so the paywall can show the owned state and guard double-purchase.

### 3. Paywall UI (`PaywallView.swift`) — Layout A (three stacked tiers)

- Extend the `Plan` enum with `.lifetime`; default selection stays `.yearly` (BEST VALUE).
- Render three `planRow`s top-to-bottom: **Monthly · Yearly *(BEST VALUE · SAVE n%)* · Lifetime**.
  - Lifetime row: price `$99.99`, sub-line "Pay once · own forever", and a neutral **"NO SUBSCRIPTION"** capsule (distinct from the green savings pill). No per-month line, no trial line.
- **Computed savings badge:** replace the hardcoded `Text("SAVE 51%")` with a value derived from `manager.yearly` / `manager.monthly`; hide it until both products load. Mirror the same value into the `--mock-paywall-prices` path.
- **Purchase button** adapts to `selection`:
  - Monthly/Yearly: existing "Start Free Trial" / "Subscribe" logic + the trial line.
  - Lifetime: title "Buy Lifetime — $99.99", **no** trial line.
- **Trial line** (the "Free for 1 week, then …" copy) renders only for subscription selections.
- **Owned state:** when `manager.ownsLifetime`, the paywall body shows "You own Cadence Pro forever ✓" instead of the tiers + buy button (Restore still available). This also doubles as the **double-buy guard** (no purchase path when owned).
- **Active-sub + lifetime nudge:** if the user buys lifetime while a subscription is active, after success show a one-time note: "You're set forever. You may want to cancel your subscription in Settings to avoid future charges." (We cannot cancel it programmatically.)

### 4. "What you get" block

Out of scope for THIS spec — the under-the-button benefits list is part of the separate "paywall polish" initiative. If the existing PR #12 paywall already lists benefits, the new Lifetime tier inherits them unchanged (the benefits are entitlement-wide, not per-tier).

## Data flow

- `SubscriptionManager.refreshProducts()` → loads 3 products → `monthly/yearly/lifetime` populated → paywall renders prices + computed badge.
- Purchase (`purchase(_:)`) is product-agnostic (`product.purchase()`), so the lifetime non-consumable flows through the existing method; the entitlement loop reclassifies the user to `.pro` on the resulting transaction.
- `isPro`/`canAccessReports`/`canRemoveWatermark` gates are unchanged — they read `isPro`, which now also returns true for lifetime owners.

## Edge cases / error handling

- **Owns lifetime, opens paywall:** owned state; no buy path.
- **Subscribed, then buys lifetime:** succeeds; `.pro` (terminal); show the cancel-your-sub nudge; no auto-refund (Apple disallows programmatic cancel).
- **Lifetime refunded** (`Transaction.updates` revocation): entitlement re-resolves; if no active sub remains → `.free`.
- **Restore on a new device:** `restore()` → `currentEntitlements` returns the non-consumable → `.pro`.
- **Products fail to load:** badge hidden, prices show `ProgressView` (existing behavior); lifetime row shows the same loading state.
- **Family Sharing:** lifetime is `familyShareable: false` for v1 (matches subs).

## Testing (BillableCore, `_fetchProducts`/entitlement hooks already exist)

- `ownsLifetime` true → `entitlement == .pro` → `isPro`, `canAccessReports`, `canRemoveWatermark` all true.
- Lifetime **wins over** sub state: lifetime + expired sub → `.pro`; lifetime + active sub → `.pro`.
- No lifetime, no sub → `.free`. Lifetime revoked → falls back to sub state or `.free`.
- Restore path resolves lifetime ownership.
- Savings-percentage helper: `(monthly: 3.99, yearly: 39.99) → 16`; guards divide-by-zero / missing products (returns nil → badge hidden).
- Paywall (mock-prices UI path): three tiers render; lifetime row has no trial line; owned state hides the buy button.

## Human-only App Store Connect gates (owner)

1. Create the **non-consumable** IAP `com.eldenstudios.billable.pro.lifetime` at the **$99.99** US price tier; add localized name/description; submit with the build.
2. Edit the existing subscription prices: Monthly → **$3.99**, Yearly → **$39.99** (price change with the standard "keep existing subscribers / apply to new" choice — owner's call on whether to preserve current subscribers' rates).
3. Screenshots/review notes if the paywall layout changed materially.

These cannot be done from code; the `.storekit` change only enables local testing until ASC is updated.

## Out of scope / non-goals (separate initiatives)

- Paywall visual polish + the "what you get" benefits block (#3 of the monetization set).
- Recurring-invoice → Pro A/B test (#4).
- Promo/launch discount on lifetime, win-back offers, family sharing.
- Changing the trial length or the free-tier feature gates.
