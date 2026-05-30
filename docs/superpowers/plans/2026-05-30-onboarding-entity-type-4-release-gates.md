# Onboarding Entity-Type — Plan 4: Release-gates + Polish

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the release-gate config and the success-measurement readout that have no UI-flow dependency: (1) the dev-credit string fix + its UI-test, (2) `PrivacyInfo.xcprivacy` privacy manifests on the app target, the widget extension, and the BillableCore package, (3) the Data-Protection entitlement on both the app and widget, and (4) a `#if DEBUG` Tier-1 activation-metrics readout computed entirely on-device from existing SwiftData. No telemetry, no egress, no `privacy.md` change.

**Architecture:** Config + strings + one pure compute + one DEBUG view. The privacy manifests are plist XML referenced from `project.pbxproj` (app + widget) and from `Package.swift` `resources:` (BillableCore). The Data-Protection entitlement is two `.entitlements` plist edits. The success-metrics logic is a pure, read-only `@MainActor enum ActivationMetrics` in BillableCore that **clones the shipping `BadgeCount` pattern** (static compute over `ModelContext`, unit-tested with `swift test`); the DEBUG surface is a thin SwiftUI `List` readout reusing the existing `--debug-scheduler` Settings gate next to `DiagnosticsView`. Privacy-pure: every metric is derived from `createdAt`/`onboardingCompletedAt`/`Invoice.createdAt`/`Project.client` already in the store.

**Tech Stack:** Swift 6 (strict concurrency), SwiftData, SwiftUI + `@Observable`, Swift Testing (`@Test`/`#expect`) for `BillableCore`, XCUITest for the dev-credit assertion, `xcodebuild` for app/widget config verification.

**Spec:** `docs/superpowers/specs/2026-05-30-onboarding-entity-type-design.md` (§12 dev credit, §13 security/privacy, §14 success metrics, §15 release-gate residual risk).

**Builds on Plan 1 (DONE + committed):** `EntityType`, `BusinessProfile.onboardingCompletedAt`/`firstSetupCompletedAt`/`entityType`, `BusinessProfileStore`. This plan adds NOTHING to those; it only reads `onboardingCompletedAt` + `createdAt` for metrics.

**Independence note:** Plan 4 touches **disjoint files** from Plans 2 (onboarding flow / Today UI) and 3 (editor / invoice-time prompt). The only shared file is `SettingsView.swift` — Task 1 edits line 111 (About → Developer) and Task 5 edits the existing `--debug-scheduler` Debug `Section` (lines 96–104); neither overlaps Plan 3's Business-profile `NavigationLink`. Safe to land before, after, or in parallel with 2/3. (Coordinate the actual commit ordering with the controller per the parallel-session rule.)

**Verification reality (read before starting):**
- `cd Packages/BillableCore && swift test` runs BillableCore unit tests ONLY — use it for `ActivationMetrics` (pure logic). It does **not** build the app, widget, entitlements, or privacy manifests.
- The app/widget config (privacy manifests, entitlements, the DEBUG view compiling) is verified by an **app build**:
  `xcodebuild -project Billable.xcodeproj -scheme Billable -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -configuration Debug build`
- The dev-credit string is verified by the **UI test**:
  `xcodebuild -project Billable.xcodeproj -scheme Billable -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:BillableUITests/SettingsAboutUITests test`
- **App Store submission is the real gate** for the privacy manifest + entitlement. A green `xcodebuild build` proves the plist/entitlement parse and code-sign correctly and the bundle is assembled with them; it does NOT prove Apple accepts the declared reasons. The manual gate is named in Task 6.
- The DEBUG metrics **view rendering** is NOT unit-testable. Its logic lives in `ActivationMetrics` (swift-tested); the view itself is build-verified, with named on-simulator manual checks in Task 5.

---

## File Structure

```
Packages/BillableCore/
  Package.swift                                          (MODIFY — add PrivacyInfo.xcprivacy resource)
  Sources/BillableCore/
    PrivacyInfo.xcprivacy                                (CREATE — package privacy manifest)
    Reporting/
      ActivationMetrics.swift                            (CREATE — pure Tier-1 compute, mirrors BadgeCount)
  Tests/BillableCoreTests/
    ActivationMetricsTests.swift                         (CREATE — full metric matrix, swift test)

App/
  Resources/
    Billable.entitlements                                (MODIFY — + default-data-protection)
    PrivacyInfo.xcprivacy                                (CREATE — app privacy manifest)
  Sources/Features/Settings/
    SettingsView.swift                                   (MODIFY — dev-credit string @ L111; add metrics link in the --debug-scheduler Section)
    ActivationMetricsView.swift                          (CREATE — #if DEBUG readout)
  BillableUITests/
    SettingsAboutUITests.swift                           (MODIFY — assertion text)

Widgets/
  Resources/
    BillableWidgets.entitlements                         (MODIFY — + default-data-protection)
    PrivacyInfo.xcprivacy                                (CREATE — widget privacy manifest)

Billable.xcodeproj/
  project.pbxproj                                        (MODIFY — register both PrivacyInfo.xcprivacy in Resources build phases)
```

Task order is dependency-first: dev-credit fix (trivial, fast UI-test loop) → metrics compute (pure TDD) → metrics view → entitlements → privacy manifests → final gate. Each task ends in a commit.

---

### Task 1: Dev-credit string fix (§12)

Spec §12: `SettingsView` Developer attribution → drop the "Cadence by" prefix so it reads `"Elden Studios Company"`. Update the UI-test assertion that locks the old string.

**Files:**
- Modify: `App/Sources/Features/Settings/SettingsView.swift`
- Test (modify): `App/BillableUITests/SettingsAboutUITests.swift`

- [ ] **Step 1: Update the failing UI-test assertion FIRST (red)**

In `App/BillableUITests/SettingsAboutUITests.swift`, replace the Developer-attribution assertion block (currently lines 29–32) with the new expected string:

```swift
        XCTAssertTrue(
            app.staticTexts["Elden Studios Company"].exists,
            "About section must contain Developer attribution 'Elden Studios Company'"
        )
```

- [ ] **Step 2: Run the UI test to verify it FAILS against the un-changed source**

