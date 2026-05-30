# Onboarding Entity-Type — Plan 2: Onboarding flow + Profile editor + §8 call-site wiring

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the Plan-1 foundation into the product surface: a shared `EntityType → labels` mapping, a redesigned `welcome → identity` onboarding flow with a crash-safe throwing `finish()`, a latch-aware `OnboardingFlags.shouldShow`, the §8 reconcile/stamp call-site wiring (with a "count stable across two checks" delete-safety guard at the call site), deterministic `sort: \.createdAt` on the ~12 `@Query private var profiles` sites, and an entity-aware Business Profile editor with hardened financial fields. Zero changes to invoice/PDF math.

**Architecture:** Plan 1 already shipped the pure `BillableCore` layer (`EntityType`, `BusinessProfile` fields/latches, `BusinessProfileStore.{allSorted,canonical,reconcile,stampFirstSetupIfReached}`). This plan adds **App-target** code only:
- One shared, table-shaped mapping `EntityType+Presentation.swift` (App target) so onboarding and the editor read the same name/tax-ID labels (DRY). English literals (localization out of scope, §11).
- `finish()` becomes **fetch-then-mutate** the canonical profile with a **throwing** `try modelContext.save()` (latch set only after a successful save); creates **no** Client/Project/TimeEntry.
- `OnboardingFlags.shouldShow` drops the legacy `clientCount == 0` branch and returns `false` when any profile latch is set or the local fast-path flag is set; re-evaluated in `RootView`'s existing `scenePhase==.active` seam.
- §8 wiring lives in an **App-target wrapper** `BusinessProfileMaintenance` that implements the delete-safety guard (only call the already-shipping `reconcile` when the duplicate count is **stable across two consecutive observations**), invoked from `BillableApp.performStartupWiring()` and `RootView`'s `scenePhase==.active`. The shipped `BusinessProfileStore.reconcile` is **not** modified — the guard decides *whether* to call it.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI + `@Observable`, SwiftData + CloudKit private-DB mirror, `BillableCore` SPM package, Swift Testing for pure logic, XCUITest for UI. **English-only release.**

**Spec:** `docs/superpowers/specs/2026-05-30-onboarding-entity-type-design.md` (§5, §6, §8 call-site wiring; §9 a11y; §11 localization posture; §16 testing).

**Plan 1 (DONE + committed) — build on these EXACT interfaces, do not re-create:**
- `EntityType` (BillableCore): `.freelancer`/`.organization`; `var showsTaxByDefault: Bool` (true for org).
- `BusinessProfile` (BillableCore): `entityTypeRaw`/`entityType`; `onboardingCompletedAt: Date?`; `firstSetupCompletedAt: Date?`; `isProfileEnriched`; defaulted init; `expectedStoredPropertyCount = 28`.
- `BusinessProfileStore` (`@MainActor enum`, BillableCore): `allSorted(in:)`, `canonical(in:)`, `reconcile(in:)`, `stampFirstSetupIfReached(in:)`.
- `BillableModelContainer.schema` is the test-facing schema accessor.

**Verification reality:** pure logic → `cd Packages/BillableCore && swift test` (Swift Testing). SwiftUI views + app-target wiring are NOT unit-testable that way — the verify step is an app **build**:

```
xcodebuild -project Billable.xcodeproj -scheme Billable -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -configuration Debug build
```

and UI behavior via:

```
xcodebuild -project Billable.xcodeproj -scheme Billable -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:BillableUITests test
```

Do not invent fake unit tests for view rendering. Where a step is a view, the code-step writes the view and the verify-step is the build (+ a UI test where it adds real value); on-device/simulator manual checks are named explicitly per task.

**Worktree:** `/Users/lbazerbashi/Elden Studios/billable/.worktrees/onboarding-entity-type` (branch `feature/onboarding-entity-type`). Do **not** switch branches. Do **not** commit beyond the per-task commits below — the controller does a consistency review.

---

## File Structure

```
Packages/BillableCore/                         (Plan 1 — DONE, not edited here)
  Sources/BillableCore/Models/EntityType.swift
  Sources/BillableCore/Models/BusinessProfile.swift
  Sources/BillableCore/Persistence/BusinessProfileStore.swift

App/Sources/
  Presentation/
    EntityType+Presentation.swift              [CREATE]  shared label mapping (App target)
  Maintenance/
    BusinessProfileMaintenance.swift           [CREATE]  §8 call-site wrapper + stable-count delete guard
  Features/Onboarding/
    OnboardingView.swift                       [MODIFY]  welcome→identity, entity cards, throwing finish(), shouldShow rewrite
  Features/Settings/
    BusinessProfileEditorView.swift            [MODIFY]  entity Picker, mapped labels, freelancer DisclosureGroup, hardened fields, blank-name reject, "Incomplete"
    SettingsView.swift                         [MODIFY]  sort profiles by createdAt; surface "Incomplete" on the row
    CurrencyPickerView.swift                   [MODIFY]  sort profiles by createdAt
    PaymentRemindersView.swift                 [MODIFY]  sort profiles by createdAt
  Features/Today/TodayView.swift               [MODIFY]  sort BOTH profiles @Query by createdAt
  Features/Work/WorkView.swift                 [MODIFY]  sort profiles by createdAt
  Features/Reports/ReportsView.swift           [MODIFY]  sort profiles by createdAt
  Features/Projects/ProjectDetailView.swift    [MODIFY]  sort profiles by createdAt
  Features/Clients/ClientDetailView.swift      [MODIFY]  sort profiles by createdAt
  Features/Invoicing/InvoiceGeneratorView.swift [MODIFY] sort profiles by createdAt
  Features/Timer/StartTimerSheet.swift         [MODIFY]  sort profiles by createdAt
  App/BillableApp.swift                        [MODIFY]  wire BusinessProfileMaintenance into performStartupWiring(); honor --reset-store in prod branch (test slate)
  App/RootView.swift                           [MODIFY]  re-evaluate onboarding + run maintenance in scenePhase==.active

App/BillableUITests/
  OnboardingEntityTypeUITests.swift            [CREATE]  freelancer/org name-label; finish → Today, no auto-timer
  LaunchTaglineUITests.swift                   [PRESERVE] keep tagline + --ui-test-show-onboarding (re-run, do not edit)

Packages/BillableCore/Tests/BillableCoreTests/
  EntityTypePresentationTests.swift            [CREATE]  guards the shared mapping IF the mapping is placed in Core
  (see Task 1 note: the mapping lives in the App target per spec §6, so its
   guard is a build-time check, not a swift-test — Task 1 documents this.)
```

