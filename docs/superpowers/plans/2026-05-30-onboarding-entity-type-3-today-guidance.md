# Onboarding Entity-Type — Plan 3: Today Guidance (Get-Started + Enrichment)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Drive Today's first-run guidance — a pure `TodayGuidance` precedence resolver (BillableCore, full TDD), a `GetStartedSection` view (2-step checklist + one-tap "Start a timer now" quick-start), the §7b enrichment prompt (primary at invoice creation, secondary as a dismissible Today nudge), all wired into `TodayView` so **exactly one** guidance element shows at a time.

**Architecture:** Pure precedence lives in `BillableCore` as `TodayGuidance.resolve(...) -> Element` (mirrors `BadgeCount`: a `@MainActor`-free, side-effect-free enum the view feeds booleans into — never reads SwiftData, never mutates). SwiftUI views (`GetStartedSection`, the generator banner, the Today nudge) are App-target and verified by `xcodebuild build` + targeted XCUITests; rendering correctness is confirmed at **named simulator checkpoints**, not faked unit tests. The quick-start fetch-or-creates ONE canonical clientless `Project(name:"General")` and routes through the existing `TimerActions.start`; it deliberately does **not** stamp `firstSetupCompletedAt`, so quick-start users keep the checklist. The single first-setup latch writer (`BusinessProfileStore.stampFirstSetupIfReached`) and `reconcile` already exist (Plan 1) and are already wired at the launch + `scenePhase==.active` seam (Plan 2) — **this plan consumes the latch; it does not re-wire it.**

**Tech Stack:** Swift 6 (strict concurrency), SwiftData, SwiftUI + `@Observable`/`@Query`, Swift Testing (`@Test`/`#expect`) for pure logic, XCUITest for flows, `BillableCore` SPM package; app target `Billable` / `Billable.xcodeproj`.

**Spec:** `docs/superpowers/specs/2026-05-30-onboarding-entity-type-design.md` (§7, §7a, §7b, §9, §16).

**Depends on (already shipping):**
- Plan 1 — `BusinessProfile.onboardingCompletedAt` / `firstSetupCompletedAt` / `isProfileEnriched`; `BusinessProfileStore.canonical/allSorted/reconcile/stampFirstSetupIfReached`.
- Plan 2 — onboarding stamps `onboardingCompletedAt`; `stampFirstSetupIfReached` + `reconcile` are called at the launch + `scenePhase==.active` seam. **Do not re-wire either.**

**Run pure-logic tests with:** `cd Packages/BillableCore && swift test` (filter per task).
**Build-verify app + view wiring with:**
```bash
xcodebuild -project Billable.xcodeproj -scheme Billable \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -configuration Debug build
```
**Run a UI test with:**
```bash
xcodebuild -project Billable.xcodeproj -scheme Billable \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BillableUITests/<SuiteName> test
```

---

## File Structure

```
Packages/BillableCore/
  Sources/BillableCore/Today/
    TodayGuidance.swift                         (NEW — Task 1: pure precedence resolver)
  Tests/BillableCoreTests/
    TodayGuidanceTests.swift                    (NEW — Task 1: exhaustive precedence matrix)

App/Sources/Features/Today/
  GetStartedSection.swift                       (NEW — Tasks 2–5: checklist + quick-start + 0-rate)
  TodayView.swift                               (MODIFY — Task 6: feed TodayGuidance, render one element)

App/Sources/Features/Invoicing/
  InvoiceGeneratorView.swift                    (MODIFY — Task 7: §7b primary inline enrichment prompt)

App/Sources/App/
  BillableApp.swift                             (MODIFY — Task 8: --seed-onboarding-needs-setup UI-test fixture)

App/BillableUITests/
  GetStartedChecklistUITests.swift              (NEW — Task 9: checklist reactivity + quick-start dedupe)
```

No new `@Query var allProjects` anywhere. The active-project probe is a **bounded** `fetchCount`/`fetchLimit 1`. The checklist reuses `TodayView`'s existing `allClients` query (passed in), so the section adds **no** second client query.

---

### Task 1: `TodayGuidance` — pure precedence resolver (full TDD)

Mirrors `BadgeCount` (`Packages/BillableCore/Sources/BillableCore/Scheduling/BadgeCount.swift`): a pure enum the view feeds booleans into. It NEVER reads SwiftData and NEVER mutates — so it is exhaustively unit-testable. Precedence (spec §7): name-missing → get-started → enrichment → none.

**Files:**
- Create: `Packages/BillableCore/Sources/BillableCore/Today/TodayGuidance.swift`
- Test: `Packages/BillableCore/Tests/BillableCoreTests/TodayGuidanceTests.swift`

- [ ] **Step 1: Write the failing test (the full precedence matrix)**

Create `Packages/BillableCore/Tests/BillableCoreTests/TodayGuidanceTests.swift`:

