# First-run UX (PR A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rework the Today first-run experience to be setup-first (client → project), close the "+" sheet dead-ends, decouple profile-completion guidance, and re-scope the Today summary tiles.

**Architecture:** SwiftUI + SwiftData. Most changes are view-layer in `App/Sources/Features/Today/*` + the two "+" sheets; one model-layer addition (`missingProfileFields`) in `BillableCore`. No schema changes. The single guidance-element resolver (`TodayGuidance.resolve`) and the block self-dismissal invariant are preserved.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, XCTest (BillableCore unit tests), XCUITest (`BillableUITests`), XcodeGen (`project.yml`).

**Source spec:** `docs/superpowers/specs/2026-06-02-cadence-ux-overhaul-design.md` (Sub-project A).

---

## Prerequisites (execution-time)

- [ ] **PR #25 (CloudKit crash fix) is merged to `main`.** PR A modifies `TodayView.swift` and `StartTimerSheet.swift`, which the crash fix also touches — branch off the **merged** fix to inherit it and avoid conflicts.
- [ ] Create a fresh worktree off updated `main`: `git worktree add .worktrees/firstrun-ux -b feature/firstrun-ux origin/main`
- [ ] Copy + commit the spec and this plan into the new worktree as the first commit, then `xcodegen generate`.
- [ ] Baseline build/tests green before starting: `xcodebuild test -scheme Billable -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:BillableCoreTests` (adjust sim name to one installed).

## File structure (what changes & why)

- `Packages/BillableCore/Sources/BillableCore/Models/BusinessProfile.swift` — **add** `ProfileField` enum + `missingProfileFields` computed property. `isProfileEnriched` is **untouched**.
- `Packages/BillableCore/Tests/BillableCoreTests/BusinessProfileCompletenessTests.swift` — **new** unit tests for `missingProfileFields`.
- `App/Sources/Features/Settings/SettingsView.swift` — Business-profile row: replace bare "Incomplete" with a named-missing-fields indicator driven by `missingProfileFields`.
- `App/Sources/Features/Today/TodayView.swift` — `enrichmentNudge` copy broadened (bank/logo); `TodaySummarySection` restructured (Today = Hours/Earnings; separate "Ready to invoice" card hidden at $0; drop in-tile "· ALL PROJECTS" caption).
- `App/Sources/Features/Today/GetStartedSection.swift` — rebuilt: setup-first (Add client → Create project); remove quick-start button, `fetchOrCreateGeneralProject`, `GeneralRateSheet`, 0-rate row.
- `App/Sources/Features/Timer/StartTimerSheet.swift` — add zero-project empty state (CTA branches on client count).
- `App/Sources/Features/Timer/ManualEntrySheet.swift` — add zero-project empty state (same pattern).
- `App/Sources/Features/Work/WorkView.swift` + `Packages/BillableCore/.../Persistence/BusinessProfileStore.swift` — comment-only updates (stale "General quick-start" rationale).
- `App/BillableUITests/GetStartedChecklistUITests.swift` — delete the quick-start test, keep the checklist test, add new setup-first tests.

> Each executing step should READ the current file before editing (line numbers in this plan are indicative — verify against the merged-main checkout).

---

## Task 1: `missingProfileFields` on BusinessProfile (model + tests)

**Files:**
- Modify: `Packages/BillableCore/Sources/BillableCore/Models/BusinessProfile.swift`
- Test: `Packages/BillableCore/Tests/BillableCoreTests/BusinessProfileCompletenessTests.swift` (create)

Context: `isProfileEnriched` is defined as `!name.isEmpty && !address.isEmpty` and must NOT change (three push-nudge sites depend on it; `BusinessProfileEntityTests` pins it). `hasBankDetails` and an optional `logoData` already exist on the model. We add a SEPARATE completeness breakdown that also covers bank + logo; tax is excluded.

- [ ] **Step 1: Write the failing test**

Create `Packages/BillableCore/Tests/BillableCoreTests/BusinessProfileCompletenessTests.swift`:

```swift
import XCTest
@testable import BillableCore

final class BusinessProfileCompletenessTests: XCTestCase {
    func test_emptyProfile_missesNameAddressBankLogo() {
        let p = BusinessProfile(name: "")
        XCTAssertEqual(Set(p.missingProfileFields), [.name, .address, .bankDetails, .logo])
    }

    func test_nameAndAddressOnly_stillMissesBankAndLogo() {
        let p = BusinessProfile(name: "Acme")
        p.address = "1 Main St"
        XCTAssertEqual(Set(p.missingProfileFields), [.bankDetails, .logo])
    }

    func test_fullyComplete_missesNothing() {
        let p = BusinessProfile(name: "Acme")
        p.address = "1 Main St"
        p.bankIBAN = "DE00 0000"      // any one bank field → hasBankDetails true
        p.logoData = Data([0x1])
        XCTAssertTrue(p.missingProfileFields.isEmpty)
    }

    func test_taxIsExcludedFromCompleteness() {
        let p = BusinessProfile(name: "Acme")
        p.address = "1 Main St"
        p.bankIBAN = "DE00"
        p.logoData = Data([0x1])
        // taxRate left at default; profile is still "complete"
        XCTAssertTrue(p.missingProfileFields.isEmpty)
    }

    func test_isProfileEnriched_unchanged_nameAddressOnly() {
        let p = BusinessProfile(name: "Acme")
        p.address = "1 Main St"
        XCTAssertTrue(p.isProfileEnriched)   // bank/logo NOT required by enriched
    }
}
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `xcodebuild test -scheme Billable -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:BillableCoreTests/BusinessProfileCompletenessTests`
Expected: FAIL — `value of type 'BusinessProfile' has no member 'missingProfileFields'`.

- [ ] **Step 3: Implement the property**

In `BusinessProfile.swift`, near `isProfileEnriched`, add (verify `hasBankDetails`'s exact definition and reuse it):

```swift
/// Invoice-relevant fields a complete profile should have. Tax is intentionally excluded.
/// This is the SETTINGS completeness indicator's source — it is NOT `isProfileEnriched`
/// (which stays name+address and gates the push nudges).
public enum ProfileField: String, CaseIterable, Sendable {
    case name, address, bankDetails, logo
    public var label: String {
        switch self {
        case .name: return "name"
        case .address: return "address"
        case .bankDetails: return "bank details"
        case .logo: return "logo"
        }
    }
}

public var missingProfileFields: [ProfileField] {
    var missing: [ProfileField] = []
    if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { missing.append(.name) }
    if address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { missing.append(.address) }
    if !hasBankDetails { missing.append(.bankDetails) }
    if logoData == nil { missing.append(.logo) }
    return missing
}
```

> If `hasBankDetails` is not already a property, define `missingProfileFields` using the same bank-field check used elsewhere (grep `hasBankDetails`). Do not change `isProfileEnriched`.

- [ ] **Step 4: Run the test, verify it passes**

Run: the same command as Step 2. Expected: PASS (5 tests). Also run the full `BillableCoreTests` to confirm `BusinessProfileEntityTests` still passes (no enriched regression).

- [ ] **Step 5: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Models/BusinessProfile.swift Packages/BillableCore/Tests/BillableCoreTests/BusinessProfileCompletenessTests.swift
git commit -m "feat(profile): add missingProfileFields completeness breakdown (separate from isProfileEnriched)"
```

---

## Task 2: Settings — named completeness indicator

**Files:**
- Modify: `App/Sources/Features/Settings/SettingsView.swift` (the Business-profile row, ~line 43)

Context: today the row shows a bare orange "Incomplete" when `!isProfileEnriched`. Replace with a named list driven by `missingProfileFields`; show a "Complete" affordance when empty.

- [ ] **Step 1: Read the current Business-profile row** and identify the `Text("Incomplete")`/status view + how the row accesses the canonical `BusinessProfile`.

- [ ] **Step 2: Implement the indicator.** Replace the status subview with:

```swift
// `profile` = the canonical BusinessProfile in scope (same accessor the row already uses).
if profile.missingProfileFields.isEmpty {
    Label("Complete", systemImage: "checkmark.circle.fill")
        .font(.caption).foregroundStyle(.green)
} else {
    let names = profile.missingProfileFields.map(\.label)
        .formatted(.list(type: .and, width: .short))
    Text("Add \(names)")
        .font(.caption).foregroundStyle(.orange)
        .lineLimit(1).truncationMode(.tail)
}
```

