# Lifetime IAP + Pricing-Ladder Reset — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a $99.99 Lifetime non-consumable, reset the ladder to Monthly $3.99 / Yearly $39.99, and restructure the paywall (Yearly-hero, Lifetime-as-affordance, reframed savings, light funnel metrics) for maximum conversion.

**Architecture:** Pure, unit-testable helpers in BillableCore (`resolveEntitlement`, `PricingDisplay`, `PaywallMetrics`) hold all the logic; the StoreKit `currentEntitlements` loop and SwiftUI `PaywallView` are thin shells that call them. Prices live in `Billable.storekit` (local testing) + App Store Connect (production). No new dependencies, no analytics SDK.

**Tech Stack:** Swift 6 (strict concurrency), StoreKit 2, SwiftUI, SwiftData, Swift Testing (`@Test`/`#expect`), xcodegen.

**Spec:** `docs/superpowers/specs/2026-05-31-lifetime-pricing-design.md` (`ed2a387`).
**Build/test commands:**
- Core tests: `cd Packages/BillableCore && swift test 2>&1 | tail -25`
- App build: `xcodebuild -project Billable.xcodeproj -scheme Billable -configuration Debug -destination 'platform=iOS Simulator,id=4AA84237-0FFF-4652-A3CC-6C3DC2C63DC7' -derivedDataPath /tmp/lifetime-dd build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
- After adding any NEW file under `App/Sources`: run `xcodegen generate` before the app build.

**Files:**
- Modify: `Packages/BillableCore/Sources/BillableCore/Subscriptions/SubscriptionManager.swift` — lifetime product ID + property, `ownsLifetime`, pure `resolveEntitlement`, restructured `refreshEntitlements`, lifetime ID in `refreshProducts`.
- Create: `Packages/BillableCore/Sources/BillableCore/Subscriptions/PricingDisplay.swift` — pure savings computation.
- Create: `Packages/BillableCore/Sources/BillableCore/Subscriptions/PaywallMetrics.swift` — on-device variant-keyed funnel counters.
- Modify: `App/Resources/Billable.storekit` — prices + lifetime non-consumable.
- Create: `App/Sources/Features/Paywall/PricingConfig.swift` — variant/layout ids + copy.
- Modify: `App/Sources/Features/Paywall/PaywallView.swift` — `Plan.lifetime`, hero/affordance layout, computed badge, copy, owned state, metrics calls, remove stale bullet.
- Create tests: `SubscriptionManagerLifetimeTests.swift`, `PricingDisplayTests.swift`, `PaywallMetricsTests.swift` (all in `Packages/BillableCore/Tests/BillableCoreTests/`).

---

### Task 1: Pure entitlement-resolution helper + lifetime product ID

**Files:**
- Modify: `Packages/BillableCore/Sources/BillableCore/Subscriptions/SubscriptionManager.swift` (add constant near line 18; add static helper near the other pure helper `computeIntroEligibility` ~line 164)
- Test: `Packages/BillableCore/Tests/BillableCoreTests/SubscriptionManagerLifetimeTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Packages/BillableCore/Tests/BillableCoreTests/SubscriptionManagerLifetimeTests.swift`:

```swift
import Testing
@testable import BillableCore

@Suite("Lifetime entitlement resolution")
struct SubscriptionManagerLifetimeTests {
    typealias E = SubscriptionManager.Entitlement

    @Test("lifetime owned wins over every subscription state")
    func lifetimeWins() {
        #expect(SubscriptionManager.resolveEntitlement(ownsLifetime: true, subscription: nil) == .pro)
        #expect(SubscriptionManager.resolveEntitlement(ownsLifetime: true, subscription: .free) == .pro)
        #expect(SubscriptionManager.resolveEntitlement(ownsLifetime: true, subscription: .trial(daysRemaining: 3)) == .pro)
        #expect(SubscriptionManager.resolveEntitlement(ownsLifetime: true, subscription: .pro) == .pro)
    }