```swift
import Testing
@testable import BillableCore

@Suite("TodayGuidance precedence")
struct TodayGuidanceTests {

    // MARK: Tier 1 — name banner wins over everything

    @Test("missing name wins even when setup incomplete and not enriched")
    func nameBeatsAll() {
        #expect(
            TodayGuidance.resolve(
                hasName: false, hasActiveSetup: false,
                isEnriched: false, enrichmentSnoozed: false
            ) == .nameBanner
        )
    }

    @Test("missing name wins even when setup is complete")
    func nameBeatsGetStartedAndEnrichment() {
        #expect(
            TodayGuidance.resolve(
                hasName: false, hasActiveSetup: true,
                isEnriched: false, enrichmentSnoozed: false
            ) == .nameBanner
        )
    }

    // MARK: Tier 2 — get-started (onboarded, name present, setup not yet reached)

    @Test("named but setup not reached → get-started")
    func getStartedWhenNotSetUp() {
        #expect(
            TodayGuidance.resolve(
                hasName: true, hasActiveSetup: false,
                isEnriched: false, enrichmentSnoozed: false
            ) == .getStarted
        )
    }

    @Test("get-started outranks enrichment while setup unreached")
    func getStartedBeatsEnrichment() {
        // Not enriched AND not snoozed would qualify for enrichment, but setup
        // isn't reached yet, so get-started takes precedence.
        #expect(
            TodayGuidance.resolve(
                hasName: true, hasActiveSetup: false,
                isEnriched: false, enrichmentSnoozed: false
            ) == .getStarted
        )
    }

    // MARK: Tier 3 — enrichment (named, setup reached, not enriched, not snoozed)

    @Test("named + set up + not enriched + not snoozed → enrichment")
    func enrichmentWhenIncomplete() {
        #expect(
            TodayGuidance.resolve(
                hasName: true, hasActiveSetup: true,
                isEnriched: false, enrichmentSnoozed: false
            ) == .enrichment
        )
    }

    @Test("snoozing the enrichment nudge suppresses it → none")
    func snoozeSuppressesEnrichment() {
        #expect(
            TodayGuidance.resolve(
                hasName: true, hasActiveSetup: true,
                isEnriched: false, enrichmentSnoozed: true
            ) == .none
        )
    }

    // MARK: Tier 4 — none

    @Test("fully enriched → none")
    func noneWhenEnriched() {
        #expect(
            TodayGuidance.resolve(
                hasName: true, hasActiveSetup: true,
                isEnriched: true, enrichmentSnoozed: false
            ) == .none
        )
    }

    @Test("enriched + snoozed is still none (no double-suppression bug)")
    func noneWhenEnrichedAndSnoozed() {
        #expect(
            TodayGuidance.resolve(
                hasName: true, hasActiveSetup: true,
                isEnriched: true, enrichmentSnoozed: true
            ) == .none
        )
    }

    // MARK: Exhaustive — all 16 boolean combinations have a deterministic answer

    @Test("all 16 input combinations resolve deterministically per the precedence ladder")
    func fullTruthTable() {
        for hasName in [true, false] {
            for hasActiveSetup in [true, false] {
                for isEnriched in [true, false] {
                    for enrichmentSnoozed in [true, false] {
                        let got = TodayGuidance.resolve(
                            hasName: hasName, hasActiveSetup: hasActiveSetup,
                            isEnriched: isEnriched, enrichmentSnoozed: enrichmentSnoozed
                        )
                        let expected: TodayGuidance.Element
                        if !hasName {
                            expected = .nameBanner
                        } else if !hasActiveSetup {
                            expected = .getStarted
                        } else if !isEnriched && !enrichmentSnoozed {
                            expected = .enrichment
                        } else {
                            expected = .none
                        }
                        #expect(got == expected, "mismatch for \(hasName),\(hasActiveSetup),\(isEnriched),\(enrichmentSnoozed)")
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/BillableCore && swift test --filter TodayGuidanceTests`
Expected: FAIL — `cannot find 'TodayGuidance' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Packages/BillableCore/Sources/BillableCore/Today/TodayGuidance.swift`:

```swift
import Foundation

/// Pure, read-only resolver for Today's *single* guidance element. Mirrors
/// `BadgeCount`: it takes booleans the view already computes and returns the one
/// element to show — it NEVER reads SwiftData and NEVER mutates (so it is
/// exhaustively unit-testable). Precedence (spec §7), highest first:
///
///   1. name missing            → `.nameBanner`   (can't send invoices at all)
///   2. onboarded, setup unreached → `.getStarted`
///   3. set up, not enriched, not snoozed → `.enrichment`
///   4. otherwise               → `.none`
///
/// "One element at a time": the resolver returns exactly one case; the view
/// renders that case and nothing else. The first-setup latch is owned by
/// `BusinessProfileStore.stampFirstSetupIfReached` — NOT stamped here.
public enum TodayGuidance: Sendable {

    /// The single guidance element Today should render (or `.none`).
    public enum Element: Sendable, Equatable {
        case nameBanner
        case getStarted
        case enrichment
        case none
    }

    /// - Parameters:
    ///   - hasName: `BusinessProfile.canSendInvoice(profile:)` — a non-blank issuer name exists.
    ///   - hasActiveSetup: `firstSetupCompletedAt != nil` — a client + a client-linked active project have coexisted.
    ///   - isEnriched: `BusinessProfile.isProfileEnriched` — address + payment details present.
    ///   - enrichmentSnoozed: session-only "Not now" was tapped (no persisted flag; spec §7b).
    public static func resolve(
        hasName: Bool,
        hasActiveSetup: Bool,
        isEnriched: Bool,
        enrichmentSnoozed: Bool
    ) -> Element {
        if !hasName { return .nameBanner }
        if !hasActiveSetup { return .getStarted }
        if !isEnriched && !enrichmentSnoozed { return .enrichment }
        return .none
    }
}
```

> Note: the `.getStarted` case here only governs *which* guidance element shows. The spec's gate that the get-started block requires `onboardingCompletedAt != nil` is enforced at the call site in `TodayView` (Task 6) by deriving `hasActiveSetup`/`hasName` only when onboarding is complete — `TodayGuidance` stays a pure function of its four inputs.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Packages/BillableCore && swift test --filter TodayGuidanceTests`
Expected: PASS (9 tests, incl. the 16-combination exhaustive case).

- [ ] **Step 5: Run the FULL BillableCore suite (no regressions)**