> **Pre-flight (run once, no commit):** confirm the build is green before touching anything, so later failures are attributable to this plan.
>
> ```
> xcodebuild -project Billable.xcodeproj -scheme Billable -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -configuration Debug build
> ```
>
> Expected: `** BUILD SUCCEEDED **`. If the named simulator is unavailable, run `xcrun simctl list devices available | grep iPhone` and substitute an available iPhone in every `-destination` below (keep it consistent across tasks).

---

### Task 1: Shared `EntityType → labels` mapping (App target)

Per spec §6/§11 the strings live in the **App layer**, not BillableCore (`EntityType.showsTaxByDefault` is the only policy on the enum; strings are presentation). Both onboarding and the editor consume this one type → DRY. It is App-target code, so its guard is the app **build** (a Swift-Testing unit test in BillableCore cannot see an App-target file). The mapping is a pure value type with no SwiftData/SwiftUI dependency, so the verification is a compile + the consuming tasks (3, 6) exercising it.

**Files:**
- Create: `App/Sources/Presentation/EntityType+Presentation.swift`

- [ ] **Step 1: Write the complete implementation**

```swift
import BillableCore

/// App-layer presentation strings for `EntityType`. The enum itself carries only
/// *policy* (`showsTaxByDefault`); the human-facing labels live here so the
/// onboarding identity screen and the Business Profile editor render IDENTICAL
/// copy from one source (DRY). English literals by product decision — Cadence
/// ships English-only and localization is out of scope (spec §11). Copy is still
/// written translation-shaped (single noun phrase, no glued fragments) as
/// zero-cost future insurance.
extension EntityType {
    /// Visible label for the issuer's name field, e.g. the ALL-CAPS field label
    /// in onboarding and the `TextField` title in the editor.
    var issuerNameLabel: String {
        switch self {
        case .freelancer:   return "Your name"
        case .organization: return "Business name"
        }
    }

    /// Prompt/placeholder for the issuer name field (matches `issuerNameLabel`'s register).
    var issuerNamePrompt: String {
        switch self {
        case .freelancer:   return "Jane Doe"
        case .organization: return "Acme Corp"
        }
    }

    /// Default tax-ID label shown beside the registration-number field.
    /// US-natural defaults; the editor's free-text field lets the user override.
    var taxIDLabel: String {
        switch self {
        case .freelancer:   return "Tax ID"
        case .organization: return "Business tax ID (EIN)"
        }
    }

    /// `UITextContentType` hint so the keyboard/AutoFill offers the right value
    /// (a person's name vs. an organization name).
    var nameContentType: UITextContentType {
        switch self {
        case .freelancer:   return .name
        case .organization: return .organizationName
        }
    }

    /// One-line, how-you-bill framing for the selectable entity cards (spec §5).
    var cardTitle: String {
        switch self {
        case .freelancer:   return "Freelancer"
        case .organization: return "Organization"
        }
    }

    var cardSubtitle: String {
        switch self {
        case .freelancer:   return "Just me — I bill for my own time."
        case .organization: return "A team — we bill under one company name."
        }
    }

    var cardSystemImage: String {
        switch self {
        case .freelancer:   return "person.fill"
        case .organization: return "building.2.fill"
        }
    }
}

import UIKit  // for UITextContentType
```

> Place the `import UIKit` at the **top** of the file (Swift requires imports before declarations); it is shown last above only to flag the dependency. Final file order: `import BillableCore`, `import UIKit`, then the `extension`.

- [ ] **Step 2: Verify it compiles (app build)**

Run:
```
xcodebuild -project Billable.xcodeproj -scheme Billable -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`. (No file references the new symbols yet; this proves the extension itself compiles against the shipped `EntityType`.)

- [ ] **Step 3: Commit**

```bash
git add "App/Sources/Presentation/EntityType+Presentation.swift"
git commit -m "feat(app): shared EntityType→labels presentation mapping (DRY for onboarding + editor)"
```

---

### Task 2: Deterministic `sort: \.createdAt` on all ~12 `@Query private var profiles` sites

Spec §8 BLOCKER: a `@Query` can't call `BusinessProfileStore.canonical`, so each site must sort by `createdAt` ascending so `profiles.first` is the deterministic oldest (the same survivor reconciliation keeps). Pure mechanical edit; the verify is a build.

**Files (MODIFY — one line each):**
- `App/Sources/Features/Today/TodayView.swift` (**two** sites: line ~9 and the nested `JumpBackInSection` ~111)
- `App/Sources/Features/Settings/SettingsView.swift` (~7)
- `App/Sources/Features/Settings/CurrencyPickerView.swift` (~11)
- `App/Sources/Features/Settings/BusinessProfileEditorView.swift` (~12)
- `App/Sources/Features/Settings/PaymentRemindersView.swift` (~10)
- `App/Sources/Features/Work/WorkView.swift` (~9)
- `App/Sources/Features/Reports/ReportsView.swift` (~13)
- `App/Sources/Features/Projects/ProjectDetailView.swift` (~11)
- `App/Sources/Features/Clients/ClientDetailView.swift` (~140)
- `App/Sources/Features/Invoicing/InvoiceGeneratorView.swift` (~15)
- `App/Sources/Features/Timer/StartTimerSheet.swift` (~13)

- [ ] **Step 1: Replace every occurrence**

In each file, change:
```swift
    @Query private var profiles: [BusinessProfile]
```
to:
```swift
    @Query(sort: \BusinessProfile.createdAt, order: .forward) private var profiles: [BusinessProfile]
```

> Use the fully-qualified key path `\BusinessProfile.createdAt` (not `\.createdAt`) — `@Query(sort:)` cannot always infer the root from the property's declared type, and the explicit form is unambiguous. `TodayView.swift` has **TWO** declarations (the view + the private `JumpBackInSection`); edit **both**. Confirm the full set first:
>
> ```
> grep -rn 'profiles: \[BusinessProfile\]' App/Sources/
> ```
> Expected: 12 lines across 11 files (TodayView twice). After editing, re-run the grep and confirm **zero** lines still read `@Query private var profiles` (i.e. every match now includes `sort:`):
> ```
> grep -rn '@Query private var profiles: \[BusinessProfile\]' App/Sources/
> ```
> Expected: no output.

- [ ] **Step 2: Verify the build**

