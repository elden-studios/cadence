---
# Paywall + Reports (PR B) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a three-equal-tier paywall (Monthly/Yearly/Lifetime) with a fixed savings badge, a chart-led locked Reports preview backed by a new unit-tested monthly-collected aggregation, and a Lifetime availability guard so a missing App Store product can never render a dead buy button.

**Architecture:** A 3-tier paywall is presented in `PaywallView` (Yearly the filled hero, Lifetime a gold "PAY ONCE" peer), with pure locale-aware copy/CTA helpers extracted into BillableCore (`PaywallCopy`). A new unit-testable monthly-collected aggregation (`ReportsAggregator.collectedMonthlyTrend`) feeds a Swift Charts bar chart in the locked paywall preview, gated real-vs-sample by a pure `hasEnoughCollectedHistory` predicate. A tri-state `LifetimeAvailability` resolver nil-guards the Lifetime tier; all SwiftData reads stay single-hop (no `\.project?.client` traversal) for CloudKit safety.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, StoreKit 2, Swift Charts, XCTest.

---

## ✅ Build status — where we stopped (2026-06-03)

> **This plan is fully EXECUTED.** Built subagent-driven via three phase-workflows (B1 → B2 → B3) + a perf follow-up, on branch `feature/paywall-reports` (worktree `.worktrees/paywall-reports`, off `origin/main` `6fa10a6`). **OPEN as [PR #27](https://github.com/elden-studios/cadence/pull/27)** (MERGEABLE), tip `f3d5035`.
>
> - **B1** (Tasks 1–12) ✅ — three equal tiers + pure `PaywallCopy`. **B2** (13–28) ✅ — GREEN "Collected · last 6 months" locked chart + pure `collectedMonthlyTrend` / `collectedThisYear` / `hasEnoughCollectedHistory`. **B3** (29–39) ✅ — `LifetimeAvailability` guard + DEBUG diagnostic + scheme audit + ASC owner-note. **Perf** ✅ — `ReportsPaywallTeaser` child view so the Reports `@Query` only fire on the `.reports` trigger.
> - **379 BillableCore tests pass · clean app build · 0 warnings.** Per-task spec + code-quality reviews + a final whole-branch Opus review = **READY**.
> - **Gemini reviewed** → **applied F8/F9** (perf micro-opts: single-pass `collectedThisYear` + lazy `collectedMonthlyTrend`, `f3d5035`); **declined F1–F7** (localization — app is English-only, no l10n infra); rationale posted on the PR.
> - **Owner-confirmed:** chart bar = GREEN; teaser middle stat = "This year" (YTD).
>
> **⏳ Awaiting USER MERGE** + 3 pre-merge gates (none block code review): (1) create ASC non-consumable `com.eldenstudios.billable.pro.lifetime` @ $99.99 (Lifetime tier stays hidden until then — the B3 guard); (2) on-device CloudKit smoke-test the paywall (sim/tests use the local-store fallback); (3) manual paywall visual check (also covers B1 Task 12). **Next UX-overhaul piece after this merges: PR C** (start-timer motion → Hero Morph default + delete the DEBUG picker; spec sub-project C; plan not yet written).

---

## File Structure

### Created
- `Packages/BillableCore/Sources/BillableCore/Subscriptions/PaywallCopy.swift` — pure, locale-aware paywall display copy: `monthlyEquivalentLine(...)` (Yearly "Just $X/mo · 2 months free" sub-line) and `Tier` + `ctaTitle(...)` (lifetime/subscription CTA mapping). No currency literals; locale supplied by the call site from the StoreKit product.
- `Packages/BillableCore/Tests/BillableCoreTests/PaywallCopyTests.swift` — unit tests for `PaywallCopy.monthlyEquivalentLine` and `PaywallCopy.ctaTitle` (two suites).
- `Packages/BillableCore/Tests/BillableCoreTests/ReportsCollectedTrendTests.swift` — unit tests for `ReportsAggregator.collectedMonthlyTrend` (window shape, paidAt bucketing, exclusions, tax-inclusive total, month-boundary instant) and `hasEnoughCollectedHistory`.
- `Packages/BillableCore/Tests/BillableCoreTests/LifetimeAvailabilityTests.swift` — unit tests for `SubscriptionManager.lifetimeAvailability` and `SubscriptionManager.lifetimeDiagnostic` (two suites).

### Modified
- `Packages/BillableCore/Sources/BillableCore/Reporting/ReportsAggregator.swift` — adds the pure `collectedMonthlyTrend(...)` monthly-collected series (Σ paid-invoice total bucketed by `month(paidAt)`, gap-filled, currency-scoped) and the pure `hasEnoughCollectedHistory(...)` presentation gate.
- `Packages/BillableCore/Sources/BillableCore/Subscriptions/SubscriptionManager.swift` — adds the pure `LifetimeAvailability` enum + `lifetimeAvailability(...)` resolver, the pure `lifetimeDiagnostic(...)` message builder, a DEBUG-gated diagnostic log in `refreshProducts()`, an `os.Logger` (if absent), and (conditionally) `Equatable` on `LoadState`.
- `App/Sources/Features/Paywall/PaywallView.swift` — three-tier `planRow`/`mockPlanRow`, Lifetime as a third peer row in `pricePicker`, savings-badge color fix, CTA routed through `PaywallCopy.ctaTitle`, `lifetimeAffordance` collapsed to owned-state guard, `perCycleLabel` removed, the locked chart-led Reports teaser (`teaserChartHero`/`teaserStatLine`/`statCell`/`sampleCollectedSeries`), `ReportsTeaserModel.collectedSeries` + real-vs-sample gate wiring, shortened headline, and the `LifetimeAvailability` view guard. **NOTE: B1 and B3 both edit the shared `PaywallView` functions `lifetimeAffordance` and `purchaseButton`'s `.disabled(...)` modifier — see the per-task flags below; both sets of edits are kept and composed.**
- `App/Sources/Features/Paywall/PricingConfig.swift` — bumps `variant`/`layout` to `ladder_2026_06_v2` / `three_equal_tiers`, adds the three-equal-tiers tier copy (`bestValueBadge`, `payOnceBadge`, `lifetimeOnceSuffix`, `lifetimePeerSubtitle`), removes the demoted `lifetimeAffordance*` constants.
- `App/Sources/Features/Reports/ReportsSampleData.swift` — adds the display-only 6-month `collectedLast6Months` sample series anchored to the existing `collected` scalar.
- `Billable.xcodeproj/xcshareddata/xcschemes/Billable.xcscheme` — audited read-only (B3 Task 35); edited ONLY if a StoreKit config reference is found in a Release/Archive/Profile action.
- `docs/superpowers/specs/2026-06-02-cadence-ux-overhaul-design.md` — appends the ASC Lifetime non-consumable owner-dependency note to the B3 section (B3 Task 38).

---

## Task 1: Add `PaywallCopy.monthlyEquivalentLine` pure helper with a failing unit test

The "$X/mo · 2 months free" sub-line must be computed per-locale and is currently inline in `perCycleLabel` (a SwiftUI-view-private method, untestable). Extract a pure, locale-driven helper into BillableCore so it can be unit-tested, and so the view delegates to it.

First write the failing test.

**File:** `/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/Packages/BillableCore/Tests/BillableCoreTests/PaywallCopyTests.swift` (new)

```swift
import Foundation
import Testing
@testable import BillableCore

@Suite("PaywallCopy monthly-equivalent sub-line")
struct PaywallCopyMonthlyEquivalentTests {
    // A fixed en_US locale so the assertion is deterministic regardless of host.
    private let enUS = Locale(identifier: "en_US")

    @Test("yearly hero sub-line leads with per-month price and months-free")
    func subLine() throws {
        let line = try #require(PaywallCopy.monthlyEquivalentLine(
            yearlyPrice: 39.99, monthlyPrice: 3.99, locale: enUS))
        #expect(line == "Just $3.33/mo · 2 months free")
    }

    @Test("nil monthly price falls back to per-month only, no months-free clause")
    func noMonthly() throws {
        let line = try #require(PaywallCopy.monthlyEquivalentLine(
            yearlyPrice: 39.99, monthlyPrice: nil, locale: enUS))
        #expect(line == "Just $3.33/mo")
    }

    @Test("nil yearly price yields nil (products not loaded → hide the line)")
    func noYearly() {
        #expect(PaywallCopy.monthlyEquivalentLine(
            yearlyPrice: nil, monthlyPrice: 3.99, locale: enUS) == nil)
    }
}
```

Run it, expect FAIL (no such type `PaywallCopy`):

```
swift test --package-path "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/Packages/BillableCore" --filter PaywallCopyMonthlyEquivalentTests
```

## Task 2: Implement `PaywallCopy.monthlyEquivalentLine` (minimal) → PASS → commit

Create the helper. It divides yearly by 12, formats per-locale (no USD literals — the locale is passed in from `product.priceFormatStyle.locale` at the call site), and appends the months-free clause only when a monthly price is supplied and yearly is genuinely cheaper (reusing `PricingDisplay.annualSavings`).

**File:** `/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/Packages/BillableCore/Sources/BillableCore/Subscriptions/PaywallCopy.swift` (new)

```swift
import Foundation

/// Pure, testable display copy for the paywall tier rows. Keeps locale-aware
/// money formatting out of the SwiftUI view so it can be unit-tested without a
/// running app or a live StoreKit session. No hardcoded currency — every figure
/// is formatted via the locale the call site derives from the StoreKit product
/// (`product.priceFormatStyle.locale`), so the app ships correctly in 175 countries.
public enum PaywallCopy {
    /// The Yearly-hero price sub-line, e.g. "Just $3.33/mo · 2 months free".
    ///
    /// - Returns nil when `yearlyPrice` is absent (products not loaded yet) so the
    ///   caller can hide the line rather than flash an incorrect figure.
    /// - Omits the "· N months free" clause when `monthlyPrice` is absent or the
    ///   yearly isn't actually cheaper than 12× monthly (mirrors `savingsPill`'s guard).
    public static func monthlyEquivalentLine(
        yearlyPrice: Decimal?,
        monthlyPrice: Decimal?,
        locale: Locale
    ) -> String? {
        guard let yearlyPrice, yearlyPrice > 0 else { return nil }
        let perMonth = yearlyPrice / 12
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = locale
        guard let perMonthString = formatter.string(from: perMonth as NSDecimalNumber) else {
            return nil
        }
        var line = "Just \(perMonthString)/mo"
        if let monthlyPrice,
           let savings = PricingDisplay.annualSavings(monthlyPrice: monthlyPrice, yearlyPrice: yearlyPrice) {
            line += " · \(savings.monthsFree) months free"
        }
        return line
    }
}
```

Run it, expect PASS:

```
swift test --package-path "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/Packages/BillableCore" --filter PaywallCopyMonthlyEquivalentTests
```

Then commit:

```
git -C "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports" add Packages/BillableCore/Sources/BillableCore/Subscriptions/PaywallCopy.swift Packages/BillableCore/Tests/BillableCoreTests/PaywallCopyTests.swift && git -C "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports" commit -m "feat(paywall): pure locale-aware monthly-equivalent sub-line helper

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

## Task 3: Add `PaywallCopy.ctaTitle(for:lifetimePrice:eligibleForIntroOffer:)` with a failing unit test

The CTA-title logic (Lifetime → "Buy Lifetime — <price>"; subscription → trial vs "Subscribe") is currently inline in the view-private `purchaseButtonTitle` (untestable, and carries a `$99.99` USD literal). Extract the selection→title mapping to a pure helper so the three-tier CTA behavior is unit-covered and the literal moves to a clearly-labeled fallback.

First write the failing test.

**File:** `/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/Packages/BillableCore/Tests/BillableCoreTests/PaywallCopyTests.swift` (append a new suite to the file from Task 1)

```swift
@Suite("PaywallCopy CTA title")
struct PaywallCopyCTATests {
    @Test("lifetime selection names the price and never offers a trial")
    func lifetime() {
        #expect(PaywallCopy.ctaTitle(for: .lifetime, lifetimePrice: "$99.99",
                                     eligibleForIntroOffer: true) == "Buy Lifetime — $99.99")
        // Eligibility is irrelevant for a one-time buy.
        #expect(PaywallCopy.ctaTitle(for: .lifetime, lifetimePrice: "£94.99",
                                     eligibleForIntroOffer: false) == "Buy Lifetime — £94.99")
    }

    @Test("intro-eligible subscription offers the free trial")
    func subTrial() {
        #expect(PaywallCopy.ctaTitle(for: .yearly, lifetimePrice: nil,
                                     eligibleForIntroOffer: true) == "Start 7-day free trial")
        #expect(PaywallCopy.ctaTitle(for: .monthly, lifetimePrice: nil,
                                     eligibleForIntroOffer: true) == "Start 7-day free trial")
    }

    @Test("ineligible subscription shows Subscribe")
    func subNoTrial() {
        #expect(PaywallCopy.ctaTitle(for: .yearly, lifetimePrice: nil,
                                     eligibleForIntroOffer: false) == "Subscribe")
    }
}
```

Note this test references `PaywallCopy.Tier` (the new pure enum mirror of the view's `Plan`). Run it, expect FAIL (no `ctaTitle`, no `Tier`):

```
swift test --package-path "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/Packages/BillableCore" --filter PaywallCopyCTATests
```

## Task 4: Implement `PaywallCopy.Tier` + `ctaTitle(...)` (minimal) → PASS → commit

Add a pure `Tier` enum and the CTA mapping to the existing `PaywallCopy` file. The Lifetime price is passed in already-resolved (the view supplies `manager.lifetime?.displayPrice` with its mock/nil fallback), so this helper carries no USD literal itself.

**File:** `/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/Packages/BillableCore/Sources/BillableCore/Subscriptions/PaywallCopy.swift` (edit — add inside the `PaywallCopy` enum, after `monthlyEquivalentLine`)

```swift
    /// Pure mirror of the paywall's three purchasable tiers, so CTA logic is
    /// testable without the SwiftUI `Plan` enum.
    public enum Tier: String, CaseIterable, Sendable {
        case yearly, monthly, lifetime
    }

    /// The purchase-button title for the current selection.
    ///
    /// - Lifetime is a one-time buy: it always reads "Buy Lifetime — <price>" and
    ///   never offers a trial. `lifetimePrice` is the already-resolved, localized
    ///   display price the caller derives from the StoreKit product (no literal here).
    /// - Subscriptions read "Start 7-day free trial" when intro-eligible, else "Subscribe".
    public static func ctaTitle(
        for tier: Tier,
        lifetimePrice: String?,
        eligibleForIntroOffer: Bool
    ) -> String {
        switch tier {
        case .lifetime:
            return "Buy Lifetime — \(lifetimePrice ?? "")"
        case .yearly, .monthly:
            return eligibleForIntroOffer ? "Start 7-day free trial" : "Subscribe"
        }
    }
