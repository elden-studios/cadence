# Phase 6 — Paywall & conversion polish — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Polish the paywall & conversion surfaces — honest copy/metrics, correct in-flight behavior, and a spec (`FEATURES.md`) that matches the shipped watermark-only model — without adding any gating.

**Architecture:** App-layer only (`PaywallView`, `SettingsView`) + `FEATURES.md`. No BillableCore source changes → build- + runtime-gated; the 344 BillableCore unit tests are a regression check only.

**Tech Stack:** SwiftUI, StoreKit-backed `SubscriptionManager`/`PaywallMetrics`. iOS app target.

**Spec:** `docs/superpowers/specs/2026-06-01-phase6-paywall-conversion-design.md`. Decisions: #4 = correct the spec (watermark-only, NO new gates); F31 = alert in the paywall (no BillableCore refactor).

**Commands:**
- App + widget build: `xcodebuild -project Billable.xcodeproj -scheme Billable -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build/DerivedData build`
- Regression: `swift test --package-path Packages/BillableCore` (expect **344**, unchanged)

**Note for all tasks:** the line numbers below are approximate (`~L`) — **locate the exact current lines by reading the cited function/region before editing.** Touch only the files/regions named per task. Keep existing code style. The "GET PAID"/pricing/CTA structure is correct — only the specified copy/behavior changes.

---

## File Structure

- `App/Sources/Features/Paywall/PaywallView.swift` — WS-B (in-flight/metric/owned-footer), WS-C (restore alert), WS-E (caption/currency), WS-A (`.reports` subhead + lead bullet).
- `App/Sources/Features/Settings/SettingsView.swift` — WS-D (chevron + restore placement), WS-C tail (restore feedback in Settings).
- `FEATURES.md` — WS-A (§6/§10 reconciliation).

**Task order (sequential — several share `PaywallView.swift`):** Task 1 WS-B → Task 2 WS-C → Task 3 WS-D → Task 4 WS-E → Task 5 WS-A.

---

## Task 1 (WS-B): Paywall in-flight & metric correctness

**File:** `App/Sources/Features/Paywall/PaywallView.swift`. No unit test (view); gate = build.

- [ ] **Step 1: NEW-S1-1 — disable the close (X) button during processing.** Find the `ToolbarItem(placement: .topBarTrailing)` close `Button` (it sets `dismiss()`, label `Image(systemName: "xmark")`, has `.accessibilityLabel("Close paywall")`, rendered when `!isEmbedded`). Append `.disabled(isProcessing)` to its modifier chain:

```swift
                        Button { dismiss() } label: { Image(systemName: "xmark") }
                            .accessibilityLabel("Close paywall")
                            .disabled(isProcessing)
```

- [ ] **Step 2: NEW-S1-2 — record `lifetimeOwnedView` reactively (fix the cold-present race).** Add a state flag near the other `@State` properties:

```swift
    /// One-shot guard so the owned-Lifetime funnel event records exactly once per
    /// presentation even though `ownsLifetime` resolves async after onAppear. (S6/NEW-S1-2)
    @State private var didRecordLifetimeOwned = false
```