Run: `cd Packages/BillableCore && swift test`
Expected: PASS — all prior tests (Plan 1's ~14 new + the existing suite) still green; `TodayGuidance` is additive.

- [ ] **Step 6: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Today/TodayGuidance.swift Packages/BillableCore/Tests/BillableCoreTests/TodayGuidanceTests.swift
git commit -m "feat(core): TodayGuidance pure precedence resolver (name → get-started → enrichment → none)"
```

---

### Task 2: `GetStartedSection` — checklist skeleton (2 rows, client-gated)

The view shell: header + 2-row checklist (Row 1 "Add a client", Row 2 "Create a project" disabled until a client exists). Quick-start + 0-rate + acknowledgement land in Tasks 3–5. Reuses Today's existing `allClients` (passed in) — NO second client query. The active-project probe uses a **bounded** `@Query` count, never an unbounded `allProjects`.

**Files:**
- Create: `App/Sources/Features/Today/GetStartedSection.swift`

- [ ] **Step 1: Write the view (complete; quick-start stubbed to Task 3)**

Create `App/Sources/Features/Today/GetStartedSection.swift`:

```swift
import SwiftUI
import SwiftData
import BillableCore

/// First-run guidance block on Today (spec §7a). Shows while the user has
/// onboarded but a real client+project haven't yet coexisted
/// (`firstSetupCompletedAt == nil`). One PRIMARY action ("Start a timer now")
/// plus a SECONDARY 2-step checklist. The block disappears on its own once
/// `BusinessProfileStore.stampFirstSetupIfReached` latches first-setup — this
/// view never writes that latch.
///
/// `clients` is passed in from TodayView's existing `allClients` @Query so we
/// don't open a second client query. The "is there an active project?" probe is
/// a BOUNDED count query (never an unbounded `allProjects`).
struct GetStartedSection: View {
    @Environment(\.modelContext) private var modelContext

    /// Reused from TodayView's `allClients` — do not add a second @Query here.
    let clients: [Client]
    let currencyCode: String

    /// Bounded probe: at most one running entry. Drives the header reframe +
    /// the 0-rate "Set your rate" affordance.
    @Query(Self.runningDescriptor) private var runningEntries: [TimeEntry]

    /// Bounded probe: does at least one non-archived client-linked project exist?
    /// `fetchLimit 1` → SwiftData stops after the first match; this is NOT an
    /// unbounded project list.
    @Query(Self.anyLinkedProjectDescriptor) private var linkedProjectProbe: [Project]

    @State private var showingAddClient = false
    @State private var showingNewProject = false
    @State private var startingQuickTimer = false

    private static var runningDescriptor: FetchDescriptor<TimeEntry> {
        var d = FetchDescriptor<TimeEntry>(predicate: #Predicate { $0.endedAt == nil })
        d.fetchLimit = 1
        d.relationshipKeyPathsForPrefetching = [\.project]
        return d
    }

    private static var anyLinkedProjectDescriptor: FetchDescriptor<Project> {
        var d = FetchDescriptor<Project>(predicate: #Predicate { !$0.isArchived && $0.client != nil })
        d.fetchLimit = 1
        return d
    }

    private var hasClient: Bool { !clients.isEmpty }
    private var hasLinkedProject: Bool { !linkedProjectProbe.isEmpty }
    private var runningEntry: TimeEntry? { runningEntries.first }
    private var isTimerRunning: Bool { runningEntry != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            quickStartButton                       // PRIMARY (filled) — Task 3
            if let runningEntry, runningEntry.project?.hourlyRate == 0 {
                setRateRow(for: runningEntry)       // 0-rate affordance — Task 5
            }
            VStack(spacing: 0) {
                checklistRow(
                    title: "Add a client",
                    isDone: hasClient,
                    isEnabled: true,
                    hint: nil
                ) { showingAddClient = true }
                Divider().padding(.leading, 44)
                checklistRow(
                    title: "Create a project",
                    isDone: hasLinkedProject,
                    isEnabled: hasClient,
                    hint: hasClient ? nil : "Add a client first"
                ) { showingNewProject = true }
            }
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 14))
        }
        .padding(16)
        .background(.thinMaterial, in: .rect(cornerRadius: 18))
        .sheet(isPresented: $showingAddClient) {
            NavigationStack { ClientEditorView(client: nil) }
        }
        .sheet(isPresented: $showingNewProject) {
            GetStartedNewProjectSheet()
        }
    }

    // MARK: Header (reframes once a timer is running — spec §7a acknowledgement)

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(isTimerRunning ? "Timer running" : "Get started")
                .font(.headline)
            Text(isTimerRunning
                 ? "Add a client to invoice this time."
                 : "Track time now, or set up a client and project to invoice.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Quick-start PRIMARY (filled) — wired in Task 3

    @ViewBuilder private var quickStartButton: some View { EmptyView() }

    // MARK: 0-rate affordance — wired in Task 5

    @ViewBuilder private func setRateRow(for entry: TimeEntry) -> some View { EmptyView() }

    // MARK: Secondary checklist row

    private func checklistRow(
        title: String,
        isDone: Bool,
        isEnabled: Bool,
        hint: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isDone ? .green : (isEnabled ? .accentColor : .secondary))
                    .frame(width: 32)
                Text(title)
                    .font(.body)
                    .foregroundStyle(isEnabled ? .primary : .secondary)
                    .strikethrough(isDone, color: .secondary)
                Spacer()
                if !isDone && isEnabled {
                    Image(systemName: "chevron.right")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 12)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isDone)
        .accessibilityHint(hint ?? "")
    }
}