Run:
```
xcodebuild -project Billable.xcodeproj -scheme Billable -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add "App/Sources/Features/Today/TodayView.swift" \
        "App/Sources/Features/Settings/SettingsView.swift" \
        "App/Sources/Features/Settings/CurrencyPickerView.swift" \
        "App/Sources/Features/Settings/BusinessProfileEditorView.swift" \
        "App/Sources/Features/Settings/PaymentRemindersView.swift" \
        "App/Sources/Features/Work/WorkView.swift" \
        "App/Sources/Features/Reports/ReportsView.swift" \
        "App/Sources/Features/Projects/ProjectDetailView.swift" \
        "App/Sources/Features/Clients/ClientDetailView.swift" \
        "App/Sources/Features/Invoicing/InvoiceGeneratorView.swift" \
        "App/Sources/Features/Timer/StartTimerSheet.swift"
git commit -m "fix(app): deterministic oldest-first profiles @Query (sort createdAt) at all ~12 sites"
```

---

### Task 3: Onboarding flow — `welcome → identity`, entity cards, throwing `finish()`, latch-aware `shouldShow`

Replaces the 3-step (welcome → client → timer) flow with `welcome → identity`. The identity screen presents two descriptive selectable entity cards and a name field whose label comes from the Task-1 mapping. `finish()` becomes fetch-then-mutate with a throwing save and a retry alert; it creates **no** Client/Project/TimeEntry. `OnboardingFlags.shouldShow` drops the legacy `clientCount == 0` branch. This is a full rewrite of `OnboardingView.swift`; verify by build + the Task-7 UI test. Preserve the welcome tagline verbatim (`LaunchTaglineUITests`).

**Files:**
- Modify (full replace): `App/Sources/Features/Onboarding/OnboardingView.swift`

- [ ] **Step 1: Replace the entire file with the new implementation**

```swift
import SwiftUI
import SwiftData
import BillableCore

/// Two-screen first-launch flow: welcome → identity (choose how you bill + enter
/// your name). On finish it mutates the canonical `BusinessProfile` and stamps
/// `onboardingCompletedAt` — it creates NO Client/Project/TimeEntry. The user lands
/// on Today and is guided to first value there (spec §5/§7).
struct OnboardingView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onFinish: () -> Void

    @State private var step: Step = .welcome
    @State private var entityType: EntityType = .freelancer   // pre-select Freelancer (spec §5)
    @State private var name: String = ""
    @State private var showingSaveError = false
    @FocusState private var nameFocused: Bool

    enum Step { case welcome, identity }

    var body: some View {
        ZStack {
            backgroundGradient
                .ignoresSafeArea()
            VStack(spacing: 0) {
                // Content scrolls so the keyboard cannot occlude the name field on
                // small devices (SE); the CTA stays pinned in the safe area.
                ScrollView {
                    content
                        .padding(.horizontal, 24)
                        .frame(maxWidth: .infinity)
                }
                bottomBar
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            }
        }
        .preferredColorScheme(.dark)
        .alert("Couldn't save", isPresented: $showingSaveError) {
            Button("Try Again") { finish() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("We couldn't save your profile. Please try again.")
        }
    }

    // MARK: - Background

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [
                Color(red: 10/255, green: 18/255, blue: 36/255),
                Color(red: 28/255, green: 44/255, blue: 80/255),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:  welcomeScreen
        case .identity: identityScreen
        }
    }

    private var welcomeScreen: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 60)
            iconHero
                .frame(width: 140, height: 140)
            VStack(spacing: 10) {
                Text("Cadence")
                    .font(.system(size: 38, weight: .bold))
                    .foregroundStyle(.white)
                // PRESERVE VERBATIM — guarded by LaunchTaglineUITests.
                Text("Track hours.\nSend invoices.")
                    .font(.title3.weight(.medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.85))
                Text("Made for freelancers and small businesses.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
            Spacer(minLength: 40)
        }
    }

    private var identityScreen: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer().frame(height: 12)
            VStack(alignment: .leading, spacing: 6) {
                Text("How do you bill?")
                    .font(.title.weight(.bold))
                    .foregroundStyle(.white)
                Text("This sets up your invoice labels. You can change it later in Settings.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.7))
            }

            VStack(spacing: 12) {
                ForEach(EntityType.allCases, id: \.self) { type in
                    entityCard(type)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                fieldLabel(entityType.issuerNameLabel.uppercased())
                TextField(
                    "",
                    text: $name,
                    prompt: Text(entityType.issuerNamePrompt).foregroundStyle(.white.opacity(0.55))
                )
                .focused($nameFocused)
                .textContentType(entityType.nameContentType)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .onSubmit { if primaryEnabled { finish() } }
                .padding(14)
                .background(.white.opacity(0.08), in: .rect(cornerRadius: 12))
                .foregroundStyle(.white)
            }
            Spacer(minLength: 24)
        }
    }

    private func entityCard(_ type: EntityType) -> some View {
        let isSelected = entityType == type
        return Button {
            withAnimation(reduceMotion ? nil : .snappy) { entityType = type }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: type.cardSystemImage)
                    .font(.title2)
                    .frame(width: 32)
                    .foregroundStyle(isSelected ? Color.orange : .white.opacity(0.7))
                VStack(alignment: .leading, spacing: 3) {
                    Text(type.cardTitle)
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(type.cardSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                // Selected state = border + fill + checkmark (NOT color-alone; spec §5/§9).
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.orange : .white.opacity(0.3))
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(
                (isSelected ? Color.orange.opacity(0.12) : Color.white.opacity(0.06)),
                in: .rect(cornerRadius: 14)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? Color.orange : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(type.cardTitle). \(type.cardSubtitle)")
        .accessibilityHint(isSelected ? "Selected" : "Double-tap to choose")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var iconHero: some View {
        ZStack {
            Circle()
                .stroke(
                    LinearGradient(
                        colors: [Color(red: 1, green: 0.68, blue: 0.25),
                                 Color(red: 1, green: 0.47, blue: 0.24)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    style: StrokeStyle(lineWidth: 12, lineCap: .round)
                )
                .padding(8)
                .rotationEffect(.degrees(-30))
            Circle()
                .fill(Color(red: 1, green: 0.94, blue: 0.82))
                .frame(width: 18, height: 18)
                .offset(x: 50, y: 22)
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .tracking(1)
            .foregroundStyle(.white.opacity(0.55))
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        Button {
            advance()
        } label: {
            Text(primaryLabel)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    Capsule().fill(
                        LinearGradient(
                            colors: [Color(red: 1, green: 0.68, blue: 0.25),
                                     Color(red: 1, green: 0.47, blue: 0.24)],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                )
                .foregroundStyle(.black.opacity(0.85))
        }
        .disabled(!primaryEnabled)
        .opacity(primaryEnabled ? 1 : 0.4)
    }

    private var primaryLabel: String {
        switch step {
        case .welcome:  "Get started"
        case .identity: "Finish setup"
        }
    }

    private var primaryEnabled: Bool {
        switch step {
        case .welcome:  return true
        case .identity: return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    // MARK: - Behavior

    private func advance() {
        switch step {
        case .welcome:
            withAnimation(reduceMotion ? nil : .snappy) { step = .identity }
            // Do NOT auto-focus on appear — that would hide the cards behind the
            // keyboard. Focus only after the user has reached the identity step.
        case .identity:
            finish()
        }
    }

    /// Crash-safe, throwing save (spec §5). Fetch-then-mutate the canonical profile;
    /// insert a fresh one ONLY if none exists. Set the one-way latch only AFTER the
    /// user fields save successfully. Creates no Client/Project/TimeEntry.
    private func finish() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let profile = BusinessProfileStore.canonical(in: modelContext)
            ?? {
                let fresh = BusinessProfile.defaultForCurrentLocale()
                modelContext.insert(fresh)
                return fresh
            }()

        profile.name = trimmed
        profile.entityType = entityType
        profile.updatedAt = .now

        do {
            try modelContext.save()
        } catch {
            // Surface a retry instead of silently dropping the user's input.
            showingSaveError = true
            return
        }

        // Latch only after a confirmed save; a best-effort second save persists it.
        profile.onboardingCompletedAt = .now
        try? modelContext.save()
        UserDefaults.standard.set(true, forKey: OnboardingFlags.completedKey)
        onFinish()
    }
}

enum OnboardingFlags {
    static let completedKey = "cadence.onboarding.completed"

    /// Onboarding is done when ANY profile has `onboardingCompletedAt` set (the
    /// CloudKit-synced source of truth) OR the local fast-path flag is set (covers
    /// the same device before a sync round-trip). The legacy `clientCount == 0`
    /// branch is DELETED: the new flow no longer seeds a client, so it would
    /// falsely re-trigger onboarding for a finished user who has no clients yet
    /// (spec §5).
    static func shouldShow(in context: ModelContext) -> Bool {
        if UserDefaults.standard.bool(forKey: completedKey) { return false }
        let completed = (try? context.fetchCount(
            FetchDescriptor<BusinessProfile>(
                predicate: #Predicate { $0.onboardingCompletedAt != nil }
            )
        )) ?? 0
        return completed == 0
    }
}
```