```

Run it, expect PASS:

```
swift test --package-path "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/Packages/BillableCore" --filter PaywallCopyCTATests
```

Then commit:

```
git -C "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports" add Packages/BillableCore/Sources/BillableCore/Subscriptions/PaywallCopy.swift Packages/BillableCore/Tests/BillableCoreTests/PaywallCopyTests.swift && git -C "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports" commit -m "feat(paywall): pure selection→CTA-title mapping (lifetime/subscription)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

## Task 5: Add the new tier copy to `PricingConfig` and bump the variant/layout

The three-tier layout is a deliberate change from "yearly_hero_lifetime_below". Add the new tier-label/badge copy as SSoT constants (not literals in the view), and bump `variant`/`layout` so funnel metrics stay sliceable across the layout change (per the constraint: "bump PricingConfig.variant/layout if the tier layout changes").

There is no pure test for these string constants; this is a copy/SSoT step verified by the app build in Task 11. Make the edits, then commit alongside Task 6 (they ship together).

**File:** `/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/App/Sources/Features/Paywall/PricingConfig.swift` (edit)

Replace:

```swift
    /// Bump when prices, tier order, or layout change — keeps metrics sliceable.
    static let variant = "ladder_2026_05_v1"
    static let layout = "yearly_hero_lifetime_below"

    static let lifetimeAffordanceTitle = "Prefer to pay once?"
    static let lifetimeAffordanceSubtitle = "Own Cadence Pro forever"
    static let trialReassurance = "No charge today. We'll remind you before your trial ends. Cancel anytime."
    static let ownedTitle = "You own Cadence Pro forever ✓"
```

with:

```swift
    /// Bump when prices, tier order, or layout change — keeps metrics sliceable.
    /// `three_equal_tiers` = Monthly / Yearly / Lifetime as co-equal rows (B1),
    /// superseding the prior "yearly_hero_lifetime_below" demoted-Lifetime layout.
    static let variant = "ladder_2026_06_v2"
    static let layout = "three_equal_tiers"

    // Tier-row copy (B1 three-equal-tiers layout).
    /// Pill on the Yearly hero row.
    static let bestValueBadge = "BEST VALUE"
    /// Pill on the Lifetime peer row.
    static let payOnceBadge = "PAY ONCE"
    /// Trailing word on the Lifetime price, e.g. "$99.99 once".
    static let lifetimeOnceSuffix = "once"
    /// Sub-line under the Lifetime row title.
    static let lifetimePeerSubtitle = "Own Cadence Pro forever"

    // Retained for the owned-state collapse + remaining copy.
    static let trialReassurance = "No charge today. We'll remind you before your trial ends. Cancel anytime."
    static let ownedTitle = "You own Cadence Pro forever ✓"
```

(The two `lifetimeAffordance*` constants are removed because the demoted affordance is folded into the picker in Task 6; if any other file references them, that will surface as a build error in Task 11 and must be reconciled there.)

No test run for this step. Proceed to Task 6.

## Task 6: Rewrite `planRow` to a parameterized three-tier row + fix the live savings-badge color → app build → commit

This is the core view change. Make `planRow` handle all three tiers with a consistent selection affordance (checkmark on every selected row, not just the hero), keep Yearly the filled accent hero, render Lifetime as a gold-accent "PAY ONCE" peer with "$99.99 once", move the saving into the Yearly sub-line via the Task 2 helper, and fix the washed-out `savingsPill` color. This is SwiftUI layout — not unit-testable — so it is verified by `xcodebuild` (compile) here and a manual check in Task 12.

**File:** `/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/App/Sources/Features/Paywall/PaywallView.swift` (edit)