    @Test("without lifetime, the subscription state passes through")
    func noLifetime() {
        #expect(SubscriptionManager.resolveEntitlement(ownsLifetime: false, subscription: nil) == .free)
        #expect(SubscriptionManager.resolveEntitlement(ownsLifetime: false, subscription: .free) == .free)
        #expect(SubscriptionManager.resolveEntitlement(ownsLifetime: false, subscription: .trial(daysRemaining: 5)) == .trial(daysRemaining: 5))
        #expect(SubscriptionManager.resolveEntitlement(ownsLifetime: false, subscription: .pro) == .pro)
    }

    @Test("lifetime product ID is the agreed string")
    func productID() {
        #expect(SubscriptionManager.lifetimeProductID == "com.eldenstudios.billable.pro.lifetime")
    }
}
```

> Note: confirm `Entitlement` is `Equatable` (the existing `.trial(daysRemaining:)` case implies a payload — if it isn't already `Equatable`, add `: Equatable` to the enum; the existing `isPro` switch suggests it's a simple enum, synthesis will work).

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd Packages/BillableCore && swift test --filter SubscriptionManagerLifetimeTests 2>&1 | tail -20`
Expected: FAIL — `resolveEntitlement` and `lifetimeProductID` don't exist yet.

- [ ] **Step 3: Add the constant and the pure helper**

In `SubscriptionManager.swift`, after `yearlyProductID` (line 19) add:

```swift
    public static let lifetimeProductID = "com.eldenstudios.billable.pro.lifetime"
```

Near `computeIntroEligibility` (~line 166) add:

```swift
    /// Pure entitlement resolution: lifetime ownership is terminal and always
    /// wins over any subscription state; otherwise the subscription-derived
    /// state passes through (nil → .free). Unit-testable without StoreKit.
    static func resolveEntitlement(ownsLifetime: Bool, subscription: Entitlement?) -> Entitlement {
        if ownsLifetime { return .pro }
        return subscription ?? .free
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd Packages/BillableCore && swift test --filter SubscriptionManagerLifetimeTests 2>&1 | tail -20`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Subscriptions/SubscriptionManager.swift Packages/BillableCore/Tests/BillableCoreTests/SubscriptionManagerLifetimeTests.swift
git commit -m "feat(subs): pure lifetime entitlement resolution + product ID"
```

---

### Task 2: Wire lifetime into product load + entitlement loop

**Files:**
- Modify: `SubscriptionManager.swift` — add `lifetime`/`ownsLifetime` properties (~line 42), load the lifetime ID in `refreshProducts` (~line 138-148), restructure `refreshEntitlements` (lines 275-299).

No new unit test (the StoreKit `currentEntitlements` loop isn't mockable; Task 1's pure helper covers the logic). Verified by build + the integration test session.

- [ ] **Step 1: Add properties**

After `public private(set) var yearly: Product?` (line 42) add:

```swift
    public private(set) var lifetime: Product?
    /// True when the non-consumable lifetime entitlement is owned (terminal Pro).
    public private(set) var ownsLifetime: Bool = false
```

- [ ] **Step 2: Load the lifetime product**

In `refreshProducts()`, change the fetched IDs (lines 138-141) to include lifetime:

```swift
                try await fetcher([
                    Self.monthlyProductID,
                    Self.yearlyProductID,
                    Self.lifetimeProductID,
                ])
```

After the `yearly = …` assignment (line 148) add:

```swift
            lifetime = products.first { $0.id == Self.lifetimeProductID }
```

- [ ] **Step 3: Restructure `refreshEntitlements` to detect lifetime + apply precedence**

Replace the loop body (lines 281-298) so it scans ALL entitlements (no early return on the first sub), tracking lifetime separately, then resolves:

```swift
        var foundLifetime = false
        var subscriptionState: Entitlement? = nil
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.revocationDate == nil else { continue }

            if transaction.productID == Self.lifetimeProductID,
               transaction.productType == .nonConsumable {
                foundLifetime = true
                continue
            }
            guard transaction.productType == .autoRenewable,
                  (transaction.expirationDate ?? .distantFuture) > .now,
                  transaction.productID == Self.monthlyProductID ||
                  transaction.productID == Self.yearlyProductID else { continue }
            if let days = introOfferDaysRemaining(transaction: transaction) {
                subscriptionState = .trial(daysRemaining: days)
            } else {
                subscriptionState = .pro
            }
        }
        ownsLifetime = foundLifetime
        entitlement = Self.resolveEntitlement(ownsLifetime: foundLifetime, subscription: subscriptionState)