> The row still navigates to `BusinessProfileEditorView`. Do not gate on `isProfileEnriched` here anymore — use `missingProfileFields`.

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild build -scheme Billable -destination 'platform=iOS Simulator,name=iPhone 16'`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Verify visually** (sim): a profile with name only → "Add address, bank details, and logo"; a fully-filled profile → "Complete".

- [ ] **Step 5: Commit**

```bash
git add App/Sources/Features/Settings/SettingsView.swift
git commit -m "feat(settings): name the missing profile fields instead of a bare 'Incomplete'"
```

---

## Task 3: Today enrichment nudge — broaden copy

**Files:**
- Modify: `App/Sources/Features/Today/TodayView.swift` (`enrichmentNudge`, ~lines 176-209)

Context: copy-only. The nudge still fires on the SAME trigger (`!isProfileEnriched`, i.e., missing address) — do not change the trigger or `TodayGuidance` precedence. Only broaden the message.

- [ ] **Step 1: Change the nudge copy.** Replace the title/subtitle strings:

```swift
Text("Finish your invoice details")
Text("Add your address, bank details, and logo so invoices look professional.")
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild build -scheme Billable -destination 'platform=iOS Simulator,name=iPhone 16'`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add App/Sources/Features/Today/TodayView.swift
git commit -m "copy(today): broaden enrichment nudge to mention bank details + logo"
```

---

## Task 4: Get-started block → setup-first; remove quick-start + General

**Files:**
- Modify/rewrite: `App/Sources/Features/Today/GetStartedSection.swift`

Context (verified): `GetStartedSection` currently has a PRIMARY "Start a timer now" (`quickStartButton`), the 0-rate `setRateRow`, the 2-row checklist, `startQuickTimer()`, `fetchOrCreateGeneralProject()`, and a private `GeneralRateSheet`. We make the checklist the lead and remove the timer/General pieces. `GetStartedNewProjectSheet` (client-pick → ProjectEditorView) is REUSED for "Create a project".

- [ ] **Step 1: Rebuild the `body`** so the block leads with the two-step setup as the primary action, no timer:

```swift
var body: some View {
    VStack(alignment: .leading, spacing: 12) {
        header                                  // "Set up to get paid" / subtitle (see Step 2)
        VStack(spacing: 0) {
            checklistRow(title: "Add your first client",
                         isDone: hasClient, isEnabled: true, hint: nil) {
                showingAddClient = true
            }
            Divider().padding(.leading, 44)
            checklistRow(title: "Create a project",
                         isDone: hasLinkedProject, isEnabled: hasClient,
                         hint: hasClient ? nil : "Add a client first") {
                showingNewProject = true
            }
        }
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 14))
    }
    .padding(16)
    .background(.thinMaterial, in: .rect(cornerRadius: 18))
    .sheet(isPresented: $showingAddClient) { NavigationStack { ClientEditorView(client: nil) } }
    .sheet(isPresented: $showingNewProject) { GetStartedNewProjectSheet() }
}
```

- [ ] **Step 2: Update `header` copy** to a setup framing (no "Timer running" reframe):

```swift
private var header: some View {
    VStack(alignment: .leading, spacing: 2) {
        Text("Set up to get paid").font(.headline)
        Text("Add a client and a project so the time you track can become an invoice.")
            .font(.subheadline).foregroundStyle(.secondary)
    }.frame(maxWidth: .infinity, alignment: .leading)
}
```

- [ ] **Step 3: Delete the removed members:** `quickStartButton`, `startQuickTimer()`, `fetchOrCreateGeneralProject()`, `setRateRow(...)`, the `GeneralRateSheet` struct, and the now-unused `@State` (`startingQuickTimer`, `rateTargetProject`, `runningEntries` query if only used by the removed 0-rate row — verify each is unused before deleting). Keep `hasClient`, `hasLinkedProject`, `linkedProjectProbe`, `checklistRow`, `GetStartedNewProjectSheet`, and the `showingAddClient`/`showingNewProject` state.

- [ ] **Step 4: Build to verify it compiles**

Run: `xcodebuild build -scheme Billable -destination 'platform=iOS Simulator,name=iPhone 16'`
Expected: BUILD SUCCEEDED (fix any references to deleted members).

- [ ] **Step 5: Verify on simulator** (fresh state via `--reset-store`): empty Today shows "Set up to get paid" with "Add your first client" enabled and "Create a project" disabled; NO "Start a timer now". Adding a client enables "Create a project".

- [ ] **Step 6: Commit**

