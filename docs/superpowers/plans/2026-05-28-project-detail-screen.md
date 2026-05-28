# Project Detail Screen Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a dedicated per-project screen showing lifetime hours worked (with their live $ value at the current rate), the engagement window (start date · days worked · completion date), a per-project timer, recent sessions, and contextual Create-invoice + Complete-project actions.

**Architecture:** A new SwiftData-backed SwiftUI screen (`ProjectDetailView`) reached by tapping a project. Lifetime figures are computed on the fly by a pure `ProjectStats` value type in BillableCore (no stored totals). The running-timer card is extracted from `TodayView` into a shared view, and all timer side-effects (Live Activity, widget reload, Siri-intent donation) are consolidated into a `TimerActions` helper so Today, the start sheet, onboarding, and the project screen never drift. One new nullable model field, `Project.completedAt`, records when a project is completed.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Swift Testing (`import Testing`), StoreKit-gated Reports unaffected. iOS app target `Billable`; core logic in the `BillableCore` Swift package.

**Branch:** `feature/project-detail` (already cut from `origin/main`, which contains invoice-per-project). Do not touch shared branches.

**Spec:** `docs/superpowers/specs/2026-05-28-project-detail-screen-design.md`

**Build/verify commands:**
- BillableCore tests: `cd Packages/BillableCore && swift test`
- App build for simulator: `xcodebuild -project Billable.xcodeproj -scheme Billable -configuration Debug -destination 'platform=iOS Simulator,id=A946AE5D-C969-4EB2-8384-001B3451A6A4' -derivedDataPath build/DerivedData build`
- Reinstall + launch with Pro unlocked: `xcrun simctl install A946AE5D-C969-4EB2-8384-001B3451A6A4 build/DerivedData/Build/Products/Debug-iphonesimulator/Billable.app && xcrun simctl launch A946AE5D-C969-4EB2-8384-001B3451A6A4 com.eldenstudios.billable --pretend-pro`

---

## Task 1: Add `Project.completedAt` field

**Files:**
- Modify: `Packages/BillableCore/Sources/BillableCore/Models/Project.swift`
- Test: `Packages/BillableCore/Tests/BillableCoreTests/ProjectCompletedAtTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Packages/BillableCore/Tests/BillableCoreTests/ProjectCompletedAtTests.swift`:

```swift
import Foundation
import Testing
import SwiftData
@testable import BillableCore

@Suite("Project.completedAt")
@MainActor
struct ProjectCompletedAtTests {
    @Test("new project has nil completedAt")
    func defaultsNil() throws {
        let project = Project(name: "Site", hourlyRate: 100)
        #expect(project.completedAt == nil)
    }

    @Test("completedAt round-trips through the store")
    func persists() throws {
        let container = try BillableModelContainer.inMemory()
        let context = ModelContext(container)
        let project = Project(name: "Site", hourlyRate: 100)
        let stamp = Date(timeIntervalSince1970: 1_779_793_200)
        project.completedAt = stamp
        context.insert(project)
        try context.save()

        let fetched = try #require(try context.fetch(FetchDescriptor<Project>()).first)
        #expect(fetched.completedAt == stamp)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/BillableCore && swift test --filter ProjectCompletedAtTests`
Expected: FAIL — `value of type 'Project' has no member 'completedAt'`.

- [ ] **Step 3: Add the field**

In `Project.swift`, add the stored property after `updatedAt` (line 12):

```swift
    public var updatedAt: Date

    /// When the user tapped "Complete project"; `nil` while the project is active.
    /// Cleared on restore. Display-only — `isArchived` remains the source of truth
    /// for whether a project is active.
    public var completedAt: Date?
```

Add the parameter to `init` (after `updatedAt: Date = .now`) and assign it:

```swift
    public init(
        name: String,
        hourlyRate: Decimal,
        isBillable: Bool = true,
        isArchived: Bool = false,
        notes: String? = nil,
        client: Client? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        completedAt: Date? = nil
    ) {
        self.name = name
        self.hourlyRate = hourlyRate
        self.isBillable = isBillable
        self.isArchived = isArchived
        self.notes = notes
        self.client = client
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
    }
```

Adding a new optional property to an `@Model` is an automatic lightweight migration (matches how invoice-per-project added `Invoice.project`/`scopeOfWork`). No migration plan needed.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Packages/BillableCore && swift test --filter ProjectCompletedAtTests`
Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Models/Project.swift Packages/BillableCore/Tests/BillableCoreTests/ProjectCompletedAtTests.swift
git commit -m "feat(core): add Project.completedAt for completion date"
```