```

(Keep the `--pretend-pro` override block above it unchanged; also set `ownsLifetime = false` is fine to leave default under that override, or leave as-is.)

- [ ] **Step 4: Build BillableCore to verify it compiles**

Run: `cd Packages/BillableCore && swift build 2>&1 | tail -15`
Expected: builds clean. Then re-run Task 1's tests to confirm no regression: `swift test --filter SubscriptionManagerLifetimeTests 2>&1 | tail -5` → PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Subscriptions/SubscriptionManager.swift
git commit -m "feat(subs): load lifetime product + detect non-consumable entitlement (precedence)"
```

---

### Task 3: StoreKit config — prices + lifetime non-consumable

**Files:**
- Modify: `App/Resources/Billable.storekit`

Config-only; verified by the app build + a StoreKit Testing run. No unit test.

- [ ] **Step 1: Lower the subscription prices**

In `Billable.storekit`, set the monthly `"displayPrice"` (line 39) from `"5.99"` to `"3.99"`, and the yearly `"displayPrice"` (line 66) from `"34.99"` to `"39.99"`.

- [ ] **Step 2: Add the non-consumable lifetime product**

Replace `"products" : [],` (line 4) with:

```json
  "products" : [
    {
      "displayPrice" : "99.99",
      "familyShareable" : false,
      "internalID" : "LIFETIME_ID",
      "localizations" : [
        {
          "description" : "Pay once. Own Cadence Pro forever — unlimited invoicing, reports, exports, no watermark.",
          "displayName" : "Billable Pro — Lifetime",
          "locale" : "en_US"
        }
      ],
      "productID" : "com.eldenstudios.billable.pro.lifetime",
      "referenceName" : "Pro Lifetime",
      "type" : "NonConsumable"
    }
  ],
```

- [ ] **Step 3: Build the app to verify the config parses**

Run: `xcodebuild -project Billable.xcodeproj -scheme Billable -configuration Debug -destination 'platform=iOS Simulator,id=4AA84237-0FFF-4652-A3CC-6C3DC2C63DC7' -derivedDataPath /tmp/lifetime-dd build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add App/Resources/Billable.storekit
git commit -m "feat(iap): \$3.99/\$39.99 prices + \$99.99 lifetime non-consumable (storekit config)"
```

---

### Task 4: Computed savings helper (`PricingDisplay`)

**Files:**
- Create: `Packages/BillableCore/Sources/BillableCore/Subscriptions/PricingDisplay.swift`
- Test: `Packages/BillableCore/Tests/BillableCoreTests/PricingDisplayTests.swift`

- [ ] **Step 1: Write the failing test**

Create `PricingDisplayTests.swift`:

```swift
import Foundation
import Testing
@testable import BillableCore

@Suite("PricingDisplay savings")
struct PricingDisplayTests {
    @Test("annual vs 12x monthly yields dollar + months-free framing")
    func savings() throws {
        let s = try #require(PricingDisplay.annualSavings(monthlyPrice: 3.99, yearlyPrice: 39.99))
        #expect(s.dollarsSaved == Decimal(string: "7.89"))   // 47.88 - 39.99
        #expect(s.monthsFree == 2)                            // floor(7.89 / 3.99) = 1.97 → "about 2"
        #expect(s.percent == 16)                              // round(1 - 39.99/47.88) = 16
    }

    @Test("guards bad input")
    func guards() {
        #expect(PricingDisplay.annualSavings(monthlyPrice: 0, yearlyPrice: 39.99) == nil)
        #expect(PricingDisplay.annualSavings(monthlyPrice: 3.99, yearlyPrice: 60) == nil) // yearly not cheaper
    }
}
```

> `monthsFree`: use rounding so 1.97 → 2 (the honest "about 2 months free"). Implement as `Int((dollarsSaved / monthlyPrice).rounded())`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd Packages/BillableCore && swift test --filter PricingDisplayTests 2>&1 | tail -20`
Expected: FAIL — no such type.

- [ ] **Step 3: Implement**

Create `PricingDisplay.swift`:

```swift
import Foundation