> **Verify-before-coding:** `#Predicate { $0.onboardingCompletedAt != nil }` over an optional `Date?` is expressible in SwiftData. If the toolchain rejects it (rare optional-keypath quirk), fall back to:
> ```swift
> let any = BusinessProfileStore.allSorted(in: context).contains { $0.onboardingCompletedAt != nil }
> return !any
> ```
> which uses the shipped Plan-1 helper and is equivalent.

- [ ] **Step 2: Verify the build**

Run:
```
xcodebuild -project Billable.xcodeproj -scheme Billable -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Re-run the tagline regression (must still pass after the rewrite)**

Run:
```
xcodebuild -project Billable.xcodeproj -scheme Billable -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:BillableUITests/LaunchTaglineUITests test
```
Expected: `** TEST SUCCEEDED **` — `test_launchScreen_showsTrackHoursAndSendInvoicesTagline` and `test_launchScreen_doesNotShowGetPaid` both pass. (The welcome screen still renders `Text("Track hours.\nSend invoices.")` and `--ui-test-show-onboarding` still force-shows it.)

- [ ] **Step 4: Commit**

```bash
git add "App/Sources/Features/Onboarding/OnboardingView.swift"
git commit -m "feat(onboarding): welcome→identity flow, entity cards, throwing finish(), latch-aware shouldShow"
```

---

### Task 4: §8 call-site wrapper — `BusinessProfileMaintenance` with the stable-count delete guard

Spec §8 mandates the delete-safety guard "AT THE CALL SITE": the shipped `BusinessProfileStore.reconcile` deletes duplicates whenever it runs, so the wrapper must decide *whether* to call it — only when the duplicate count is **stable across two consecutive observations** (so we never hard-delete mid-CloudKit-sync, when a transient duplicate count could still be settling). The wrapper also runs `stampFirstSetupIfReached` every time (idempotent, one-way, cheap). This is App-target glue; verify by build + the Task-7 UI test (which exercises the launch path).

**Files:**
- Create: `App/Sources/Maintenance/BusinessProfileMaintenance.swift`

- [ ] **Step 1: Write the complete implementation**

```swift
import Foundation
import SwiftData
import BillableCore

/// App-side call-site wrapper for the Plan-1 `BusinessProfileStore` repairs.
///
/// Spec §8 requires the duplicate-delete to fire ONLY when the duplicate count is
/// stable across two consecutive observations — never mid-CloudKit-sync, when the
/// count could still be converging and a delete might race an inbound record. The
/// shipped `BusinessProfileStore.reconcile` deletes unconditionally, so this wrapper
/// owns the "stable across two checks" decision: it remembers the last observed
/// profile count and only calls `reconcile` when the current count is > 1 AND equals
/// the previous observation. `stampFirstSetupIfReached` is always safe to run
/// (idempotent + one-way), so it runs every pass.
///
/// `@MainActor` and stateless except for one in-memory observation counter, mirroring
/// `TimerService.reconcileActiveSessionOnLaunch`'s wiring. Call from
/// `BillableApp.performStartupWiring()` and `RootView`'s `scenePhase == .active` seam.
@MainActor
enum BusinessProfileMaintenance {
    /// Last observed BusinessProfile count. nil = never observed (first launch).
    /// Process-lifetime memory (not persisted): two foreground passes within a
    /// session are exactly the "two consecutive checks" the guard needs, and a
    /// fresh launch SHOULD re-observe before deleting.
    private static var lastObservedCount: Int?

    /// One maintenance pass. Always stamps first-setup; reconciles duplicates only
    /// when their count is stable across this and the previous pass.
    static func run(in context: ModelContext) {
        // First-setup latch: idempotent + one-way, always safe.
        BusinessProfileStore.stampFirstSetupIfReached(in: context)

        let count = (try? context.fetchCount(FetchDescriptor<BusinessProfile>())) ?? 0
        defer { lastObservedCount = count }

        // Need duplicates AND a prior observation that agrees: stable across two checks.
        guard count > 1, lastObservedCount == count else { return }

        BusinessProfileStore.reconcile(in: context)
    }