**6a.** Replace the entire `planRow(_:)` function (lines 496-564) with a three-tier version. Selection affordance is consistent (checkmark on any selected row, tinted to match the row's foreground); Lifetime uses a gold accent border/badge and the "$99.99 once" price composition; the Yearly hero's saving is the sub-line, not a separate pill.

```swift
    @ViewBuilder
    private func planRow(_ plan: Plan) -> some View {
        let isSelected = selection == plan
        let isHero = (plan == .yearly)
        let isLifetime = (plan == .lifetime)
        let product: Product? = {
            switch plan {
            case .yearly:   return manager.yearly
            case .monthly:  return manager.monthly
            case .lifetime: return manager.lifetime
            }
        }()
        // Gold accent for the Lifetime "pay once" peer; blue accent hero for Yearly;
        // recessed card for Monthly. Lifetime's selected border/badge read gold.
        let lifetimeGold = Color(red: 0.72, green: 0.53, blue: 0.04)
        let selectionAccent: Color = isLifetime ? lifetimeGold : Color.accentColor

        Button {
            selection = plan
            PaywallMetrics.record(.tierSelected, variant: PricingConfig.variant,
                                  trigger: trigger.metricKey, tier: plan.rawValue)
        } label: {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(planTitle(plan))
                            .font(.headline)
                        if isHero {
                            Text(PricingConfig.bestValueBadge)
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.white.opacity(0.22), in: .capsule)
                                .foregroundStyle(.white)
                        } else if isLifetime {
                            Text(PricingConfig.payOnceBadge)
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(lifetimeGold.opacity(0.16), in: .capsule)
                                .foregroundStyle(lifetimeGold)
                        }
                    }
                    if let sub = planSubLine(plan, product: product) {
                        Text(sub)
                            .font(.caption)
                            .foregroundStyle(isHero ? AnyShapeStyle(.white.opacity(0.85))
                                                    : AnyShapeStyle(.secondary))
                    }
                }
                Spacer()
                planPrice(plan, product: product, isHero: isHero)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(isHero ? AnyShapeStyle(.white)
                                                : AnyShapeStyle(selectionAccent))
                }
            }
            // The hero gets taller padding + a solid accent fill + white text so
            // Yearly is the default; Monthly/Lifetime recede to plain cards with a
            // consistent selection border.
            .padding(.vertical, isHero ? 20 : 14)
            .padding(.horizontal, 14)
            .foregroundStyle(isHero ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isHero {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(LinearGradient(
                            colors: [Color.accentColor, Color.accentColor.opacity(0.85)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                } else {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color(.secondarySystemBackground))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(isSelected ? selectionAccent : Color.gray.opacity(0.18),
                                  lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func planTitle(_ plan: Plan) -> String {
        switch plan {
        case .yearly:   return "Yearly"
        case .monthly:  return "Monthly"
        case .lifetime: return "Lifetime"
        }
    }

    /// Sub-line under each tier title. Yearly carries the per-locale
    /// "Just $X/mo · 2 months free" saving (hidden when products/currencies
    /// aren't comparable); Monthly + Lifetime carry their static framing.
    private func planSubLine(_ plan: Plan, product: Product?) -> String? {
        switch plan {
        case .yearly:
            // Hide the line entirely when products aren't loaded or the
            // monthly/yearly currencies mismatch (mirrors savingsPill's guard).
            guard let yearly = product else { return "Billed yearly" }
            let monthlyCurrency = manager.monthly?.priceFormatStyle.locale.currency?.identifier
            let yearlyCurrency  = yearly.priceFormatStyle.locale.currency?.identifier
            let comparableMonthly: Decimal? =
                (monthlyCurrency != nil && monthlyCurrency == yearlyCurrency) ? manager.monthly?.price : nil
            return PaywallCopy.monthlyEquivalentLine(
                yearlyPrice: yearly.price,
                monthlyPrice: comparableMonthly,
                locale: yearly.priceFormatStyle.locale)
                ?? "Billed yearly"
        case .monthly:
            return "Billed monthly · Cancel anytime"
        case .lifetime:
            return PricingConfig.lifetimePeerSubtitle
        }
    }

    /// The trailing price for a tier. Lifetime composes "<price> once"; others
    /// show the plain localized display price, or a spinner while loading.
    @ViewBuilder
    private func planPrice(_ plan: Plan, product: Product?, isHero: Bool) -> some View {
        if let product {
            if plan == .lifetime {
                Text("\(product.displayPrice) \(PricingConfig.lifetimeOnceSuffix)")
                    .font(.title3.weight(.semibold).monospacedDigit())
            } else {
                Text(product.displayPrice)
                    .font(.title3.weight(.semibold).monospacedDigit())
            }
        } else {
            ProgressView().controlSize(.small)
                .tint(isHero ? .white : nil)
        }
    }
```

**6b.** Fix the washed-out live `savingsPill` color (lines 569-582). The pill is no longer rendered inside the hero row (the saving now lives in the sub-line), but `savingsPill` is retained for any remaining reference and its color is corrected away from green-on-blue to a solid, legible green capsule. Replace the body of `savingsPill`:

```swift
    @ViewBuilder
    private var savingsPill: some View {
        let monthlyCurrency = manager.monthly?.priceFormatStyle.locale.currency?.identifier
        let yearlyCurrency  = manager.yearly?.priceFormatStyle.locale.currency?.identifier
        if let monthlyCurrency, let yearlyCurrency, monthlyCurrency == yearlyCurrency,
           let m = manager.monthly?.price, let y = manager.yearly?.price,
           let s = PricingDisplay.annualSavings(monthlyPrice: m, yearlyPrice: y) {
            Text(PricingDisplay.savingsBadge(s, currencyCode: yearlyCurrency))
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.green, in: .capsule)
                .foregroundStyle(.white)
        }
    }
```

Build the app (run `xcodegen` first in case the project is stale), expect BUILD SUCCEEDED:

```
xcodegen generate --spec "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/project.yml" --project "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports" && xcodebuild -project "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/Billable.xcodeproj" -scheme Billable -destination 'generic/platform=iOS Simulator' build
```

Then commit:

```
git -C "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports" add App/Sources/Features/Paywall/PaywallView.swift App/Sources/Features/Paywall/PricingConfig.swift && git -C "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports" commit -m "feat(paywall): three-equal tier rows + fix washed-out savings badge

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

## Task 7: Add the third Lifetime row to the live `pricePicker` `.ready` branch and route the CTA through the pure helper → app build → commit

With `planRow` now tier-aware, surface Lifetime as a peer row in the picker and switch `purchaseButtonTitle` to the unit-tested `PaywallCopy.ctaTitle`.

**File:** `/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/App/Sources/Features/Paywall/PaywallView.swift` (edit)

**7a.** In `pricePicker`, the `.ready` branch (lines 397-401) currently renders only Yearly + Monthly. Replace:

```swift
        case .ready:
            VStack(spacing: 10) {
                planRow(.yearly)
                planRow(.monthly)
            }
```

with (order: Monthly / Yearly / Lifetime — Yearly the visual hero in the middle; Lifetime always shown as a peer because the picker only renders when `loadState == .ready`, and an absent Lifetime product renders its spinner placeholder via `planPrice`, with the B3 diagnostic handled separately):

```swift
        case .ready:
            VStack(spacing: 10) {
                planRow(.monthly)
                planRow(.yearly)
                planRow(.lifetime)
            }
```

**7b.** Replace `purchaseButtonTitle` (lines 631-641) to delegate to the pure helper, removing the inline USD literal from the live path (the literal now lives only in the mock/nil fallbacks of `selectedPlanPrice`/`lifetimeDisplayPrice`):

```swift
    private var purchaseButtonTitle: String {
        let tier = PaywallCopy.Tier(rawValue: selection.rawValue) ?? .yearly
        // In marketing-screenshot mode there are no real products to derive
        // intro-eligibility from, so force the strongest CTA (the free trial).
        let introEligible = mockPaywallPrices || manager.eligibleForIntroOffer
        return PaywallCopy.ctaTitle(for: tier,
                                    lifetimePrice: lifetimeDisplayPrice,
                                    eligibleForIntroOffer: introEligible)
    }
```

(`lifetimeDisplayPrice` already supplies the `$99.99` mock/nil fallback, so the live path stays literal-free and an unavailable Lifetime price degrades to "Buy Lifetime — " rather than a wrong figure — tightened in Task 9.)

Build the app, expect BUILD SUCCEEDED:

```
xcodebuild -project "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/Billable.xcodeproj" -scheme Billable -destination 'generic/platform=iOS Simulator' build
```

Then commit:

```
git -C "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports" add App/Sources/Features/Paywall/PaywallView.swift && git -C "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports" commit -m "feat(paywall): Lifetime as third peer row + CTA via pure helper

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

## Task 8: Collapse the now-redundant `lifetimeAffordance` to owned-state-only (preserve the double-buy guard) → app build → commit

> **Shared-file note:** This task rewrites `lifetimeAffordance`. B3 (Task 36) further edits the SAME function to add the `.unavailable` DEBUG branch. Both edits are kept and composed: this task establishes the owned-label-only body; Task 36 adds the `else if`/DEBUG branch onto it.

Lifetime is now a first-class picker row, so the demoted affordance link must go — but `lifetimeAffordance` also renders the owned-state label that doubles as the double-buy guard and is shown via the body's `!ownsLifetime` collapse. Reduce it to only the owned label so the collapse behavior is preserved exactly.

**File:** `/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/App/Sources/Features/Paywall/PaywallView.swift` (edit)

Replace the entire `lifetimeAffordance` (lines 697-729) with:

```swift
    /// When the user already owns Lifetime, the body's `!ownsLifetime` guard
    /// suppresses the picker + CTA + trialTerms; this renders the owned-state
    /// label (the double-buy guard) in their place. Lifetime is otherwise a
    /// first-class row in `pricePicker`, so there is no demoted affordance.
    @ViewBuilder
    private var lifetimeAffordance: some View {
        if manager.ownsLifetime {
            Label(PricingConfig.ownedTitle, systemImage: "checkmark.seal.fill")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.green)
        }
    }
```

This keeps the `body` structure (lines 82-95) intact: when `ownsLifetime`, the `if !manager.ownsLifetime { … }` block (picker/CTA/trialTerms) is suppressed, `lifetimeAffordance` shows only the owned label, and `termsPrivacyLinks` renders — exactly the current owned-state.

Build the app, expect BUILD SUCCEEDED:

```
xcodebuild -project "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/Billable.xcodeproj" -scheme Billable -destination 'generic/platform=iOS Simulator' build
```

Then commit:

```
git -C "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports" add App/Sources/Features/Paywall/PaywallView.swift && git -C "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports" commit -m "refactor(paywall): collapse lifetimeAffordance to owned-state guard only

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

## Task 9: Harden `purchaseButtonTitle`/`trialTerms` against an absent Lifetime price and stale `perCycleLabel` → app build → commit

> **Shared-file note:** This task edits `purchaseButton`'s `.disabled(...)` modifier (line 628). B3 (Task 36, step 8c) edits the SAME `.disabled(...)` modifier again to add the explicit `.unavailable` clause. Both edits are kept: this task adds the `selection == .lifetime && lifetimeDisplayPrice == nil` clause; Task 36 generalizes it to the `lifetimeAvailability == .unavailable` form. The Task-36 form supersedes/absorbs this one — apply both in order and keep the final composed modifier from Task 36.

Two loose ends from folding Lifetime into the picker: (1) the CTA could read "Buy Lifetime — " if `lifetimeDisplayPrice` is nil (Lifetime is now selectable as a row even when its product fails to load); guard so an unbuyable Lifetime never shows a bare CTA. (2) `perCycleLabel` (lines 593-610) is now dead (replaced by `planSubLine`) — remove it to avoid a stale second source of the sub-line copy.

**File:** `/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/App/Sources/Features/Paywall/PaywallView.swift` (edit)

**9a.** Make the purchase button defensively disabled when Lifetime is selected but unpurchasable. Replace `purchaseButton`'s `.disabled(...)` modifier (line 628):

```swift
        .disabled((selectedProduct == nil && !mockPaywallPrices) || isProcessing)
```

with:

```swift
        .disabled((selectedProduct == nil && !mockPaywallPrices)
                  || (selection == .lifetime && lifetimeDisplayPrice == nil)
                  || isProcessing)
```

**9b.** Delete the now-unused `perCycleLabel(for:product:)` function entirely (lines 593-610). Its only callers were the old `planRow`/`mockPlanRow`, replaced by `planSubLine` and (Task 10) the mock sub-line.

Build the app, expect BUILD SUCCEEDED (a successful build confirms `perCycleLabel` had no remaining callers):

```
xcodebuild -project "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/Billable.xcodeproj" -scheme Billable -destination 'generic/platform=iOS Simulator' build
```

Then commit:

```
git -C "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports" add App/Sources/Features/Paywall/PaywallView.swift && git -C "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports" commit -m "fix(paywall): disable CTA for unbuyable Lifetime; drop dead perCycleLabel

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

## Task 10: Add the mock Lifetime row + mock CTA/disabled handling + fix the static mock badge color → app build → commit

The `--mock-paywall-prices` branch (App Store screenshots) must show all three tiers and not leave green-on-blue. Add a mock Lifetime row, make `mockPlanRow` tier-aware (mirroring the live `planRow`), and fix the static savings badge color.

**File:** `/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/App/Sources/Features/Paywall/PaywallView.swift` (edit)

**10a.** In `pricePicker`, the mock branch (lines 387-390) renders only yearly + monthly. Replace:

```swift
            VStack(spacing: 10) {
                mockPlanRow(.yearly,  price: "$39.99", perCycle: "Just $3.33 per month, billed yearly")
                mockPlanRow(.monthly, price: "$3.99",  perCycle: "Billed monthly · Cancel anytime")
            }
```

with (Monthly / Yearly / Lifetime to match the live order; the Lifetime price already composes "once" inside `mockPlanRow`):

```swift
            VStack(spacing: 10) {
                mockPlanRow(.monthly,  price: "$3.99",  perCycle: "Billed monthly · Cancel anytime")
                mockPlanRow(.yearly,   price: "$39.99", perCycle: "Just $3.33/mo · 2 months free")
                mockPlanRow(.lifetime, price: "$99.99", perCycle: PricingConfig.lifetimePeerSubtitle)
            }
```

**10b.** Replace the entire `mockPlanRow(_:price:perCycle:)` (lines 428-494) with a tier-aware twin of the new `planRow`: consistent selection checkmark on all rows, gold Lifetime peer, "$99.99 once" composition, and the corrected solid-green badge (no longer green-on-blue, and the saving is now the Yearly sub-line so the static SAVE pill is removed):

```swift
    @ViewBuilder
    private func mockPlanRow(_ plan: Plan, price: String, perCycle: String) -> some View {
        let isSelected = selection == plan
        let isHero = (plan == .yearly)
        let isLifetime = (plan == .lifetime)
        let lifetimeGold = Color(red: 0.72, green: 0.53, blue: 0.04)
        let selectionAccent: Color = isLifetime ? lifetimeGold : Color.accentColor
        Button {
            selection = plan
            PaywallMetrics.record(.tierSelected, variant: PricingConfig.variant,
                                  trigger: trigger.metricKey, tier: plan.rawValue)
        } label: {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(planTitle(plan))
                            .font(.headline)
                        if isHero {
                            Text(PricingConfig.bestValueBadge)
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.white.opacity(0.22), in: .capsule)
                                .foregroundStyle(.white)
                        } else if isLifetime {
                            Text(PricingConfig.payOnceBadge)
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(lifetimeGold.opacity(0.16), in: .capsule)
                                .foregroundStyle(lifetimeGold)
                        }
                    }
                    Text(perCycle)
                        .font(.caption)
                        .foregroundStyle(isHero ? AnyShapeStyle(.white.opacity(0.85))
                                                : AnyShapeStyle(.secondary))
                }
                Spacer()
                if isLifetime {
                    Text("\(price) \(PricingConfig.lifetimeOnceSuffix)")
                        .font(.title3.weight(.semibold).monospacedDigit())
                } else {
                    Text(price)
                        .font(.title3.weight(.semibold).monospacedDigit())
                }
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(isHero ? AnyShapeStyle(.white)
                                                : AnyShapeStyle(selectionAccent))
                }
            }
            .padding(.vertical, isHero ? 20 : 14)
            .padding(.horizontal, 14)
            .foregroundStyle(isHero ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isHero {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(LinearGradient(
                            colors: [Color.accentColor, Color.accentColor.opacity(0.85)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                } else {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color(.secondarySystemBackground))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(isSelected ? selectionAccent : Color.gray.opacity(0.18),
                                  lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
```

**10c.** Confirm the mock CTA + disabled-state already handle `selection == .lifetime`: `purchaseButtonTitle` (Task 7b) routes through `PaywallCopy.ctaTitle` with `lifetimeDisplayPrice` (which returns "$99.99" under `mockPaywallPrices`), and `purchaseButton`'s `.disabled` (Task 9a) keeps the button enabled in mock mode because `mockPaywallPrices` is true and `lifetimeDisplayPrice` is non-nil. No further edit needed — this sub-step is a verification note, exercised in the manual check (Task 12).

Build the app, expect BUILD SUCCEEDED:

```
xcodebuild -project "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/Billable.xcodeproj" -scheme Billable -destination 'generic/platform=iOS Simulator' build
```

Then commit:

```
git -C "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports" add App/Sources/Features/Paywall/PaywallView.swift && git -C "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports" commit -m "feat(paywall): mock Lifetime row + solid-green badge for screenshots

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

## Task 11: Full BillableCore suite + clean app build (regression gate) → commit (if needed)

Run the complete BillableCore test suite and a clean app build to catch any regression from the `PricingConfig` constant removals (Task 5 dropped `lifetimeAffordanceTitle`/`Subtitle`) or the view refactor.

```
swift test --package-path "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/Packages/BillableCore"
```

Expect: all suites PASS, including `PaywallCopyMonthlyEquivalentTests`, `PaywallCopyCTATests`, and the pre-existing `PricingDisplayTests`.

Then a clean app build:

```
xcodebuild -project "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/Billable.xcodeproj" -scheme Billable -destination 'generic/platform=iOS Simulator' clean build
```

Expect BUILD SUCCEEDED. If the build surfaces a dangling reference to a removed `PricingConfig.lifetimeAffordance*` constant in another file (e.g. a metrics or test file), fix that call site to use the retained constants or remove the dead reference, rebuild to green, then commit:

```
git -C "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports" add -A && git -C "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports" commit -m "chore(paywall): reconcile call sites after tier-config refactor

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

If the build was already green with nothing to fix, skip the commit.

## Task 12: Manual verification of the three-tier picker (layout, selection, CTA, owned-state, mock)

The view layout/interaction can't be unit-tested; verify it by running the app with the StoreKit Testing config attached (Debug/Launch scheme) and the mock screenshot path.

**12a — Live three-tier picker (Simulator, Debug):** Launch the app in the Simulator (StoreKit config is attached to the Launch/Debug action), trigger the paywall from Settings → Upgrade (or the locked Reports tab). Confirm:
- Three rows render in order **Monthly / Yearly / Lifetime**.
- **Yearly** is the filled accent hero, **default-selected** (checkmark visible), with a single white-on-accent **"BEST VALUE"** pill and a sub-line reading **"Just $3.33/mo · 2 months free"** (per-locale; no separate green pill).
- **Lifetime** is a gold-accent peer with a **"PAY ONCE"** badge and price **"$99.99 once"**.
- Tapping **Monthly** moves the checkmark to Monthly (consistent affordance on a recessed card); tapping **Lifetime** shows a **gold** selection border + gold checkmark.
- CTA reads **"Start 7-day free trial"** for Monthly/Yearly and **"Buy Lifetime — $99.99"** for Lifetime.
- The savings figure in the Yearly sub-line is legible (no washed-out green-on-blue anywhere).

**12b — Owned-Lifetime collapse:** Relaunch with the `--pretend-pro` override (or purchase Lifetime in the StoreKit Testing transaction manager) so `manager.ownsLifetime == true`. Confirm the paywall shows **no purchase rows and no CTA** — only the **"You own Cadence Pro forever ✓"** label plus the Terms/Privacy links.

**12c — Mock screenshot path:** Edit the Billable scheme's Run arguments to pass `--mock-paywall-prices`, launch, and confirm the paywall renders **all three tiers** ($3.99 / $39.99 / $99.99 once) with the corrected solid-green saving in the Yearly sub-line, that selecting Lifetime updates the CTA to "Buy Lifetime — $99.99", and that the CTA stays **enabled** in mock mode. Remove the launch arg afterward.

Record the observations (PASS/FAIL per bullet) as the verification evidence for B1; no code change in this step unless a defect is found (in which case loop back to the relevant task).

## Task 13: Verify worktree baseline and read the exact code anchors before writing any tests

**No code change in this step — establish ground truth on the actual checkout so every subsequent EXACT line reference is correct.**

This worktree (`feature/paywall-reports`) is branched off `origin/main` (6fa10a6), which ALREADY includes the merged PR #25 CloudKit crash fix (the `\.project?.client` → single-hop fix; only explanatory comments now mention the old keypath). The line numbers in this plan were captured during investigation and must still be re-verified on the live checkout before editing. Do this first.

Run these read-only commands and confirm the outputs match expectations:

```bash
# 1. Confirm worktree + branch
git -C "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports" status --short --branch

# 2. Confirm the existing TrendPoint type + snapshot func anchor (math will be appended AFTER snapshot, before the `groupings` MARK)
grep -n "struct TrendPoint" "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/Packages/BillableCore/Sources/BillableCore/Reporting/ReportsAggregator.swift"
grep -n "public static func snapshot" "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/Packages/BillableCore/Sources/BillableCore/Reporting/ReportsAggregator.swift"
grep -n "MARK: - " "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/Packages/BillableCore/Sources/BillableCore/Reporting/ReportsAggregator.swift"

# 3. Confirm MoneySummary.collected recipe (the scalar we are generalizing)
grep -n "collected" "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/Packages/BillableCore/Sources/BillableCore/Reporting/ReportsAggregator.swift"

# 4. Confirm Invoice fields used by the aggregation
grep -n "var paidAt\|var statusRaw\|var status:\|var total:\|var currencyCodeSnapshot\|enum InvoiceStatus" "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/Packages/BillableCore/Sources/BillableCore/Models/Invoice.swift"

# 5. Confirm the existing test-suite helper pattern + fixed reference date convention
grep -rn "1_700_000_000\|func makeInvoice\|Calendar(identifier: .gregorian)\|@testable import BillableCore\|import Testing" "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/Packages/BillableCore/Tests/BillableCoreTests/" | head -40

# 6. Confirm PaywallView anchors: @Query, makeTeaserModel, sampleTeaserModel, ReportsTeaserModel, crispTasteHeader, teaser tiles, currency helper
grep -n "reportInvoices\|func makeTeaserModel\|func sampleTeaserModel\|struct ReportsTeaserModel\|var crispTasteHeader\|func teaserARCard\|func teaserTileRow\|func teaserTile\|func currency(\|hasReportableData\|profiles.first?.currencyCode\|trigger.headline\|import Charts" "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/App/Sources/Features/Paywall/PaywallView.swift"

# 7. Confirm ReportsView chart idiom (BarMark Decimal->Double, axis format, gradient) we must match
grep -n "BarMark\|doubleValue\|foregroundStyle(Color\|chartXAxis\|month(.abbreviated)\|frame(height:" "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/App/Sources/Features/Reports/ReportsView.swift"

# 8. Confirm ReportsSampleData current shape + the existing `collected` scalar (new series anchors to it)
grep -n "static let" "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/App/Sources/Features/Reports/ReportsSampleData.swift"

# 9. Confirm Trigger.headline current copy (the headline we shorten)
grep -n "case reports\|headline\|Know what you" "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/App/Sources/Features/Paywall/PaywallView.swift"
```

**Verification:** All anchors resolve. In particular: `TrendPoint` exists with `id: Date`, `bucketStart: Date`, `amount: Decimal`; `snapshot(...)` and a `// MARK: - groupings` (or similar) MARK both exist so the new func can be inserted between them; `MoneySummary.collected` shows the `status == .paid && paidAt-in-range` recipe; `Invoice` exposes `paidAt: Date?`, `status` (typed over `statusRaw`), `total: Decimal`, `currencyCodeSnapshot: String`; the test dir already uses `import Testing` + `@testable import BillableCore` + a `makeInvoice(...)` helper + the `1_700_000_000` reference date; `ReportsView.swift` feeds `BarMark` a `Double` via `(point.amount as NSDecimalNumber).doubleValue`. If any line reference differs from the findings, RECORD the corrected line numbers and use those in all later tasks. Do NOT proceed until confirmed.

## Task 14: Write the FIRST failing test — `collectedMonthlyTrend` returns exactly `monthsBack` gap-filled monthly buckets, oldest→newest, ending the asOf month

Create the new BillableCore test file. Mirror the existing suites' conventions confirmed in Task 13 (`import Testing`, `@testable import BillableCore`, a private `makeInvoice(...)` helper, fixed reference date `1_700_000_000`, explicit `Calendar(identifier: .gregorian)`).

Create `/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/Packages/BillableCore/Tests/BillableCoreTests/ReportsCollectedTrendTests.swift`:

```swift
import Testing
import Foundation
@testable import BillableCore

@Suite("ReportsAggregator.collectedMonthlyTrend")
struct ReportsCollectedTrendTests {

    // Fixed reference instant used across the BillableCore reporting suites for determinism.
    // 1_700_000_000 == 2023-11-14 22:13:20 UTC.
    private let asOf = Date(timeIntervalSince1970: 1_700_000_000)
    private var gregorian: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// Builds a paid/sent/draft invoice with a single line item summing to `total` (taxRate 0 by default).
    private func makeInvoice(
        total: Decimal,
        status: InvoiceStatus,
        issued: Date,
        paid: Date?,
        currency: String = "USD",
        taxRate: Decimal = 0
    ) -> Invoice {
        // FULL required-param Invoice.init (matches the canonical helper in
        // ReportsSnapshotIntegrationTests.swift:17) + a threaded taxRate so Task 19
        // can assert a tax-inclusive total. One line item at hours:1 × rate:total
        // ⇒ subtotal == total; status is passed to the init (not set after).
        let inv = Invoice(
            number: "INV-1", issuedAt: issued, dueAt: issued, status: status,
            clientNameSnapshot: "C", issuerNameSnapshot: "Me", issuerAddressSnapshot: "",
            issuerEmailSnapshot: "", paymentTermsSnapshot: "", taxLabelSnapshot: "",
            taxRateSnapshot: taxRate, currencyCodeSnapshot: currency,
            lineItems: [InvoiceLineItem(description: "work", hours: 1, hourlyRate: total)]
        )
        inv.paidAt = paid
        return inv
    }

    /// First instant of the calendar month `monthsAgo` months before the asOf month.
    private func monthStart(_ monthsAgo: Int) -> Date {
        let thisMonth = gregorian.dateInterval(of: .month, for: asOf)!.start
        return gregorian.date(byAdding: .month, value: -monthsAgo, to: thisMonth)!
    }

    @Test("returns exactly monthsBack points, oldest→newest, ids == month starts ending asOf month")
    func returnsGapFilledWindow() {
        let points = ReportsAggregator.collectedMonthlyTrend(
            invoices: [],
            activeCurrency: "USD",
            monthsBack: 6,
            asOf: asOf,
            calendar: gregorian
        )

        #expect(points.count == 6)
        // Oldest first (5 months ago) … newest last (current month).
        let expectedStarts = (0..<6).reversed().map { monthStart($0) }
        #expect(points.map(\.bucketStart) == expectedStarts)
        #expect(points.map(\.id) == expectedStarts)
        // Empty input → all zero buckets (gap-filled, not an empty array).
        #expect(points.allSatisfy { $0.amount == 0 })
    }
}
```

**Verification:** Run BillableCore tests — expect **FAIL to COMPILE** (the symbol `ReportsAggregator.collectedMonthlyTrend` does not exist yet). This is the expected red state.

```bash
swift test --package-path "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/Packages/BillableCore" 2>&1 | tail -30
```

Confirm the output contains a compile error referencing `collectedMonthlyTrend` (e.g. "type 'ReportsAggregator' has no member 'collectedMonthlyTrend'"). Do NOT add the implementation yet.

> NOTE: `makeInvoice` above uses the FULL required-param `Invoice.init` (the same shape as the canonical helper in `ReportsSnapshotIntegrationTests.swift:17`), so it compiles against the real model — the ONLY unresolved symbol should be `collectedMonthlyTrend`. If Task 13 surfaced any init-param rename, adjust `makeInvoice` to match; never let anything but `collectedMonthlyTrend` be the missing symbol.

## Task 15: Minimal implementation — add the pure `collectedMonthlyTrend` aggregation to `ReportsAggregator`, make Task 14 pass

Insert the new pure static func into the existing `ReportsAggregator` enum, immediately AFTER the `snapshot(...)` function and BEFORE the `// MARK: - groupings` (use the exact insertion point confirmed in Task 13).

In `/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/Packages/BillableCore/Sources/BillableCore/Reporting/ReportsAggregator.swift`, add:

```swift
    // MARK: - Collected monthly trend (paywall teaser)

    /// Σ `invoice.total` of PAID invoices, grouped by the calendar month of `paidAt`, over a
    /// fixed trailing window of `monthsBack` months ending the `referenceDate` month.
    ///
    /// Pure: takes plain `[Invoice]`, returns `[TrendPoint]` (oldest→newest), no SwiftData /
    /// `ModelContext` / fetch. Months with no collected invoices are gap-filled with `amount == 0`,
    /// so the result always has exactly `monthsBack` elements (a continuous bar axis).
    ///
    /// "Collected" is binary at the invoice level (no `Payment` model / partial-payment field):
    /// an invoice counts iff `status == .paid`; its bucket is `month(paidAt)` (a `.paid` invoice
    /// with `paidAt == nil` is excluded); its contribution is `invoice.total` (tax-inclusive).
    /// This is the series generalization of the scalar `MoneySummary.collected`, so the chart
    /// agrees with the COLLECTED tile. Currency-filtered FIRST (never sums across currencies).
    public static func collectedMonthlyTrend(
        invoices: [Invoice],
        activeCurrency: String,
        monthsBack: Int = 6,
        asOf referenceDate: Date = .now,
        calendar: Calendar = .current
    ) -> [TrendPoint] {
        guard monthsBack > 0 else { return [] }

        // Currency guard first — mirrors snapshot(...)'s mixed-currency exclusion.
        let scoped = invoices.filter { $0.currencyCodeSnapshot == activeCurrency }

        guard let thisMonthStart = calendar.dateInterval(of: .month, for: referenceDate)?.start,
              let oldestStart = calendar.date(byAdding: .month, value: -(monthsBack - 1), to: thisMonthStart)
        else { return [] }

        // Pre-group paid invoices by their paidAt month-start (O(N)). The nil key bucket
        // (paid but no paidAt) is simply never walked below, so it is excluded.
        let paidByMonth = Dictionary(grouping: scoped.filter { $0.status == .paid }) { inv in
            inv.paidAt.flatMap { calendar.dateInterval(of: .month, for: $0)?.start }
        }

        var points: [TrendPoint] = []
        var cursor = oldestStart
        var guardCount = 0
        while guardCount < monthsBack {
            let amount = (paidByMonth[cursor] ?? []).reduce(Decimal(0)) { $0 + $1.total }
            points.append(TrendPoint(id: cursor, bucketStart: cursor, amount: amount))
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = next
            guardCount += 1
        }
        return points
    }
```

**Verification:** Run the BillableCore tests — expect Task 14's test to **PASS** (compiles + green).

```bash
swift test --package-path "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/Packages/BillableCore" --filter ReportsCollectedTrendTests 2>&1 | tail -20
```

Confirm `returnsGapFilledWindow` passes and the suite compiles.

## Task 16: Commit the green core skeleton

```bash
git -C "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports" add "Packages/BillableCore/Sources/BillableCore/Reporting/ReportsAggregator.swift" "Packages/BillableCore/Tests/BillableCoreTests/ReportsCollectedTrendTests.swift"
git -C "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports" commit -m "feat(reports): collectedMonthlyTrend aggregation + gap-fill test (B2)

Pure BillableCore static func: Σ paid-invoice total bucketed by month(paidAt)
over a fixed trailing window, oldest→newest, gap-filled. First test covers the
empty-input window shape (exactly monthsBack zero buckets).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

**Verification:** `git -C "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports" log --oneline -1` shows the commit.

## Task 17: Behavior-locking tests (green-on-arrival) — a paid invoice lands in its `paidAt` month at `total`; paid-but-issued-earlier lands in the PAID month (the core correctness assertion)

Add these tests to the existing `ReportsCollectedTrendTests` struct in `/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/Packages/BillableCore/Tests/BillableCoreTests/ReportsCollectedTrendTests.swift` (insert before the closing `}` of the struct):

```swift
    @Test("a paid invoice sums into the bucket of its paidAt month at invoice.total")
    func paidInvoiceLandsInPaidMonth() {
        // Paid 2 months ago.
        let paidDate = gregorian.date(byAdding: .day, value: 3, to: monthStart(2))!
        let inv = makeInvoice(total: 500, status: .paid, issued: paidDate, paid: paidDate)

        let points = ReportsAggregator.collectedMonthlyTrend(
            invoices: [inv], activeCurrency: "USD", monthsBack: 6, asOf: asOf, calendar: gregorian
        )

        // Index 3 == "2 months ago" in a 6-bucket oldest→newest window (0:−5 … 5:−0).
        #expect(points[3].bucketStart == monthStart(2))
        #expect(points[3].amount == 500)
        // Every other bucket stays zero.
        #expect(points.enumerated().filter { $0.offset != 3 }.allSatisfy { $0.element.amount == 0 })
    }

    @Test("an invoice issued in an earlier month but paid in a later in-window month lands in the PAID month")
    func bucketsByPaidAtNotIssuedAt() {
        let issued = gregorian.date(byAdding: .day, value: 2, to: monthStart(4))!   // issued 4 months ago
        let paid = gregorian.date(byAdding: .day, value: 5, to: monthStart(1))!     // paid 1 month ago
        let inv = makeInvoice(total: 750, status: .paid, issued: issued, paid: paid)

        let points = ReportsAggregator.collectedMonthlyTrend(
            invoices: [inv], activeCurrency: "USD", monthsBack: 6, asOf: asOf, calendar: gregorian
        )

        // Lands in the PAID month (index 4 == 1 month ago), NOT the issued month (index 1 == 4 months ago).
        #expect(points[4].amount == 750)
        #expect(points[1].amount == 0)
    }