/// Pure, testable display math for the paywall savings badge. Computes the
/// annual saving vs 12x monthly as dollars, "months free", and a percentage —
/// so the badge is never a stale hardcoded string.
public enum PricingDisplay {
    public struct AnnualSavings: Equatable {
        public let dollarsSaved: Decimal
        public let monthsFree: Int
        public let percent: Int
    }

    /// Returns nil when inputs are invalid or the yearly isn't actually cheaper.
    public static func annualSavings(monthlyPrice: Decimal, yearlyPrice: Decimal) -> AnnualSavings? {
        guard monthlyPrice > 0, yearlyPrice > 0 else { return nil }
        let twelveMonths = monthlyPrice * 12
        guard yearlyPrice < twelveMonths else { return nil }
        let dollars = twelveMonths - yearlyPrice
        let months = Int((NSDecimalNumber(decimal: dollars / monthlyPrice)).doubleValue.rounded())
        let fraction = (NSDecimalNumber(decimal: yearlyPrice / twelveMonths)).doubleValue
        let percent = Int(((1 - fraction) * 100).rounded())
        return AnnualSavings(dollarsSaved: dollars, monthsFree: months, percent: percent)
    }

    /// Badge copy, leading with the tangible framing (per CRO assessment).
    /// e.g. "SAVE $7.89 · about 2 months free".
    public static func savingsBadge(_ s: AnnualSavings, currencyCode: String) -> String {
        let dollars = s.dollarsSaved.formatted(.currency(code: currencyCode))
        return "SAVE \(dollars) · about \(s.monthsFree) months free"
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd Packages/BillableCore && swift test --filter PricingDisplayTests 2>&1 | tail -20`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Subscriptions/PricingDisplay.swift Packages/BillableCore/Tests/BillableCoreTests/PricingDisplayTests.swift
git commit -m "feat(paywall): pure computed annual-savings helper (dollars + months-free)"
```

---

### Task 5: On-device funnel metrics (`PaywallMetrics`)

**Files:**
- Create: `Packages/BillableCore/Sources/BillableCore/Subscriptions/PaywallMetrics.swift`
- Test: `Packages/BillableCore/Tests/BillableCoreTests/PaywallMetricsTests.swift`

- [ ] **Step 1: Write the failing test**

Create `PaywallMetricsTests.swift`:

```swift
import Foundation
import Testing
@testable import BillableCore

@Suite("PaywallMetrics funnel keys")
struct PaywallMetricsTests {
    @Test("event key composes variant + trigger + event + tier")
    func keyComposition() {
        #expect(PaywallMetrics.key(variant: "v1", trigger: "reports", event: .tierSelected, tier: "lifetime")
                == "paywall.v1.reports.tier_selected.lifetime")
        #expect(PaywallMetrics.key(variant: "v1", trigger: "settings", event: .paywallView, tier: nil)
                == "paywall.v1.settings.paywall_view")
    }

    @Test("record increments the composed counter in the provided store")
    func recordIncrements() {
        let store = UserDefaults(suiteName: "PaywallMetricsTests")!
        store.removePersistentDomain(forName: "PaywallMetricsTests")
        PaywallMetrics.record(.purchaseSuccess, variant: "v1", trigger: "reports", tier: "yearly", store: store)
        PaywallMetrics.record(.purchaseSuccess, variant: "v1", trigger: "reports", tier: "yearly", store: store)
        #expect(store.integer(forKey: "paywall.v1.reports.purchase_success.yearly") == 2)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd Packages/BillableCore && swift test --filter PaywallMetricsTests 2>&1 | tail -20`
Expected: FAIL — no such type.

- [ ] **Step 3: Implement**

Create `PaywallMetrics.swift`:

```swift
import Foundation

/// On-device-only, privacy-pure paywall funnel counters (no SDK, no network,
/// no identifiers). Every counter is stamped with the pricing/layout variant id
/// so a future price/layout change keeps pre-change data sliceable.
public enum PaywallMetrics {
    public enum Event: String {
        case paywallView = "paywall_view"
        case tierSelected = "tier_selected"
        case purchaseStart = "purchase_start"
        case purchaseSuccess = "purchase_success"
        case purchaseFailure = "purchase_failure"
        case trialStart = "trial_start"
        case restoreTapped = "restore_tapped"
        case lifetimeOwnedView = "lifetime_owned_view"
    }

    public static func key(variant: String, trigger: String, event: Event, tier: String?) -> String {
        var k = "paywall.\(variant).\(trigger).\(event.rawValue)"
        if let tier { k += ".\(tier)" }
        return k
    }

    public static func record(_ event: Event, variant: String, trigger: String,
                              tier: String? = nil, store: UserDefaults = .standard) {
        let k = key(variant: variant, trigger: trigger, event: event, tier: tier)
        store.set(store.integer(forKey: k) + 1, forKey: k)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd Packages/BillableCore && swift test --filter PaywallMetricsTests 2>&1 | tail -20`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Subscriptions/PaywallMetrics.swift Packages/BillableCore/Tests/BillableCoreTests/PaywallMetricsTests.swift
git commit -m "feat(paywall): on-device variant-keyed funnel metrics (no SDK)"
```

---

### Task 6: PricingConfig (variant + layout + copy)

**Files:**
- Create: `App/Sources/Features/Paywall/PricingConfig.swift`

Small constants file; build-verified. Run `xcodegen generate` after creating it.

- [ ] **Step 1: Create the file**

```swift
import Foundation

/// Single source of truth for the paywall's variant identity + tier-order +
/// copy that used to be scattered literals. Stamped into every funnel metric so
/// a future price/layout test is a config flip, not a re-instrumentation.
enum PricingConfig {
    /// Bump when prices, tier order, or layout change — keeps metrics sliceable.
    static let variant = "ladder_2026_05_v1"
    static let layout = "yearly_hero_lifetime_below"

    static let lifetimeAffordanceTitle = "Prefer to pay once?"
    static let lifetimeAffordanceSubtitle = "Own Cadence Pro forever"
    static let trialReassurance = "No charge today. We'll remind you before your trial ends. Cancel anytime."
    static let ownedTitle = "You own Cadence Pro forever ✓"
}
```

- [ ] **Step 2: Register + build**

Run: `xcodegen generate && xcodebuild -project Billable.xcodeproj -scheme Billable -configuration Debug -destination 'platform=iOS Simulator,id=4AA84237-0FFF-4652-A3CC-6C3DC2C63DC7' -derivedDataPath /tmp/lifetime-dd build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add App/Sources/Features/Paywall/PricingConfig.swift Billable.xcodeproj/project.pbxproj
git commit -m "feat(paywall): PricingConfig variant/layout/copy surface"
```

---

### Task 7: PaywallView restructure — hero Yearly, Lifetime affordance, computed badge, copy, owned state, metrics

**Files:**
- Modify: `App/Sources/Features/Paywall/PaywallView.swift`

UI task; build-verified now, runtime-verified in Task 8. Make these edits in order:

- [ ] **Step 1: Add `.lifetime` to the Plan enum + a trigger string for metrics**

Line 55: `enum Plan: String, CaseIterable { case yearly, monthly }` → `case yearly, monthly, lifetime`.
Add a computed `triggerKey` on `Trigger` (after `subhead`, ~line 33):

```swift
        var metricKey: String {
            switch self { case .reports: "reports"; case .settings: "settings"; case .removeWatermark: "remove_watermark" }
        }
```

- [ ] **Step 2: Remove the stale "Lifetime — when it lands" bullet**

In `valueBullets` (lines 310-311) delete the `bullet("infinity", "Lifetime — when it lands", …)` call entirely (Lifetime now ships in this paywall; the copy would contradict the visible affordance).

- [ ] **Step 3: Make Yearly the hero + Monthly recede in `planRow`**

In `planRow(_:)` (lines 417-462), give the selected/Yearly row dominance. Replace the `.background`/`.overlay` (lines 450-459) with a hero-aware treatment:

```swift
            .padding(plan == .yearly ? 18 : 14)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(plan == .yearly
                          ? AnyShapeStyle(LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.85)], startPoint: .topLeading, endPoint: .bottomTrailing))
                          : AnyShapeStyle(Color(.secondarySystemBackground)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(isSelected ? Color.accentColor : Color.gray.opacity(0.18),
                                  lineWidth: isSelected ? 2 : 1)
            )
            .foregroundStyle(plan == .yearly ? Color.white : Color.primary)