```bash
git add App/Sources/Features/Today/GetStartedSection.swift
git commit -m "feat(today): setup-first get-started block; remove quick-start + clientless General"
```

---

## Task 5: Retire-General downstream comments + UI tests

**Files:**
- Modify: `App/BillableUITests/GetStartedChecklistUITests.swift`
- Modify (comments only): `App/Sources/Features/Work/WorkView.swift`, `Packages/BillableCore/.../Persistence/BusinessProfileStore.swift`

Context: `ActivationMetrics.FirstTimerKind.quickStart` is KEPT (DEBUG-only metric, now legacy-only data) — do not delete it. Only comments + the obsolete UI test change.

- [ ] **Step 1: Delete the quick-start UI test.** Remove the test that taps `getStarted.quickStart`, asserts a "General" is created, and checks the "Timer running" reframe (the `test_quickStart_*` case). Keep the add-client/checklist test.

- [ ] **Step 2: Add the new setup-first UI tests:**

```swift
func test_firstRun_leadsWithAddClient_andNoTimerCTA() {
    let app = XCUIApplication()
    app.launchArguments += ["--reset-store"]
    app.launch()
    // onboarding → finish (reuse the existing helper if present), then:
    XCTAssertTrue(app.staticTexts["Add your first client"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["getStarted.quickStart"].exists)
}
```

> Reuse the existing onboarding-completion helper from the test target; if none, drive the two onboarding screens (pick entity, type a name, Finish setup).

- [ ] **Step 3: Fix stale comments.** In `WorkView.swift` (~106-107) remove the "load-bearing for the quickStart General project" phrasing (keep the no-client bucket — it still handles legacy data). In `BusinessProfileStore.swift` update the `stampFirstSetupIfReached` "General doesn't count" comment to note the quick-start path is removed (logic unchanged).

- [ ] **Step 4: Run the UI test**

Run: `xcodebuild test -scheme Billable -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:BillableUITests/GetStartedChecklistUITests`
Expected: PASS (old quick-start test gone; new test green).

- [ ] **Step 5: Commit**

```bash
git add App/BillableUITests/GetStartedChecklistUITests.swift App/Sources/Features/Work/WorkView.swift Packages/BillableCore/Sources/BillableCore/Persistence/BusinessProfileStore.swift
git commit -m "test+docs(today): replace quick-start UI test; de-stale General references"
```

---

## Task 6: StartTimerSheet — zero-project empty state

**Files:**
- Modify: `App/Sources/Features/Timer/StartTimerSheet.swift`

Context (verified): with no projects the sheet renders a bare `List`. Add an empty state whose CTA branches on client count. Read the file for its `@Query` of projects/clients and add a clients query if absent.

- [ ] **Step 1: Add the empty state.** When the projects list is empty, render instead of the `List`:

```swift
if projects.isEmpty {
    ContentUnavailableView {
        Label("No projects yet", systemImage: "folder.badge.plus")
    } description: {
        Text(clients.isEmpty
             ? "Add a client, then create a project to track time against."
             : "Create a project to track time against.")
    } actions: {
        Button(clients.isEmpty ? "Add a client" : "Create a project") {
            if clients.isEmpty { showingAddClient = true } else { showingNewProject = true }
        }
        .buttonStyle(.borderedProminent)
    }
    .sheet(isPresented: $showingAddClient) { NavigationStack { ClientEditorView(client: nil) } }
    .sheet(isPresented: $showingNewProject) { GetStartedNewProjectSheet() }
} else {
    // existing List(...) unchanged
}
```

> Add `@State private var showingAddClient = false`, `@State private var showingNewProject = false`, and a `@Query private var clients: [Client]` if not present. Reuse `GetStartedNewProjectSheet` (make it non-private/shared if needed, or mirror it).

- [ ] **Step 2: Build to verify it compiles** — `xcodebuild build -scheme Billable -destination 'platform=iOS Simulator,name=iPhone 16'`. Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Verify** (sim, `--reset-store`, no projects): "+" → Start timer shows the empty state + the correct CTA (Add a client when none exist).

- [ ] **Step 4: Commit**

```bash
git add App/Sources/Features/Timer/StartTimerSheet.swift
git commit -m "fix(timer): zero-project empty state with client-aware CTA in StartTimerSheet"
```

---

## Task 7: ManualEntrySheet — zero-project empty state

