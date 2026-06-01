# Phase 8 — Onboarding/entity + clients/currency polish — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Final cluster — entity/profile coherence (incl. a BillableCore default + `isProfileEnriched` change), payment-reminders polish, and empty-state/recurrence/onboarding cleanup. No net-new features.

**Architecture:** WS-A touches BillableCore (`BusinessProfile`, + tests) + App (`BusinessProfileEditorView`); WS-B/WS-C are App view-layer. Build- + test-gated.

**Tech Stack:** SwiftUI, SwiftData, BillableCore, swift-testing.

**Spec:** `docs/superpowers/specs/2026-06-01-phase8-onboarding-polish-design.md`. Forks (decided): default → `.freelancer`; entity control → rewrite footer copy; reminder preview → hide when off; "Incomplete" → fix `isProfileEnriched` definition.

**Commands:** unit `swift test --package-path Packages/BillableCore`; build `xcodebuild -project Billable.xcodeproj -scheme Billable -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build/DerivedData build`.

**Note:** line numbers are approximate — re-read the cited region before editing. Tasks run sequentially. Keep existing style.

## File Structure
- `Packages/BillableCore/Sources/BillableCore/Models/BusinessProfile.swift` — WS-A (default + isProfileEnriched).
- `Packages/BillableCore/Tests/BillableCoreTests/BusinessProfileEntityTests.swift`, `BusinessProfileMigrationTests.swift` — WS-A test updates.
- `App/Sources/Features/Settings/BusinessProfileEditorView.swift` — WS-A (tax literal, footer, onChange, remove Incomplete row).
- `App/Sources/App/BillableApp.swift`, `App/Sources/Features/Settings/SettingsView.swift` — WS-A (verify seed fixture + badge copy).
- `App/Sources/Features/Settings/PaymentRemindersView.swift` — WS-B.
- `App/Sources/Features/Work/WorkView.swift`, `.../RecurringRulesView.swift`, `.../OnboardingView.swift` — WS-C.

Order: Task 1 (WS-A) → Task 2 (WS-B) → Task 3 (WS-C).

---

## Task 1 (WS-A): Entity-type & business-profile coherence

**Files:** `BusinessProfile.swift` + its 2 test files (BillableCore); `BusinessProfileEditorView.swift`, `BillableApp.swift`, `SettingsView.swift` (App). TDD for the model change.

- [ ] **Step 1: Update the BillableCore tests to the NEW expected behavior (red).** In `BusinessProfileEntityTests.swift`:

Replace `defaultEntityType()` (currently expects `.organization`):
```swift
    @Test("entityType defaults to freelancer (freelancer-first product)")
    func defaultEntityType() {
        let p = BusinessProfile(name: "Acme")
        #expect(p.entityType == .freelancer)
        #expect(p.entityTypeRaw == "freelancer")
    }
```
(Leave `accessorSetsRaw()` unchanged — the `"bogus" → .organization` getter-fallback assertion still holds.)

Replace `enriched()` (currently "requires address AND bank details") — per spec NEW-S7-5 the badge "fires when name/address are missing", so gate on **name + address** (bank optional):
```swift
    @Test("isProfileEnriched requires a non-blank name and address (bank details optional)")
    func enriched() {
        let p = BusinessProfile(name: "X")
        #expect(p.isProfileEnriched == false)   // name present, no address
        p.address = "1 Main St"
        #expect(p.isProfileEnriched == true)    // name + address — bank NOT required
        p.bankIBAN = "GB00 0000"
        #expect(p.isProfileEnriched == true)    // still true with a bank
        p.address = "   "
        #expect(p.isProfileEnriched == false)   // blank/whitespace address → not enriched
        p.address = "1 Main St"
        p.name = "   "
        #expect(p.isProfileEnriched == false)   // blank/whitespace name → not enriched
    }
```