```

**Verification:** Run the suite — expect both new tests to **PASS** already (the Task 15 implementation buckets by `paidAt` and sums `total` correctly). This step is a behavior-locking guard, not a red→green pair; confirm green and that NOTHING regressed.

```bash
swift test --package-path "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports" --filter ReportsCollectedTrendTests 2>&1 | tail -25
```

Confirm `paidInvoiceLandsInPaidMonth` and `bucketsByPaidAtNotIssuedAt` both pass. (If `bucketsByPaidAtNotIssuedAt` were to fail, the implementation would be bucketing by `issuedAt` — fix the implementation, not the test.)

## Task 18: Behavior-locking tests (green-on-arrival) — exclusions (draft/sent contribute 0; paidAt==nil excluded; out-of-window & future excluded; currency guard) and same-month aggregation

Add these tests to `ReportsCollectedTrendTests` in `/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/Packages/BillableCore/Tests/BillableCoreTests/ReportsCollectedTrendTests.swift` (before the struct's closing `}`):

```swift
    @Test("draft and sent invoices contribute 0 (only .paid counts)")
    func nonPaidStatusesExcluded() {
        let when = gregorian.date(byAdding: .day, value: 3, to: monthStart(2))!
        let draft = makeInvoice(total: 999, status: .draft, issued: when, paid: nil)
        let sent  = makeInvoice(total: 888, status: .sent,  issued: when, paid: nil)

        let points = ReportsAggregator.collectedMonthlyTrend(
            invoices: [draft, sent], activeCurrency: "USD", monthsBack: 6, asOf: asOf, calendar: gregorian
        )
        #expect(points.allSatisfy { $0.amount == 0 })
    }

    @Test("a .paid invoice with paidAt == nil is excluded")
    func paidWithNilPaidAtExcluded() {
        let when = gregorian.date(byAdding: .day, value: 3, to: monthStart(2))!
        let inv = makeInvoice(total: 600, status: .paid, issued: when, paid: nil)

        let points = ReportsAggregator.collectedMonthlyTrend(
            invoices: [inv], activeCurrency: "USD", monthsBack: 6, asOf: asOf, calendar: gregorian
        )
        #expect(points.allSatisfy { $0.amount == 0 })
    }

    @Test("paid OLDER than the window, and paid in a FUTURE month, are both excluded")
    func outOfWindowExcluded() {
        let tooOld = gregorian.date(byAdding: .day, value: 3, to: monthStart(7))!   // 7 months ago (window is 6)
        let future = gregorian.date(byAdding: .month, value: 2, to: asOf)!          // 2 months ahead
        let oldInv = makeInvoice(total: 400, status: .paid, issued: tooOld, paid: tooOld)
        let futInv = makeInvoice(total: 300, status: .paid, issued: future, paid: future)

        let points = ReportsAggregator.collectedMonthlyTrend(
            invoices: [oldInv, futInv], activeCurrency: "USD", monthsBack: 6, asOf: asOf, calendar: gregorian
        )
        #expect(points.allSatisfy { $0.amount == 0 })
    }

    @Test("an invoice in a non-matching currency contributes 0 (currency guard)")
    func currencyGuardExcludes() {
        let when = gregorian.date(byAdding: .day, value: 3, to: monthStart(2))!
        let foreign = makeInvoice(total: 5000, status: .paid, issued: when, paid: when, currency: "EUR")

        let points = ReportsAggregator.collectedMonthlyTrend(
            invoices: [foreign], activeCurrency: "USD", monthsBack: 6, asOf: asOf, calendar: gregorian
        )
        #expect(points.allSatisfy { $0.amount == 0 })
    }

    @Test("two paid invoices in the same month aggregate into one bucket")
    func sameMonthAggregates() {
        let d1 = gregorian.date(byAdding: .day, value: 2,  to: monthStart(3))!
        let d2 = gregorian.date(byAdding: .day, value: 20, to: monthStart(3))!
        let a = makeInvoice(total: 200, status: .paid, issued: d1, paid: d1)
        let b = makeInvoice(total: 350, status: .paid, issued: d2, paid: d2)

        let points = ReportsAggregator.collectedMonthlyTrend(
            invoices: [a, b], activeCurrency: "USD", monthsBack: 6, asOf: asOf, calendar: gregorian
        )
        // Index 2 == 3 months ago.
        #expect(points[2].amount == 550)
    }