In the existing `.onAppear`, where it currently does `if manager.ownsLifetime { PaywallMetrics.record(.lifetimeOwnedView, …) }`, set the flag when it fires (so the warm-path doesn't double count). Then add an `.onChange` beside the existing `.onChange(of: reportEntries)` / `.onChange(of: reportInvoices)` modifiers:

```swift
            .onChange(of: manager.ownsLifetime) { _, owned in
                guard owned, !didRecordLifetimeOwned else { return }
                didRecordLifetimeOwned = true
                PaywallMetrics.record(.lifetimeOwnedView, variant: PricingConfig.variant,
                                      trigger: trigger.metricKey, tier: "lifetime")
            }
```

And update the onAppear branch to set the flag:

```swift
                if manager.ownsLifetime {
                    didRecordLifetimeOwned = true
                    PaywallMetrics.record(.lifetimeOwnedView, variant: PricingConfig.variant,
                                          trigger: trigger.metricKey, tier: "lifetime")
                }
```

(Match the existing `.onChange` two-parameter closure style used in this file; if the file uses the zero-arg form, mirror that.)

- [ ] **Step 3: NEW-S1-4 — slim the owned-Lifetime footer.** Today `lifetimeAffordance`, `secondaryActions`, and `finePrint` render unconditionally in `body` (only the price picker + CTA are inside the `if !manager.ownsLifetime` block). Gate `secondaryActions` and `finePrint` so an owner sees only Terms + Privacy. Extract a small view from the two `Link`s already inside `secondaryActions` (Terms of Use + Privacy Policy):

```swift
    private var termsPrivacyLinks: some View {
        HStack(spacing: 16) {
            Link("Terms of Use", destination: URL(string: "https://...")!)   // reuse the exact URLs already in secondaryActions
            Link("Privacy Policy", destination: URL(string: "https://...")!)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
```

In `body`, replace the unconditional `secondaryActions` + `finePrint` with:

```swift
                    if manager.ownsLifetime {
                        termsPrivacyLinks
                    } else {
                        secondaryActions
                        finePrint
                    }
```

(Keep `lifetimeAffordance` rendering unconditionally — it already shows the owned title. Copy the real Terms/Privacy URLs verbatim from the existing `secondaryActions` `Link`s; do not invent URLs.)

- [ ] **Step 4: Build.** Run the xcodebuild command → expect `** BUILD SUCCEEDED **`.
- [ ] **Step 5: Commit.**

```bash
git add App/Sources/Features/Paywall/PaywallView.swift
git commit -m "Phase 6 (WS-B): disable X during purchase; reactive lifetimeOwnedView; slim owned-Lifetime footer"
```

---

## Task 2 (WS-C): Restore feedback (F31 = alert in the paywall)

**File:** `App/Sources/Features/Paywall/PaywallView.swift`. No unit test; gate = build.

- [ ] **Step 1: Add a dedicated restore-notice alert.** Near the other `@State` (beside the existing `error: String?`), add:

```swift
    @State private var restoreNotice: String?
```

Add a `.alert` beside the existing purchase-error alert (the one titled "Couldn't complete purchase"):

```swift
            .alert("Restore purchases", isPresented: Binding(
                get: { restoreNotice != nil }, set: { if !$0 { restoreNotice = nil } }
            )) {
                Button("OK", role: .cancel) { restoreNotice = nil }
            } message: {
                Text(restoreNotice ?? "")
            }
```

- [ ] **Step 2: Surface the empty/failed restore.** In `restore()` (currently `isProcessing = true; let restored = await manager.restore(); isProcessing = false; if restored { dismiss() }`), add the missing `else`:

```swift
        if restored {
            dismiss()
        } else {
            restoreNotice = "No active purchases were found for your Apple ID."
        }
```

(Leave `runPurchase()` and its existing `error` alert untouched. On a successful restore the view dismisses / flips to Pro, so no success alert is needed here.)

- [ ] **Step 3: Build + commit.**

Run xcodebuild → `** BUILD SUCCEEDED **`.

```bash
git add App/Sources/Features/Paywall/PaywallView.swift
git commit -m "Phase 6 (WS-C): surface empty/failed restore with a dedicated alert"
```

---

## Task 3 (WS-D): Settings cleanup

**File:** `App/Sources/Features/Settings/SettingsView.swift` (the ~L78-95 subscription section + the restore row). No unit test; gate = build.

- [ ] **Step 1: Remove the false push-chevron on "Upgrade to Pro".** The "Upgrade to Pro" `Button` (action sets `showingPaywall = true`, which presents a `.sheet`) renders an `HStack` ending in `Image(systemName: "chevron.right")`. Delete that trailing chevron `Image` (and any `Spacer()` that only existed to push it, if removing it leaves a dangling spacer — keep the row visually sensible). The row should no longer imply a push navigation.

- [ ] **Step 2: Show "Restore purchases" only for non-Pro users.** The `if subscriptions.isPro { … } else { … }` block currently closes before the "Restore purchases" `Button`, so it renders for everyone. Move the "Restore purchases" `Button` **inside** the `else` branch (so Pro users see only "Cadence Pro · Active" + "Manage subscription").

- [ ] **Step 3: Surface the restore result (WS-C tail).** The restore row currently does `_ = await subscriptions.restore()`. Capture the result and show feedback consistent with the paywall — add a `@State private var restoreNotice: String?` to `SettingsView` and an `.alert("Restore purchases", …)` (same shape as Task 2), setting `restoreNotice = "No active purchases were found for your Apple ID."` when `restore()` returns `false`. (On success the `isPro` view state flips, changing the section.)

```swift
                Button("Restore purchases") {
                    Task {
                        let restored = await subscriptions.restore()
                        if !restored { restoreNotice = "No active purchases were found for your Apple ID." }
                    }
                }
```

- [ ] **Step 4: Build + commit.**

Run xcodebuild → `** BUILD SUCCEEDED **`.

```bash
git add App/Sources/Features/Settings/SettingsView.swift
git commit -m "Phase 6 (WS-D): drop false Upgrade chevron; Restore only for non-Pro + result feedback"
```

---

## Task 4 (WS-E): Paywall copy/display polish

**File:** `App/Sources/Features/Paywall/PaywallView.swift`. No unit test; gate = build.

- [ ] **Step 1: F33 — symmetric monthly caption.** Find `perCycleLabel(for:product:)`. The `.yearly` case returns `"Just \(perMonth) per month, billed yearly"`; the `.monthly` case returns the bare `"Billed every month"`. Replace the `.monthly` case so it restates the price, mirroring the yearly pattern — e.g.:

```swift
        case .monthly:
            let price = product?.displayPrice ?? ""
            return price.isEmpty ? "Billed monthly" : "\(price) billed monthly"
```

(Use the product's formatted price the same way the yearly case derives `perMonth`; if the file already has a formatted-price helper, reuse it. Keep the cadence-second word order consistent with yearly.)

- [ ] **Step 2: F33 — update the mock twin.** Find `mockPlanRow` (used under the `--mock-paywall-prices` launch arg) — it hardcodes `"Billed every month"`. Update it to match the new monthly caption (e.g. `"$3.99 billed monthly"`) so screenshots stay consistent.

- [ ] **Step 3: NEW-S1-3 — guard the savings-badge currency.** In `savingsPill` (computes annual savings from `manager.monthly?.price` + `manager.yearly?.price`, formats with `yearlyCurrencyCode`), suppress the badge when the two products' currencies differ. Add an early guard so the pill renders nothing on a currency mismatch:

```swift
        // Both products must share a currency for the savings figure to be meaningful.
        let monthlyCurrency = manager.monthly?.priceFormatStyle.locale.currency?.identifier
        let yearlyCurrency = manager.yearly?.priceFormatStyle.locale.currency?.identifier
        guard let monthlyCurrency, let yearlyCurrency, monthlyCurrency == yearlyCurrency else {
            return AnyView(EmptyView())
        }
```

(Adapt to `savingsPill`'s actual return type — if it isn't already `some View` via `AnyView`/`@ViewBuilder`, use the file's existing pattern to conditionally render nothing, e.g. wrap the body in `if …` within a `@ViewBuilder`. Do not change `PricingDisplay`.)

- [ ] **Step 4: Build + commit.**

Run xcodebuild → `** BUILD SUCCEEDED **`.

```bash
git add App/Sources/Features/Paywall/PaywallView.swift
git commit -m "Phase 6 (WS-E): symmetric monthly caption + savings-badge currency guard"
```

---

## Task 5 (WS-A): Spec reconciliation + paywall copy (#4 = B, F48)

**Files:** `FEATURES.md`, `App/Sources/Features/Paywall/PaywallView.swift`. No unit test; gate = build (PaywallView) + doc accuracy.

- [ ] **Step 1: `FEATURES.md` §6 — watermark-only model.** Find the §6 line that reads (approx) "Paywall fires if the user is not Pro." Replace it to describe the actual model: free users fully create, finalize, and send invoices — watermarked with "Sent with Cadence"; **Pro removes the watermark and unlocks Reports + CSV export.** (No client/invoice creation gating.)

- [ ] **Step 2: `FEATURES.md` §10 tier table.** In the tier/comparison table:
  - **Delete** the "Up to 2 active clients ✅ | —" row (clients are unlimited on both tiers).
  - Change the "Create + send invoices — | ✅" row to **"Watermark-free invoices — | ✅"** (free can create/send watermarked invoices; Pro removes the watermark).
  - Correct the pricing rows: `$5.99`/`$34.99` → **`$3.99` (Monthly) / `$39.99` (Yearly)**, and **add the `$99.99` Lifetime** tier.
  - Remove or replace the documented `.createInvoice` / `.extraClient` trigger copy (those triggers don't exist) with the actual triggers: `.removeWatermark`, `.reports`, `.settings`.
  - Reconcile any §10 reports/settings headline copy with what `PaywallView` actually shows (see Step 4).

  (Read the current §10 carefully and edit precisely — keep the table's existing format.)

- [ ] **Step 3: PaywallView — align the `.reports` Trigger subhead.** In the `Trigger` enum's `subhead` (or equivalent) computed copy, the `.reports` case names only the AR dashboard. Bring it in line with the rule "lead with context, then enumerate the full unlock," e.g.:

```swift
        case .reports:
            return "Full Reports dashboard, watermark-free invoices, and CSV export — all in one upgrade."
```

(Keep `.settings` and `.removeWatermark` as they are — they already enumerate.)

- [ ] **Step 4: PaywallView — rename the lead value-bullet title.** In `valueBullets`, the lead bullet title "Watermark-free PDF invoices" can read as if invoicing is gated. Rename the title to **"Clean, professional invoices"** (keep the body "Send polished invoices without 'Sent with Cadence' in the footer.").

- [ ] **Step 5: Build + commit.**

Run xcodebuild → `** BUILD SUCCEEDED **`.

```bash
git add FEATURES.md App/Sources/Features/Paywall/PaywallView.swift
git commit -m "Phase 6 (WS-A): correct FEATURES.md to watermark-only model + align paywall copy"
```

---

## Final verification (after all tasks)

- [ ] App + widget `xcodebuild … build` → `** BUILD SUCCEEDED **`.
- [ ] `swift test --package-path Packages/BillableCore` → **344** (unchanged; regression check).
- [ ] Runtime (seeded sim): Settings shows no chevron on Upgrade + "Restore" only for non-Pro; paywall `.reports` entry copy names all three Pro values; monthly/yearly captions symmetric.
- [ ] Manual / StoreKit-config QA (document on PR): X disabled mid-purchase; empty-restore alert; owned-Lifetime footer = Terms+Privacy only; `lifetimeOwnedView` fires once on cold present for an owner.

---

## Self-Review

**1. Spec coverage:** WS-A (#4=B + F48) → Task 5; WS-B (NEW-S1-1/2/4) → Task 1; WS-C (F31) → Task 2; WS-D (F32 + restore tail) → Task 3; WS-E (F33 + NEW-S1-3) → Task 4. All 10 open items mapped. ✅

**2. Placeholder scan:** Each step shows the concrete snippet to add/replace. The two spots that depend on existing values — the Terms/Privacy URLs (Task 1 Step 3) and the monthly formatted-price helper (Task 4 Step 1) — explicitly instruct reuse of the file's existing code rather than inventing values. ✅

**3. Consistency:** `restoreNotice` is the alert-state name in both Task 2 (PaywallView) and Task 3 (SettingsView). `didRecordLifetimeOwned` defined and used in Task 1. The `.onChange` closure arity must match the file's existing usage (noted). ✅

**Implementer note:** all line numbers are approximate — read the cited region first. Do not refactor beyond the named edits. `PaywallView.swift` is large and shared by Tasks 1/2/4/5 — these run sequentially (subagent-driven), each committing before the next, so there are no parallel-edit conflicts.