In `BusinessProfileMigrationTests.swift`, change line 35 from `#expect(p.entityType == .organization)` to:
```swift
        #expect(p.entityType == .freelancer)
```
(Line 37 `#expect(p.isProfileEnriched == false)` stays — the persisted profile has no address, so it's not enriched under either definition.)

- [ ] **Step 2: Run the tests → verify they FAIL.** `swift test --package-path Packages/BillableCore --filter BusinessProfile` → expect failures on `defaultEntityType` (gets `.organization`) and `enriched` (name+address-without-bank not yet true).

- [ ] **Step 3: Apply the BillableCore model changes (green).** In `BusinessProfile.swift`:

Change the stored default (currently `public var entityTypeRaw: String = EntityType.organization.rawValue` with a comment about `.organization`). Replace lines ~63-65 with:
```swift
    /// Raw `EntityType`. Default `.freelancer` matches the freelancer-first product
    /// and both UIs (onboarding + editor). The getter's fallback stays `.organization`
    /// as a conservative decode guard for corrupt/unknown raw values (see below).
    public var entityTypeRaw: String = EntityType.freelancer.rawValue
```

Keep the getter fallback at `.organization` but clarify it (lines ~67-70):
```swift
    public var entityType: EntityType {
        // Fallback fires ONLY for a corrupt/unknown stored raw string (e.g. CloudKit
        // sync of a future case); `.organization` is the safe "show more UI" default
        // there. New profiles default to `.freelancer` via `entityTypeRaw` above.
        get { EntityType(rawValue: entityTypeRaw) ?? .organization }
        set { entityTypeRaw = newValue.rawValue }
    }
```

Change the `init` default (line ~110) from `entityTypeRaw: String = EntityType.organization.rawValue` to:
```swift
        entityTypeRaw: String = EntityType.freelancer.rawValue,
```

Change `isProfileEnriched` (lines ~76-80) to drop the bank requirement and gate on name + address:
```swift
    /// "Enriched" = the invoice-completing fields are present: a non-blank issuer
    /// name AND a postal address for the invoice header. Bank details are
    /// intentionally optional ("Leave blank to hide"), so they do NOT gate this.
    /// Drives the dismissible enrichment nudge only — never blocks anything.
    public var isProfileEnriched: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
```

Run `swift test --package-path Packages/BillableCore` → expect ALL green (the updated tests pass; `defaultForCurrentLocale` inherits the new default).

- [ ] **Step 4: NEW-S2-1 — wire `showsTaxByDefault` as the single source of truth.** In `BusinessProfileEditorView.swift` line ~93, change:
```swift
                if entityType == .organization {
```
to:
```swift
                if entityType.showsTaxByDefault {
```

- [ ] **Step 5: NEW-S2-3 — align the editor footer with onboarding's subtitles.** In `BusinessProfileEditorView.swift`, the Issuer Section footer (line ~73) currently reads "Freelancer bills under your own name; Organization bills under a company name. This only changes invoice labels." Replace with copy that mirrors `EntityType.cardSubtitle` ("Just me — I bill for my own time." / "A team — we bill under one company name."):
```swift
                Text("Freelancer — just you, billing for your own time. Organization — a team billing under one company name. This only changes the labels on your invoices.")
```

- [ ] **Step 6: NEW-S7-3 — keep a typed tax rate visible when switching to Freelancer.** In `BusinessProfileEditorView.swift`, add an `.onChange(of: entityType)` next to `.onAppear { loadIfNeeded() }` (line ~209) that re-evaluates `taxExpanded` from the CURRENT in-editor rate (mirroring `loadIfNeeded`'s `taxExpanded = profile.taxRate != .zero`):
```swift
        .onChange(of: entityType) { _, _ in
            // Don't hide a freshly-entered rate behind the collapsed Freelancer
            // DisclosureGroup when toggling Org→Freelancer live.
            taxExpanded = taxRatePercent != 0
        }
```
(If the file's other `.onChange` modifiers use the single-param closure form, match that; the two-param form is correct on the iOS 17 target.)

- [ ] **Step 7: NEW-S7-5 — remove the now-redundant in-editor "Incomplete" row.** In `BusinessProfileEditorView.swift`, delete the entire conditional Section at lines ~184-198:
```swift
            if let profile = profiles.first, !profile.isProfileEnriched {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                        Text("Incomplete")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Add your address and a payment method")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
```
(The `SettingsView` badge remains the single enrichment surface; its meaning is now "add your address". See Step 8.)

- [ ] **Step 8: Verify two downstream sites (no change expected, adjust only if needed).**
  - `BillableApp.swift` (~line 68) — the `--seed-onboarding-needs-setup` fixture `BusinessProfile(name: "Test Co")` now defaults to `.freelancer`. Confirm nothing asserts `.organization` for that fixture (grep the launch-arg handling + any UITest). If a comment/assertion expects `.organization`, update it to `.freelancer`.
  - `SettingsView.swift` (~41-47) — the "Incomplete" badge now fires on a missing address (not bank). Confirm its subtext (if any) doesn't tell the user to add *bank* details; if it says e.g. "Add address and payment method", trim to "Add your address" so it matches the new `isProfileEnriched`. (Copy-only; skip if the badge has no bank-specific subtext.)

- [ ] **Step 9: Full test + build.** `swift test --package-path Packages/BillableCore` → green. `xcodebuild … build` → `** BUILD SUCCEEDED **`.

- [ ] **Step 10: Commit.**
```bash
git add Packages/BillableCore/Sources/BillableCore/Models/BusinessProfile.swift Packages/BillableCore/Tests/BillableCoreTests/BusinessProfileEntityTests.swift Packages/BillableCore/Tests/BillableCoreTests/BusinessProfileMigrationTests.swift App/Sources/Features/Settings/BusinessProfileEditorView.swift App/Sources/App/BillableApp.swift App/Sources/Features/Settings/SettingsView.swift
git commit -m "Phase 8 (WS-A): entity default→freelancer, showsTaxByDefault SSoT, footer copy, keep tax rate on toggle, isProfileEnriched=name+address"
```

---

## Task 2 (WS-B): Payment reminders polish

**File:** `App/Sources/Features/Settings/PaymentRemindersView.swift` only. No unit test; gate = build. Read the cited regions first.

- [ ] **Step 1: F26 — real sender name in the preview.** The two `ReminderTemplateRenderer.render(...)` calls (~lines 149, 155) pass `senderName: "Studio Lina"`. Change BOTH to:
```swift
                    senderName: profiles.first?.name ?? "Your business",
```
(The `profiles` `@Query` is already declared at ~line 10 and used at ~13.)

- [ ] **Step 2: NEW-S7-1 — warn when reminders are on but no timing is selected.** In `offsetsSection` (~77-91), add a conditional `footer` (or trailing caption) shown only when `masterEnabled && enabledSet.isEmpty` (use the exact name of the enabled-offsets set as it appears in the file):
```swift
            } footer: {
                if masterEnabled && enabledSet.isEmpty {
                    Text("Pick at least one timing or no reminders will send.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
```
(If `offsetsSection` already has a `header`, attach the `footer` to the same `Section`. Match the existing caption styling.)

- [ ] **Step 3: NEW-S7-2 — hide the live Preview when reminders are off.** Wrap `previewSection` (rendered in the Form `body` ~line 48, defined ~144-181) so it only renders when enabled:
```swift
                if masterEnabled {
                    previewSection
                }
```
(Find where `previewSection` is referenced in `body` and gate that reference.)

- [ ] **Step 4: Build + commit.**
Run xcodebuild → `** BUILD SUCCEEDED **`.
```bash
git add App/Sources/Features/Settings/PaymentRemindersView.swift
git commit -m "Phase 8 (WS-B): reminders — real preview sender, zero-offsets warning, hide preview when off"
```

---

## Task 3 (WS-C): Empty-states / recurrence copy / onboarding cleanup

**Files:** `WorkView.swift`, `RecurringRulesView.swift`, `OnboardingView.swift`. No unit test; gate = build. Read each region first.

- [ ] **Step 1: F4 — Work empty-state CTA.** In `WorkView.swift`, the "No projects yet" `ContentUnavailableView` (~138-143) has no `actions:`. Add an `actions:` closure exposing the existing `@State` sheet triggers (mirror `ClientsListContent`'s `borderedProminent` "Add Client" at `ClientsView.swift:~77-89`):
```swift
            } actions: {
                Button { showingNewProject = true } label: { Text("New Project") }
                    .buttonStyle(.borderedProminent)
                Button { showingNewClient = true } label: { Text("Add Client") }
            }
```
(Use the EXACT `@State` var names declared in WorkView — confirm they're `showingNewProject` / `showingNewClient`; adjust to match. These already drive existing sheets.)

- [ ] **Step 2: F4 — NewProjectSheet "No clients yet" CTA.** In the `NewProjectSheet` (in `WorkView.swift`, ~182-228), the "No clients yet" state (~193-198) only offers Cancel. Add `@State private var showingAddClient = false` to the sheet, an `actions:` "Add Client" button, and a `.sheet(isPresented: $showingAddClient) { NavigationStack { ClientEditorView(client: nil) } }`. (Confirm `ClientEditorView(client:)` accepts `nil` for new — it does per the codebase; match its real initializer.)
```swift
            } actions: {
                Button { showingAddClient = true } label: { Text("Add Client") }
                    .buttonStyle(.borderedProminent)
            }
```

- [ ] **Step 3 (optional, same file): F44 clarifying comment.** At the "No client" grouping in `WorkView.swift` (~111), add a one-line comment so a future reviewer doesn't remove it:
```swift
                    // "No client" bucket: load-bearing for the quickStart "General"
                    // project (client-less by design). Do not remove.
```

- [ ] **Step 4: F27 — RecurringRules copy + ended-template actions.** In `RecurringRulesView.swift`: (a) the empty-state copy (~23) names a non-existent "New Invoice screen" — replace with the real entry point:
```swift
            "To set up recurring billing, open the Invoices tab, tap +, then turn on 'Make this recurring'."
```
(b) The swipe actions (~31-39) always offer Pause/Resume even for ended templates. Guard the Pause/Resume button with `if !template.isEnded()` (use the real method/property — `isEnded()` per the evidence) so an Ended template offers only Delete:
```swift
                if !template.isEnded() {
                    Button { togglePause(template) } label: { … }   // keep the existing Pause/Resume button
                }
                // keep the existing Delete button unguarded
```
(Match the existing swipeActions structure + the real toggle method name.)

- [ ] **Step 5: NEW-S2-4 — remove the inert `@FocusState`.** In `OnboardingView.swift`, remove `@FocusState private var nameFocused` (~18) and the `.focused($nameFocused)` modifier (~119). Leave the surrounding field + the no-auto-focus behavior intact (the explanatory comment ~248-249 can stay or be trimmed to match).

- [ ] **Step 6: Build + commit.**
Run xcodebuild → `** BUILD SUCCEEDED **`.
```bash
git add App/Sources/Features/Work/WorkView.swift App/Sources/Features/Settings/RecurringRulesView.swift App/Sources/Features/Onboarding/OnboardingView.swift
git commit -m "Phase 8 (WS-C): Work/NewProject empty-state CTAs; RecurringRules copy + hide Pause/Resume on Ended; remove inert FocusState"
```
(Adjust the RecurringRulesView/OnboardingView paths to their real locations — grep if needed.)

---

## Final verification (after all tasks)
- [ ] `swift test --package-path Packages/BillableCore` → all green (updated entity/enriched tests pass).
- [ ] App + widget `xcodebuild … build` → `** BUILD SUCCEEDED **`.
- [ ] Runtime (seeded sim): new profile defaults to Freelancer; editor entity footer reads the card-subtitle wording; switch Org→Freelancer with a typed rate → rate stays visible; bank-less profile is NOT flagged "Incomplete"; reminders master-on + zero offsets → warning caption; preview hidden when reminders off; preview signs the real business name; Work "No projects yet" + NewProject "No clients yet" show working CTAs; RecurringRules empty-state points to Invoices+; an Ended template shows only Delete.

## Self-Review
**1. Spec coverage:** WS-A → Task 1 (S2-1 step4, S2-2 steps1-3, S2-3 step5, S7-3 step6, S7-5 steps1/3/7); WS-B → Task 2 (F26, S7-1, S7-2); WS-C → Task 3 (F4, F27, S2-4) + F44 comment. ✅
**2. Placeholder scan:** WS-A shows exact before/after incl. the two test rewrites; WS-B/C give exact snippets + "use the real var/method name" notes where the implementer must confirm an identifier. ✅
**3. Consistency:** `isProfileEnriched` = name+address (bank optional) is reflected in both the model change (Step 3) and its test (Step 1) and the removed in-editor row (Step 7) + the SettingsView badge check (Step 8). `.freelancer` default is reflected in the model (Step 3) + both test files (Step 1) + the seed-fixture check (Step 8). ✅

**Implementer note:** confirm real identifiers before editing — `enabledSet`/`previewSection`/`masterEnabled` in PaymentRemindersView; `showingNewProject`/`showingNewClient` in WorkView; `ClientEditorView(client:)` init; `template.isEnded()` + the Pause/Resume toggle name in RecurringRulesView; OnboardingView/RecurringRulesView file paths.