```

In the same row, gate the per-cycle/title colors so they read on the filled hero (white) vs the plain monthly. Drop the separate "BEST VALUE" capsule's competing styling so Yearly carries exactly one badge + the savings line (Step 4). Add a checkmark when `isSelected`:

```swift
                if isSelected { Image(systemName: "checkmark.circle.fill") }
```

- [ ] **Step 4: Computed savings badge (replace hardcoded "SAVE 51%")**

Replace `savingsPill` (lines 464-472) so it reads from products via `PricingDisplay`:

```swift
    @ViewBuilder
    private var savingsPill: some View {
        if let m = manager.monthly?.price, let y = manager.yearly?.price,
           let s = PricingDisplay.annualSavings(monthlyPrice: m, yearlyPrice: y) {
            Text(PricingDisplay.savingsBadge(s, currencyCode: manager.yearly?.priceFormatStyle.currencyCode ?? "USD"))
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.green.opacity(0.18), in: .capsule)
                .foregroundStyle(.green)
        }
    }
```

> If `Product.priceFormatStyle.currencyCode` is unavailable, fall back to `Locale.current.currency?.identifier ?? "USD"`. For the `--mock-paywall-prices` path, update the two `mockPlanRow` calls (lines 335-336) to `"$39.99"` / `"$3.99"` and `"Just $3.33 per month, billed yearly"`.

- [ ] **Step 5: Lifetime affordance + owned state in `pricePicker`**

In `pricePicker`'s `.ready` case (lines 344-348), keep `planRow(.yearly)` then `planRow(.monthly)`, and below the picker (after the purchase button in the body) add the affordance. Simplest: add a `lifetimeAffordance` view and render it after the CTA. Implement:

```swift
    @ViewBuilder
    private var lifetimeAffordance: some View {
        if manager.ownsLifetime {
            Label(PricingConfig.ownedTitle, systemImage: "checkmark.seal.fill")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.green)
        } else if let lifetime = manager.lifetime {
            Divider().padding(.vertical, 4)
            Button {
                selection = .lifetime
                PaywallMetrics.record(.tierSelected, variant: PricingConfig.variant, trigger: trigger.metricKey, tier: "lifetime")
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(PricingConfig.lifetimeAffordanceTitle).font(.subheadline.weight(.semibold))
                        Text("\(PricingConfig.lifetimeAffordanceSubtitle) — \(lifetime.displayPrice)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 6)
                .overlay(alignment: .top) { if selection == .lifetime { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 2).padding(-6) } }
            }
            .buttonStyle(.plain)
        }
    }