Run:
```bash
xcodebuild -project Billable.xcodeproj -scheme Billable \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BillableUITests/SettingsAboutUITests test
```
Expected: **FAIL** — `SettingsView` still renders `"Cadence by Elden Studios Company"`, so `app.staticTexts["Elden Studios Company"].exists` is `false` and the assertion fails with "About section must contain Developer attribution 'Elden Studios Company'".

- [ ] **Step 3: Fix the source string**

In `App/Sources/Features/Settings/SettingsView.swift`, change the Developer attribution `Text` (line 111):

```swift
                        Text("Elden Studios Company")
```

(Leave the surrounding `HStack`/`Spacer`/`.foregroundStyle(.secondary)`/`.multilineTextAlignment(.trailing)` exactly as-is.)

- [ ] **Step 4: Run the UI test to verify it PASSES**

Run:
```bash
xcodebuild -project Billable.xcodeproj -scheme Billable \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BillableUITests/SettingsAboutUITests test
```
Expected: **PASS** — `test_settingsAbout_showsDeveloperAttribution` passes (Version row, the new "Elden Studios Company" attribution, and the contact email are all found).

- [ ] **Step 5: Commit**

```bash
git add App/Sources/Features/Settings/SettingsView.swift App/BillableUITests/SettingsAboutUITests.swift
git commit -m "fix(settings): dev credit reads 'Elden Studios Company' (drop 'Cadence by' prefix)"
```

---

### Task 2: `ActivationMetrics` — pure Tier-1 compute (§14, the TDD task)

Spec §14: surface activation Tier-1 on-device only (no transmission). This task is the **pure, unit-tested** computation; Task 5 renders it. It mirrors the shipping `BadgeCount` pattern (`@MainActor public enum`, `static func compute(context:now:) -> …`, authoritative re-derivation from SwiftData — never persisted, never sent).

Metrics computed (all from data already in the store):
- **entity-type split** — count of `BusinessProfile`s by `entityType` (canonical profile is usually one; report the raw split for honesty across un-reconciled multi-device states).
- **activation-reached** — does at least one `TimeEntry` exist (first timer = activation, per §14).
- **time-to-first-timer** — `earliest TimeEntry.createdAt − onboardingCompletedAt` (nil if either side missing).
- **time-to-first-project** — `earliest non-archived Project.createdAt − onboardingCompletedAt`.
- **time-to-first-invoice** — `earliest Invoice.createdAt − onboardingCompletedAt` (no `firstInvoiceAt` latch needed — derivable, per §14).
- **HEADLINE quick-start-vs-checklist split** — on the project of the **earliest** `TimeEntry`, is `project.client == nil`? `nil` ⇒ quick-start ("General"); non-nil ⇒ checklist (client-linked). This is the direct answer to "did the hybrid bet pay off" (§14).

**Files:**
- Create: `Packages/BillableCore/Sources/BillableCore/Reporting/ActivationMetrics.swift`
- Test: `Packages/BillableCore/Tests/BillableCoreTests/ActivationMetricsTests.swift`

- [ ] **Step 1: Write the failing tests (the metric matrix)**

```swift
import Testing
import Foundation
import SwiftData
@testable import BillableCore

@MainActor
@Suite("ActivationMetrics")
struct ActivationMetricsTests {
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: BillableModelContainer.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private let onboarded = Date(timeIntervalSince1970: 1_000)

    @Test("empty store: zeros and nils, not activated")
    func emptyStore() throws {
        let ctx = try makeContext()
        let m = ActivationMetrics.compute(in: ctx)
        #expect(m.freelancerCount == 0)
        #expect(m.organizationCount == 0)
        #expect(m.activationReached == false)
        #expect(m.timeToFirstTimer == nil)
        #expect(m.timeToFirstProject == nil)
        #expect(m.timeToFirstInvoice == nil)
        #expect(m.firstTimerKind == .none)
    }

    @Test("entity-type split counts profiles by entityType")
    func entitySplit() throws {
        let ctx = try makeContext()
        let f = BusinessProfile(name: "Solo"); f.entityType = .freelancer
        let o = BusinessProfile(name: "Acme"); o.entityType = .organization
        ctx.insert(f); ctx.insert(o); try ctx.save()
        let m = ActivationMetrics.compute(in: ctx)
        #expect(m.freelancerCount == 1)
        #expect(m.organizationCount == 1)
    }

    @Test("activation-reached flips once any TimeEntry exists")
    func activation() throws {
        let ctx = try makeContext()
        let p = BusinessProfile(name: "X"); p.onboardingCompletedAt = onboarded
        ctx.insert(p)
        #expect(ActivationMetrics.compute(in: ctx).activationReached == false)
        let proj = Project(name: "General", hourlyRate: 0, client: nil)
        ctx.insert(proj)
        ctx.insert(TimeEntry(startedAt: onboarded, project: proj,
                             createdAt: onboarded.addingTimeInterval(60)))
        try ctx.save()
        #expect(ActivationMetrics.compute(in: ctx).activationReached == true)
    }

    @Test("time-to-first-* measured from onboardingCompletedAt to earliest createdAt")
    func timeDeltas() throws {
        let ctx = try makeContext()
        let p = BusinessProfile(name: "X"); p.onboardingCompletedAt = onboarded
        ctx.insert(p)
        let client = Client(name: "Acme", color: .blue); ctx.insert(client)
        let proj = Project(name: "Site", hourlyRate: 100, client: client,
                           createdAt: onboarded.addingTimeInterval(120))
        ctx.insert(proj)
        ctx.insert(TimeEntry(startedAt: onboarded, project: proj,
                             createdAt: onboarded.addingTimeInterval(300)))
        let inv = Invoice(number: "0001", createdAt: onboarded.addingTimeInterval(600))
        ctx.insert(inv)
        try ctx.save()
        let m = ActivationMetrics.compute(in: ctx)
        #expect(m.timeToFirstTimer == 300)
        #expect(m.timeToFirstProject == 120)
        #expect(m.timeToFirstInvoice == 600)
    }

    @Test("deltas are nil when onboardingCompletedAt is unset")
    func nilWhenNotOnboarded() throws {
        let ctx = try makeContext()
        let p = BusinessProfile(name: "X")           // onboardingCompletedAt == nil
        ctx.insert(p)
        let proj = Project(name: "General", hourlyRate: 0, client: nil)
        ctx.insert(proj)
        ctx.insert(TimeEntry(startedAt: .now, project: proj))
        try ctx.save()
        let m = ActivationMetrics.compute(in: ctx)
        #expect(m.timeToFirstTimer == nil)
        #expect(m.timeToFirstProject == nil)
    }

    @Test("HEADLINE: earliest-entry project client == nil ⇒ quickStart")
    func headlineQuickStart() throws {
        let ctx = try makeContext()
        let p = BusinessProfile(name: "X"); p.onboardingCompletedAt = onboarded
        ctx.insert(p)
        let general = Project(name: "General", hourlyRate: 0, client: nil)
        ctx.insert(general)
        ctx.insert(TimeEntry(startedAt: onboarded, project: general,
                             createdAt: onboarded.addingTimeInterval(30)))
        try ctx.save()
        #expect(ActivationMetrics.compute(in: ctx).firstTimerKind == .quickStart)
    }

    @Test("HEADLINE: earliest-entry project has a client ⇒ checklist")
    func headlineChecklist() throws {
        let ctx = try makeContext()
        let p = BusinessProfile(name: "X"); p.onboardingCompletedAt = onboarded
        ctx.insert(p)
        let client = Client(name: "Acme", color: .blue); ctx.insert(client)
        let linked = Project(name: "Site", hourlyRate: 100, client: client)
        ctx.insert(linked)
        ctx.insert(TimeEntry(startedAt: onboarded, project: linked,
                             createdAt: onboarded.addingTimeInterval(45)))
        try ctx.save()
        #expect(ActivationMetrics.compute(in: ctx).firstTimerKind == .checklist)
    }

    @Test("HEADLINE uses the EARLIEST entry, not insertion order")
    func headlineEarliestWins() throws {
        let ctx = try makeContext()
        let p = BusinessProfile(name: "X"); p.onboardingCompletedAt = onboarded
        ctx.insert(p)
        let client = Client(name: "Acme", color: .blue); ctx.insert(client)
        let linked = Project(name: "Site", hourlyRate: 100, client: client)
        let general = Project(name: "General", hourlyRate: 0, client: nil)
        ctx.insert(linked); ctx.insert(general)
        // Insert the client-linked entry FIRST but with a LATER createdAt …
        ctx.insert(TimeEntry(startedAt: onboarded, project: linked,
                             createdAt: onboarded.addingTimeInterval(500)))
        // … and the quick-start entry SECOND with an EARLIER createdAt.
        ctx.insert(TimeEntry(startedAt: onboarded, project: general,
                             createdAt: onboarded.addingTimeInterval(100)))
        try ctx.save()
        #expect(ActivationMetrics.compute(in: ctx).firstTimerKind == .quickStart) // earliest-by-createdAt
    }
}
```