```

**Verification:** Run the suite — expect all five to **PASS** with the Task 15 implementation (it filters `.paid`, drops nil-`paidAt` via the unwalked nil key, currency-filters first, window-bounds by cursor walk, and sums per bucket).

```bash
swift test --package-path "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports" --filter ReportsCollectedTrendTests 2>&1 | tail -30
```

Confirm `nonPaidStatusesExcluded`, `paidWithNilPaidAtExcluded`, `outOfWindowExcluded`, `currencyGuardExcludes`, `sameMonthAggregates` all pass.

## Task 19: Behavior-locking tests (green-on-arrival) — month-boundary instant lands in the correct month, and `amount` is tax-INCLUSIVE (`total`, not subtotal)

Add these tests to `ReportsCollectedTrendTests` in `/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/Packages/BillableCore/Tests/BillableCoreTests/ReportsCollectedTrendTests.swift` (before the struct's closing `}`):

```swift
    @Test("paidAt exactly at a month's first instant lands in that month, not the prior one")
    func monthBoundaryInstant() {
        let boundary = monthStart(2)   // 00:00:00 on the first of the month, 2 months ago
        let inv = makeInvoice(total: 100, status: .paid, issued: boundary, paid: boundary)

        let points = ReportsAggregator.collectedMonthlyTrend(
            invoices: [inv], activeCurrency: "USD", monthsBack: 6, asOf: asOf, calendar: gregorian
        )
        // Index 3 == 2 months ago; index 4 == 1 month ago (the would-be "prior month" error bucket).
        #expect(points[3].amount == 100)
        #expect(points[4].amount == 0)
    }

    @Test("amount equals tax-inclusive total (subtotal + tax), not subtotal")
    func amountIsTaxInclusive() {
        let when = gregorian.date(byAdding: .day, value: 3, to: monthStart(2))!
        // subtotal 1000, taxRate 0.15 → total 1150.
        let inv = makeInvoice(total: 1000, status: .paid, issued: when, paid: when, taxRate: 0.15)

        let points = ReportsAggregator.collectedMonthlyTrend(
            invoices: [inv], activeCurrency: "USD", monthsBack: 6, asOf: asOf, calendar: gregorian
        )
        #expect(points[3].amount == Decimal(1150))
    }
```

**Verification:** Run the suite — expect both to **PASS** (the implementation uses `calendar.dateInterval(of: .month,…).start` for both bucketing and the boundary, and sums `invoice.total` which is `subtotal + taxAmount`).

```bash
swift test --package-path "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports" --filter ReportsCollectedTrendTests 2>&1 | tail -25
```

Confirm `monthBoundaryInstant` and `amountIsTaxInclusive` pass.

> NOTE: If `amountIsTaxInclusive` fails because the real `Invoice.taxAmount`/`total` computation rounds differently (e.g. bankers-rounding to cents), adjust the EXPECTED value to the model's actual `total` for subtotal 1000 @ 0.15 — do NOT change the implementation; `total` is the model's source of truth and the test must match it. Re-derive the expected number from `Invoice.total` semantics confirmed in Task 13.

## Task 20: Write the failing test for the App-side real-vs-sample gate predicate `hasTwoMonthsCollected`

The <2-months-history gate is presentation policy (App-side), but it is a pure predicate over `[TrendPoint]`, so it is unit-testable. Per the locked design it lives App-side; however App-target files are not reachable by `swift test`. To keep it testable, place the pure predicate in **BillableCore** as a small static helper on `ReportsAggregator` (pure math, no SwiftData — consistent with the rest of the aggregator) and have PaywallView call it. This preserves testability without a fake view test.

First, the failing test. Add to `ReportsCollectedTrendTests` in `/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/Packages/BillableCore/Tests/BillableCoreTests/ReportsCollectedTrendTests.swift` (before the struct's closing `}`):

```swift
    @Test("hasEnoughCollectedHistory requires ≥2 distinct months with positive collected amount")
    func enoughHistoryPredicate() {
        let zero = (0..<6).reversed().map { TrendPoint(id: monthStart($0), bucketStart: monthStart($0), amount: 0) }
        #expect(ReportsAggregator.hasEnoughCollectedHistory(zero) == false)

        // Exactly one positive month → still not enough.
        var one = zero
        one[3] = TrendPoint(id: one[3].id, bucketStart: one[3].bucketStart, amount: 500)
        #expect(ReportsAggregator.hasEnoughCollectedHistory(one) == false)

        // Two positive months → enough.
        var two = one
        two[5] = TrendPoint(id: two[5].id, bucketStart: two[5].bucketStart, amount: 200)
        #expect(ReportsAggregator.hasEnoughCollectedHistory(two) == true)
    }
```

**Verification:** Run the suite — expect **FAIL to COMPILE** (`hasEnoughCollectedHistory` does not exist yet).

```bash
swift test --package-path "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports" --filter ReportsCollectedTrendTests 2>&1 | tail -20
```

Confirm the output references the missing `hasEnoughCollectedHistory` member. Do NOT implement yet.

## Task 21: Minimal implementation — add `hasEnoughCollectedHistory` to `ReportsAggregator`, make Task 20 pass

In `/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/Packages/BillableCore/Sources/BillableCore/Reporting/ReportsAggregator.swift`, add this helper immediately after `collectedMonthlyTrend` (same `// MARK: - Collected monthly trend (paywall teaser)` section):

```swift
    /// Presentation gate for the paywall teaser: returns `true` only when at least two distinct
    /// months in the trend carry a positive collected amount. Below that threshold the caller
    /// shows a clearly-labeled SAMPLE chart instead of a sparse/declining real trend, so a thin
    /// history never reads as "your numbers". Pure predicate — unit-tested in BillableCore.
    public static func hasEnoughCollectedHistory(_ trend: [TrendPoint]) -> Bool {
        trend.filter { $0.amount > 0 }.count >= 2
    }
```

**Verification:** Run the suite — expect Task 20's `enoughHistoryPredicate` to **PASS** and all prior collected-trend tests to remain green.

```bash
swift test --package-path "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports" --filter ReportsCollectedTrendTests 2>&1 | tail -20
```

Confirm `enoughHistoryPredicate` passes.

## Task 22: Run the FULL BillableCore suite (no regressions) and commit the complete tested aggregation

Run the entire BillableCore test suite to prove the new pure functions did not disturb existing Reports tests.

```bash
swift test --package-path "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports" 2>&1 | tail -30
```

**Verification:** Whole suite reports success (e.g. all tests passed; previously-passing count + the new collected-trend tests, zero failures).

Then commit:

```bash
git -C "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports" add "Packages/BillableCore/Sources/BillableCore/Reporting/ReportsAggregator.swift" "Packages/BillableCore/Tests/BillableCoreTests/ReportsCollectedTrendTests.swift"
git -C "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports" commit -m "test(reports): full collectedMonthlyTrend coverage + history gate (B2)

Locks: bucket-by-paidAt (not issuedAt), tax-inclusive total, draft/sent &
nil-paidAt & out-of-window & future & wrong-currency exclusions, same-month
aggregation, month-boundary instant. Adds pure hasEnoughCollectedHistory gate
(≥2 positive months) for the <2-months-history sample fallback.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

**Verification:** `git -C "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports" log --oneline -2` shows both B2-core commits. The entire testable CORE of B2 (the riskiest item) is now complete and green BEFORE any view work.

## Task 23: Add the App-target sample monthly-collected series to `ReportsSampleData`

Now the App layer. Add the 6-month sample series (display-only, never persisted, NOT currency/locale-bound) anchored so its final value equals the existing `collected` scalar.

Read `/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/App/Sources/Features/Reports/ReportsSampleData.swift` first to confirm the exact current members, then add the series.

Add to the `ReportsSampleData` enum (place it after the existing `collected` scalar):

```swift
    /// Six-month "collected" sample series (oldest→newest) for the paywall teaser chart when the
    /// user has <2 months of real collected history. Display-only, never persisted. One organic
    /// mid dip (1950) so it reads real, not linear-fake. The FINAL value equals `collected` (2400)
    /// so the chart's last bar agrees with the COLLECTED tile.
    static let collectedLast6Months: [Decimal] = [1800, 2200, 1950, 2600, 3100, 2400]
```

**Verification:** No test for a plain constant. It will compile as part of the app build in Task 26. Confirm via:

```bash
grep -n "collectedLast6Months" "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/App/Sources/Features/Reports/ReportsSampleData.swift"
```

Confirm the constant is present and `collected` (the existing scalar) still equals `Decimal(2400)` so the anchor holds.

## Task 24: Wire the chart data into `PaywallView` — extend `ReportsTeaserModel` + `makeTeaserModel`/`sampleTeaserModel` with the collected series and the real-vs-sample gate

Read the exact current bodies of `ReportsTeaserModel`, `makeTeaserModel()`, `sampleTeaserModel()` (and the `currency(_:code:)` helper + `profiles.first?.currencyCode` access) in `/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/App/Sources/Features/Paywall/PaywallView.swift` using the line numbers confirmed in Task 13, then make these edits.

**(a)** Ensure `import Charts` is present at the top of the file (add it under the existing imports if missing — confirmed absent/present in Task 13):

```swift
import Charts
```

**(b)** Add the series field to `ReportsTeaserModel` (add alongside the existing `collected`/`isSample` fields):

```swift
    /// Six monthly "collected" buckets (oldest→newest) driving the teaser bar chart.
    let collectedSeries: [ReportsAggregator.TrendPoint]
```

**(c)** Add a small helper that builds a sample `[TrendPoint]` by zipping `ReportsSampleData.collectedLast6Months` onto the trailing 6 real month-starts ending the current month (so X-axis month labels are derived, never hardcoded). Add it as a private helper near `makeTeaserModel`:

```swift
    /// Builds a sample collected series mapped onto the real trailing-6 month starts ending now,
    /// so month labels are calendar-derived (never hardcoded) while amounts are the sample values.
    private func sampleCollectedSeries(asOf now: Date = .now, calendar: Calendar = .current) -> [ReportsAggregator.TrendPoint] {
        let values = ReportsSampleData.collectedLast6Months
        guard let thisMonthStart = calendar.dateInterval(of: .month, for: now)?.start else { return [] }
        let count = values.count
        return values.enumerated().compactMap { idx, amount in
            // idx 0 == oldest (count-1 months ago) … idx count-1 == current month.
            guard let start = calendar.date(byAdding: .month, value: -(count - 1 - idx), to: thisMonthStart) else { return nil }
            return ReportsAggregator.TrendPoint(id: start, bucketStart: start, amount: amount)
        }
    }
```

**(d)** In `makeTeaserModel()`, compute the real series and apply the two-tier gate. Locate the existing branch that switches on `snap.hasReportableData` (confirmed in Task 13) and adjust so the REAL series is used only when there is reportable data AND enough collected history; otherwise fall back to the sample series with `isSample: true`.

Replace the real-branch model construction so it includes `collectedSeries`. Concretely, where the real `ReportsTeaserModel(...)` is built, add:

```swift
        let code = profiles.first?.currencyCode ?? "USD"
        let realSeries = ReportsAggregator.collectedMonthlyTrend(
            invoices: reportInvoices,
            activeCurrency: code
        )
        let collectedHistoryOK = ReportsAggregator.hasEnoughCollectedHistory(realSeries)