**Files:**
- Modify: `App/Sources/Features/Timer/ManualEntrySheet.swift`

Context (verified): `canSave` is permanently false with no project and the picker is empty. Apply the same empty-state pattern as Task 6.

- [ ] **Step 1: Add the empty state** (same `ContentUnavailableView` + client-aware CTA as Task 6, wrapping the form when `projects.isEmpty`). Reuse the same `showingAddClient`/`showingNewProject` state + `clients` query pattern.

- [ ] **Step 2: Build** — `xcodebuild build -scheme Billable -destination 'platform=iOS Simulator,name=iPhone 16'`. Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Verify** (sim, no projects): "+" → Add past entry shows the empty state, no blank picker.

- [ ] **Step 4: Commit**

```bash
git add App/Sources/Features/Timer/ManualEntrySheet.swift
git commit -m "fix(timer): zero-project empty state with client-aware CTA in ManualEntrySheet"
```

---

## Task 8: Today tiles — split out "Ready to invoice", hide at $0

**Files:**
- Modify: `App/Sources/Features/Today/TodayView.swift` (`TodaySummarySection`, ~lines 402-446)

Context (verified): Hours + Earnings + the all-time `UninvoicedTile` render in one VStack under `Text("Today")`. The tile already suppresses its tap at $0 but still renders "$0.00". Keep Hours/Earnings always; move the uninvoiced tile under a new "Ready to invoice" heading; hide it entirely at $0; drop the in-tile "· ALL PROJECTS" caption (the heading carries scope).

- [ ] **Step 1: Restructure `content(asOf:)`** so the section is two labelled groups:

```swift
VStack(alignment: .leading, spacing: 18) {
    VStack(alignment: .leading, spacing: 14) {
        Text("Today").font(.title3.weight(.semibold))
        HStack(spacing: 12) {
            SummaryTile(label: "Hours", value: DurationFormatting.hoursMinutes(seconds: todaysSeconds), color: .blue)
            SummaryTile(label: "Earnings", value: todaysAmount.formatted(.currency(code: currencyCode)), color: .green)
        }
    }
    if uninvoiced > 0 {                       // hide the whole card at $0
        VStack(alignment: .leading, spacing: 10) {
            Text("Ready to invoice").font(.title3.weight(.semibold))
            UninvoicedTile(amount: uninvoiced, currency: currencyCode,
                           onTap: { showingGenerator = true })
        }
    }
}
```

- [ ] **Step 2: Drop the in-tile scope caption.** In `UninvoicedTile.tileBody`, remove the `Text("UNINVOICED · ALL PROJECTS")` eyebrow (the "Ready to invoice" heading now names it) — keep the amount + the "Hours you've tracked but haven't invoiced yet." line. (Per spec, the noun "Uninvoiced" stays elsewhere; the on-Today eyebrow is redundant with the heading.)

- [ ] **Step 3: Build to verify it compiles** — `xcodebuild build -scheme Billable -destination 'platform=iOS Simulator,name=iPhone 16'`. Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Verify** (sim): a fresh account ($0 uninvoiced) shows only "Today / Hours / Earnings" — no "Ready to invoice" card; after seeding uninvoiced work, the "Ready to invoice" card appears and taps into the generator.

- [ ] **Step 5: Commit**

```bash
git add App/Sources/Features/Today/TodayView.swift
git commit -m "feat(today): split Today (Hours/Earnings) from a Ready-to-invoice on-ramp; hide at $0"
```

---

## Final verification

- [ ] Full build: `xcodebuild build -scheme Billable -destination 'platform=iOS Simulator,name=iPhone 16'` → SUCCEEDED.
- [ ] `BillableCoreTests` green (esp. `BusinessProfileEntityTests` — no enriched regression — and the new completeness tests).
- [ ] `BillableUITests/GetStartedChecklistUITests` green.
- [ ] Simulator smoke (`--reset-store`): onboarding → Today leads with "Add your first client" (no timer); "+" sheets never blank; Settings names missing fields; fresh Today shows no $0 "Ready to invoice" card.
- [ ] Open PR A off merged `main`.

## Notes / non-goals

- `isProfileEnriched` and `TodayGuidance.resolve` precedence are unchanged.
- Existing clientless "General" projects remain valid + startable (B-1 decision) — this PR removes only the creation path, not existing data.
- No paywall (PR B) or timer-motion (PR C) changes here.