> Before running, confirm constructor signatures against the models (verified at authoring time): `BusinessProfile(name:)`, `Client(name:color:)`, `Project(name:hourlyRate:isBillable:isArchived:notes:client:createdAt:updatedAt:completedAt:)`, `TimeEntry(startedAt:endedAt:notes:isManual:project:accumulatedSeconds:activeSegmentStartedAt:createdAt:updatedAt:)`, `Invoice(number:…createdAt:)`. The `Invoice` initializer has many params — call only `number:` + `createdAt:` and rely on its other defaults; if `number:` is not the first label, adjust to the real `Invoice.init` (open `Models/Invoice.swift`) — the only fields these tests touch are `createdAt`, so use whatever minimal init compiles.

- [ ] **Step 2: Run the tests to verify they FAIL**

Run: `cd Packages/BillableCore && swift test --filter ActivationMetricsTests`
Expected: **FAIL** — `cannot find 'ActivationMetrics' in scope`.

- [ ] **Step 3: Write the implementation**

`Packages/BillableCore/Sources/BillableCore/Reporting/ActivationMetrics.swift`:

```swift
import Foundation
import SwiftData

/// On-device-only Tier-1 activation readout (spec §14). PRIVACY-PURE: every value is
/// re-derived from authoritative SwiftData on demand — nothing is persisted and nothing
/// is transmitted (no analytics, no `privacy.md` change). Surfaced only behind a `#if DEBUG`
/// diagnostics row gated by `--debug-scheduler` (see `ActivationMetricsView`).
///
/// Mirrors the shipping `BadgeCount` shape: a `@MainActor` enum with a single static
/// `compute(in:)` that reads the store and returns a value type.
@MainActor
public enum ActivationMetrics {

    /// Which first-run path produced the user's earliest timed entry — the headline
    /// "did the hybrid bet pay off" signal (spec §14).
    public enum FirstTimerKind: String, Sendable {
        case none        // no TimeEntry yet
        case quickStart  // earliest entry's project has no client ("General")
        case checklist   // earliest entry's project is client-linked
    }

    /// Immutable snapshot. `TimeInterval?` deltas are seconds from `onboardingCompletedAt`
    /// to the earliest relevant `createdAt`; nil when either endpoint is missing.
    public struct Snapshot: Sendable, Equatable {
        public var freelancerCount: Int
        public var organizationCount: Int
        public var activationReached: Bool
        public var timeToFirstTimer: TimeInterval?
        public var timeToFirstProject: TimeInterval?
        public var timeToFirstInvoice: TimeInterval?
        public var firstTimerKind: FirstTimerKind
    }