---

## Task 2: `ProjectStats` aggregation

**Files:**
- Create: `Packages/BillableCore/Sources/BillableCore/Reporting/ProjectStats.swift`
- Test: `Packages/BillableCore/Tests/BillableCoreTests/ProjectStatsTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Packages/BillableCore/Tests/BillableCoreTests/ProjectStatsTests.swift`:

```swift
import Foundation
import Testing
import SwiftData
@testable import BillableCore

@Suite("ProjectStats.compute")
@MainActor
struct ProjectStatsTests {
    /// Fixture: an in-memory store with one billable project at $60/h.
    private func fixture(billable: Bool = true) throws -> (ModelContext, Project) {
        let container = try BillableModelContainer.inMemory()
        let context = ModelContext(container)
        let client = Client(name: "Acme")
        let project = Project(name: "Site", hourlyRate: 60, isBillable: billable, client: client)
        context.insert(client)
        context.insert(project)
        try context.save()
        return (context, project)
    }

    /// Adds a finished entry of `hours` on `day`, optionally invoiced.
    @discardableResult
    private func addEntry(_ context: ModelContext, _ project: Project,
                          start: Date, hours: Double, invoiced: Bool = false) throws -> TimeEntry {
        let end = start.addingTimeInterval(hours * 3600)
        let entry = TimeEntry(startedAt: start, endedAt: end, isManual: true,
                              project: project, accumulatedSeconds: hours * 3600)
        if invoiced { entry.invoiceID = UUID() }
        context.insert(entry)
        try context.save()
        return entry
    }

    private let day1 = Date(timeIntervalSince1970: 1_779_793_200) // 2026-05-21 ~12:00 UTC

    @Test("sums hours and current-rate value across this project's entries")
    func totals() throws {
        let (context, project) = try fixture()
        try addEntry(context, project, start: day1, hours: 2)               // 2h
        try addEntry(context, project, start: day1.addingTimeInterval(86_400), hours: 3) // next day, 3h
        let stats = ProjectStats.compute(for: project, asOf: day1.addingTimeInterval(200_000))
        #expect(stats.lifetimeSeconds == 5 * 3600)
        #expect(stats.lifetimeValue == 5 * 60)        // 5h * $60
        #expect(stats.sessionCount == 2)
    }

    @Test("uninvoicedAmount excludes entries already on an invoice")
    func uninvoiced() throws {
        let (context, project) = try fixture()
        try addEntry(context, project, start: day1, hours: 2, invoiced: true) // billed
        try addEntry(context, project, start: day1, hours: 1, invoiced: false)
        let stats = ProjectStats.compute(for: project, asOf: day1.addingTimeInterval(200_000))
        #expect(stats.lifetimeValue == 3 * 60)      // all 3h valued
        #expect(stats.uninvoicedAmount == 1 * 60)   // only the un-invoiced hour
    }

    @Test("activeDayCount counts distinct calendar days, not sessions")
    func dayCount() throws {
        let (context, project) = try fixture()
        let cal = Calendar(identifier: .gregorian)
        try addEntry(context, project, start: day1, hours: 1)                       // day A
        try addEntry(context, project, start: day1.addingTimeInterval(3 * 3600), hours: 1) // same day A
        try addEntry(context, project, start: day1.addingTimeInterval(2 * 86_400), hours: 1) // day B
        let stats = ProjectStats.compute(for: project, asOf: day1.addingTimeInterval(300_000), calendar: cal)
        #expect(stats.activeDayCount == 2)
        #expect(stats.sessionCount == 3)
    }

    @Test("firstTrackedDay is the earliest startedAt; nil with no entries")
    func firstDay() throws {
        let (context, project) = try fixture()
        #expect(ProjectStats.compute(for: project, asOf: day1).firstTrackedDay == nil)
        let later = day1.addingTimeInterval(5 * 86_400)
        try addEntry(context, project, start: later, hours: 1)
        try addEntry(context, project, start: day1, hours: 1) // earlier
        let stats = ProjectStats.compute(for: project, asOf: later.addingTimeInterval(10_000))
        #expect(stats.firstTrackedDay == day1)
    }

    @Test("non-billable project: hours retained, value and uninvoiced are zero")
    func nonBillable() throws {
        let (context, project) = try fixture(billable: false)
        try addEntry(context, project, start: day1, hours: 4)
        let stats = ProjectStats.compute(for: project, asOf: day1.addingTimeInterval(50_000))
        #expect(stats.lifetimeSeconds == 4 * 3600)
        #expect(stats.lifetimeValue == 0)
        #expect(stats.uninvoicedAmount == 0)
    }

    @Test("lifetimeValue follows the CURRENT rate, not a snapshot")
    func rateChange() throws {
        let (context, project) = try fixture()
        try addEntry(context, project, start: day1, hours: 2)
        let asOf = day1.addingTimeInterval(50_000)
        #expect(ProjectStats.compute(for: project, asOf: asOf).lifetimeValue == 2 * 60)
        project.hourlyRate = 90
        try context.save()
        #expect(ProjectStats.compute(for: project, asOf: asOf).lifetimeValue == 2 * 90)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Packages/BillableCore && swift test --filter ProjectStatsTests`