    #if DEBUG
    /// Test/preview hook so a fresh-launch observation starts clean.
    static func resetObservationForTesting() { lastObservedCount = nil }
    #endif
}
```

> **Design note for the reviewer:** the guard is intentionally conservative — on a device that just received a duplicate via CloudKit, the *first* foreground records the count and skips the delete; the *second* foreground (or the next launch) finds the same count and reconciles. Convergence is "next foreground," matching the spec's "converges at next foreground" language for the reconcile seam. If a legitimate second profile arrives between the two checks, the counts differ and we correctly wait another cycle rather than deleting prematurely.

- [ ] **Step 2: Verify the build**

Run:
```
xcodebuild -project Billable.xcodeproj -scheme Billable -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`. (Not wired into a call site yet — Task 5 does that; this proves the wrapper compiles against the shipped store API.)

- [ ] **Step 3: Commit**

```bash
git add "App/Sources/Maintenance/BusinessProfileMaintenance.swift"
git commit -m "feat(app): BusinessProfileMaintenance — call-site stable-count delete guard for §8 reconcile"
```

---

### Task 5: Wire maintenance + onboarding re-evaluation into `BillableApp` and `RootView`

`performStartupWiring()` runs `BusinessProfileMaintenance.run` next to the existing `TimerService.reconcileActiveSessionOnLaunch`. `RootView`'s existing `scenePhase == .active` block runs `BusinessProfileMaintenance.run` again (so duplicates that arrive via CloudKit converge at the next foreground) and re-evaluates `OnboardingFlags.shouldShow` (so a cross-device completion dismisses onboarding without a relaunch). Also: honor `--reset-store` in the production container branch so the Task-7 onboarding UI test gets a clean slate (today `--reset-store` only fires under `--seed-marketing`). App-target glue → verify by build + Task-7 UI test.

**Files:**
- Modify: `App/Sources/App/BillableApp.swift`
- Modify: `App/Sources/App/RootView.swift`

- [ ] **Step 1: `BillableApp` — run maintenance on launch**

In `performStartupWiring()`, immediately after the existing line:
```swift
        try? TimerService.reconcileActiveSessionOnLaunch(in: container.mainContext)
```
add:
```swift
        // Profile singleton upkeep: stamp first-setup + converge duplicate profiles
        // (the stable-count delete guard lives in BusinessProfileMaintenance). Same
        // launch seam as the timer-session repair above.
        BusinessProfileMaintenance.run(in: container.mainContext)
```

- [ ] **Step 2: `BillableApp` — honor `--reset-store` in the production branch (test slate)**

In `init()`, the production `else` branch currently reads:
```swift
            } else {
                // Production: try CloudKit + App Group; gracefully degrades to
                // App-Group-only when CloudKit entitlements aren't active.
                self.container = try BillableModelContainer.appGroup(
                    "group.com.eldenstudios.billable",
                    cloudKitContainerID: BillableModelContainer.defaultCloudKitContainerID
                )
            }
```
Replace it with:
```swift
            } else {
                // UI-test support: `--reset-store` wipes the App Group store files so
                // a from-empty onboarding run is deterministic across dirty simulators.
                // Test-only flag; scoped to the Billable.store files in the group.
                if CommandLine.arguments.contains("--reset-store") {
                    Self.resetAppGroupStore("group.com.eldenstudios.billable")
                }
                // Production: try CloudKit + App Group; gracefully degrades to
                // App-Group-only when CloudKit entitlements aren't active.
                self.container = try BillableModelContainer.appGroup(
                    "group.com.eldenstudios.billable",
                    cloudKitContainerID: BillableModelContainer.defaultCloudKitContainerID
                )
            }
```

> `resetAppGroupStore(_:)` already exists in `BillableApp` (used by the `--seed-marketing` branch) — this only adds a second caller. No new code beyond the two-line guard.

- [ ] **Step 3: `RootView` — re-evaluate onboarding + run maintenance on foreground**

Replace the existing `scenePhase` handler:
```swift
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else { return }
                Task {
                    let scheduler = Scheduler(
                        center: UNUserNotificationCenter.current(),
                        modelContext: modelContext
                    )
                    _ = await scheduler.resyncOnLaunch()
                    let count = BadgeCount.compute(context: modelContext)
                    try? await UNUserNotificationCenter.current().setBadgeCount(count)
                }
            }
```
with:
```swift
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else { return }
                // Profile upkeep + onboarding re-eval on the SAME foreground seam as
                // badge/notification resync. Re-evaluating shouldShow here means a
                // completion synced from another device dismisses onboarding without a
                // relaunch. The --ui-test-show-onboarding force-show is preserved so
                // tagline/onboarding UI tests stay deterministic.
                BusinessProfileMaintenance.run(in: modelContext)
                if !CommandLine.arguments.contains("--ui-test-show-onboarding") {
                    needsOnboarding = OnboardingFlags.shouldShow(in: modelContext)
                }
                Task {
                    let scheduler = Scheduler(
                        center: UNUserNotificationCenter.current(),
                        modelContext: modelContext
                    )
                    _ = await scheduler.resyncOnLaunch()
                    let count = BadgeCount.compute(context: modelContext)
                    try? await UNUserNotificationCenter.current().setBadgeCount(count)
                }
            }
```

> `BusinessProfileMaintenance.run` is `@MainActor`; this closure already runs on the main actor (it's a SwiftUI `.onChange`), so the call is synchronous and correctly isolated — do **not** wrap it in the `Task`.

- [ ] **Step 4: Verify the build**

Run:
```
xcodebuild -project Billable.xcodeproj -scheme Billable -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add "App/Sources/App/BillableApp.swift" "App/Sources/App/RootView.swift"
git commit -m "feat(app): wire BusinessProfileMaintenance + onboarding re-eval into launch + scenePhase seams"
```

---

### Task 6: Business Profile editor — entity Picker, mapped labels, freelancer DisclosureGroup, hardened fields, blank-name reject, "Incomplete"

Spec §6: a segmented entity `Picker` at the top of Issuer; the name + tax-ID labels come from the Task-1 mapping; the freelancer tax section collapses into a `DisclosureGroup` "Add tax (if you charge it)" that auto-expands when a non-zero rate already exists (organization stays expanded); IBAN/SWIFT/tax-ID fields are hardened with `.keyboardType(.asciiCapable)` + `.textContentType(nil)`; the editor rejects a **blank** name on save; and `!isProfileEnriched` renders an "Incomplete" `Text`. App-target view → verify by build; UI labels are asserted by the Task-7 UI test.

**Files:**
- Modify: `App/Sources/Features/Settings/BusinessProfileEditorView.swift`
- Modify: `App/Sources/Features/Settings/SettingsView.swift` (surface "Incomplete" on the row)

- [ ] **Step 1: Add the entity-type `@State` and a save-error alert flag**

After the existing `@State private var hasLoaded = false` declaration, add:
```swift
    @State private var entityType: EntityType = .freelancer
    @State private var taxExpanded = false
    @State private var showingBlankNameError = false