```

Render `lifetimeAffordance` in the body right under the purchase button. When `manager.ownsLifetime`, ALSO hide the tier picker + purchase button (show only the owned label) — wrap the picker+button in `if !manager.ownsLifetime { … }` and emit `PaywallMetrics.record(.lifetimeOwnedView, …)` in `.onAppear` when owned.

- [ ] **Step 6: CTA title + trial reassurance adapt to selection**

In `purchaseButtonTitle` (find the computed property feeding `purchaseButton`), return for `.lifetime`: `"Buy Lifetime — \(manager.lifetime?.displayPrice ?? "$99.99")"`; for subs keep the existing "Try Pro Free for 7 Days"/"Subscribe" logic. Replace the buried `trialTerms` (lines 521-531) so that for subscription selections it shows `PricingConfig.trialReassurance` in a higher-contrast style (`.footnote`, `.primary` weight medium), and renders nothing for `.lifetime`.

- [ ] **Step 7: Wire the remaining metrics**

- `.onAppear` of the body: `PaywallMetrics.record(.paywallView, variant: PricingConfig.variant, trigger: trigger.metricKey, tier: nil)`.
- In each `planRow`/`mockPlanRow` tap (`selection = plan`): also `PaywallMetrics.record(.tierSelected, …, tier: plan.rawValue)`.
- In `runPurchase()` (the purchase action): record `.purchaseStart` before, `.trialStart` if eligible+sub, `.purchaseSuccess`/`.purchaseFailure` on the outcome, all stamped with `selection.rawValue`. Keep the existing `ReportsConversionMetrics.recordConversion()` call for back-compat.
- Restore button: `PaywallMetrics.record(.restoreTapped, …)`.

- [ ] **Step 8: Build**

Run: `xcodebuild -project Billable.xcodeproj -scheme Billable -configuration Debug -destination 'platform=iOS Simulator,id=4AA84237-0FFF-4652-A3CC-6C3DC2C63DC7' -derivedDataPath /tmp/lifetime-dd build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: `** BUILD SUCCEEDED **`. Fix any type/signature mismatches against Tasks 1–6.