Expected: FAIL — `cannot find 'ProjectStats' in scope`.

- [ ] **Step 3: Implement `ProjectStats`**

Create `Packages/BillableCore/Sources/BillableCore/Reporting/ProjectStats.swift`:

```swift
import Foundation

/// Lifetime, on-the-fly aggregation of a single project's tracked time.
///
/// Pure value type computed from `project.entries` — nothing is stored on the
/// model. Mirrors the reduce pattern in `ReportsAggregator`. `lifetimeValue`
/// is the value of tracked time at the project's CURRENT rate (the same live
/// computation the timer shows) — it is NOT a billed/invoiced figure and moves
/// if the rate changes.
public struct ProjectStats: Equatable, Sendable {
    public let lifetimeSeconds: TimeInterval
    public let lifetimeValue: Decimal
    public let uninvoicedAmount: Decimal
    public let sessionCount: Int
    public let activeDayCount: Int
    public let firstTrackedDay: Date?

    public static func compute(
        for project: Project,
        asOf: Date = .now,
        calendar: Calendar = .current
    ) -> ProjectStats {
        var seconds: TimeInterval = 0
        var value: Decimal = 0
        var uninvoiced: Decimal = 0
        var days = Set<Date>()
        var earliest: Date?

        for entry in project.entries {
            seconds += entry.duration(asOf: asOf)
            let amount = entry.amount(asOf: asOf)   // 0 for non-billable projects
            value += amount
            if entry.invoiceID == nil { uninvoiced += amount }
            days.insert(calendar.startOfDay(for: entry.startedAt))
            if earliest == nil || entry.startedAt < earliest! {
                earliest = entry.startedAt
            }
        }

        return ProjectStats(
            lifetimeSeconds: seconds,
            lifetimeValue: value,
            uninvoicedAmount: uninvoiced,
            sessionCount: project.entries.count,
            activeDayCount: days.count,
            firstTrackedDay: earliest
        )
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Packages/BillableCore && swift test --filter ProjectStatsTests`
Expected: PASS (all six tests).

- [ ] **Step 5: Run the full core suite to confirm no regressions**

Run: `cd Packages/BillableCore && swift test`
Expected: PASS (existing suite + the new tests).

- [ ] **Step 6: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Reporting/ProjectStats.swift Packages/BillableCore/Tests/BillableCoreTests/ProjectStatsTests.swift
git commit -m "feat(core): add ProjectStats lifetime aggregation"
```

---

## Task 3: `TimerActions` helper + migrate existing call sites

This is a behavior-preserving refactor. SwiftUI/Live-Activity side effects can't be unit-tested here; verification is build + simulator (Today, start sheet, and onboarding timing must be unchanged).

**Files:**
- Create: `App/Sources/Features/Timer/TimerActions.swift`
- Modify: `App/Sources/Features/Today/TodayView.swift` (the four closures + `stopRunning`)
- Modify: `App/Sources/Features/Timer/StartTimerSheet.swift` (`startOrSwitch`)
- Modify: `App/Sources/Features/Onboarding/OnboardingView.swift` (start site)

- [ ] **Step 1: Create the helper**

Create `App/Sources/Features/Timer/TimerActions.swift`:

```swift
import Foundation
import SwiftData
import WidgetKit
import BillableCore