```

and gate the existing `snap.hasReportableData` real/sample decision on `snap.hasReportableData && collectedHistoryOK`. In the REAL `ReportsTeaserModel(...)` initializer add `collectedSeries: realSeries`; in the SAMPLE `ReportsTeaserModel(...)` initializer add `collectedSeries: sampleCollectedSeries()` and keep `isSample: true`.

**(e)** In `sampleTeaserModel()` (the first-frame placeholder at the line confirmed in Task 13), add `collectedSeries: sampleCollectedSeries()` to its `ReportsTeaserModel(...)` initializer and keep its existing `isSample` value.

**Verification:** This is wiring; it is verified by the app build in Task 26 (and the manual check in Task 28). For now confirm the edits are internally consistent — every `ReportsTeaserModel(...)` call site sets `collectedSeries`:

```bash
grep -n "ReportsTeaserModel(" "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/App/Sources/Features/Paywall/PaywallView.swift"
grep -n "collectedSeries\|hasEnoughCollectedHistory\|collectedMonthlyTrend\|sampleCollectedSeries" "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/App/Sources/Features/Paywall/PaywallView.swift"
```

Confirm the `collectedSeries:` count equals the `ReportsTeaserModel(` call-site count (every initializer is updated). Do NOT build yet — the view body (headline + locked container + chart) is replaced in Task 25 so the build is meaningful once.

## Task 25: Rebuild the teaser view — shorten the headline, add the always-on "🔒 Your Reports preview" eyebrow + tinted/bordered locked container, and LEAD with the "Collected · last 6 months" bar chart + compact stat line

Read the exact current `crispTasteHeader`, `teaserARCard`, `teaserTileRow`, `teaserTile`, and the `Trigger.headline` definition in `/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/App/Sources/Features/Paywall/PaywallView.swift` (line numbers from Task 13). Make these edits.

**(a) Shorten the headline.** Change the `.reports` trigger headline to `"Know what you're owed."`. If `Trigger.headline` is a computed `switch`, edit the `.reports` case string. Then change the headline modifiers in `crispTasteHeader` from `.lineLimit(2).minimumScaleFactor(0.7)` to `.lineLimit(1)` (drop the shrink factor entirely):

```swift
        Text(trigger.headline)
            .font(.largeTitle.weight(.bold))
            .lineLimit(1)
```

**(b) Add a stat-line helper** that renders the compact Owed / This year / Effective rate row from the snapshot-derived values already available to the teaser. Read where `crispTasteHeader` obtains its model (the memoized `teaserModel`) and the `currency(_:code:)` helper (Task 13). Add a private helper:

```swift
    @ViewBuilder
    private func teaserStatLine(_ model: ReportsTeaserModel) -> some View {
        HStack(spacing: 16) {
            statCell("Owed", currency(model.outstanding, code: model.currencyCode))
            Divider().frame(height: 28)
            statCell("This year", currency(model.collected, code: model.currencyCode))
            Divider().frame(height: 28)
            statCell("Effective rate", model.effectiveRate.map { "\(currency($0, code: model.currencyCode))/h" } ?? "—")
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func statCell(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
```

> NOTE: `ReportsTeaserModel` already carries `outstanding`, `collected`, `effectiveRate`, `currencyCode` (confirmed in Task 13). "This year" maps to `model.collected` per the locked design's stat-line mapping; if the owner later wants invoiced-this-year, that is a one-field swap. `effectiveRate` is optional → shows "—" when nil. No USD literals: all money goes through the existing `currency(_:code:)` helper with `model.currencyCode`.

**(c) Add the locked chart hero** — a tinted, bordered container with a lock eyebrow that LEADS the showcase. Add a private helper:

```swift
    @ViewBuilder
    private func teaserChartHero(_ model: ReportsTeaserModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Always-on locked-preview eyebrow (both real and sample states).
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.caption2.weight(.semibold))
                Text("Your Reports preview")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(.tint)

            Text("Collected · last 6 months")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Chart(model.collectedSeries) { point in
                BarMark(
                    x: .value("Month", point.bucketStart, unit: .month),
                    y: .value("Collected", (point.amount as NSDecimalNumber).doubleValue)
                )
                .foregroundStyle(Color.green.gradient)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month(.abbreviated))
                }
            }
            .chartYAxis(.hidden)
            .frame(height: 140)

            teaserStatLine(model)
        }
        .padding(16)
        .background(Color.accentColor.opacity(0.06), in: .rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
        }
    }