- [ ] **Step 9: Commit**

```bash
git add App/Sources/Features/Paywall/PaywallView.swift
git commit -m "feat(paywall): Yearly-hero + Lifetime affordance, computed savings, reframed trial copy, funnel metrics, drop stale bullet"
```

---

### Task 8: Full gate + runtime verification

**Files:** none (verification)

- [ ] **Step 1: Full BillableCore test suite**

Run: `cd Packages/BillableCore && swift test 2>&1 | tail -15`
Expected: all green (existing + the 3 new suites).

- [ ] **Step 2: Clean app build**

Run: `xcodebuild -project Billable.xcodeproj -scheme Billable -configuration Debug -destination 'platform=iOS Simulator,id=4AA84237-0FFF-4652-A3CC-6C3DC2C63DC7' -derivedDataPath /tmp/lifetime-dd build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Runtime-verify the paywall**

Install + launch with the mock-prices path (no StoreKit session needed) to a paywall surface, e.g. the locked Reports tab:
```bash
xcrun simctl install booted /tmp/lifetime-dd/Build/Products/Debug-iphonesimulator/Billable.app
xcrun simctl launch booted com.eldenstudios.billable --reset-store --ui-test-skip-onboarding --ui-test-open-reports --mock-paywall-prices
xcrun simctl io booted screenshot /tmp/paywall.png
```
Confirm by screenshot: Yearly renders as the filled hero (selected) with the "SAVE $7.89 · about 2 months free" badge; Monthly recedes; the "Prefer to pay once? Own Cadence Pro forever — $99.99 ›" affordance sits below the trial CTA; the trial reassurance line is prominent; no "Lifetime — when it lands" bullet remains.

- [ ] **Step 4: Final commit (if any verification fixes)**

```bash
git add -A && git commit -m "test(paywall): runtime-verify lifetime ladder + hero layout"
```

---

## Self-review

**Spec coverage:** Products/prices (T3) ✓ · lifetime entitlement + precedence + restore (T1/T2) ✓ · computed savings badge (T4/T7.4) ✓ · Yearly-hero + Lifetime affordance + owned state + double-buy guard (T7) ✓ · reframed trial reassurance (T6/T7.6) ✓ · one badge / drop stale bullet / lock order (T7.2/T7.3) ✓ · PricingConfig + variant-keyed funnel metrics (T5/T6/T7.7) ✓ · tests (T1/T4/T5/T8) ✓ · active-sub nudge — **covered by the owned-state + a follow-up note; if not surfaced in T7.5, add a one-line alert after a lifetime purchase while `manager.entitlement` had an active sub.** Human ASC steps are out of code scope ✓.

**Placeholder scan:** none — all code steps carry literal code; the one conditional ("if `priceFormatStyle.currencyCode` is unavailable") gives the explicit fallback.

**Type consistency:** `resolveEntitlement(ownsLifetime:subscription:)`, `lifetimeProductID`, `lifetime`/`ownsLifetime`, `PricingDisplay.annualSavings`/`savingsBadge`, `PaywallMetrics.Event`/`key`/`record`, `PricingConfig.variant`/`layout`/copy, `Plan.lifetime`, `Trigger.metricKey` — names used consistently across T1–T8.

**Deferred (NOT in this plan, per spec):** invoice-send soft paywall trigger, internal metrics readout screen, "what you get" compaction.