/// Single source of truth for timer mutations and their side effects
/// (Live Activity, widget reload, Siri-intent donation). Used by TodayView,
/// StartTimerSheet, OnboardingView, and ProjectDetailView so the behavior
/// never drifts between entry points.
@MainActor
enum TimerActions {
    /// Start tracking `project`. Stops any other running timer first
    /// (`TimerService.start` finalizes it). Returns the new running entry.
    @discardableResult
    static func start(project: Project, currencyCode: String, in context: ModelContext) -> TimeEntry? {
        guard let entry = try? TimerService.start(project: project, in: context) else { return nil }
        Task { await TimerActivityController.shared.startActivity(for: entry, currencyCode: currencyCode) }
        if let entity = ProjectEntity(from: project) {
            Task { try? await StartTimerIntent(project: entity).donate() }
        }
        WidgetCenter.shared.reloadAllTimelines()
        return entry
    }

    /// Atomic stop+start into `project`. No-op if it's already the running project.
    @discardableResult
    static func switchTo(project: Project, currencyCode: String, in context: ModelContext) -> TimeEntry? {
        do {
            let entry = try TimerService.switchTo(project: project, in: context)
            Task { await TimerActivityController.shared.startActivity(for: entry, currencyCode: currencyCode) }
            if let entity = ProjectEntity(from: project) {
                Task { try? await SwitchTimerIntent(project: entity).donate() }
            }
            WidgetCenter.shared.reloadAllTimelines()
            return entry
        } catch {
            // alreadyTrackingSameProject / archived etc. — match StartTimerSheet: swallow.
            return nil
        }
    }