    public static func compute(in context: ModelContext) -> Snapshot {
        let profiles = (try? context.fetch(FetchDescriptor<BusinessProfile>())) ?? []
        let freelancers = profiles.filter { $0.entityType == .freelancer }.count
        let organizations = profiles.filter { $0.entityType == .organization }.count

        // Canonical onboarding instant = earliest non-nil stamp across profiles.
        let onboardedAt = profiles.compactMap(\.onboardingCompletedAt).min()

        let entries = (try? context.fetch(FetchDescriptor<TimeEntry>())) ?? []
        let earliestEntry = entries.min { $0.createdAt < $1.createdAt }

        // Earliest ACTIVE project (matches the §7 "non-archived project" activation notion).
        let activeProjects = (try? context.fetch(
            FetchDescriptor<Project>(predicate: #Predicate { !$0.isArchived })
        )) ?? []
        let earliestProjectAt = activeProjects.map(\.createdAt).min()

        let invoices = (try? context.fetch(FetchDescriptor<Invoice>())) ?? []
        let earliestInvoiceAt = invoices.map(\.createdAt).min()

        func delta(_ end: Date?) -> TimeInterval? {
            guard let start = onboardedAt, let end else { return nil }
            return end.timeIntervalSince(start)
        }

        let kind: FirstTimerKind
        if let earliestEntry {
            kind = earliestEntry.project?.client == nil ? .quickStart : .checklist
        } else {
            kind = .none
        }

        return Snapshot(
            freelancerCount: freelancers,
            organizationCount: organizations,
            activationReached: earliestEntry != nil,
            timeToFirstTimer: delta(earliestEntry?.createdAt),
            timeToFirstProject: delta(earliestProjectAt),
            timeToFirstInvoice: delta(earliestInvoiceAt),
            firstTimerKind: kind
        )
    }
}
```

> Convenience flat accessors used by the tests (`m.freelancerCount`, etc.) read through to `Snapshot`'s properties because `compute` returns `Snapshot` directly — the tests bind `let m = ActivationMetrics.compute(in: ctx)` and read `m.freelancerCount`, which is the `Snapshot` field. No extra surface needed.
>
> If `#Predicate { !$0.isArchived }` fails to compile against `Project` (it won't — `isArchived` is a stored `Bool`), fall back to fetching all `Project` and filtering `!$0.isArchived` in memory; the store is small.

- [ ] **Step 4: Run the tests to verify they PASS**

Run: `cd Packages/BillableCore && swift test --filter ActivationMetricsTests`
Expected: **PASS** (8 tests).

- [ ] **Step 5: Run the FULL BillableCore suite (no regressions)**

Run: `cd Packages/BillableCore && swift test`
Expected: **PASS** — 279 prior tests + 8 new = 287, zero failures. (`ActivationMetrics` is additive read-only code; it touches no existing type.)

- [ ] **Step 6: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Reporting/ActivationMetrics.swift Packages/BillableCore/Tests/BillableCoreTests/ActivationMetricsTests.swift
git commit -m "feat(core): ActivationMetrics — on-device Tier-1 activation readout (no telemetry)"
```

---

### Task 3: `ActivationMetricsView` — `#if DEBUG` readout (§14)

Spec §14: surface Tier-1 via a `#if DEBUG` diagnostics row (no UI polish, no persistence, no egress), headlined by the quick-start-vs-checklist split. Reuse the existing `--debug-scheduler` Settings gate (sibling to `DiagnosticsView`). The whole file is wrapped in `#if DEBUG` so it cannot ship in a Release binary.

**Files:**
- Create: `App/Sources/Features/Settings/ActivationMetricsView.swift`
- Modify: `App/Sources/Features/Settings/SettingsView.swift` (add the link in the existing Debug `Section`)

This task is a SwiftUI view — **not unit-testable**. The verify step is an app build; named on-simulator manual checks follow.

- [ ] **Step 1: Create the view (COMPLETE code)**

`App/Sources/Features/Settings/ActivationMetricsView.swift`:

```swift
#if DEBUG
import SwiftUI
import SwiftData
import BillableCore

/// Internal QA readout of Tier-1 activation metrics (spec §14). DEBUG-only, computed
/// on-device from existing SwiftData via `ActivationMetrics` — nothing persisted, nothing
/// transmitted. Gated by `--debug-scheduler` in `SettingsView`, sibling to `DiagnosticsView`.
struct ActivationMetricsView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var snapshot: ActivationMetrics.Snapshot?

    var body: some View {
        List {
            if let s = snapshot {
                Section {
                    LabeledContent("First-timer path", value: s.firstTimerKind.rawValue)
                    LabeledContent("Activation reached", value: s.activationReached ? "yes" : "no")
                } header: { Text("Headline") } footer: {
                    Text("quickStart = first timed entry on a clientless \u{201C}General\u{201D} project; checklist = client-linked. The direct read on the hybrid-onboarding bet.")
                }

                Section {
                    LabeledContent("Freelancer profiles", value: "\(s.freelancerCount)")
                    LabeledContent("Organization profiles", value: "\(s.organizationCount)")
                } header: { Text("Entity-type split") }

                Section {
                    LabeledContent("To first timer", value: format(s.timeToFirstTimer))
                    LabeledContent("To first project", value: format(s.timeToFirstProject))
                    LabeledContent("To first invoice", value: format(s.timeToFirstInvoice))
                } header: { Text("Time from onboarding") } footer: {
                    Text("Elapsed from onboardingCompletedAt to the earliest createdAt. \u{201C}\u{2014}\u{201D} means the milestone or the onboarding stamp is absent.")
                }
            } else {
                Text("Computing\u{2026}").font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Activation")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { snapshot = ActivationMetrics.compute(in: modelContext) }
    }

    /// Compact human duration; "—" for nil.
    private func format(_ interval: TimeInterval?) -> String {
        guard let interval else { return "\u{2014}" }
        let f = DateComponentsFormatter()
        f.allowedUnits = [.day, .hour, .minute, .second]
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        return f.string(from: interval) ?? "\(Int(interval))s"
    }
}
#endif
```

> `ActivationMetrics.compute` is `@MainActor`; `onAppear` runs on the main actor, so the call is legal with no `Task`/`await`. The `Snapshot` is `Equatable`/`Sendable` (from Task 2) so holding it in `@State` is clean.

- [ ] **Step 2: Add the DEBUG link in `SettingsView`'s existing Debug section**

In `App/Sources/Features/Settings/SettingsView.swift`, the `--debug-scheduler` block currently is:

```swift
                if CommandLine.arguments.contains("--debug-scheduler") {
                    Section {
                        NavigationLink {
                            DiagnosticsView()
                        } label: {
                            Label("Diagnostics", systemImage: "stethoscope")
                        }
                    } header: { Text("Debug") }
                }
```

Add a second `NavigationLink` inside the SAME `Section`, wrapped in `#if DEBUG` (the metrics view only exists in DEBUG; the launch flag alone is not enough — a Release build with the flag must still compile):

```swift
                if CommandLine.arguments.contains("--debug-scheduler") {
                    Section {
                        NavigationLink {
                            DiagnosticsView()
                        } label: {
                            Label("Diagnostics", systemImage: "stethoscope")
                        }
                        #if DEBUG
                        NavigationLink {
                            ActivationMetricsView()
                        } label: {
                            Label("Activation metrics", systemImage: "chart.bar.xaxis")
                        }
                        #endif
                    } header: { Text("Debug") }
                }
```

- [ ] **Step 3: Build the app to verify it compiles (DEBUG)**

Run:
```bash
xcodebuild -project Billable.xcodeproj -scheme Billable \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -configuration Debug build
```
Expected: **BUILD SUCCEEDED** — `ActivationMetricsView` compiles, the new `NavigationLink` resolves, `ActivationMetrics.Snapshot`/`FirstTimerKind` are visible from the app target via `import BillableCore`.

- [ ] **Step 4: Verify it does NOT leak into Release (config guard)**

Run:
```bash
xcodebuild -project Billable.xcodeproj -scheme Billable \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -configuration Release build
```
Expected: **BUILD SUCCEEDED** — the `#if DEBUG` block is excluded from Release; `SettingsView` still compiles (the inner `#if DEBUG` collapses to just the Diagnostics link). This proves the metrics surface cannot ship.

- [ ] **Step 5: Manual on-simulator verification (named — not automated)**

These confirm rendering/behavior the build can't:
  1. Launch with `--debug-scheduler --seed-marketing` → Settings → "Debug" section shows **both** "Diagnostics" and "Activation metrics" rows.
  2. Tap "Activation metrics" → three sections render (Headline / Entity-type split / Time from onboarding); no crash; "First-timer path" shows one of none/quickStart/checklist.
  3. Launch a quick-start "General" timer from Today (Plan 2), return here → "First-timer path" reads `quickStart`. (If Plan 2 isn't landed yet, seed an entry on a clientless project and confirm `quickStart`; this dependency is noted, not blocking — the logic is already proven by Task 2.)

- [ ] **Step 6: Commit**

```bash
git add App/Sources/Features/Settings/ActivationMetricsView.swift App/Sources/Features/Settings/SettingsView.swift
git commit -m "feat(settings): DEBUG ActivationMetricsView readout behind --debug-scheduler (no egress)"
```

---

### Task 4: Data-Protection entitlement on app + widget (§13)

Spec §13: set `com.apple.developer.default-data-protection = NSFileProtectionCompleteUntilFirstUserAuthentication` on **both** the app and the widget. **Cannot use `…Complete`** — the widget reads the App-Group SwiftData store while the device is locked, and `Complete` makes files unreadable while locked, which would break widget timeline reloads. `…CompleteUntilFirstUserAuthentication` keeps data encrypted at rest but readable after the first unlock following boot, which is the strongest level compatible with a locked-screen widget reading a shared store.

**Files:**
- Modify: `App/Resources/Billable.entitlements`
- Modify: `Widgets/Resources/BillableWidgets.entitlements`

- [ ] **Step 1: Add the key to the app entitlements**

`App/Resources/Billable.entitlements` currently ends with the `aps-environment` pair before `</dict>`. Add the data-protection key immediately after the `aps-environment` `<string>development</string>` line. Diff:

```diff
     <key>aps-environment</key>
     <string>development</string>
+    <key>com.apple.developer.default-data-protection</key>
+    <string>NSFileProtectionCompleteUntilFirstUserAuthentication</string>
 </dict>
 </plist>
```

Resulting `App/Resources/Billable.entitlements` (full file, for certainty):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.com.eldenstudios.billable</string>
    </array>
    <key>com.apple.developer.icloud-container-identifiers</key>
    <array>
        <string>iCloud.com.eldenstudios.billable</string>
    </array>
    <key>com.apple.developer.icloud-services</key>
    <array>
        <string>CloudKit</string>
    </array>
    <key>com.apple.developer.ubiquity-container-identifiers</key>
    <array>
        <string>iCloud.com.eldenstudios.billable</string>
    </array>
    <key>aps-environment</key>
    <string>development</string>
    <key>com.apple.developer.default-data-protection</key>
    <string>NSFileProtectionCompleteUntilFirstUserAuthentication</string>
</dict>
</plist>
```

- [ ] **Step 2: Add the same key to the widget entitlements**

`Widgets/Resources/BillableWidgets.entitlements` (full file after edit):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.com.eldenstudios.billable</string>
    </array>
    <key>com.apple.developer.default-data-protection</key>
    <string>NSFileProtectionCompleteUntilFirstUserAuthentication</string>
</dict>
</plist>
```

> **Why both, and why this level — document inline in the commit message (below).** App and widget share `group.com.eldenstudios.billable`; the SwiftData store lives in that container. The widget's timeline provider can run while the device is locked, so the shared store's files must remain readable post-first-unlock — hence `…CompleteUntilFirstUserAuthentication` on **both** targets (mismatched levels on a shared container risk EPERM reads on the widget side). `…Complete` would yield "file is locked"/`EPERM` reads in the widget after the screen locks.

- [ ] **Step 3: Build the app + widget to verify the entitlements parse and code-sign**

Run:
```bash
xcodebuild -project Billable.xcodeproj -scheme Billable \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -configuration Debug build
```
Expected: **BUILD SUCCEEDED** — the `Billable` scheme builds the app **and** the `BillableWidgets` extension; a malformed entitlements plist or an unrecognized key would fail code-signing/processing. (Simulator builds don't enforce the data-protection class at runtime, but they DO validate that the entitlement plist is well-formed and the key is accepted by the toolchain — that's the build-time gate this step covers.)

- [ ] **Step 4: Commit**

```bash
git add App/Resources/Billable.entitlements Widgets/Resources/BillableWidgets.entitlements
git commit -m "chore(security): default-data-protection CompleteUntilFirstUserAuthentication (app + widget)

Widget reads the App-Group SwiftData store while the device is locked, so full
NSFileProtectionComplete would break locked-screen timeline reloads. UntilFirstUserAuthentication
is the strongest level compatible with a shared-container widget; applied to both targets to keep
the protection class consistent across the group."
```

---

### Task 5: `PrivacyInfo.xcprivacy` privacy manifests (§13)

Spec §13: add `PrivacyInfo.xcprivacy` to the app, the widget, and the BillableCore bundle. Declare `NSPrivacyTracking=false`, **no** tracking domains, required-reason API codes for `UserDefaults` + file-timestamp, and `NSPrivacyCollectedDataTypes` for name/address/email/phone/payment/other-financial with `Linked=false` + `Tracking=false`.

Required-reason API codes used (Apple's official values):
- **`NSPrivacyAccessedAPICategoryUserDefaults`** → reason **`CA92.1`** ("access info from same app, per documentation" — the onboarding fast-path flag + app settings live in the app's own `UserDefaults`).
- **`NSPrivacyAccessedAPICategoryFileTimestamp`** → reason **`C617.1`** ("timestamps of files inside the app container, for the app itself" — SwiftData store files + the app's own document timestamps).

Collected data types (all `Linked=false`, `Tracking=false`, purpose **App Functionality** — issuer details for invoicing, stored locally + mirrored to the user's **own** private CloudKit DB, never to us):
- `NSPrivacyCollectedDataTypeName`, `…EmailAddress`, `…PhoneNumber`, `…PhysicalAddress`, `…PaymentInfo`, `…OtherFinancialInfo`.

**App + widget** manifests are referenced from `project.pbxproj` (each as a `PBXFileReference` + `PBXBuildFile` in that target's `Resources` build phase). **BillableCore** (source-distributed SPM, statically linked into the app) carries its manifest via `Package.swift` `resources: [.copy("PrivacyInfo.xcprivacy")]`. Note: for a statically-linked source package Apple aggregates the package manifest into the app's privacy report at submission; shipping it in the package is still the documented practice, hence "(if applicable)" in the spec — we include it.

**Files:**
- Create: `App/Resources/PrivacyInfo.xcprivacy`
- Create: `Widgets/Resources/PrivacyInfo.xcprivacy`
- Create: `Packages/BillableCore/Sources/BillableCore/PrivacyInfo.xcprivacy`
- Modify: `Packages/BillableCore/Package.swift` (declare the resource)
- Modify: `Billable.xcodeproj/project.pbxproj` (register the app + widget manifests in their Resources build phases)

- [ ] **Step 1: Create the app manifest (exact XML)**

`App/Resources/PrivacyInfo.xcprivacy`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>NSPrivacyTracking</key>
    <false/>
    <key>NSPrivacyTrackingDomains</key>
    <array/>
    <key>NSPrivacyAccessedAPITypes</key>
    <array>
        <dict>
            <key>NSPrivacyAccessedAPIType</key>
            <string>NSPrivacyAccessedAPICategoryUserDefaults</string>
            <key>NSPrivacyAccessedAPITypeReasons</key>
            <array>
                <string>CA92.1</string>
            </array>
        </dict>
        <dict>
            <key>NSPrivacyAccessedAPIType</key>
            <string>NSPrivacyAccessedAPICategoryFileTimestamp</string>
            <key>NSPrivacyAccessedAPITypeReasons</key>
            <array>
                <string>C617.1</string>
            </array>
        </dict>
    </array>
    <key>NSPrivacyCollectedDataTypes</key>
    <array>
        <dict>
            <key>NSPrivacyCollectedDataType</key>
            <string>NSPrivacyCollectedDataTypeName</string>
            <key>NSPrivacyCollectedDataTypeLinked</key>
            <false/>
            <key>NSPrivacyCollectedDataTypeTracking</key>
            <false/>
            <key>NSPrivacyCollectedDataTypePurposes</key>
            <array>
                <string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
            </array>
        </dict>
        <dict>
            <key>NSPrivacyCollectedDataType</key>
            <string>NSPrivacyCollectedDataTypeEmailAddress</string>
            <key>NSPrivacyCollectedDataTypeLinked</key>
            <false/>
            <key>NSPrivacyCollectedDataTypeTracking</key>
            <false/>
            <key>NSPrivacyCollectedDataTypePurposes</key>
            <array>
                <string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
            </array>
        </dict>
        <dict>
            <key>NSPrivacyCollectedDataType</key>
            <string>NSPrivacyCollectedDataTypePhoneNumber</string>
            <key>NSPrivacyCollectedDataTypeLinked</key>
            <false/>
            <key>NSPrivacyCollectedDataTypeTracking</key>
            <false/>
            <key>NSPrivacyCollectedDataTypePurposes</key>
            <array>
                <string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
            </array>
        </dict>
        <dict>
            <key>NSPrivacyCollectedDataType</key>
            <string>NSPrivacyCollectedDataTypePhysicalAddress</string>
            <key>NSPrivacyCollectedDataTypeLinked</key>
            <false/>
            <key>NSPrivacyCollectedDataTypeTracking</key>
            <false/>
            <key>NSPrivacyCollectedDataTypePurposes</key>
            <array>
                <string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
            </array>
        </dict>
        <dict>
            <key>NSPrivacyCollectedDataType</key>
            <string>NSPrivacyCollectedDataTypePaymentInfo</string>
            <key>NSPrivacyCollectedDataTypeLinked</key>
            <false/>
            <key>NSPrivacyCollectedDataTypeTracking</key>
            <false/>
            <key>NSPrivacyCollectedDataTypePurposes</key>
            <array>
                <string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
            </array>
        </dict>
        <dict>
            <key>NSPrivacyCollectedDataType</key>
            <string>NSPrivacyCollectedDataTypeOtherFinancialInfo</string>
            <key>NSPrivacyCollectedDataTypeLinked</key>
            <false/>
            <key>NSPrivacyCollectedDataTypeTracking</key>
            <false/>
            <key>NSPrivacyCollectedDataTypePurposes</key>
            <array>
                <string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
```

> Data-type rationale (for the App Store privacy questionnaire, which must match): **Name/Email/Phone/PhysicalAddress** = the issuer's business profile + client contacts; **PaymentInfo/OtherFinancialInfo** = bank beneficiary/IBAN/SWIFT + invoice amounts. All entered by the user, persisted locally and mirrored only to the user's **own** iCloud private DB — `Linked=false` (not linked by us to an identity we hold), `Tracking=false`, purpose App Functionality. No "Contacts" type is declared because the app never reads the system address book.

- [ ] **Step 2: Create the widget manifest (exact XML)**

`Widgets/Resources/PrivacyInfo.xcprivacy` — the widget reads the shared store (file timestamps) and `UserDefaults` (App-Group), and renders the same profile-derived data. Use the **identical** content as the app manifest in Step 1 (same two API-reason entries, same six collected types). Copy the Step-1 XML verbatim into this file.

> Honest scope note (tracked follow-up §13, NOT this PR): today the widget replicates the full profile into widget scope; the plan to mirror only `currencyCode` would later let the widget drop the financial data types. Until then the widget declares the same types the app does, which is the truthful state.

- [ ] **Step 3: Create the BillableCore manifest (exact XML)**

`Packages/BillableCore/Sources/BillableCore/PrivacyInfo.xcprivacy` — the package is the layer that touches `UserDefaults` + SwiftData file timestamps; it collects the same data **types** via its models. Use the **identical** content as Step 1. Copy the Step-1 XML verbatim into this file.

- [ ] **Step 4: Declare the resource in `Package.swift`**

In `Packages/BillableCore/Package.swift`, add a `resources:` argument to the `BillableCore` target so SPM bundles the manifest. Change:

```swift
        .target(
            name: "BillableCore",
            path: "Sources/BillableCore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
```

to:

```swift
        .target(
            name: "BillableCore",
            path: "Sources/BillableCore",
            resources: [
                .copy("PrivacyInfo.xcprivacy"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
```

- [ ] **Step 5: Verify the package still resolves + tests pass with the bundled resource**

Run: `cd Packages/BillableCore && swift build`
Expected: **Compiling / Build complete** — SPM generates a resource bundle for `BillableCore` containing `PrivacyInfo.xcprivacy`; no "found 1 file(s) which are unhandled" warning for the manifest (the `.copy` rule claims it).

Run: `cd Packages/BillableCore && swift test`
Expected: **PASS** — 287 tests (declaring a resource does not affect test behavior).

- [ ] **Step 6: Register the app + widget manifests in `project.pbxproj`**

`xcodebuild` only copies files listed in a target's `Resources` build phase, so each new manifest needs three wiring edits. Mirror exactly how `Billable.storekit` is wired (it is already a Resources-build-phase member of the app target). For each of the two manifests, add:

  **(a) a `PBXFileReference`** in the `/* Begin PBXFileReference section */` block. Match the `Billable.entitlements` reference style. Add near the other Resources file refs:

  ```
  /* App manifest */
  AAAA0001AAAA0001AAAA0001 /* PrivacyInfo.xcprivacy */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = PrivacyInfo.xcprivacy; sourceTree = "<group>"; };
  /* Widget manifest */
  BBBB0001BBBB0001BBBB0001 /* PrivacyInfo.xcprivacy */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = PrivacyInfo.xcprivacy; sourceTree = "<group>"; };
  ```

  **(b) a `PBXBuildFile`** in the `/* Begin PBXBuildFile section */` block (the thing that puts the ref into a build phase). Match the `Billable.storekit in Resources` build-file line:

  ```
  AAAA0002AAAA0002AAAA0002 /* PrivacyInfo.xcprivacy in Resources */ = {isa = PBXBuildFile; fileRef = AAAA0001AAAA0001AAAA0001 /* PrivacyInfo.xcprivacy */; };
  BBBB0002BBBB0002BBBB0002 /* PrivacyInfo.xcprivacy in Resources */ = {isa = PBXBuildFile; fileRef = BBBB0001BBBB0001BBBB0001 /* PrivacyInfo.xcprivacy */; };
  ```

  **(c) add each `PBXBuildFile` to the right `PBXResourcesBuildPhase` `files` list.** The app's Resources phase is `6652CD1A12232CC6ADD336BF` (contains `Billable.storekit in Resources`); the widget's is `C252C1A25605C8315C0DC348` (contains the widget `Assets.xcassets in Resources`). Add:

  ```diff
   /* app Resources phase 6652CD1A... */
   files = (
       00137A9F89BDC48EBE9DC927 /* Assets.xcassets in Resources */,
       CD8FFD9FDBE064528DE473F3 /* Billable.storekit in Resources */,
  +    AAAA0002AAAA0002AAAA0002 /* PrivacyInfo.xcprivacy in Resources */,
   );
  ```
  ```diff
   /* widget Resources phase C252C1A2... */
   files = (
       F8B9ABD63F4371F7F28F6E3B /* Assets.xcassets in Resources */,
  +    BBBB0002BBBB0002BBBB0002 /* PrivacyInfo.xcprivacy in Resources */,
   );
  ```

  **(d) (recommended, for Xcode navigator hygiene)** add each file ref to its group's `children`: the app manifest into the app Resources group `6352BBD570F513F934FCA091` (alongside `Billable.entitlements`/`Billable.storekit`), the widget manifest into the widget Resources group that lists `BillableWidgets.entitlements` (`11AC163D...`). This is optional for the build but keeps the project tree truthful.

  > The 24-char IDs above are PLACEHOLDERS — generate fresh unique 24-hex-character IDs (Xcode uses uppercase hex). They must be unique within the file; pick any unused values and keep the `fileRef`↔ref pairing consistent. If hand-editing the pbxproj is error-prone, the equivalent is: open `Billable.xcodeproj` in Xcode, drag each `PrivacyInfo.xcprivacy` into the matching target's "Copy Bundle Resources" build phase, and let Xcode assign the IDs. Either path must end with **both** manifests in **both** targets' Resources phases.

- [ ] **Step 7: Build the app + widget to verify both manifests are bundled**

Run:
```bash
xcodebuild -project Billable.xcodeproj -scheme Billable \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -configuration Debug build
```
Expected: **BUILD SUCCEEDED**. Then confirm each manifest landed in its bundle (path comes from the build output's `TARGET_BUILD_DIR`; the products are `Billable.app` and the embedded `BillableWidgetsExtension.appex`):

```bash
APP=$(xcodebuild -project Billable.xcodeproj -scheme Billable -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -configuration Debug -showBuildSettings 2>/dev/null | awk -F' = ' '/ TARGET_BUILD_DIR =/{print $2; exit}')
find "$APP" -name PrivacyInfo.xcprivacy
```
Expected: **at least two** results — `…/Billable.app/PrivacyInfo.xcprivacy`, `…/Billable.app/PlugIns/BillableWidgetsExtension.appex/PrivacyInfo.xcprivacy`, and (from SPM) the BillableCore resource bundle's copy nested in the app. If the app or widget copy is missing, the corresponding `PBXResourcesBuildPhase` edit in Step 6 didn't take — fix before committing.

- [ ] **Step 8: Commit**

```bash
git add App/Resources/PrivacyInfo.xcprivacy Widgets/Resources/PrivacyInfo.xcprivacy \
        Packages/BillableCore/Sources/BillableCore/PrivacyInfo.xcprivacy \
        Packages/BillableCore/Package.swift \
        Billable.xcodeproj/project.pbxproj
git commit -m "chore(privacy): PrivacyInfo.xcprivacy manifests (app + widget + BillableCore)

NSPrivacyTracking=false, no tracking domains; required-reason API: UserDefaults CA92.1,
FileTimestamp C617.1; collected types name/email/phone/address/payment/other-financial all
Linked=false Tracking=false, purpose App Functionality. App Store submission is the real gate."
```

---

### Task 6: Release-gate sign-off (whole-plan green + named manual gates)

No new code — this is the explicit "config actually parses + the manual gates that a simulator build cannot prove" checkpoint.

- [ ] **Step 1: Full BillableCore suite**

Run: `cd Packages/BillableCore && swift test`
Expected: **PASS** — 287 tests (279 baseline + 8 `ActivationMetrics`), zero failures.

- [ ] **Step 2: Full app build, both configurations**

Run:
```bash
xcodebuild -project Billable.xcodeproj -scheme Billable \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -configuration Debug build
xcodebuild -project Billable.xcodeproj -scheme Billable \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -configuration Release build
```
Expected: **BUILD SUCCEEDED** for both — proves entitlements parse, both privacy manifests bundle, and the DEBUG metrics surface is excluded from Release.

- [ ] **Step 3: Dev-credit UI test (final confirmation)**

Run:
```bash
xcodebuild -project Billable.xcodeproj -scheme Billable \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BillableUITests/SettingsAboutUITests test
```
Expected: **PASS**.

- [ ] **Step 4: Regression-guard the preserved UI tests (no collateral damage)**

Run:
```bash
xcodebuild -project Billable.xcodeproj -scheme Billable \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BillableUITests/LaunchTaglineUITests \
  -only-testing:BillableUITests/InvoicePreviewLineItemEditUITests test
```
Expected: **PASS** — Plan-4 changes (a string, config, a DEBUG view) don't touch the launch tagline (`Track hours.\nSend invoices.` + `--ui-test-show-onboarding`) or the invoice-preview flow.

- [ ] **Step 5: Record the MANUAL gates the controller must execute before ship (NOT automatable here)**

These are the real release gates this plan sets up but cannot itself prove (spec §13/§15) — list them in the PR description, do not check them off in CI:
  1. **App Store Connect privacy questionnaire** must match the declared `NSPrivacyCollectedDataTypes` (name/email/phone/address/payment/other-financial, not used for tracking). The `.xcprivacy` is the machine half; the questionnaire is the human half — they must agree or review bounces.
  2. **Validate-before-upload**: `Product → Archive → Validate App` in Xcode (or `xcodebuild -exportArchive` validation) surfaces privacy-manifest/required-reason errors that a simulator build never runs. This is the true gate for the API-reason codes.
  3. **On-device data-protection sanity (optional but cheap):** install to a real locked device, confirm the lock-screen/home-screen widget still renders after the screen locks (proves `…CompleteUntilFirstUserAuthentication` didn't break the widget's shared-store read).
  4. **ASC App Analytics baseline snapshot** (spec §14 Tier-0) BEFORE this version ships — the pre-redesign retention/activation baseline is destroyed on release.

- [ ] **Step 6: Stop — Plan 4 complete**

Plan 4 is done: dev-credit fixed (UI-test-locked), Tier-1 activation metrics computed on-device + readable behind the DEBUG flag (privacy-pure, unit-tested), Data-Protection entitlement on app + widget, and `PrivacyInfo.xcprivacy` on all three targets (build-verified; App Store validation/submission is the real gate, named in Step 5). No `privacy.md` change — nothing leaves the device.

---

## Self-review notes (author)

- **Spec coverage (Plan 4 scope):** §12 dev credit (Task 1). §13 privacy manifest app+widget+BillableCore (Task 5) + Data-Protection entitlement both targets with the "can't use Complete" rationale (Task 4). §14 Tier-1 on-device metrics + the headline quick-start-vs-checklist split + the DEBUG readout (Tasks 2–3). §15 release-gate residual risk named as manual gates (Task 6 Step 5). Deferred (other plans): §5 onboarding, §6 editor, §7/§7a/§7b Today + enrichment, §8 reconciliation wiring (Plan 2), §14 Tier-0 ASC snapshot is an ops action not code.
- **Privacy-pure, confirmed:** `ActivationMetrics` only *reads* SwiftData and returns a value type; the view holds it in `@State` and renders it; nothing is written, persisted as a new field, or transmitted. No `privacy.md` edit. Matches §14 "Tier-2 out of scope, owner confirmed privacy-pure."
- **Verify-before-coding flags for the implementer:**
  1. `Invoice.init` label/order — Task 2 tests call a minimal `Invoice(number:…createdAt:)`; open `Models/Invoice.swift` and use whatever minimal initializer compiles (only `createdAt` is asserted).
  2. Fresh unique 24-hex pbxproj IDs in Task 5 Step 6 (placeholders given); or do the drag-into-build-phase route in Xcode.
  3. Required-reason codes `CA92.1` (UserDefaults) + `C617.1` (FileTimestamp) — re-confirm against the current Apple "Describing use of required reason API" table at implementation time; if the app reads `UserDefaults` from the App Group on behalf of the widget, `1C8F.1` may be the better UserDefaults reason — pick the one that matches actual access and keep app/widget consistent.
  4. Simulator name `iPhone 17 Pro` must exist in the local Xcode (matches the other plans' destination); swap to an installed simulator if not.
- **Test-count honesty:** baseline measured at 279 BillableCore tests on this worktree (Plan 1 merged); Task 2 adds 8 → 287. Numbers in the plan reflect that measurement, not a guess.
- **Why no fake view unit tests:** `ActivationMetricsView` rendering is verified by `xcodebuild build` (Debug + Release) plus named on-simulator manual checks (Task 3 Step 5) — the logic it shows is the part under `swift test` (Task 2). Per the verification-reality rule, view rendering is not pretended to be unit-tested.
- **Independence / merge-safety:** disjoint files from Plans 2–3 except `SettingsView.swift`, where Plan 4's two edits (About L111; the `--debug-scheduler` Section) don't collide with Plan 3's Business-profile `NavigationLink`. Commit ordering coordinated with the controller per the parallel-session rule; this plan does not push/rebase/merge on its own.