/// New-project sheet for the get-started checklist: pick a client, then push the
/// existing `ProjectEditorView`. Mirrors `WorkView`'s `NewProjectSheet` (a
/// `private` type there, so this is the Today-local sibling per spec §7a "the
/// existing add-project sheet via the New-Project flow"). Only non-archived
/// clients are offered, matching the rest of the app.
private struct GetStartedNewProjectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Client> { !$0.isArchived }, sort: \Client.name)
    private var clients: [Client]
    @State private var selectedClientID: PersistentIdentifier?

    var body: some View {
        NavigationStack {
            Group {
                if clients.isEmpty {
                    ContentUnavailableView(
                        "No clients yet",
                        systemImage: "person.2",
                        description: Text("Add a client first, then create a project for them.")
                    )
                } else {
                    List(clients) { client in
                        Button {
                            selectedClientID = client.persistentModelID
                        } label: {
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(client.color.swiftUIColor)
                                    .frame(width: 10, height: 10)
                                Text(client.name).foregroundStyle(.primary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("New project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .navigationDestination(item: $selectedClientID) { id in
                if let client = clients.first(where: { $0.persistentModelID == id }) {
                    ProjectEditorView(client: client, project: nil, onSaved: { dismiss() })
                }
            }
        }
    }
}
```

> Verify-before-coding: `ClientEditorView(client:)`, `ProjectEditorView(client:project:onSaved:)`, `Client.color.swiftUIColor`, and `Project.hourlyRate` (a `Decimal`) all match the worktree. `runningEntry.project?.hourlyRate == 0` compares `Decimal == 0` (valid). The `EmptyView()` stubs compile cleanly and are replaced in Tasks 3 + 5.

- [ ] **Step 2: Build-verify (compiles; not yet wired into Today)**

Run:
```bash
xcodebuild -project Billable.xcodeproj -scheme Billable \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`. (The file exists but is referenced only after Task 6 — it must still compile standalone.)

- [ ] **Step 3: Commit**

```bash
git add App/Sources/Features/Today/GetStartedSection.swift
git commit -m "feat(today): GetStartedSection skeleton — 2-step checklist + client-gated project row"
```

---

### Task 3: Quick-start — fetch-or-create ONE "General", debounced

The single PRIMARY action. Fetch-or-create exactly one canonical clientless `Project(name:"General", client:nil, !isArchived)` via a `fetchLimit 1` probe (reuse if present — never a second insert), then `TimerActions.start`. Debounce with `startingQuickTimer` (disable + "Starting…") so a same-frame double-tap can't insert two Generals or two timers.

**Files:**
- Modify: `App/Sources/Features/Today/GetStartedSection.swift`

- [ ] **Step 1: Replace the quick-start stub with the real PRIMARY button**

In `GetStartedSection.swift`, replace:

```swift
    @ViewBuilder private var quickStartButton: some View { EmptyView() }
```

with:

```swift
    private var quickStartButton: some View {
        Button {
            startQuickTimer()
        } label: {
            HStack(spacing: 8) {
                if startingQuickTimer {
                    ProgressView().tint(.white)
                    Text("Starting…")
                } else {
                    Image(systemName: "play.fill")
                    Text("Start a timer now")
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(startingQuickTimer || isTimerRunning)
        .accessibilityIdentifier("getStarted.quickStart")
        .accessibilityHint(isTimerRunning ? "A timer is already running" : "Starts tracking on a General project")
    }

    /// Fetch-or-create the ONE canonical clientless "General" project, then start
    /// a timer on it. Debounced via `startingQuickTimer` so a same-frame
    /// double-tap can't double-insert. The General project deliberately does NOT
    /// satisfy first-setup (it's clientless), so the checklist stays visible.
    private func startQuickTimer() {
        guard !startingQuickTimer, !isTimerRunning else { return }
        startingQuickTimer = true
        let project = fetchOrCreateGeneralProject()
        TimerActions.start(project: project, currencyCode: currencyCode, in: modelContext)
        // The running @Query flips `isTimerRunning` on the next runloop, which
        // re-disables the button and reframes the header; clear the in-flight
        // flag so the control settles into its running (disabled) state.
        startingQuickTimer = false
    }

    /// Probe for an existing non-archived clientless "General" (fetchLimit 1 —
    /// reuse, never duplicate); create one only if absent.
    private func fetchOrCreateGeneralProject() -> Project {
        var probe = FetchDescriptor<Project>(
            predicate: #Predicate { $0.name == "General" && $0.client == nil && !$0.isArchived }
        )
        probe.fetchLimit = 1
        if let existing = try? modelContext.fetch(probe).first {
            return existing
        }
        let general = Project(name: "General", hourlyRate: 0, isBillable: true, client: nil)
        modelContext.insert(general)
        modelContext.saveOrLog("create General quick-start project")
        return general
    }
```

> Verify-before-coding: `Project(name:hourlyRate:isBillable:client:)` matches Plan 1 / the model init (`hourlyRate: Decimal`, `client: Client? = nil`). `modelContext.saveOrLog(_:)` is the house fire-and-forget save (`ModelContext+SaveOrLog.swift`). `TimerActions.start(project:currencyCode:in:)` is the existing signature. The `#Predicate` mirrors Plan 1's `stampFirstSetupIfReached` style; if SwiftData rejects `$0.client == nil` in a predicate (optional-to-one quirk), fall back to fetching non-archived `name == "General"` projects (bounded) and `.first { $0.client == nil }` in memory — same pattern Plan 1 documents.

- [ ] **Step 2: Build-verify**

Run:
```bash
xcodebuild -project Billable.xcodeproj -scheme Billable \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add App/Sources/Features/Today/GetStartedSection.swift
git commit -m "feat(today): quick-start — fetch-or-create one General + debounced TimerActions.start"
```

---

### Task 4: Designate the primary, finalize the acknowledgement reframe

Quick-start is the filled `.borderedProminent` primary (Task 3). The checklist rows are `.plain` secondary. The header already reframes to "Timer running — add a client to invoice this time" when `isTimerRunning` (Task 2). This task is the **visual-hierarchy + acknowledgement checkpoint** — it adds no new control, it confirms the surface ships exactly one primary and that the tap produces a visible in-block change.

**Files:**
- (No code change — verification + a doc-comment assertion. If Task 2/3 already satisfy it, this is purely the named simulator checkpoint.)

- [ ] **Step 1: Confirm single-primary invariant in code review**

Read `GetStartedSection.swift` and confirm:
- Exactly ONE `.buttonStyle(.borderedProminent)` (the quick-start). The two checklist rows are `.buttonStyle(.plain)`. The 0-rate row (Task 5) will be `.plain`/tinted, not prominent.
- The header's first `Text` is data-driven by `isTimerRunning` (reframes "Get started" → "Timer running").

- [ ] **Step 2: Build-verify (unchanged, sanity)**

Run:
```bash
xcodebuild -project Billable.xcodeproj -scheme Billable \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: NAMED SIMULATOR CHECKPOINT — acknowledgement**

These are manual on-simulator confirmations (rendering is not unit-testable; do them after Task 6 wires the block into Today, but the invariant is owned here):
1. Launch with `--seed-onboarding-needs-setup` (added Task 8). Today shows the get-started block, header = "Get started", ONE filled "Start a timer now" button.
2. Tap "Start a timer now". The header reframes to **"Timer running"** with subtitle "Add a client to invoice this time." The button shows "Starting…" briefly, then settles disabled. (This is the spec §7a "visible in-block change even though the latch is intentionally unset" — the checklist is still present.)
3. Confirm no second primary: only the quick-start is filled/accent.

> No commit (no code change). If Step 1 finds two prominent buttons, FIX in `GetStartedSection.swift` and commit under Task 3's scope.

---

### Task 5: 0-rate guidance — "Set your rate" on the running-General row

When a timer runs on a rate-0 project, surface an inline "Set your rate" affordance (spec §7a). `ProjectEditorView` requires a non-nil `client`, but the General project is clientless — so the affordance routes to the SAME `ProjectEditorView` for client-linked rate-0 projects, and for the clientless General it routes to a one-field rate sheet that edits `General.hourlyRate` directly (the General project has no client to satisfy `ProjectEditorView(client:)`).

**Files:**
- Modify: `App/Sources/Features/Today/GetStartedSection.swift`

- [ ] **Step 1: Replace the 0-rate stub + add the rate sheet**

In `GetStartedSection.swift`, replace:

```swift
    @ViewBuilder private func setRateRow(for entry: TimeEntry) -> some View { EmptyView() }
```

with:

```swift
    @ViewBuilder private func setRateRow(for entry: TimeEntry) -> some View {
        if let project = entry.project {
            Button {
                rateTargetProject = project
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "dollarsign.circle")
                        .foregroundStyle(.orange)
                    Text("Set your rate")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text("— this project earns nothing at $0/hr")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
                .padding(12)
                .frame(minHeight: 44)
                .background(.orange.opacity(0.10), in: .rect(cornerRadius: 12))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("getStarted.setRate")
        }
    }
```

Add the `@State` target near the other `@State` declarations:

```swift
    @State private var rateTargetProject: Project?
```

Add the sheet to the `body`'s modifier chain (after the existing `.sheet(isPresented: $showingNewProject)`):

```swift
        .sheet(item: $rateTargetProject) { project in
            if let client = project.client {
                // Client-linked rate-0 project → the full project editor.
                NavigationStack { ProjectEditorView(client: client, project: project) }
            } else {
                // Clientless "General" has no client to satisfy ProjectEditorView(client:);
                // edit just its rate.
                GeneralRateSheet(project: project)
            }
        }
```

Add the focused rate sheet at file scope (sibling to `GetStartedNewProjectSheet`):

```swift
/// One-field rate editor for the clientless "General" quick-start project, which
/// can't use `ProjectEditorView` (that requires a client). Edits `hourlyRate`
/// in place. "General" is explicitly a scratchpad; this is the on-ramp to a rate.
private struct GeneralRateSheet: View {
    @Environment(\.dismiss) private var dismiss
    let project: Project
    @State private var rateInput: Double = 0
    @State private var hasLoaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Hourly rate") {
                    HStack {
                        Text("Rate")
                        Spacer()
                        TextField("0", value: $rateInput, format: .number.precision(.fractionLength(0...2)))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 140)
                    }
                    if rateInput.isZero {
                        Label(
                            "A 0 rate tracks time but earns nothing. Set a rate to track earnings.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Set rate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        project.hourlyRate = Decimal(rateInput)
                        project.updatedAt = .now
                        dismiss()
                    }
                    .bold()
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                guard !hasLoaded else { return }
                hasLoaded = true
                rateInput = (project.hourlyRate as NSDecimalNumber).doubleValue
            }
        }
    }
}
```

> Verify-before-coding: `Project` is `Identifiable` (SwiftData `@Model`), so `.sheet(item: $rateTargetProject)` works. `Project.updatedAt` exists (model). The rate-editing block mirrors `ProjectEditorView`'s exact rate field (`format: .number.precision(.fractionLength(0...2))`, `.decimalPad`) for consistency. Mutating `project.hourlyRate` on a `@Model` autosaves via SwiftData's context; if the house pattern requires an explicit `saveOrLog`, add `modelContext.saveOrLog("set General rate")` (inject `@Environment(\.modelContext)` into `GeneralRateSheet`).

- [ ] **Step 2: Build-verify**

Run:
```bash
xcodebuild -project Billable.xcodeproj -scheme Billable \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add App/Sources/Features/Today/GetStartedSection.swift
git commit -m "feat(today): 0-rate 'Set your rate' affordance on the running-General row"
```

---

### Task 6: Wire `GetStartedSection` + `TodayGuidance` precedence into `TodayView`

Replace the lone `showEmptyBusinessBanner` check with a single `TodayGuidance.resolve(...)`-driven `switch`, so **exactly one** of {name banner, get-started, enrichment nudge} renders. The get-started block shows only while `onboardingCompletedAt != nil && firstSetupCompletedAt == nil`. The enrichment nudge is the §7b SECONDARY tier-3 card with a session-only "Not now".

**Files:**
- Modify: `App/Sources/Features/Today/TodayView.swift`

- [ ] **Step 1: Add the guidance-driven section to `TodayView`**

In `TodayView.swift`, add a session-only snooze state next to the existing `@State`:

```swift
    @State private var enrichmentSnoozedThisSession = false
```

Replace the existing `if showEmptyBusinessBanner { … }` block in `body` (the whole `NavigationLink(destination: BusinessProfileEditorView()) { … }` for the name banner) with a single call:

```swift
                    guidanceSection
```

Replace the existing `showEmptyBusinessBanner` computed property:

```swift
    private var showEmptyBusinessBanner: Bool {
        !BusinessProfile.canSendInvoice(profile: profiles.first)
    }
```

with the resolver-driven plumbing:

```swift
    private var profile: BusinessProfile? { profiles.first }

    /// The single guidance element for Today, resolved by the pure
    /// `TodayGuidance`. Inputs are derived here (the resolver never touches
    /// SwiftData). Get-started is gated on onboarding being complete AND
    /// first-setup not yet reached.
    private var guidanceElement: TodayGuidance.Element {
        let onboarded = profile?.onboardingCompletedAt != nil
        // Before onboarding completes, suppress get-started/enrichment entirely
        // (RootView is showing the onboarding screen anyway); only the rare
        // name-missing banner can apply.
        let hasActiveSetup = onboarded ? (profile?.firstSetupCompletedAt != nil) : true
        return TodayGuidance.resolve(
            hasName: BusinessProfile.canSendInvoice(profile: profile),
            hasActiveSetup: hasActiveSetup,
            isEnriched: profile?.isProfileEnriched ?? false,
            enrichmentSnoozed: enrichmentSnoozedThisSession
        )
    }

    @ViewBuilder
    private var guidanceSection: some View {
        switch guidanceElement {
        case .nameBanner:
            nameBanner
        case .getStarted:
            GetStartedSection(clients: allClients, currencyCode: currencyCode)
                .padding(.horizontal)
        case .enrichment:
            enrichmentNudge
        case .none:
            EmptyView()
        }
    }

    private var nameBanner: some View {
        NavigationLink(destination: BusinessProfileEditorView()) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Add your business name to send invoices")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(.orange.opacity(0.12), in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
    }

    /// §7b SECONDARY Today nudge (tier 3): an info card. "Not now" is
    /// session-only — no persisted flag. `isProfileEnriched` is the durable
    /// driver; the card returns next launch if the profile is still incomplete.
    private var enrichmentNudge: some View {
        HStack(alignment: .top, spacing: 10) {
            NavigationLink(destination: BusinessProfileEditorView()) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Finish your invoice details")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        Text("Add your address and payment details so invoices look complete.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            Button {
                enrichmentSnoozedThisSession = true
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)        // ≥44pt touch target (spec §7b/§9)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .background(.blue.opacity(0.08), in: .rect(cornerRadius: 12))
        .padding(.horizontal)
    }
```

> Note: the parent `VStack` already has `.padding()` on the `ScrollView` content; the explicit `.padding(.horizontal)` on each guidance variant matches the existing name-banner inset. `GetStartedSection` carries its own internal padding + card background, so it gets only the horizontal inset to align with the other cards.

- [ ] **Step 2: Build-verify**

Run:
```bash
xcodebuild -project Billable.xcodeproj -scheme Billable \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: NAMED SIMULATOR CHECKPOINT — one-element-at-a-time precedence**

Manual on-simulator confirmations (the four precedence states; rendering isn't unit-testable):
1. **Get-started:** launch `--seed-onboarding-needs-setup` (Task 8) → Today shows the get-started block, and NO name banner, NO enrichment card.
2. **Name banner wins:** with a profile whose name is blank, the orange name banner shows and the get-started block does NOT (name outranks). (Reachable by clearing the name in Settings, then returning to Today.)
3. **Enrichment nudge:** with a complete name + a real client+project (first-setup latched) + address/bank empty → the blue "Finish your invoice details" card shows; tapping the ✕ ("Dismiss") removes it for the session; relaunch → it returns (session-only snooze).
4. **None:** name + first-setup + enriched (address + bank filled) → no guidance card.

- [ ] **Step 4: Commit**

```bash
git add App/Sources/Features/Today/TodayView.swift
git commit -m "feat(today): drive guidance via TodayGuidance precedence — name / get-started / enrichment / none"
```

---

### Task 7: §7b PRIMARY enrichment prompt at invoice creation

Opening `InvoiceGeneratorView` with `!isProfileEnriched` surfaces an inline "Add your address & payment details so this invoice looks complete" → `BusinessProfileEditorView`, with conditional copy when only one half (address OR bank) is missing. This is the PRIMARY enrichment surface (the Today nudge in Task 6 is secondary). It is additive generator UI — no change to invoice/PDF math (spec §10).

**Files:**
- Modify: `App/Sources/Features/Invoicing/InvoiceGeneratorView.swift`

- [ ] **Step 1: Add the enrichment section to the generator `Form`**

In `InvoiceGeneratorView.swift`, add a computed message + section. Place the section in `body`'s `Form` immediately ABOVE the existing `if !Self.canSendInvoice(profile: profile)` section (name gating stays last; enrichment is the softer, higher-up nudge). Insert:

```swift
                if let profile, !profile.isProfileEnriched, Self.canSendInvoice(profile: profile) {
                    Section {
                        NavigationLink {
                            BusinessProfileEditorView()
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "doc.text.magnifyingglass")
                                    .foregroundStyle(.blue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Complete your invoice details")
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary)
                                    Text(enrichmentPromptMessage(for: profile))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .accessibilityIdentifier("invoiceGenerator.enrichmentPrompt")
                    }
                }
```

Add the conditional-copy helper near the other `private` computed members (e.g. below `canPreview`):

```swift
    /// §7b conditional copy: name which half is missing, or both. `isProfileEnriched`
    /// requires a non-blank address AND `hasBankDetails`; mirror those two checks.
    private func enrichmentPromptMessage(for profile: BusinessProfile) -> String {
        let hasAddress = !profile.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasBank = profile.hasBankDetails
        switch (hasAddress, hasBank) {
        case (false, false):
            return "Add your address and payment details so this invoice looks complete."
        case (false, true):
            return "Add your address so this invoice looks complete."
        case (true, false):
            return "Add your payment details so this invoice looks complete."
        case (true, true):
            return ""   // unreachable: !isProfileEnriched implies at least one is missing
        }
    }
```

> Verify-before-coding: `BusinessProfile.address` (String) and `BusinessProfile.hasBankDetails` (Bool) exist — `isProfileEnriched` is defined as `!address.trimmed.isEmpty && hasBankDetails` (Plan 1), so the two halves here match its definition exactly. `BusinessProfileEditorView()` is the no-arg editor (it reads `profiles.first`). The gating `Self.canSendInvoice(profile:)` ensures the name banner (shown lower) and this enrichment prompt are mutually exclusive in spirit: name-missing surfaces the stronger name section; once named, this softer enrichment nudge appears.

- [ ] **Step 2: Build-verify**

Run:
```bash
xcodebuild -project Billable.xcodeproj -scheme Billable \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: NAMED SIMULATOR CHECKPOINT — invoice-time enrichment copy**

Manual on-simulator confirmations:
1. With a named profile, empty address + empty bank → open Invoices → + → the "Complete your invoice details" row reads "Add your address **and** payment details…"; tapping it pushes `BusinessProfileEditorView`.
2. Fill only the address (leave bank empty), reopen the generator → copy now reads "Add your **payment details**…".
3. Fill only bank (clear address) → copy reads "Add your **address**…".
4. Fill both → the row disappears (`isProfileEnriched == true`).

- [ ] **Step 4: Commit**

```bash
git add App/Sources/Features/Invoicing/InvoiceGeneratorView.swift
git commit -m "feat(invoicing): inline enrichment prompt at invoice creation (conditional address/payment copy)"
```

---

### Task 8: UI-test fixture — `--seed-onboarding-needs-setup`

A deterministic launch state for the get-started/quick-start UI test: a RESET store seeded with a single onboarded-but-unfinished `BusinessProfile` (`onboardingCompletedAt` set, `firstSetupCompletedAt == nil`, a non-blank name so the name banner does NOT pre-empt) and NO clients/projects — so Today renders the get-started block on first frame. Mirrors the existing `--reset-store` / `--seed-marketing` flag handling in `BillableApp.init`.

**Files:**
- Modify: `App/Sources/App/BillableApp.swift`

- [ ] **Step 1: Read the existing flag-handling block**

Run: `cd "Packages/.." ; sed -n '14,60p' App/Sources/App/BillableApp.swift` — confirm the `--reset-store` / `--seed-marketing` branch shape and the `appGroup`/`container` symbols you'll seed into. (Match this region's exact container variable + `resetAppGroupStore` usage.)

- [ ] **Step 2: Add the fixture branch**

In `BillableApp.swift`, inside `init()`, add a branch alongside `--seed-marketing` (after the existing `--reset-store` wipe runs, before the normal container is used). It seeds the onboarded-but-unfinished profile into the same store the app reads:

```swift
            } else if CommandLine.arguments.contains("--seed-onboarding-needs-setup") {
                // UI-test fixture (spec §16): onboarded but first-setup NOT reached.
                // A named profile (so the name banner doesn't pre-empt) with
                // onboardingCompletedAt set + firstSetupCompletedAt nil, and NO
                // clients/projects → Today renders the get-started block.
                if CommandLine.arguments.contains("--reset-store") {
                    Self.resetAppGroupStore(appGroupID)
                }
                let profile = BusinessProfile(name: "Test Co")
                profile.onboardingCompletedAt = .now
                container.mainContext.insert(profile)
                try? container.mainContext.save()
```

> Verify-before-coding: match the real symbol names in this file — the App Group identifier constant (read it from the existing `--reset-store` call, e.g. `resetAppGroupStore(<id>)`) and the container variable that backs `mainContext`. If `--reset-store` already runs unconditionally earlier for any reset flag, drop the inner `if … resetAppGroupStore` and just seed. The branch must sit where `container` is already the App-Group container (so the seeded profile is what `RootView`/`TodayView` read). Keep `BusinessProfile(name:)` + the `onboardingCompletedAt` setter from Plan 1.

- [ ] **Step 3: Build-verify**

Run:
```bash
xcodebuild -project Billable.xcodeproj -scheme Billable \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add App/Sources/App/BillableApp.swift
git commit -m "test(app): --seed-onboarding-needs-setup launch fixture (onboarded, first-setup unreached)"
```

---

### Task 9: UI test — checklist reactivity + quick-start dedupe

The spec §16 UI checks for this surface: double-tap quick-start → ONE "General" + a running timer (the debounce holds); the checklist Row 1 advances when a client is added. Mirrors `InvoicePreviewLineItemEditUITests` house style (launch args, `waitForExistence`, `XCTWaiter` for async settle).

**Files:**
- Create: `App/BillableUITests/GetStartedChecklistUITests.swift`

- [ ] **Step 1: Write the UI test**

Create `App/BillableUITests/GetStartedChecklistUITests.swift`:

```swift
import XCTest

/// UI checks for the get-started block (spec §7a / §16):
///  A. Double-tapping "Start a timer now" creates exactly ONE General project
///     and ONE running timer (the `startingQuickTimer` debounce holds), and the
///     block header reframes to "Timer running".
///  B. Adding a client advances checklist Row 1 ("Add a client" → done) and
///     enables Row 2 ("Create a project").
///
/// Launched with --seed-onboarding-needs-setup (onboarded, first-setup
/// unreached, no clients) so Today renders the get-started block on first frame.
final class GetStartedChecklistUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--reset-store",                       // Wipe the App Group store
            "--seed-onboarding-needs-setup",       // Onboarded; first-setup unreached; no clients
            "--pretend-pro"                        // Remove paywall gates (consistency w/ other UI tests)
        ]
        app.launch()
        return app
    }

    // MARK: A — quick-start double-tap creates exactly one General + one timer

    func test_quickStart_doubleTap_createsOneGeneral_andRunningTimer() throws {
        let app = launchedApp()

        // Today tab is the default; the get-started block shows on first frame.
        let quickStart = app.buttons["getStarted.quickStart"]
        XCTAssertTrue(quickStart.waitForExistence(timeout: 5),
                      "Get-started quick-start button must be visible on Today. Tree:\n\(app.debugDescription)")

        // Double-tap as fast as possible to race the debounce.
        quickStart.tap()
        quickStart.tap()

        // The header reframes to "Timer running" once the timer starts — wait for it.
        let runningHeader = app.staticTexts["Timer running"]
        XCTAssertTrue(runningHeader.waitForExistence(timeout: 5),
                      "Block header must reframe to 'Timer running' after quick-start. Tree:\n\(app.debugDescription)")

        // Verify exactly ONE "General" project exists by navigating to Work and
        // counting rows whose label is exactly "General". (Two would mean the
        // debounce failed and we double-inserted.)
        let workTab = app.tabBars.buttons["Work"]
        XCTAssertTrue(workTab.waitForExistence(timeout: 3), "Work tab must exist")
        workTab.tap()

        let generalCells = app.staticTexts.matching(NSPredicate(format: "label == 'General'"))
        // Allow the list to populate.
        XCTAssertTrue(app.staticTexts["General"].waitForExistence(timeout: 5),
                      "A 'General' project must appear in Work after quick-start. Tree:\n\(app.debugDescription)")
        XCTAssertEqual(generalCells.count, 1,
                       "Exactly ONE 'General' project must exist (debounce must prevent a double-insert). Found \(generalCells.count). Tree:\n\(app.debugDescription)")
    }

    // MARK: B — adding a client advances Row 1 + enables Row 2

    func test_addingClient_advancesChecklist_andEnablesProjectRow() throws {
        let app = launchedApp()

        // Row 2 "Create a project" starts disabled (no client). XCUITest reports
        // a disabled SwiftData Button as isEnabled == false.
        let createProjectRow = app.buttons["Create a project"]
        XCTAssertTrue(createProjectRow.waitForExistence(timeout: 5),
                      "'Create a project' checklist row must be present. Tree:\n\(app.debugDescription)")
        XCTAssertFalse(createProjectRow.isEnabled,
                       "'Create a project' must be disabled until a client exists")

        // Tap Row 1 "Add a client" → ClientEditorView sheet.
        let addClientRow = app.buttons["Add a client"]
        XCTAssertTrue(addClientRow.waitForExistence(timeout: 3),
                      "'Add a client' checklist row must be present")
        addClientRow.tap()

        // Fill the client name. ClientEditorView's first field placeholder is "Client name".
        let nameField = app.textFields["Client name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 3),
                      "Client name field must appear in the editor. Tree:\n\(app.debugDescription)")
        nameField.tap()
        nameField.typeText("Acme Co")

        // Save the client (ClientEditorView's trailing "Save" button).
        let save = app.buttons["Save"]
        XCTAssertTrue(save.waitForExistence(timeout: 3), "Client editor Save button must exist")
        save.tap()

        // Back on Today: Row 2 must now be enabled (a client exists). The @Query
        // refreshes on the next runloop, so wait dynamically.
        XCTAssertTrue(createProjectRow.waitForExistence(timeout: 5),
                      "'Create a project' row must still be present after returning to Today")
        let enabledPredicate = NSPredicate(format: "isEnabled == true")
        let exp = expectation(for: enabledPredicate, evaluatedWith: createProjectRow)
        let outcome = XCTWaiter().wait(for: [exp], timeout: 5)
        XCTAssertEqual(outcome, .completed,
                       "'Create a project' must enable once a client exists. Tree:\n\(app.debugDescription)")
    }
}
```

> Verify-before-coding: confirm `ClientEditorView`'s save control is labelled "Save" and its name field placeholder is "Client name" (both read from the worktree). The Work-tab "General" count assertion depends on `GetStartedNewProjectSheet`/Work rendering the project name as a `staticText` with the exact label "General" — if Work nests the name differently, adjust the predicate to `label CONTAINS 'General'` scoped to the project list. If the checklist rows aren't reliably addressed by their title strings (SwiftData may compose row labels), add explicit `.accessibilityIdentifier("getStarted.addClient")` / `"getStarted.createProject"` to the two `checklistRow` buttons in Task 2 and match on those instead.

- [ ] **Step 2: Run the UI test suite**

Run:
```bash
xcodebuild -project Billable.xcodeproj -scheme Billable \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BillableUITests/GetStartedChecklistUITests test
```
Expected: `** TEST SUCCEEDED **` — both tests pass (one General after a double-tap; Row 2 enables after adding a client). If `generalCells.count` is 2, the debounce regressed — STOP and fix `startQuickTimer`'s guard before proceeding (this is the load-bearing dedupe assertion).

- [ ] **Step 3: Commit**

```bash
git add App/BillableUITests/GetStartedChecklistUITests.swift
git commit -m "test(ui): get-started checklist reactivity + quick-start double-tap dedupe"
```

---

### Task 10: Regression gate — preserved UI tests + full build

Confirm the existing UI tests this plan must not break still pass, and the whole app builds clean.

- [ ] **Step 1: Preserve `LaunchTaglineUITests` (tagline + onboarding flag)**

Run:
```bash
xcodebuild -project Billable.xcodeproj -scheme Billable \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BillableUITests/LaunchTaglineUITests test
```
Expected: `** TEST SUCCEEDED **` — the "Track hours.\nSend invoices." tagline + `--ui-test-show-onboarding` path are untouched by this plan.

- [ ] **Step 2: Confirm the invoice-preview UI test is unaffected**

Run:
```bash
xcodebuild -project Billable.xcodeproj -scheme Billable \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BillableUITests/InvoicePreviewLineItemEditUITests test
```
Expected: `** TEST SUCCEEDED **` — the §7b generator section is additive and `--seed-marketing` seeds an enriched-enough profile (or the new row simply sits above the form without blocking Preview).

> If the new enrichment row shifts the generator layout enough to break the `boundBy: 0` / label-prefix locators in that test, the FIX is to keep the enrichment row in its own `Section` ABOVE the Client section so existing row indices are preserved — re-confirm and adjust Task 7's placement, not this test.

- [ ] **Step 3: Full app build (Debug)**

Run:
```bash
xcodebuild -project Billable.xcodeproj -scheme Billable \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Full BillableCore suite (pure-logic gate)**

Run: `cd Packages/BillableCore && swift test`
Expected: PASS — `TodayGuidance` tests + all prior tests green.

- [ ] **Step 5: Final NAMED SIMULATOR CHECKPOINT — accessibility + appearance (spec §9)**

Manual on-simulator confirmations on the get-started block + enrichment nudge:
1. **Dynamic Type (largest):** Settings → larger accessibility sizes; the checklist rows + quick-start button wrap without truncation; the enrichment nudge text doesn't clip.
2. **SE-size keyboard occlusion:** on iPhone SE, with the General-rate sheet keyboard up, the rate field stays visible.
3. **VoiceOver:** Row 2 "Create a project" announces the "Add a client first" hint while disabled; the enrichment ✕ announces "Dismiss"; quick-start announces its hint.
4. **Light + dark:** the get-started card, the orange 0-rate row, and the blue enrichment card are legible in both; contrast on secondary text reads ≥ the spec's threshold (measure, don't eyeball).
5. **Touch targets:** the ✕ dismiss is ≥44pt; the quick-start button is ≥44pt tall.

- [ ] **Step 6: Stop — Plan 3 complete**

Plan 3 is done: a pure, exhaustively-tested `TodayGuidance` resolver; a `GetStartedSection` (one PRIMARY quick-start that fetch-or-creates a single General + debounces, a client-gated 2-step checklist, header acknowledgement, 0-rate affordance); the §7b enrichment prompt (primary at invoice creation with conditional copy, secondary session-snoozable Today nudge); all wired so exactly one guidance element shows. Proceed to the controller's consistency review (do NOT commit beyond the per-task commits above; do NOT merge).

---

## Self-review notes (author)

- **Spec coverage (Plan 3 scope):** §7 precedence resolver + one-element-at-a-time (Tasks 1, 6); §7a get-started block — PRIMARY quick-start, 2-row checklist, fetch-or-create one General, debounce, header acknowledgement, 0-rate affordance, bounded probes (Tasks 2–5); §7b enrichment — primary at invoice creation w/ conditional copy + secondary session-snoozable Today nudge ≥44pt dismiss (Tasks 6, 7); §9 accessibility + §16 UI checks (Tasks 9, 10). Out of scope / owned elsewhere: the `firstSetupCompletedAt` writer + `reconcile` wiring (Plan 1 + Plan 2 — consumed here, NOT re-wired); onboarding flow + editor (Plan 2); §13 release-gates + §14 readout (later).
- **Verify-before-coding flags for the implementer:** `ClientEditorView(client:)` + its "Save" label + "Client name" placeholder; `ProjectEditorView(client:project:onSaved:)`; whether `$0.client == nil` / `$0.client != nil` is expressible in `#Predicate` (in-memory fallback noted, matching Plan 1); `BusinessProfile.address`/`hasBankDetails`/`isProfileEnriched` shapes; the exact App-Group container symbol + reset helper in `BillableApp.init`; whether mutating `Project.hourlyRate` needs an explicit `saveOrLog`; the Work-tab rendering of the "General" project name for the dedupe-count assertion (add explicit accessibility identifiers to the checklist rows if title-string matching is flaky).
- **Pure-vs-view discipline:** only `TodayGuidance.resolve` is unit-tested (`swift test`) — it is a pure function of four booleans with an exhaustive 16-case truth table. Every SwiftUI view is build-verified (`xcodebuild build`) + checked at **named simulator checkpoints**; the two behaviors that add real UI-test value (quick-start double-tap dedupe; checklist reactivity) get an XCUITest. No faked unit tests for rendering.
- **Key engineering decisions:** quick-start NEVER stamps first-setup (clientless General → checklist persists, per §7); the General-rate edit can't reuse `ProjectEditorView` (requires a client) so a focused `GeneralRateSheet` edits the rate directly; the enrichment Today nudge snooze is session-only `@State` (no persisted flag) so `isProfileEnriched` stays the durable driver; the generator enrichment prompt is gated on `canSendInvoice` so it never competes with the stronger name-missing section.
- **Open contract (carried from earlier plans):** `BusinessProfileStore.stampFirstSetupIfReached` + `reconcile` are already called at the launch + `scenePhase==.active` seam (Plan 2). This plan relies on that — when a client+project arrive (here, via the checklist; elsewhere via CloudKit/Work/Clients), the get-started block disappears at next foreground because the latch flips. If Plan 2's wiring is absent, the block would never clear — confirm that seam is in place before the final simulator checkpoints.