```

> NOTE: Bar color is `Color.green.gradient` — **OWNER CONFIRMED green (2026-06-02)**: the semantic match to the green COLLECTED tile. The considered alternative (`revenueTrendChart`'s `Color.blue.gradient`) was declined — do NOT use blue. `BarMark` is fed a `Double` via `(point.amount as NSDecimalNumber).doubleValue`, matching `ReportsView.revenueTrendChart` (Task 13) — NOT a raw `Decimal`. The tint-derived eyebrow/border carry the "locked Pro preview" treatment that does not exist today.

**(d) Replace the showcase block in `crispTasteHeader`.** Swap the old `teaserARCard(model)` + `teaserTileRow(model)` (the tiles) for `teaserChartHero(model)` as the LEADING element, preserving the existing `.redacted(reason: isPlaceholder ? .placeholder : [])` + `.accessibilityHidden(true)` wrapper and the existing `.caption2`/`.tertiary` "Sample preview" tag shown when `model.isSample && !isPlaceholder`. Concretely, inside `crispTasteHeader`, replace the two showcase calls with:

```swift
            teaserChartHero(model)
                .redacted(reason: isPlaceholder ? .placeholder : [])
                .accessibilityHidden(true)

            if model.isSample && !isPlaceholder {
                Text("Sample preview")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
```

> NOTE: Keep the EXISTING redaction/`isPlaceholder` flag and `accessibilityHidden(true)` exactly as they are in the current `crispTasteHeader` (Task 13 confirms their names). The "Sample preview" caption is the watermark for the <2-months sample chart (and the first-frame placeholder). If `teaserARCard`/`teaserTileRow`/`teaserTile` become unused after this swap and are not referenced elsewhere, delete them to avoid dead code (confirm with a grep before deleting).

**Verification:** Verified by the app build (Task 26) + manual check (Task 28). For now confirm the new helpers exist and the old tiles are no longer referenced in `crispTasteHeader`:

```bash
grep -n "teaserChartHero\|teaserStatLine\|statCell\|Your Reports preview\|Collected · last 6 months\|teaserARCard\|teaserTileRow" "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/App/Sources/Features/Paywall/PaywallView.swift"
```

Confirm `teaserChartHero` is referenced inside the header and the old `teaserARCard`/`teaserTileRow` are either deleted or unreferenced by the header.

## Task 26: Regenerate the project if stale, then build the app — fix until BUILD SUCCEEDED

Generate the Xcode project (in case `project.yml` membership changed) and build for the iOS Simulator.

```bash
xcodegen generate --spec "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/project.yml" --project "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports"
xcodebuild -project "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/Billable.xcodeproj" -scheme Billable -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -40
```

**Verification:** Output ends with `** BUILD SUCCEEDED **`. If it fails, fix the cause (common: missing `import Charts`; a `ReportsTeaserModel(...)` call site missing `collectedSeries:`; `Chart`/`BarMark`/`AxisMarks` API mismatch; an optional `effectiveRate` unwrap; a renamed `isPlaceholder`/`isSample` field). Re-run until it succeeds. Do NOT edit tests to make the build pass — only the implementation/wiring.

## Task 27: Re-run the full BillableCore suite (post-app-wiring regression gate) and commit the App-layer integration

The App edits don't change BillableCore, but the gate predicate + aggregation are now consumed; re-run the pure suite to confirm nothing drifted, then commit the App layer.

```bash
swift test --package-path "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports" 2>&1 | tail -15
```

**Verification:** All BillableCore tests still pass.

Then commit the App-layer work (sample series + view rebuild + wiring):

```bash
git -C "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports" add "App/Sources/Features/Reports/ReportsSampleData.swift" "App/Sources/Features/Paywall/PaywallView.swift"
git -C "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports" commit -m "feat(paywall): chart-led locked Reports teaser + monthly-collected wiring (B2)

Shorten headline to 'Know what you're owed.' (lineLimit 1, no shrink); add an
always-on '🔒 Your Reports preview' eyebrow + tinted/bordered locked container;
lead with a 'Collected · last 6 months' bar chart (green.gradient, Decimal→Double
to match ReportsView) + compact Owed/This year/Effective rate stat line. Feed it
ReportsAggregator.collectedMonthlyTrend over the existing single-hop @Query
reportInvoices; gate real-vs-sample on hasReportableData && hasEnoughCollectedHistory,
with a watermarked sample series (ReportsSampleData.collectedLast6Months) for
<2-months history. Block stays .redacted + .accessibilityHidden(true).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

**Verification:** `git -C "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports" log --oneline -3` shows the three B2 commits (core skeleton, full core coverage, app integration).

## Task 28: MANUAL verification of the locked teaser (view layout can't be unit-tested) + CloudKit single-hop device NOTE

The view layout is not unit-testable; verify it by eye in the Simulator, and record the hard CloudKit device-test requirement that Simulator CANNOT satisfy.

**Manual steps (Simulator — sample-data path):**
1. Launch the app on a Simulator with the StoreKit config (Debug/Launch) on a fresh/empty data store (no paid invoices), e.g. via Xcode Run, with `--mock-paywall-prices` if needed to populate prices.
2. Navigate to the locked **Reports** tab (the embedded `.reports` paywall, `trigger == .reports`).
3. Confirm ALL of:
   - Headline reads exactly **"Know what you're owed."** on a SINGLE line (no shrink).
   - An always-on **🔒 "Your Reports preview"** eyebrow (lock glyph + tinted text) sits above a **tinted, bordered** container.
   - The container LEADS with a **"Collected · last 6 months"** bar chart (6 green bars, month abbreviations on the X-axis), followed by the compact **Owed / This year / Effective rate** stat line.
   - Because the store has <2 months of collected history, a **"Sample preview"** watermark caption is shown (sample series, not the user's sparse numbers).
   - VoiceOver: the chart/stat block is accessibility-hidden (swipe does not land inside it) — the surrounding value props/CTA remain reachable.
4. (Optional real-data path) Add ≥2 invoices marked **paid** in two distinct recent months, relaunch, reopen Reports: the chart now reflects REAL collected amounts and the "Sample preview" watermark is GONE; the last bar / "This year" agree with the COLLECTED semantics.

**Verification:** All bullets observed. Capture a screenshot for the PR.

**HARD CloudKit NOTE (blocking before merge — cannot be done on Simulator/tests):** B2 reads live data via PaywallView's existing single-hop `@Query private var reportInvoices: [Invoice]`, and `collectedMonthlyTrend` reads ONLY Invoice scalars (`status`/`paidAt`/`total`/`currencyCodeSnapshot`) — it NEVER traverses `invoice.project`/`invoice.client`, so no `relationshipKeyPathsForPrefetching` is introduced and the PR #25 nested-keypath trap (`\.project?.client` → `Schema.KeyPathCache` crash) cannot occur by construction. Even so, per the standing rule (Simulator + unit tests use the local-store fallback and MISS CloudKit-only crashes), **B2 MUST be smoke-tested on a REAL CloudKit-backed device** — open the locked Reports tab on a device signed into iCloud with synced invoices, confirm no crash and the chart renders — BEFORE this PR is merged. Record this as an explicit pre-merge checkbox in the PR description. Additionally, the spec (§M-5) directs that B2 be re-based on a fresh worktree off the post-PR #25 `main` before shipping; verify the single-hop posture still holds on that rebased checkout.

## Task 29: Add `LifetimeAvailability` pure resolver to SubscriptionManager (failing test)

Create the unit test first. This pure helper is the extractable guard logic the requirements demand: `productsLoaded && lifetime == nil -> .unavailable`. It lives on `SubscriptionManager` as a `static` pure function so it has zero `@MainActor`/StoreKit/SwiftData dependencies and is unit-testable in BillableCore.

Create the test file `/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/Packages/BillableCore/Tests/BillableCoreTests/LifetimeAvailabilityTests.swift`:

```swift
import Testing
@testable import BillableCore

@Suite("Lifetime availability resolution")
struct LifetimeAvailabilityTests {

    @Test("Products not yet loaded -> .loading (never .unavailable prematurely)")
    func loadingWhileProductsPending() {
        #expect(
            SubscriptionManager.lifetimeAvailability(
                loadState: .loading,
                hasLifetimeProduct: false,
                hasAnySubscriptionProduct: false
            ) == .loading
        )
        #expect(
            SubscriptionManager.lifetimeAvailability(
                loadState: .idle,
                hasLifetimeProduct: false,
                hasAnySubscriptionProduct: false
            ) == .loading
        )
    }

    @Test("Products ready and lifetime present -> .available")
    func availableWhenLifetimeLoaded() {
        #expect(
            SubscriptionManager.lifetimeAvailability(
                loadState: .ready,
                hasLifetimeProduct: true,
                hasAnySubscriptionProduct: true
            ) == .available
        )
    }

    @Test("Products ready, subscriptions present, lifetime nil -> .unavailable (the silent-blank guard)")
    func unavailableWhenOnlyLifetimeMissing() {
        #expect(
            SubscriptionManager.lifetimeAvailability(
                loadState: .ready,
                hasLifetimeProduct: false,
                hasAnySubscriptionProduct: true
            ) == .unavailable
        )
    }

    @Test("Ready but NOTHING loaded -> .loading (do not flag lifetime as the culprit when the whole fetch is empty)")
    func loadingWhenReadyButEmpty() {
        #expect(
            SubscriptionManager.lifetimeAvailability(
                loadState: .ready,
                hasLifetimeProduct: false,
                hasAnySubscriptionProduct: false
            ) == .loading
        )
    }

    @Test("Failed load -> .loading (the .failed branch already owns retry UI; lifetime is not singled out)")
    func loadingWhenFailed() {
        #expect(
            SubscriptionManager.lifetimeAvailability(
                loadState: .failed("Pricing unavailable"),
                hasLifetimeProduct: false,
                hasAnySubscriptionProduct: true
            ) == .loading
        )
    }
}
```

Run it and expect a COMPILE FAILURE (neither `SubscriptionManager.lifetimeAvailability` nor `LifetimeAvailability` exists yet):

```
cd "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/Packages/BillableCore" && swift test --filter LifetimeAvailabilityTests
```

Expected: build error `type 'SubscriptionManager' has no member 'lifetimeAvailability'`.

## Task 30: Implement `LifetimeAvailability` enum + `lifetimeAvailability(...)` resolver (make Task 29 pass)

Open `/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/Packages/BillableCore/Sources/BillableCore/Subscriptions/SubscriptionManager.swift`. The `LoadState` enum is declared around lines 28-33 and the product accessors at 46-48. Add the pure resolver and its result type. Place the enum just above the `SubscriptionManager` class declaration (around line 45, before `@MainActor @Observable final class SubscriptionManager`), and the static func near the other pure static helpers (e.g. just after `resolveEntitlement` at line 181-184).

First, add the public result enum immediately before the class declaration:

```swift
/// Tri-state availability of the Lifetime (non-consumable) tier, derived purely from
/// load state + which products resolved. Lets the paywall distinguish "still loading"
/// from "the store genuinely has no transactable lifetime product" without ever
/// surfacing a price the store can't transact.
public enum LifetimeAvailability: Equatable, Sendable {
    /// Products are still being fetched (or the whole fetch came back empty / failed).
    case loading
    /// The lifetime product resolved and is transactable.
    case available
    /// Other products resolved but lifetime did NOT — a real gap (e.g. ASC product
    /// not yet approved). The paywall must hide the buy affordance for this tier.
    case unavailable
}
```

Then add the pure resolver. Find `resolveEntitlement`:

```swift
    static func resolveEntitlement(ownsLifetime: Bool, subscription: Entitlement?) -> Entitlement {
        ownsLifetime ? .pro : (subscription ?? .free)
    }
```

Insert immediately after its closing brace:

```swift
    /// Pure guard: decide whether the Lifetime tier should render as available,
    /// still-loading, or genuinely unavailable. We only declare `.unavailable` when
    /// the catalog is `.ready` AND at least one OTHER product resolved AND lifetime is
    /// absent — that isolates "lifetime product missing" from "the whole fetch is empty
    /// / still in flight / failed" (those stay `.loading`, owned by the existing
    /// idle/loading/failed UI). Never returns `.available` without a real product, so
    /// the caller can guarantee it never shows an untransactable price.
    static func lifetimeAvailability(
        loadState: LoadState,
        hasLifetimeProduct: Bool,
        hasAnySubscriptionProduct: Bool
    ) -> LifetimeAvailability {
        guard loadState == .ready else { return .loading }
        if hasLifetimeProduct { return .available }
        return hasAnySubscriptionProduct ? .unavailable : .loading
    }
```

Note: this relies on `LoadState` being `Equatable`. Verify it already is (the paywall switches on it and the `.failed(String)` case is compared); if `swift build` reports `LoadState` is not `Equatable`, that is surfaced in the next run — handle it in Task 31 only if the compiler demands it.

Run the test, expect PASS:

```
cd "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/Packages/BillableCore" && swift test --filter LifetimeAvailabilityTests
```

Expected: 5 tests pass. If instead the compiler reports `LoadState` does not conform to `Equatable`, proceed to Task 31; otherwise skip Task 31.

## Task 31: (Conditional) Make `LoadState` Equatable if the compiler demanded it

ONLY perform this task if Task 30's `swift test` failed with an error like `binary operator '==' cannot be applied` / `LoadState' does not conform to 'Equatable'`. If Task 30 passed, SKIP this task entirely (do not commit an empty change).

Open `/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/Packages/BillableCore/Sources/BillableCore/Subscriptions/SubscriptionManager.swift` and find the `LoadState` declaration (around lines 28-33), for example:

```swift
    public enum LoadState {
        case idle
        case loading
        case ready
        case failed(String)
    }
```

Add `Equatable` conformance (the associated `String` value is already `Equatable`, so the synthesized conformance is correct and does not change the `.failed("Pricing unavailable")` semantics the paywall relies on):

```swift
    public enum LoadState: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }
```

Re-run, expect PASS:

```
cd "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/Packages/BillableCore" && swift test --filter LifetimeAvailabilityTests
```

Expected: 5 tests pass.

## Task 32: Commit the pure availability resolver

Stage and commit only the resolver + its test (and, if Task 31 ran, the `Equatable` conformance — it is in the same already-staged file).

```
cd "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports" && git add Packages/BillableCore/Sources/BillableCore/Subscriptions/SubscriptionManager.swift Packages/BillableCore/Tests/BillableCoreTests/LifetimeAvailabilityTests.swift && git commit -m "feat(paywall): pure LifetimeAvailability resolver (loading/available/unavailable)

Isolates 'lifetime product missing' from 'fetch empty/in-flight/failed' so the
paywall can hide the Lifetime buy affordance instead of silently blanking it,
and never surface an untransactable price. Pure + unit-tested in BillableCore.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

Expected: one commit created; `git status` clean for those two paths.

## Task 33: Add `DEBUG` diagnostic logging in `refreshProducts()` when subscriptions load but lifetime is nil (failing test)

The spec's open question asks where the DEBUG diagnostic lives; the manager owns `loadState` + the resolved products, so it is the correct home. To keep it testable without StoreKit, extract the *message* as a pure helper and unit-test that; the actual `Logger` call in `refreshProducts()` is `#if DEBUG`-gated and verified by build.

First the failing test. Append to `/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/Packages/BillableCore/Tests/BillableCoreTests/LifetimeAvailabilityTests.swift` (same file, new suite):

```swift
@Suite("Lifetime diagnostic message")
struct LifetimeDiagnosticTests {

    @Test("Subscriptions loaded but lifetime nil -> returns a diagnostic naming the product id")
    func diagnosticWhenLifetimeMissing() {
        let msg = SubscriptionManager.lifetimeDiagnostic(
            hasLifetimeProduct: false,
            hasAnySubscriptionProduct: true
        )
        #expect(msg != nil)
        #expect(msg?.contains(SubscriptionManager.lifetimeProductID) == true)
    }

    @Test("Lifetime present -> no diagnostic")
    func noDiagnosticWhenLifetimePresent() {
        #expect(
            SubscriptionManager.lifetimeDiagnostic(
                hasLifetimeProduct: true,
                hasAnySubscriptionProduct: true
            ) == nil
        )
    }

    @Test("Nothing loaded -> no diagnostic (empty fetch is the .failed path's problem, not a lifetime gap)")
    func noDiagnosticWhenNothingLoaded() {
        #expect(
            SubscriptionManager.lifetimeDiagnostic(
                hasLifetimeProduct: false,
                hasAnySubscriptionProduct: false
            ) == nil
        )
    }
}
```

Run, expect COMPILE FAILURE (`lifetimeDiagnostic` does not exist):

```
cd "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/Packages/BillableCore" && swift test --filter LifetimeDiagnosticTests
```

Expected: `type 'SubscriptionManager' has no member 'lifetimeDiagnostic'`.

## Task 34: Implement `lifetimeDiagnostic(...)` + wire the DEBUG log into `refreshProducts()` (make Task 33 pass)

Open `/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/Packages/BillableCore/Sources/BillableCore/Subscriptions/SubscriptionManager.swift`.

Add the pure message helper immediately after the `lifetimeAvailability(...)` func you added in Task 30:

```swift
    /// Pure DEBUG diagnostic message builder. Returns a non-nil string ONLY when at
    /// least one subscription resolved but the lifetime non-consumable did not — the
    /// exact "silent blank tier" condition (typically the ASC non-consumable
    /// `com.eldenstudios.billable.pro.lifetime` is not yet created/approved). Returns
    /// nil otherwise so callers never log spurious warnings during a normal empty/
    /// in-flight/failed fetch.
    static func lifetimeDiagnostic(
        hasLifetimeProduct: Bool,
        hasAnySubscriptionProduct: Bool
    ) -> String? {
        guard hasAnySubscriptionProduct, !hasLifetimeProduct else { return nil }
        return "Lifetime product \(lifetimeProductID) failed to resolve while subscriptions loaded. "
            + "Verify the App Store Connect non-consumable exists and is Approved/Ready to Submit. "
            + "Lifetime tier will be hidden until it resolves."
    }
```

Now wire the DEBUG-gated log into `refreshProducts()`. The product-assignment block is around lines 156-158:

```swift
        monthly = products.first { $0.id == Self.monthlyProductID }
        yearly = products.first { $0.id == Self.yearlyProductID }
        lifetime = products.first { $0.id == Self.lifetimeProductID }
```

Immediately AFTER those three assignments (and before the intro-offer caching / `loadState = .ready`), insert:

```swift
        #if DEBUG
        if let diagnostic = Self.lifetimeDiagnostic(
            hasLifetimeProduct: lifetime != nil,
            hasAnySubscriptionProduct: monthly != nil || yearly != nil
        ) {
            Self.logger.warning("\(diagnostic, privacy: .public)")
        }
        #endif
```

This requires a `logger`. Check the top of the file for an existing `os.Logger` (search for `Logger(` / `import os`). If one already exists on the type, reuse its exact name in the line above (replace `Self.logger` to match) and skip the next paragraph.

If NO logger exists, add the import near the other imports at the top of the file:

```swift
import os
```

and add this static logger inside the class, immediately after the product-ID constants (right after `public static let lifetimeProductID = "com.eldenstudios.billable.pro.lifetime"` at line 24):

```swift
    static let logger = Logger(subsystem: "com.eldenstudios.billable", category: "Subscriptions")
```

Run the unit test, expect PASS:

```
cd "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/Packages/BillableCore" && swift test --filter LifetimeDiagnosticTests
```

Expected: 3 tests pass.

## Task 35: Full BillableCore test sweep + commit the diagnostic

Run the entire BillableCore suite to confirm no regression from the new enum/logger/import:

```
cd "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/Packages/BillableCore" && swift test
```

Expected: all tests pass (the prior 345+ plus the 8 new ones across the two suites).

Then commit:

```
cd "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports" && git add Packages/BillableCore/Sources/BillableCore/Subscriptions/SubscriptionManager.swift Packages/BillableCore/Tests/BillableCoreTests/LifetimeAvailabilityTests.swift && git commit -m "feat(paywall): DEBUG diagnostic when subscriptions load but lifetime is nil

refreshProducts() logs a build-only warning (naming the ASC product id) when the
non-consumable fails to resolve while subs load — catches the silent-blank-tier
gap during dev. Pure message builder unit-tested; Logger call DEBUG-gated so
Release behaviour is unchanged.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

Expected: one commit; clean status for those paths.

## Task 36: Verify the StoreKit config is NOT attached to Release/Archive scheme actions (read-only audit)

Before touching the view, confirm the spec's hard rule already holds on this checkout (no edit if already correct — this is the "verify the scheme" requirement). Read the single shared scheme.

```
cd "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports" && grep -n "StoreKitConfigurationFileReference\|buildConfiguration\|<LaunchAction\|<ProfileAction\|<ArchiveAction\|<TestAction" Billable.xcodeproj/xcshareddata/xcschemes/Billable.xcscheme
```

Then open the scheme to inspect placement precisely:

```
Read /Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/Billable.xcodeproj/xcshareddata/xcschemes/Billable.xcscheme
```

PASS criteria (per the code findings — LaunchAction/Debug only):
- Exactly ONE `StoreKitConfigurationFileReference` exists, and it is INSIDE `<LaunchAction ... buildConfiguration="Debug">`.
- `<ProfileAction>`, `<ArchiveAction>`, and `<TestAction>` contain NO `StoreKitConfigurationFileReference`.

If all three of Profile/Archive/Test are clean, the rule holds — record this in the Task-37 manual-verification notes and make NO scheme edit.

If (and only if) a `StoreKitConfigurationFileReference` is found inside `ArchiveAction` or `ProfileAction`'s Release configuration, remove that single `<StoreKitConfigurationFileReference .../>` line from the offending action (leave the LaunchAction/Debug one intact), then re-run the grep to confirm only the LaunchAction reference remains, and commit:

```
cd "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports" && git add Billable.xcodeproj/xcshareddata/xcschemes/Billable.xcscheme && git commit -m "fix(storekit): keep StoreKit config off Release/Archive (Debug Launch only)

Production builds must read App Store Connect, never the bundled local .storekit
testing config. Removes the stray Release-config StoreKitConfigurationFileReference.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

Expected: either NO change (rule already holds — most likely) or one corrective commit. Note the outcome explicitly in your final summary.

## Task 37: Consume `LifetimeAvailability` in `PaywallView` so the Lifetime row can't become a dead buy button (build + edit)

> **Shared-file note:** This task edits the SAME `PaywallView` functions touched by B1 — `lifetimeAffordance` (rewritten in Task 8) and `purchaseButton`'s `.disabled(...)` modifier (edited in Task 9, step 9a). Apply this task ON TOP of the B1 results: step 8b below extends the Task-8 owned-state-only `lifetimeAffordance`; step 8c below supersedes the Task-9a `.disabled(...)` clause with the generalized `lifetimeAvailability == .unavailable` form. If B1 and B3 are implemented in plan order (Tasks 1–28 first), the anchors below will reflect the already-rewritten functions — read the current bracket structure before editing.

This is the view-layer wiring of the guard. There is no fake unit test for SwiftUI here — correctness is enforced by `xcodebuild` compiling the new branch plus the manual check in Task 38. The pure logic it depends on is already unit-tested (Tasks 29-35).

Open `/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/App/Sources/Features/Paywall/PaywallView.swift`.

Step 8a — derive availability once. Add a computed property next to `lifetimeDisplayPrice` (around lines 692-695). Find:

```swift
    private var lifetimeDisplayPrice: String? {
        if let lifetime = manager.lifetime { return lifetime.displayPrice }
        return mockPaywallPrices ? "$99.99" : nil
    }
```

Insert immediately above it:

```swift
    /// Tri-state lifetime availability, driving whether the Lifetime tier renders a
    /// real buy affordance, a loading shimmer, or is suppressed. In the mock-prices
    /// branch (App Store screenshots) lifetime is always treated as available so the
    /// shot shows three tiers. Otherwise this defers to the unit-tested resolver.
    private var lifetimeAvailability: LifetimeAvailability {
        if mockPaywallPrices { return .available }
        return SubscriptionManager.lifetimeAvailability(
            loadState: manager.loadState,
            hasLifetimeProduct: manager.lifetime != nil,
            hasAnySubscriptionProduct: manager.monthly != nil || manager.yearly != nil
        )
    }
```

Step 8b — guard the `lifetimeAffordance` so a nil-price lifetime can never present a tappable buy row. Open `lifetimeAffordance` (around lines 697-729). It currently has three branches: owned-label, `else if let price = lifetimeDisplayPrice { <tappable button> }`, and implicit-nil-renders-nothing. Replace the price branch's condition so it ALSO requires `.available`, and add an explicit `.unavailable` DEBUG-only state. Find the existing branch head (the owned branch stays exactly as-is):

```swift
        } else if let price = lifetimeDisplayPrice {
```

Replace that single line with:

```swift
        } else if lifetimeAvailability == .available, let price = lifetimeDisplayPrice {
```

Then, immediately BEFORE the final closing brace of the `lifetimeAffordance` ViewBuilder (after the price-branch block closes), add the DEBUG-only unavailable diagnostic state so the gap is visible in dev without ever showing a buy control:

```swift
        }
        #if DEBUG
        else if lifetimeAvailability == .unavailable {
            Divider().padding(.vertical, 4)
            Label("Lifetime unavailable (debug) — ASC product not resolved", systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        #endif
```

IMPORTANT: the snippet above assumes the price-branch block ended with a single `}` that you are now following. When you apply this, make sure you are inserting AFTER the price branch's closing brace and BEFORE the ViewBuilder's own closing brace — read the exact bracket structure at lines 697-729 first and match indentation. Do not duplicate or drop a brace. (The leading `}` in the snippet IS the price branch's existing closing brace shown for anchoring; if your editor already has it, attach only the `#if DEBUG ... #endif` block after it rather than adding a second `}`.)

> **B1↔B3 reconciliation for step 8b:** After Task 8 (B1), `lifetimeAffordance` was collapsed to ONLY the owned-state `if manager.ownsLifetime { … }` label — the demoted `else if let price = lifetimeDisplayPrice { <tappable button> }` branch was removed. If you implemented B1 first, there is NO price branch to amend here. In that case, the B3 decision (Lifetime is now a first-class picker row, not a demoted affordance) is ALREADY satisfied by Task 8, and the only B3 addition needed is the DEBUG-only `.unavailable` caption. Add it to the collapsed `lifetimeAffordance` as a sibling branch:
>
> ```swift
>     @ViewBuilder
>     private var lifetimeAffordance: some View {
>         if manager.ownsLifetime {
>             Label(PricingConfig.ownedTitle, systemImage: "checkmark.seal.fill")
>                 .font(.subheadline.weight(.semibold)).foregroundStyle(.green)
>         }
>         #if DEBUG
>         else if lifetimeAvailability == .unavailable {
>             Divider().padding(.vertical, 4)
>             Label("Lifetime unavailable (debug) — ASC product not resolved", systemImage: "exclamationmark.triangle")
>                 .font(.caption2)
>                 .foregroundStyle(.secondary)
>                 .accessibilityHidden(true)
>         }
>         #endif
>     }
> ```
>
> The dead-buy-button risk B3 guards against is structurally prevented by B1 (Lifetime's buy path is now the picker row + the shared CTA, gated by step 8c). Keep step 8c regardless.

Step 8c — make the purchase CTA inert for an unavailable lifetime selection. Open `purchaseButton` (around lines 612-629). Its current disabled modifier is:

```swift
        .disabled((selectedProduct == nil && !mockPaywallPrices) || isProcessing)
```

The existing `selectedProduct == nil` already disables the CTA when `manager.lifetime` is nil and `selection == .lifetime` (off-mock), because `selectedProduct` switches on selection and returns `manager.lifetime` (nil) for `.lifetime`. So a dead buy button is already structurally prevented in the live path. To make the intent explicit and self-documenting, replace that line with:

```swift
        .disabled(
            (selectedProduct == nil && !mockPaywallPrices)
            || (selection == .lifetime && lifetimeAvailability == .unavailable && !mockPaywallPrices)
            || isProcessing
        )
```

> **B1↔B3 reconciliation for step 8c:** B1 Task 9a already replaced this modifier with the form `.disabled((selectedProduct == nil && !mockPaywallPrices) || (selection == .lifetime && lifetimeDisplayPrice == nil) || isProcessing)`. This step 8c REPLACES the B1 middle clause `(selection == .lifetime && lifetimeDisplayPrice == nil)` with the semantically-equivalent-but-clearer `(selection == .lifetime && lifetimeAvailability == .unavailable && !mockPaywallPrices)`. Keep the B3 form as the final composed modifier (it is the more explicit of the two; off-mock with a nil lifetime product, `lifetimeAvailability` resolves to `.unavailable` or `.loading`, and `selectedProduct == nil` still covers the `.loading` case).

Build the app, expect SUCCESS:

```
cd "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports" && xcodegen generate --spec project.yml --project . && xcodebuild -project Billable.xcodeproj -scheme Billable -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -30
```

Expected: `** BUILD SUCCEEDED **`. If `xcodebuild` reports a brace/duplicate-`}` error in `lifetimeAffordance`, fix the bracket structure per the Step-8b note and rebuild before proceeding.

## Task 38: Manual verification of the lifetime guard states + commit the view wiring

Because the guard's three states depend on StoreKit product resolution (which `swift test`/Simulator can't fully exercise off a real device), verify by reasoning + a Simulator smoke check, then record the result. The CloudKit/ASC device caveat is captured for the PR.

Manual verification steps (perform and record the outcome in your final summary):

1. Confirm the build from Task 37 ended in `** BUILD SUCCEEDED **`.
2. Launch the app in Simulator with the StoreKit testing config (Debug/Launch scheme already attaches `Billable.storekit`, which DOES contain the lifetime non-consumable) and open the paywall from the Settings entry point:
   ```
   cd "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports" && xcrun simctl list devices booted | head -5
   ```
   Then run the app from Xcode (or `xcodebuild ... -destination 'platform=iOS Simulator,name=<booted sim>'` install + launch). With the local config present, `manager.lifetime != nil` and `loadState == .ready`, so `lifetimeAvailability == .available` → the Lifetime tier renders its tappable buy affordance. CONFIRM the row appears and is tappable.
3. Verify the `.unavailable` DEBUG state path by reasoning (it cannot be hit with the local config attached, since the config always provides lifetime): the `#if DEBUG else if lifetimeAvailability == .unavailable` branch only renders when `loadState == .ready && monthly||yearly != nil && lifetime == nil` — which is the real-device / TestFlight condition before the ASC product exists. CONFIRM by code inspection that in that state (a) no buy button renders (the price branch is skipped because `lifetimeAvailability != .available`), (b) the CTA is disabled when `selection == .lifetime`, and (c) only the secondary `exclamationmark.triangle` caption shows. Record this as inspection-verified (not Simulator-reproducible) with the ASC dependency noted.
4. Confirm `lifetimeDisplayPrice` still returns `nil` off-mock when `manager.lifetime == nil` (unchanged), so no untransactable price is ever shown.

Commit the view wiring:

```
cd "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports" && git add App/Sources/Features/Paywall/PaywallView.swift Billable.xcodeproj/project.pbxproj && git commit -m "feat(paywall): gate Lifetime tier on availability — no dead buy button

PaywallView derives the unit-tested LifetimeAvailability: the Lifetime buy
affordance renders only when .available (real product loaded); a DEBUG-only
'unavailable' caption surfaces the ASC-product gap; the CTA is explicitly disabled
for an unavailable lifetime selection. lifetimeDisplayPrice stays nil-safe so an
untransactable price is never shown.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

Expected: one commit. (Include `project.pbxproj` only if `xcodegen generate` modified it; if `git status` shows it unchanged, drop it from the `git add`.)

## Task 39: Record the App Store Connect owner dependency (manual step — do NOT code it)

The lifetime tier cannot resolve off-Simulator until the owner creates the App Store Connect non-consumable. This is a human/owner action; capture it as a checklist note for the PR body rather than attempting any code or API call.

Append an "Owner action required" note to the spec's B3 section so it travels with the PR. Open `/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports/docs/superpowers/specs/2026-06-02-cadence-ux-overhaul-design.md`, locate the B3 section heading, and add the following block at the end of that section (match the file's existing Markdown heading style; read the surrounding lines first to place it correctly):

```markdown
> **Owner action required (B3 — not codeable):** Create the App Store Connect non-consumable
> `com.eldenstudios.billable.pro.lifetime` priced at the Lifetime tier (illustratively $99.99 USD;
> App Store Connect manages all 175 storefront equivalents) and move it to **Approved / Ready to Submit**.
> Until this exists and is approved, `manager.lifetime` resolves `nil` in TestFlight/Production, so the
> Lifetime tier is intentionally hidden (the DEBUG build logs a diagnostic naming this product id, and the
> in-app DEBUG "Lifetime unavailable" caption appears). No code change unblocks this — it is purely an
> App Store Connect catalog dependency. The product id must stay byte-identical across
> `SubscriptionManager.lifetimeProductID`, `App/Resources/Billable.storekit`, and the ASC product.
```

Commit the doc note:

```
cd "/Users/lbazerbashi/Elden Studios/billable/.worktrees/paywall-reports" && git add docs/superpowers/specs/2026-06-02-cadence-ux-overhaul-design.md && git commit -m "docs(spec): record ASC lifetime non-consumable as B3 owner dependency

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

Expected: one commit. This closes B3: code hardening (Tasks 29-38) + the explicit, non-codeable owner dependency recorded for the PR.

---

## Testing notes

Pulled from the spec (`docs/superpowers/specs/2026-06-02-cadence-ux-overhaul-design.md`, §Testing notes):

- **B1:** all three tiers render with consistent selection; CTA swaps for Lifetime; **owned-Lifetime → no purchase rows/CTA**; mock path shows three tiers.
- **B2:** chart never shows a misleading "your trend" for <2-month users (labeled sample fallback); **verified on a real CloudKit device**; new fetch uses single-hop prefetch only.
- **B3:** missing Lifetime is logged, never a dead buy button; Release/Archive carry no StoreKit config.

Supplementary (from this plan's task-level verification):
- All pure logic is unit-tested in BillableCore (`PaywallCopy`, `collectedMonthlyTrend` + `hasEnoughCollectedHistory`, `lifetimeAvailability` + `lifetimeDiagnostic`); run `swift test --package-path .../Packages/BillableCore` as the regression gate after each phase.
- SwiftUI layout/interaction (three-tier picker, locked teaser, Lifetime guard states) is verified by `xcodebuild` compile + the manual Simulator checks in Tasks 12, 28, and 38.

## Open dependencies / gates

- **ASC Lifetime product (owner) — gates Lifetime off-Simulator.** Owner must create the App Store Connect non-consumable `com.eldenstudios.billable.pro.lifetime` @ the Lifetime tier (illustratively $99.99 USD; ASC manages all 175 storefront equivalents) and move it to Approved / Ready to Submit. The product id must stay byte-identical across `SubscriptionManager.lifetimeProductID`, `App/Resources/Billable.storekit`, and the ASC product. Until then, `manager.lifetime` resolves `nil` in TestFlight/Production and the Lifetime tier is intentionally hidden (DEBUG logs a diagnostic + shows the in-app "Lifetime unavailable" caption). Everything else in PR B ships without it. Recorded in the spec's B3 section by Task 39.
- **B2 MUST be device-verified on real CloudKit before merge (blocking).** Simulator + unit tests use the local-store fallback and MISS CloudKit-only crashes. Although `collectedMonthlyTrend` reads only Invoice scalars (`status`/`paidAt`/`total`/`currencyCodeSnapshot`) and never traverses `\.project`/`\.project?.client` — so the PR #25 nested-keypath trap cannot occur by construction — the locked Reports tab MUST still be opened on a real device signed into iCloud with synced invoices to confirm no crash and that the chart renders, BEFORE this PR is merged. Add this as an explicit pre-merge checkbox in the PR description.
- **Branch baseline.** Per spec §M-5, PR B MUST be implemented from a fresh worktree off the post-PR #25 `main` so it inherits the CloudKit nested-keypath crash fix. Task 13 verifies the worktree/branch baseline and re-confirms the single-hop posture on the rebased checkout; re-verify line-number anchors against that checkout before editing.
- **Release/Archive StoreKit hygiene (audit gate).** Task 36 audits `Billable.xcscheme` to confirm the StoreKit testing config is attached ONLY to the Debug Launch action (never Release/Archive/Profile), so production reads App Store Connect. Edit only if a stray reference is found.
- **Shared-file edits in `PaywallView.swift`.** B1 (Tasks 8, 9) and B3 (Task 37) both edit `lifetimeAffordance` and `purchaseButton`'s `.disabled(...)` modifier. Both edits are kept and composed per the reconciliation notes in Task 37 — implement in plan order (B1 before B3) and read the current bracket structure before each B3 edit.