    /// Pause the running timer (bank the current segment, freeze the clock).
    static func takeBreak(in context: ModelContext) {
        guard let entry = try? TimerService.takeBreak(in: context) else { return }
        let elapsed = entry.duration()
        Task { await TimerActivityController.shared.pause(elapsed: elapsed) }
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Resume an on-break timer.
    static func resume(in context: ModelContext) {
        guard let entry = try? TimerService.resume(in: context) else { return }
        Task { await TimerActivityController.shared.resumeActivity(runningEntry: entry) }
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// End the running session ("Done for now").
    static func stop(in context: ModelContext) {
        _ = try? TimerService.stop(in: context)
        Task { await TimerActivityController.shared.endActivity() }
        Task { try? await StopTimerIntent().donate() }
        WidgetCenter.shared.reloadAllTimelines()
    }
}
```

Note: onboarding currently starts a timer **without** donating an intent; routing it through `TimerActions.start` adds a `StartTimerIntent` donation. That is intentional and harmless (it only seeds a Siri/Shortcuts suggestion), and it removes a divergence.

- [ ] **Step 2: Migrate `TodayView`**

In `TodayView.swift`, replace the `onTakeBreak`/`onResume` closures passed to `TodayActiveTimerSection` (currently lines 48–60) with:

```swift
                        onTakeBreak: { TimerActions.takeBreak(in: modelContext) },
                        onResume: { TimerActions.resume(in: modelContext) },
```

Replace the whole `stopRunning()` function (currently lines 130–135) with:

```swift
    private func stopRunning() {
        TimerActions.stop(in: modelContext)
    }
```

(The `onStop: stopRunning` and `onSwitch:` wiring is unchanged; `onSwitch` still just presents the switch sheet.)

- [ ] **Step 3: Migrate `StartTimerSheet`**

In `StartTimerSheet.swift`, replace the body of `startOrSwitch(to:)` (currently lines 125–150) with:

```swift
    private func startOrSwitch(to project: Project) {
        let entry = isSwitching
            ? TimerActions.switchTo(project: project, currencyCode: currencyCode, in: modelContext)
            : TimerActions.start(project: project, currencyCode: currencyCode, in: modelContext)
        if let entry { onStarted(entry) }
        dismiss()
    }
```

- [ ] **Step 4: Migrate `OnboardingView`**

In `OnboardingView.swift`, replace the start block (currently lines 319–324, the `if let entry = try? TimerService.start(...)` block that fetches the profile and calls `startActivity`) with:

```swift
        var profileFetch = FetchDescriptor<BusinessProfile>()
        profileFetch.fetchLimit = 1
        let profileCode = (try? modelContext.fetch(profileFetch))?.first?.currencyCode ?? "USD"
        TimerActions.start(project: project, currencyCode: profileCode, in: modelContext)
```

- [ ] **Step 5: Build**

Run the app build command (see header).
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Verify on simulator (behavior unchanged)**

Reinstall + launch (see header). Seed demo if needed. Verify:
- Today: Start a timer → Take a Break → Resume → Done for now. Elapsed/$ and the Live Activity behave exactly as before.
- Onboarding (fresh install): completing onboarding with a first project starts its timer and shows the Live Activity.

- [ ] **Step 7: Commit**

```bash
git add App/Sources/Features/Timer/TimerActions.swift App/Sources/Features/Today/TodayView.swift App/Sources/Features/Timer/StartTimerSheet.swift App/Sources/Features/Onboarding/OnboardingView.swift
git commit -m "refactor(timer): consolidate timer side-effects into TimerActions"
```

---

## Task 4: Extract `RunningTimerCard` into a shared file

Pure relocation + visibility change — no logic edits. Verification is build + simulator.

**Files:**
- Create: `App/Sources/Features/Timer/RunningTimerCard.swift`
- Modify: `App/Sources/Features/Today/TodayView.swift` (remove the moved types)

- [ ] **Step 1: Move the view + primitives**

Cut these declarations **verbatim** out of `TodayView.swift` and paste them into a new file `App/Sources/Features/Timer/RunningTimerCard.swift`, changing each `private`/file-scope declaration to internal (drop the `private` keyword):

- `let timerAccent` (currently `private let timerAccent = Color(...)`)
- `struct TimerStatusBadge`
- `struct TimerCardSurface`
- `struct TimerPrimaryButtonStyle`
- `struct TimerSecondaryButtonStyle`
- `struct RunningTimerCard`
- `struct AdjustStartTimePickerSheet`

The new file's header:

```swift
import SwiftUI
import SwiftData
import BillableCore
```

Then the moved declarations follow, each with `private` removed so they are visible to `TodayView` and `ProjectDetailView` within the app target. **Do not change any of their bodies** — the notes-debounce `.task`/`.onAppear`/`.onDisappear`, the adjust-start dialog, `elapsedString`, `amountString`, and all `@State` move unchanged.

Leave `IdleTimerCard`, `TodayView`, `TodayActiveTimerSection`, `TodaySummarySection`, `SummaryTile`, and `UninvoicedTile` in `TodayView.swift` (they stay private there). `IdleTimerCard` keeps referencing `timerAccent`, `TimerPrimaryButtonStyle`, and `TimerCardSurface` — now resolved from the new file.

- [ ] **Step 2: Build**

Run the app build command.
Expected: BUILD SUCCEEDED. (If the compiler reports an ambiguity or "declared in two places," confirm the type was fully removed from `TodayView.swift`.)

- [ ] **Step 3: Verify on simulator**

Reinstall + launch. The Today running card looks and behaves exactly as before: WORKING/ON BREAK badge, tappable elapsed time → adjust-start dialog, the inline notes field saving, Break/Resume + Done.

- [ ] **Step 4: Commit**

```bash
git add App/Sources/Features/Timer/RunningTimerCard.swift App/Sources/Features/Today/TodayView.swift
git commit -m "refactor(timer): extract RunningTimerCard into shared file"
```

---

## Task 5: `InvoiceGeneratorView` accepts a default project

**Files:**
- Modify: `App/Sources/Features/Invoicing/InvoiceGeneratorView.swift` (init only)

- [ ] **Step 1: Add the `defaultProject` parameter**

Replace the existing initializer (currently around line 37):

```swift
    init(defaultClient: Client? = nil) {
        _selectedClient = State(initialValue: defaultClient)
    }
```

with:

```swift
    init(defaultClient: Client? = nil, defaultProject: Project? = nil) {
        _selectedClient = State(initialValue: defaultClient)
        _selectedProject = State(initialValue: defaultProject)
    }
```

`selectedProject` already exists as `@State` (line 18). `.onAppear` calls `refreshEligibleEntries()` which reads `selectedProject`, so a seeded project loads its eligible entries immediately. `.onChange(of: selectedClient)` does **not** fire for the initial seeded value, so it won't clear the seeded project.

- [ ] **Step 2: Build**

Run the app build command.
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add App/Sources/Features/Invoicing/InvoiceGeneratorView.swift
git commit -m "feat(invoicing): InvoiceGeneratorView accepts defaultProject"
```

---

## Task 6: `ProjectDetailView`

The screen. Verification is build + simulator (with the `ProjectStats` math already unit-tested in Task 2).

**Files:**
- Create: `App/Sources/Features/Projects/ProjectDetailView.swift`

- [ ] **Step 1: Create the view**

Create `App/Sources/Features/Projects/ProjectDetailView.swift`:

```swift
import SwiftUI
import SwiftData
import BillableCore

struct ProjectDetailView: View {
    @Bindable var project: Project

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query private var profiles: [BusinessProfile]
    @Query(Self.runningDescriptor) private var runningEntries: [TimeEntry]

    @State private var showingEdit = false
    @State private var showingInvoiceGenerator = false
    @State private var showingCompleteConfirm = false
    @State private var showingSwitchSheet = false
    @State private var sessionLimit = 50

    private static var runningDescriptor: FetchDescriptor<TimeEntry> {
        var d = FetchDescriptor<TimeEntry>(predicate: #Predicate { $0.endedAt == nil })
        d.fetchLimit = 1
        return d
    }

    private var currencyCode: String {
        profiles.first?.currencyCode ?? Locale.current.currency?.identifier ?? "USD"
    }

    /// The running entry, but only if it belongs to THIS project.
    private var runningEntryForProject: TimeEntry? {
        guard let running = runningEntries.first,
              running.project?.persistentModelID == project.persistentModelID else { return nil }
        return running
    }

    private var anotherProjectRunning: Bool {
        guard let running = runningEntries.first else { return false }
        return running.project?.persistentModelID != project.persistentModelID
    }

    var body: some View {
        ScrollView {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                content(asOf: context.date)
            }
            .padding()
        }
        .scrollIndicators(.hidden)
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { showingEdit = true }
            }
        }
        .sheet(isPresented: $showingEdit) {
            NavigationStack {
                ProjectEditorView(client: project.client ?? Client(name: ""), project: project)
            }
        }
        .sheet(isPresented: $showingInvoiceGenerator) {
            InvoiceGeneratorView(defaultClient: project.client, defaultProject: project)
        }
        .sheet(isPresented: $showingSwitchSheet) {
            StartTimerSheet(isSwitching: true)
        }
        .confirmationDialog(
            "Are you sure you're done with this project?",
            isPresented: $showingCompleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Complete project", role: .destructive) { completeProject() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Marks the project complete and moves it to Archived. Logged time stays on past invoices and reports.")
        }
    }

    @ViewBuilder
    private func content(asOf: Date) -> some View {
        let stats = ProjectStats.compute(for: project, asOf: asOf)
        VStack(alignment: .leading, spacing: 20) {
            hero(stats: stats)
            engagementLine(stats: stats)
            if project.isBillable && !project.isArchived {
                uninvoicedTile(stats: stats)
            }
            timerArea(asOf: asOf)
            if project.isBillable && !project.isArchived {
                Button {
                    showingInvoiceGenerator = true
                } label: {
                    Label(invoiceLabel(stats: stats), systemImage: "doc.text")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            recentSessions(asOf: asOf)
            lifecycleButton()
        }
    }

    // MARK: Hero

    private func hero(stats: ProjectStats) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(hoursString(stats.lifetimeSeconds))
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .monospacedDigit()
            HStack(spacing: 8) {
                Text("\(stats.sessionCount) session\(stats.sessionCount == 1 ? "" : "s")")
                if project.isBillable {
                    Text("·")
                    Text("\(stats.lifetimeValue.formatted(.currency(code: currencyCode))) at \(project.hourlyRate.formatted(.currency(code: currencyCode)))/h")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.9))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            LinearGradient(colors: [Color(red: 0.98, green: 0.49, blue: 0.13),
                                    Color(red: 0.98, green: 0.49, blue: 0.13).opacity(0.85)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: .rect(cornerRadius: 18)
        )
        .foregroundStyle(.white)
    }

    // MARK: Engagement line

    @ViewBuilder
    private func engagementLine(stats: ProjectStats) -> some View {
        let start = stats.firstTrackedDay ?? project.createdAt
        let startLabel = (stats.firstTrackedDay == nil ? "Created " : "Started ")
            + start.formatted(.dateTime.month().day())
        let daysLabel = "\(stats.activeDayCount) day\(stats.activeDayCount == 1 ? "" : "s") worked"
        HStack(spacing: 6) {
            Image(systemName: "calendar")
            if project.isArchived, let completed = project.completedAt {
                Text("\(start.formatted(.dateTime.month().day())) – \(completed.formatted(.dateTime.month().day())) · \(daysLabel)")
            } else {
                Text("\(startLabel) · \(daysLabel)")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: Uninvoiced tile

    private func uninvoicedTile(stats: ProjectStats) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("UNINVOICED")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(stats.uninvoicedAmount.formatted(.currency(code: currencyCode)))
                .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
            Text("Tracked time on this project you haven't invoiced yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: .rect(cornerRadius: 14))
    }

    // MARK: Timer area

    @ViewBuilder
    private func timerArea(asOf: Date) -> some View {
        if let running = runningEntryForProject {
            RunningTimerCard(
                entry: running, asOf: asOf, currencyCode: currencyCode,
                onStop: { TimerActions.stop(in: modelContext) },
                onSwitch: { showingSwitchSheet = true },
                onTakeBreak: { TimerActions.takeBreak(in: modelContext) },
                onResume: { TimerActions.resume(in: modelContext) }
            )
            .id(running.persistentModelID)
        } else if !project.isArchived {
            Button {
                if anotherProjectRunning {
                    TimerActions.switchTo(project: project, currencyCode: currencyCode, in: modelContext)
                } else {
                    TimerActions.start(project: project, currencyCode: currencyCode, in: modelContext)
                }
            } label: {
                Label(anotherProjectRunning ? "Switch to this project" : "Start timer",
                      systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.98, green: 0.49, blue: 0.13))
        }
    }

    // MARK: Recent sessions

    @ViewBuilder
    private func recentSessions(asOf: Date) -> some View {
        let sorted = project.entries.sorted { $0.startedAt > $1.startedAt }
        let shown = Array(sorted.prefix(sessionLimit))
        VStack(alignment: .leading, spacing: 10) {
            Text("Sessions").font(.headline)
            if shown.isEmpty {
                Text("No time tracked yet.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(groupedByMonth(shown), id: \.0) { month, entries in
                    Text(month)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(entries) { entry in
                        sessionRow(entry, asOf: asOf)
                    }
                }
                if sorted.count > shown.count {
                    Button("See all \(sorted.count) sessions") { sessionLimit = sorted.count }
                        .font(.subheadline)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sessionRow(_ entry: TimeEntry, asOf: Date) -> some View {
        HStack {
            Text(entry.startedAt.formatted(.dateTime.weekday().day()))
            Spacer()
            Text(hoursString(entry.duration(asOf: asOf)))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if project.isBillable {
                Text(entry.amount(asOf: asOf).formatted(.currency(code: currencyCode)))
                    .monospacedDigit()
                    .foregroundStyle(.green)
                    .frame(minWidth: 70, alignment: .trailing)
            }
        }
        .font(.subheadline)
        .padding(.vertical, 4)
    }

    // MARK: Lifecycle button

    @ViewBuilder
    private func lifecycleButton() -> some View {
        if project.isArchived {
            Button { restoreProject() } label: {
                Label("Restore project", systemImage: "tray.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        } else {
            Button(role: .destructive) { showingCompleteConfirm = true } label: {
                Label("Complete project", systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: Actions

    private func completeProject() {
        project.isArchived = true
        project.completedAt = .now
        project.updatedAt = .now
        modelContext.saveOrLog("complete project")
        dismiss()
    }

    private func restoreProject() {
        project.isArchived = false
        project.completedAt = nil
        project.updatedAt = .now
        modelContext.saveOrLog("restore project")
    }

    // MARK: Helpers

    private func invoiceLabel(stats: ProjectStats) -> String {
        stats.uninvoicedAmount > 0
            ? "Create invoice · \(stats.uninvoicedAmount.formatted(.currency(code: currencyCode)))"
            : "Create invoice"
    }

    private func hoursString(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int(seconds / 60)
        return "\(totalMinutes / 60)h \(String(format: "%02d", totalMinutes % 60))m"
    }

    private func groupedByMonth(_ entries: [TimeEntry]) -> [(String, [TimeEntry])] {
        var order: [String] = []
        var buckets: [String: [TimeEntry]] = [:]
        for entry in entries {
            let key = entry.startedAt.formatted(.dateTime.month(.wide).year())
            if buckets[key] == nil { order.append(key); buckets[key] = [] }
            buckets[key]?.append(entry)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }
}
```

Note: `RunningTimerCard` always renders a "Switch" button, so `onSwitch` opens the same `StartTimerSheet(isSwitching: true)` that Today uses — the card is reused verbatim (Task 4 needs no edits to it). `ProjectEditorView(client:)` requires a non-optional client; a project always has one in practice, so the `?? Client(name: "")` fallback only guards an impossible nil and is never persisted.

- [ ] **Step 2: Build**

Run the app build command.
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Verify on simulator**

Reinstall + launch with `--pretend-pro`. (Navigation is wired in Task 7; until then, verify via a temporary preview or proceed to Task 7 and verify together.) Confirm the file compiles.

- [ ] **Step 4: Commit**

```bash
git add App/Sources/Features/Projects/ProjectDetailView.swift
git commit -m "feat(projects): add ProjectDetailView (stats, timer, invoice, lifecycle)"
```

---

## Task 7: Wire navigation + remove the old Complete-project sites

**Files:**
- Modify: `App/Sources/Features/Clients/ClientDetailView.swift`
- Modify: `App/Sources/Features/Projects/ProjectEditorView.swift`

- [ ] **Step 1: Point project rows at `ProjectDetailView`**

In `ClientDetailView.swift`, in the active-projects `ForEach` (currently lines 56–76), replace the `Button { editingProject = project }` row with a `NavigationLink`, and drop the Archive swipe action (keep Delete):

```swift
                    ForEach(activeProjects) { project in
                        NavigationLink {
                            ProjectDetailView(project: project)
                        } label: {
                            ProjectRow(project: project)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                deletionCandidate = project
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
```

In the archived-projects `ForEach` (currently lines 90–103), make the row navigate too (keep the Restore swipe as a harmless shortcut):

```swift
                    ForEach(archivedProjects) { project in
                        NavigationLink {
                            ProjectDetailView(project: project)
                        } label: {
                            ProjectRow(project: project)
                                .foregroundStyle(.secondary)
                        }
                        .swipeActions(edge: .trailing) {
                            Button {
                                project.isArchived = false
                                project.completedAt = nil
                                project.updatedAt = .now
                                modelContext.saveOrLog("restore project")
                            } label: {
                                Label("Restore", systemImage: "tray.and.arrow.up")
                            }
                            .tint(.blue)
                        }
                    }
```

- [ ] **Step 2: Remove the now-dead state and dialog from `ClientDetailView`**

Delete these declarations (currently lines 11–13):

```swift
    @State private var editingProject: Project?
    @State private var projectToComplete: Project?
```

(Keep `deletionCandidate`.) Delete the `.sheet(item: $editingProject)` modifier (currently lines 119–123) and the entire `projectToComplete` `.confirmationDialog` (currently lines 143–156). Editing is now reached via `ProjectDetailView`'s Edit button; completion lives on `ProjectDetailView`.

- [ ] **Step 3: Remove the Complete button from `ProjectEditorView`**

In `ProjectEditorView.swift`, delete the `if let project, !project.isArchived { Section { Button("Complete project") ... } }` block (currently lines 50–57), the `@State private var showingCompleteConfirm = false` (line 20), and the `.confirmationDialog(...)` for completion (currently lines 72–86). The editor is now purely name/rate/notes; lifecycle lives on `ProjectDetailView`.

- [ ] **Step 4: Build**

Run the app build command.
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Verify the full flow on simulator**

Reinstall + launch with `--pretend-pro`. Seed demo. Then:
- Clients → a client → tap a project → **Project Detail** opens with hours hero, engagement line, uninvoiced tile.
- **Start timer** from the project; the inline running card appears (Break/Resume/Done work); Today reflects the same running timer.
- With a different project running, the button reads **Switch to this project** and switching works.
- **Create invoice** opens the generator already scoped to this project.
- **Complete project** → confirms, the project moves to the client's Archived section, and reopening its detail shows the `start – completion` range + **Restore**. Restore returns it to active.
- **Edit** (nav bar) opens the editor (no Complete button there anymore).
- A **non-billable** project shows hours only (no $ value, no uninvoiced tile, no Create invoice).

- [ ] **Step 6: Commit**

```bash
git add App/Sources/Features/Clients/ClientDetailView.swift App/Sources/Features/Projects/ProjectEditorView.swift
git commit -m "feat(projects): navigate to ProjectDetailView; move Complete onto it"
```

---

## Final verification

- [ ] **Run the full core test suite**

Run: `cd Packages/BillableCore && swift test`
Expected: PASS (existing suite + `ProjectCompletedAtTests` + `ProjectStatsTests`).

- [ ] **Full app build + manual sweep on simulator**

Run the app build command; reinstall + launch with `--pretend-pro`; walk the Task 7 Step 5 checklist once more end-to-end, plus confirm Today's timer and onboarding's first-timer are unchanged (Task 3/4 regression check).