```

- [ ] **Step 2: Replace the `Issuer` section's name field + add the entity Picker**

Change the `Section("Issuer")` block. Replace:
```swift
            Section("Issuer") {
                TextField("Business name", text: $name)
                    .textInputAutocapitalization(.words)
```
with:
```swift
            Section {
                Picker("I bill as", selection: $entityType) {
                    ForEach(EntityType.allCases, id: \.self) { type in
                        Text(type.cardTitle).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                TextField(entityType.issuerNameLabel, text: $name)
                    .textInputAutocapitalization(.words)
                    .textContentType(entityType.nameContentType)
```
and change the **closing** of that section so it gains a footer. The section currently ends:
```swift
                TextField("Address", text: $address, axis: .vertical)
                    .lineLimit(2...4)
            }
```
Replace with:
```swift
                TextField("Address", text: $address, axis: .vertical)
                    .lineLimit(2...4)
            } header: {
                Text("Issuer")
            } footer: {
                Text("Freelancer bills under your own name; Organization bills under a company name. This only changes invoice labels.")
            }
```

- [ ] **Step 3: Wrap the freelancer tax fields in an auto-expanding `DisclosureGroup`**

Replace the entire current `Tax` section:
```swift
            Section {
                TextField("Tax label (Tax, VAT, GST, …)", text: $taxLabel)
                HStack {
                    Text("Rate")
                    Spacer()
                    TextField("0", value: $taxRatePercent, format: .number.precision(.fractionLength(0...3)))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 100)
                    Text("%")
                        .foregroundStyle(.secondary)
                }
                TextField("Tax ID label (VAT, CR, EIN, …)", text: $taxIDLabel)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                TextField("Tax ID / VAT number", text: $taxIDNumber)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
            } header: {
                Text("Tax")
            } footer: {
                Text("Tax label appears next to the rate on invoice totals. Tax ID label appears with your registration number in the issuer header — leave both blank to hide.")
            }
```
with:
```swift
            Section {
                if entityType == .organization {
                    taxFields
                } else {
                    DisclosureGroup("Add tax (if you charge it)", isExpanded: $taxExpanded) {
                        taxFields
                    }
                }
            } header: {
                Text("Tax")
            } footer: {
                Text("Tax label appears next to the rate on invoice totals. Tax ID label appears with your registration number in the issuer header — leave both blank to hide.")
            }
```

- [ ] **Step 4: Add the extracted `taxFields` subview + harden the tax-ID fields**

Add this computed view to the struct (e.g. just above `private func loadIfNeeded()`):
```swift
    @ViewBuilder
    private var taxFields: some View {
        TextField("Tax label (Tax, VAT, GST, …)", text: $taxLabel)
        HStack {
            Text("Rate")
            Spacer()
            TextField("0", value: $taxRatePercent, format: .number.precision(.fractionLength(0...3)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 100)
            Text("%")
                .foregroundStyle(.secondary)
        }
        TextField(entityType.taxIDLabel, text: $taxIDLabel)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.characters)
        // Harden the registration-NUMBER field: identifiers must not feed
        // keyboard learning or AutoFill (spec §6). Not SecureField — the user
        // must be able to verify their own tax ID.
        TextField("Tax ID / VAT number", text: $taxIDNumber)
            .keyboardType(.asciiCapable)
            .textContentType(nil)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.characters)
    }
```

- [ ] **Step 5: Harden the IBAN + SWIFT fields**

In the `Bank details` section, replace:
```swift
                TextField("IBAN", text: $bankIBAN)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                TextField("SWIFT / BIC (optional)", text: $bankSWIFT)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
```
with:
```swift
                TextField("IBAN", text: $bankIBAN)
                    .keyboardType(.asciiCapable)
                    .textContentType(nil)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                TextField("SWIFT / BIC (optional)", text: $bankSWIFT)
                    .keyboardType(.asciiCapable)
                    .textContentType(nil)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
```

- [ ] **Step 6: Load + persist `entityType`; auto-expand tax; reject a blank name**

In `loadIfNeeded()`, after `name = profile.name`, add:
```swift
        entityType = profile.entityType
        // Auto-expand the freelancer tax section if a non-zero rate already exists
        // (spec §6) — otherwise a saved rate would be hidden behind a collapsed group.
        taxExpanded = (profile.taxRate as NSDecimalNumber).doubleValue != 0
```

In `save()`, replace the opening:
```swift
    private func save() {
        let profile = profiles.first ?? newProfile()
        profile.name = name
```
with:
```swift
    private func save() {
        // Reject a blank name (spec §5/§6): an empty issuer name produces
        // "Unnamed business" on the PDF and would falsely satisfy canSendInvoice.
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showingBlankNameError = true
            return
        }
        let profile = profiles.first ?? newProfile()
        profile.name = name
        profile.entityType = entityType
```

- [ ] **Step 7: Add the blank-name alert to the view body**

On the `Form { … }` modifier chain, after the existing `.onAppear { loadIfNeeded() }`, add:
```swift
        .alert("Add a name", isPresented: $showingBlankNameError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Enter your \(entityType == .freelancer ? "name" : "business name") so it can appear on invoices.")
        }
```

- [ ] **Step 8: Render "Incomplete" in the editor + on the Settings row**

In `BusinessProfileEditorView`, the `Bank details` section is the last section; immediately after it (still inside `Form`), add a status section:
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

In `SettingsView`, in the `Business profile` `NavigationLink` label, change the populated branch:
```swift
                        if let profile = profiles.first {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(profile.name.isEmpty ? "Unnamed business" : profile.name)
                                Text("\(profile.currencyCode) · Next \(profile.previewNextInvoiceNumber)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
```
to:
```swift
                        if let profile = profiles.first {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(profile.name.isEmpty ? "Unnamed business" : profile.name)
                                Text("\(profile.currencyCode) · Next \(profile.previewNextInvoiceNumber)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if !profile.isProfileEnriched {
                                    // Its own Text (not a "· "-glued fragment) so VoiceOver
                                    // reads a discrete status, not a run-on line (spec §6).
                                    Text("Incomplete")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                            }
                        } else {
```

- [ ] **Step 9: Verify the build**

Run:
```
xcodebuild -project Billable.xcodeproj -scheme Billable -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 10: Commit**

```bash
git add "App/Sources/Features/Settings/BusinessProfileEditorView.swift" \
        "App/Sources/Features/Settings/SettingsView.swift"
git commit -m "feat(settings): entity-aware profile editor — picker, mapped labels, freelancer tax disclosure, hardened ID fields, blank-name reject, Incomplete"
```

---

### Task 7: UI test — Freelancer vs Organization name-label + finish lands on Today with no auto-timer

Adds the one UI test that pays for itself: it drives the new onboarding screen, asserts the name field's label changes between Freelancer and Organization (proving the Task-1 mapping is wired into the identity screen), then finishes and asserts the app lands on **Today** with **no running timer** (proving `finish()` creates no TimeEntry — the core behavior change). Uses `--ui-test-show-onboarding` (force-shows onboarding, already bypasses the flag) + `--reset-store` (Task 5 made the production branch honor it) for a clean slate.

**Files:**
- Create: `App/BillableUITests/OnboardingEntityTypeUITests.swift`

- [ ] **Step 1: Add accessibility identifiers the test will anchor on**

In `OnboardingView.swift`'s `identityScreen`, the name `TextField` needs a stable identifier (its visible label changes, so the test queries by identifier and asserts the label). Add `.accessibilityIdentifier("onboarding.nameField")` to the name `TextField` (right after `.foregroundStyle(.white)`):
```swift
                .foregroundStyle(.white)
                .accessibilityIdentifier("onboarding.nameField")
```
The two entity cards are already reachable by their combined accessibility label (`"Freelancer. Just me …"` / `"Organization. A team …"`).

> Re-verify the editor/onboarding build after this one-line edit is bundled into Task 7's commit (Step 4 runs the build).

- [ ] **Step 2: Write the UI test**

```swift
import XCTest

/// Covers the redesigned onboarding identity screen (spec §5):
///  1. The name field's label tracks the selected entity type (Freelancer → "Your
///     name"; Organization → "Business name"), proving the shared
///     EntityType+Presentation mapping is wired in.
///  2. Finishing setup lands on Today WITHOUT starting a timer — the new finish()
///     creates no Client/Project/TimeEntry (the core behavior change vs. the old
///     "start your first timer" flow).
final class OnboardingEntityTypeUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--reset-store",               // wipe the App Group store → from-empty onboarding
            "--ui-test-show-onboarding",   // force-show onboarding regardless of latch state
        ]
        app.launch()
        return app
    }

    /// Advance welcome → identity by tapping the primary CTA.
    private func goToIdentity(_ app: XCUIApplication) {
        let getStarted = app.buttons["Get started"]
        XCTAssertTrue(getStarted.waitForExistence(timeout: 5), "Welcome CTA missing")
        getStarted.tap()
        XCTAssertTrue(
            app.staticTexts["How do you bill?"].waitForExistence(timeout: 3),
            "Identity screen did not appear"
        )
    }

    func test_nameFieldLabel_tracksEntityType() {
        let app = launchedApp()
        goToIdentity(app)

        let nameField = app.textFields["onboarding.nameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 3), "Name field missing")

        // Freelancer is pre-selected → label "Your name".
        XCTAssertEqual(
            nameField.label, "Your name",
            "Freelancer name field must be labelled 'Your name'"
        )

        // Switch to Organization → label flips to "Business name".
        app.buttons["Organization. A team — we bill under one company name."].tap()
        XCTAssertEqual(
            app.textFields["onboarding.nameField"].label, "Business name",
            "Organization name field must be labelled 'Business name'"
        )
    }

    func test_finish_landsOnToday_withNoRunningTimer() {
        let app = launchedApp()
        goToIdentity(app)

        let nameField = app.textFields["onboarding.nameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 3), "Name field missing")
        nameField.tap()
        nameField.typeText("Jane Doe")

        app.buttons["Finish setup"].tap()

        // Lands on Today: the Today tab / navigation bar is present.
        XCTAssertTrue(
            app.navigationBars["Today"].waitForExistence(timeout: 5),
            "Finishing setup must land on the Today screen"
        )

        // No auto-timer: the running-timer affordance (a "Running" labelled control
        // in Jump-back-in) must NOT exist, because finish() creates no TimeEntry.
        XCTAssertFalse(
            app.buttons["Running"].exists,
            "Finishing setup must NOT start a timer (no 'Running' control on Today)"
        )
    }
}
```

> **Anchor verification:** `app.navigationBars["Today"]` matches `TodayView`'s `.navigationTitle("Today")`. The "Running" control is the `JumpBackInSection` play button whose `.accessibilityLabel` becomes `"Running"` only while a timer runs; on a from-empty store with no entries there are no recents at all, so the absence assertion is robust. If `nameField.label` returns the placeholder instead of the field label on this OS, switch the assertion to read the adjacent `staticTexts["YOUR NAME"]` / `staticTexts["BUSINESS NAME"]` caps label (which is rendered by `fieldLabel(...)`); confirm which the runtime exposes during the first run and keep the assertion that matches.

- [ ] **Step 3: Run the new UI test**

Run:
```
xcodebuild -project Billable.xcodeproj -scheme Billable -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:BillableUITests/OnboardingEntityTypeUITests test
```
Expected: `** TEST SUCCEEDED **` — both `test_nameFieldLabel_tracksEntityType` and `test_finish_landsOnToday_withNoRunningTimer` pass.

- [ ] **Step 4: Verify the full build still succeeds (picks up the Step-1 identifier)**

Run:
```
xcodebuild -project Billable.xcodeproj -scheme Billable -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add "App/BillableUITests/OnboardingEntityTypeUITests.swift" \
        "App/Sources/Features/Onboarding/OnboardingView.swift"
git commit -m "test(ui): onboarding entity-label tracking + finish lands on Today with no auto-timer"
```

---

### Task 8: Full UI-test regression gate + manual simulator verification

Confirms no onboarding-driving test regressed (the old flow seeded a client; `InvoicePreviewLineItemEditUITests` relies on `--seed-marketing` seeding a client, which still skips onboarding because that path does not force-show it — verify, don't assume), then names the on-device checks that prose cannot prove.

- [ ] **Step 1: Run the full UI suite**

Run:
```
xcodebuild -project Billable.xcodeproj -scheme Billable -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:BillableUITests test
```
Expected: `** TEST SUCCEEDED **` — `LaunchTaglineUITests`, `SettingsAboutUITests`, `NotificationTapFlowUITests`, `InvoicePreviewLineItemEditUITests`, and the new `OnboardingEntityTypeUITests` all pass.

> If `InvoicePreviewLineItemEditUITests` now fails by stalling on onboarding: that path launches WITHOUT `--ui-test-show-onboarding` and seeds a client via `--seed-marketing`, but the new `shouldShow` no longer keys off `clientCount`. Because the seed run never sets `onboardingCompletedAt`, `shouldShow` could return `true` on a clean store. Fix by adding `"--ui-test-show-onboarding"`'s sibling skip: in that test's `launchArguments`, the existing `"--ui-test-skip-onboarding"` flag is currently a no-op — wire it in `RootView.onAppear` to set `needsOnboarding = false` when present. Add to `RootView.onAppear`, as the first branch:
> ```swift
>                 if CommandLine.arguments.contains("--ui-test-skip-onboarding") {
>                     needsOnboarding = false
>                 } else if CommandLine.arguments.contains("--ui-test-show-onboarding") {
>                     needsOnboarding = true
>                 } else {
>                     needsOnboarding = OnboardingFlags.shouldShow(in: modelContext)
>                 }
> ```
> and mirror the skip-guard in the `scenePhase` re-eval from Task 5 (skip re-eval when `--ui-test-skip-onboarding` is present too). Re-run the suite; commit with message `fix(app): honor --ui-test-skip-onboarding so seeded UI tests bypass the redesigned onboarding`. (Only do this if the suite actually fails — it may already pass if the seeded store was created by a prior finished run.)

- [ ] **Step 2: Run the BillableCore suite (no regressions from Plan 1)**

Run:
```
cd Packages/BillableCore && swift test
```
Expected: PASS — all Plan-1 tests still green (this plan added no Core code, but the gate confirms nothing drifted).

- [ ] **Step 3: Manual simulator verification (named, not automated)**

These cannot be unit-asserted; perform each on a booted simulator (`xcrun simctl boot 'iPhone 17 Pro'` then run the app via Xcode, or `--ui-test-show-onboarding --reset-store`):

1. **Keyboard occlusion on a small device:** boot **iPhone SE (3rd generation)**, reach the identity step, tap the name field. Confirm the field and the **Finish setup** CTA remain visible above the keyboard (the `ScrollView` + safe-area CTA must prevent occlusion). The cards may scroll off — that is acceptable; the active field must not be hidden.
2. **Contrast (measured):** confirm the name-field prompt at `white.opacity(0.55)` reads at ≥ 3:1 against the gradient (spec's WCAG fix; 0.3 failed). Spot-check the selected entity card's orange border/checkmark against the dark fill.
3. **Selected-state is not color-alone:** with **Settings → Accessibility → Display & Text Size → Differentiate Without Color** on, confirm the selected card is still distinguishable via the checkmark + border + fill (not hue only).
4. **Reduced motion:** with **Reduce Motion** on, confirm the welcome→identity transition and the card-selection change do not animate (the code gates `withAnimation` on `accessibilityReduceMotion`).
5. **Light/dark editor:** open **Settings → Business profile** in both appearances; confirm the segmented entity `Picker`, the freelancer **Add tax (if you charge it)** disclosure (collapsed when rate is 0, auto-expanded when a non-zero rate exists), and the **Incomplete** row render correctly. Toggle the picker Freelancer↔Organization and confirm the name label + tax-ID label update live.
6. **No auto-timer end-to-end:** finish onboarding as Freelancer; confirm you land on Today with the get-started guidance (owned by a later plan) and **no** running timer.

- [ ] **Step 4: Final consistency check + stop**

Confirm `git status` shows only the files this plan touched and the working tree is clean after the per-task commits. Plan 2 is complete: shared label mapping, redesigned onboarding with a crash-safe `finish()`, latch-aware `shouldShow`, §8 call-site wiring with the stable-count delete guard, deterministic profile reads, and an entity-aware hardened editor are all in place and build/UI-test verified. The controller does the cross-plan consistency review and any release-gate work (§13: `PrivacyInfo.xcprivacy`, Data-Protection entitlement, CloudKit reinstall smoke test) tracked separately.

---

## Self-review notes (author)

- **Spec coverage (Plan 2 scope):** §5 onboarding flow + throwing `finish()` + `shouldShow` rewrite (Task 3); §6 editor (Task 6) + shared mapping (Task 1); §8 CALL-SITE wiring — deterministic `sort` at all ~12 sites (Task 2), `reconcile` + `stampFirstSetupIfReached` wired into `performStartupWiring` + `scenePhase==.active` with the "stable across two checks" delete guard at the call site (Tasks 4–5); §9 a11y + §16 UI assertions (Task 7) + manual checks (Task 8). **Out of Plan-2 scope (later plans):** §7/§7a/§7b Today guidance + enrichment UI, §12 dev credit (already `"Elden Studios Company"` in `SettingsView` + `SettingsAboutUITests` — verified, no edit), §13 release-gates, §14 Tier-1 readout.
- **Build-on-Plan-1 discipline:** no BillableCore file is edited; `BusinessProfileStore.reconcile` is **called through a guard wrapper**, never modified (the guard lives at the call site exactly as §8 directs).
- **Verify-before-coding flags for the implementer:** the `#Predicate { $0.onboardingCompletedAt != nil }` optional-keypath form (Task 3 fallback given); whether `XCUIElement.label` exposes the field label vs. the placeholder on the test OS (Task 7 fallback to the caps `staticTexts` label given); whether `InvoicePreviewLineItemEditUITests` needs the `--ui-test-skip-onboarding` wiring (Task 8 conditional — only if the suite fails); the exact line numbers of the 12 `@Query` sites (grep-confirm before editing).
- **DRY/YAGNI:** one `EntityType+Presentation` mapping feeds both screens; `taxFields` extracted once and reused in both the org-expanded and freelancer-disclosure branches; the delete guard is a single small wrapper, not duplicated at each call site.
- **Frequent commits:** eight tasks, each independently buildable and committed.
</content>
</invoke>
