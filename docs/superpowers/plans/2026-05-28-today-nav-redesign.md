# Today + Navigation Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the app project-first: a "Work" tab (project browser + Projects|Clients toggle) replaces Clients, Today becomes a daily summary + quick-resume, and a persistent floating timer bar makes the running timer visible on every screen.

**Architecture:** A new `RecentProjects` ranking helper (BillableCore) feeds Today's quick-resume and StartTimerSheet. A `FloatingTimerBar` is attached to the `TabView` via `.safeAreaInset(edge: .bottom)` and expands the existing `RunningTimerCard`. The Clients tab is replaced by `WorkView`, which hosts a project browser and the (extracted) clients list under a segmented toggle. Today is rebuilt from its existing summary pieces plus a recents row. All timer mutations route through the existing `TimerActions`.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Swift Testing. iOS app target `Billable`; core logic in the `BillableCore` package.

**Branch:** `feature/today-nav-redesign` (cut from `feature/project-detail`). Do not touch shared branches.

**Spec:** `docs/superpowers/specs/2026-05-28-today-nav-redesign-design.md`

**Build/verify commands:**
- Core tests: `cd Packages/BillableCore && swift test`
- App build: `xcodebuild -project Billable.xcodeproj -scheme Billable -configuration Debug -destination 'platform=iOS Simulator,id=A946AE5D-C969-4EB2-8384-001B3451A6A4' -derivedDataPath build/DerivedData build`
- New `.swift` files in `App/Sources` must be registered by running `xcodegen generate` from the repo root before building (the `App/Sources` group is a recursive glob).
- Reinstall + launch with Pro: `xcrun simctl install A946AE5D-C969-4EB2-8384-001B3451A6A4 build/DerivedData/Build/Products/Debug-iphonesimulator/Billable.app && xcrun simctl launch A946AE5D-C969-4EB2-8384-001B3451A6A4 com.eldenstudios.billable --pretend-pro`

---

## Task 1: `RecentProjects` ranking helper

**Files:**
- Create: `Packages/BillableCore/Sources/BillableCore/Reporting/RecentProjects.swift`
- Test: `Packages/BillableCore/Tests/BillableCoreTests/RecentProjectsTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Packages/BillableCore/Tests/BillableCoreTests/RecentProjectsTests.swift`:

```swift
import Foundation
import Testing
import SwiftData
@testable import BillableCore

@Suite("RecentProjects.rank")
@MainActor
struct RecentProjectsTests {
    private func fixture() throws -> (ModelContext, Client) {
        let container = try BillableModelContainer.inMemory()
        let context = ModelContext(container)
        let client = Client(name: "Acme")
        context.insert(client)
        try context.save()
        return (context, client)
    }

    private func project(_ ctx: ModelContext, _ client: Client, _ name: String, archived: Bool = false) -> Project {
        let p = Project(name: name, hourlyRate: 50, isArchived: archived, client: client)
        ctx.insert(p)
        return p
    }

    private func entry(_ ctx: ModelContext, _ p: Project, at: Date) {
        ctx.insert(TimeEntry(startedAt: at, endedAt: at.addingTimeInterval(60), isManual: true, project: p))
    }

    private let t0 = Date(timeIntervalSince1970: 1_779_000_000)

    @Test("ranks distinct projects by most-recent entry, newest first")
    func ranksByRecency() throws {
        let (ctx, client) = try fixture()
        let a = project(ctx, client, "A"); let b = project(ctx, client, "B"); let c = project(ctx, client, "C")
        entry(ctx, a, at: t0)
        entry(ctx, b, at: t0.addingTimeInterval(100))
        entry(ctx, c, at: t0.addingTimeInterval(200))
        try ctx.save()
        let all = try ctx.fetch(FetchDescriptor<TimeEntry>())
        let ranked = RecentProjects.rank(from: all, limit: 5)
        #expect(ranked.map(\.name) == ["C", "B", "A"])
    }

    @Test("dedupes a project with multiple recent entries to its latest")
    func dedupes() throws {
        let (ctx, client) = try fixture()
        let a = project(ctx, client, "A"); let b = project(ctx, client, "B")
        entry(ctx, a, at: t0)
        entry(ctx, b, at: t0.addingTimeInterval(50))
        entry(ctx, a, at: t0.addingTimeInterval(100)) // A used again, most recently
        try ctx.save()
        let all = try ctx.fetch(FetchDescriptor<TimeEntry>())
        let ranked = RecentProjects.rank(from: all, limit: 5)
        #expect(ranked.map(\.name) == ["A", "B"])
    }

    @Test("excludes archived projects")
    func excludesArchived() throws {
        let (ctx, client) = try fixture()
        let a = project(ctx, client, "A", archived: true); let b = project(ctx, client, "B")
        entry(ctx, a, at: t0.addingTimeInterval(100))
        entry(ctx, b, at: t0)
        try ctx.save()
        let all = try ctx.fetch(FetchDescriptor<TimeEntry>())
        #expect(RecentProjects.rank(from: all, limit: 5).map(\.name) == ["B"])
    }

    @Test("caps at limit")
    func caps() throws {
        let (ctx, client) = try fixture()
        for i in 0..<6 { entry(ctx, project(ctx, client, "P\(i)"), at: t0.addingTimeInterval(Double(i))) }
        try ctx.save()
        let all = try ctx.fetch(FetchDescriptor<TimeEntry>())
        #expect(RecentProjects.rank(from: all, limit: 3).count == 3)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Packages/BillableCore && swift test --filter RecentProjectsTests`
Expected: FAIL — `cannot find 'RecentProjects' in scope`.

- [ ] **Step 3: Implement the helper**

Create `Packages/BillableCore/Sources/BillableCore/Reporting/RecentProjects.swift`:

```swift
import Foundation
import SwiftData

/// Ranks the most-recently-worked projects for quick-resume surfaces
/// (Today's "Jump back in" row and the StartTimerSheet recents).
public enum RecentProjects {
    /// Distinct, non-archived projects ordered by their most recent entry
    /// (newest first), capped at `limit`. Sorts internally, so the caller's
    /// fetch order doesn't matter.
    public static func rank(from entries: [TimeEntry], limit: Int) -> [Project] {
        let sorted = entries.sorted { $0.startedAt > $1.startedAt }
        var seen = Set<PersistentIdentifier>()
        var ordered: [Project] = []
        for entry in sorted {
            guard let project = entry.project, !project.isArchived else { continue }
            if seen.insert(project.persistentModelID).inserted {
                ordered.append(project)
                if ordered.count == limit { break }
            }
        }
        return ordered
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Packages/BillableCore && swift test --filter RecentProjectsTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Run the full core suite**

Run: `cd Packages/BillableCore && swift test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Reporting/RecentProjects.swift Packages/BillableCore/Tests/BillableCoreTests/RecentProjectsTests.swift
git commit -m "feat(core): add RecentProjects ranking helper"
```

---

## Task 2: `FloatingTimerBar` + wire into RootView

The highest-risk task — build and verify it in isolation across all tabs before anything depends on it. Verification is build + simulator.

**Files:**
- Create: `App/Sources/Features/Timer/FloatingTimerBar.swift`
- Modify: `App/Sources/App/RootView.swift` (attach the bar to the TabView)

- [ ] **Step 1: Create the bar**

Create `App/Sources/Features/Timer/FloatingTimerBar.swift`:

```swift
import SwiftUI
import SwiftData
import BillableCore

/// Persistent bar shown above the tab bar whenever a timer is running.
/// Tapping it expands the full `RunningTimerCard` in a sheet. Renders nothing
/// when idle (the host attaches it via `.safeAreaInset`, so nothing = no inset).
struct FloatingTimerBar: View {
    @Query(Self.runningDescriptor) private var runningEntries: [TimeEntry]
    @Query private var profiles: [BusinessProfile]
    @Environment(\.modelContext) private var modelContext

    @State private var expanded = false
    @State private var showingSwitchSheet = false

    private static var runningDescriptor: FetchDescriptor<TimeEntry> {
        var d = FetchDescriptor<TimeEntry>(predicate: #Predicate { $0.endedAt == nil })
        d.fetchLimit = 1
        return d
    }

    private var currencyCode: String {
        profiles.first?.currencyCode ?? Locale.current.currency?.identifier ?? "USD"
    }

    var body: some View {
        if let running = runningEntries.first {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                bar(running, asOf: context.date)
            }
            .sheet(isPresented: $expanded) {
                expandedSheet(running)
            }
            .sheet(isPresented: $showingSwitchSheet) {
                StartTimerSheet(isSwitching: true)
            }
        }
    }

    private func bar(_ entry: TimeEntry, asOf: Date) -> some View {
        let accent = entry.isOnBreak ? Color.orange : Color.green
        return Button { expanded = true } label: {
            HStack(spacing: 10) {
                Circle().fill(accent).frame(width: 9, height: 9)
                Text(entry.project?.name ?? "Timer")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(elapsedString(entry, asOf: asOf))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.up")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(.regularMaterial, in: .rect(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(accent.opacity(0.45), lineWidth: 1)
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
        }
        .buttonStyle(.plain)
    }

    private func expandedSheet(_ entry: TimeEntry) -> some View {
        ScrollView {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                RunningTimerCard(
                    entry: entry, asOf: context.date, currencyCode: currencyCode,
                    onStop: { TimerActions.stop(in: modelContext); expanded = false },
                    onSwitch: { expanded = false; showingSwitchSheet = true },
                    onTakeBreak: { TimerActions.takeBreak(in: modelContext) },
                    onResume: { TimerActions.resume(in: modelContext) }
                )
                .id(entry.persistentModelID)
                .padding()
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func elapsedString(_ entry: TimeEntry, asOf: Date) -> String {
        let seconds = Int(entry.duration(asOf: asOf))
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}
```

- [ ] **Step 2: Attach the bar to the TabView in RootView**

In `App/Sources/App/RootView.swift`, in `mainShell`, add a `.safeAreaInset` to the `TabView`. Find the `TabView(selection: $selectedTab) { ... }` closing brace and the `.sheet(isPresented: $showingReportsPaywall)` that follows it; insert the inset modifier on the `TabView` (before the existing `.sheet`/`.onChange` modifiers):

```swift
            TabView(selection: $selectedTab) {
                // ... unchanged tab items ...
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                FloatingTimerBar()
            }
            .sheet(isPresented: $showingReportsPaywall) {
                PaywallView(trigger: .reports)
            }
            // ... existing .onChange modifiers unchanged ...
```

`FloatingTimerBar` renders an empty body when no timer runs, so `safeAreaInset` adds zero height in that case.

- [ ] **Step 3: Register + build**

Run `xcodegen generate` (repo root), then the app build command.
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Verify the bar on the simulator (across tabs)**

Reinstall + launch with `--pretend-pro`. With a timer running (start one from Today's existing Start flow, or via the Clients→project path), verify:
- The green bar appears above the tab bar and shows the project name + live ticking time.
- It is visible on **every** tab (Today, Clients, Invoices, Reports, Settings) and doesn't overlap tab content.
- Tapping it opens the expand sheet with the full card; Take a Break flips the bar to amber/ON BREAK; Done for now ends the timer and the bar disappears.
- Switch from the expanded card opens the StartTimerSheet and switching works (verify the expanded sheet dismisses first, then the switch sheet presents — if they conflict, that's the known sheet-over-sheet edge; adjust by presenting the switch sheet from within the expanded sheet instead).
- When idle (no running timer), there is no bar and no empty gap above the tab bar.

- [ ] **Step 5: Commit**

```bash
git add App/Sources/Features/Timer/FloatingTimerBar.swift App/Sources/App/RootView.swift Billable.xcodeproj/project.pbxproj
git commit -m "feat(timer): add persistent floating timer bar across tabs"
```

---

## Task 3: Refocus `TodayView`

Today loses its running/idle timer card (the bar owns the timer) and becomes a daily summary + "Jump back in" recents. Verification is build + simulator.

**Files:**
- Modify: `App/Sources/Features/Today/TodayView.swift`

- [ ] **Step 1: Replace the active-timer section with a recents row**

In `TodayView.swift`, in the main `VStack` of `body`, **remove** the `TodayActiveTimerSection(...)` call (the whole block passing `onStop/onSwitch/onTakeBreak/onResume/onStart`) and replace it with a `JumpBackInSection()`. Keep `headerSection`, `CatchUpBanner`, the business-profile banner, and `TodaySummarySection`. The resulting `body` VStack content order is: `headerSection`, `CatchUpBanner`, business banner (if shown), `JumpBackInSection()`, `TodaySummarySection(currencyCode:)`.

Also **remove** the now-unused timer plumbing from `TodayView`: the `stopRunning()` method, the `showingStartSheet`/`showingSwitchSheet` state and their `.sheet` modifiers, and the `onStart`/`onStop` wiring. **Keep** `showingManualEntry` + its sheet and the toolbar (timeline button, "＋" add-past-entry, "Seed demo"). Keep the `editingEntry` sheet.

- [ ] **Step 2: Add the `JumpBackInSection` view**

Add this private view to `TodayView.swift` (it reuses `RecentProjects` from Task 1 and `TimerActions`):

```swift
private struct JumpBackInSection: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [BusinessProfile]
    @Query(Self.recentDescriptor) private var recentEntries: [TimeEntry]

    private static var recentDescriptor: FetchDescriptor<TimeEntry> {
        // Last ~60 days of entries; RecentProjects dedupes/caps. Sorted desc so
        // the fetch is cheap; the helper re-sorts defensively.
        let cutoff = Date.now.addingTimeInterval(-60 * 24 * 3600)
        var d = FetchDescriptor<TimeEntry>(
            predicate: #Predicate { $0.startedAt > cutoff },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        d.relationshipKeyPathsForPrefetching = [\.project]
        return d
    }

    private var currencyCode: String {
        profiles.first?.currencyCode ?? "USD"
    }

    private var recents: [Project] {
        RecentProjects.rank(from: recentEntries, limit: 5)
    }

    var body: some View {
        if !recents.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Jump back in")
                    .font(.headline)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(recents) { project in
                            card(project)
                        }
                    }
                }
            }
        }
    }

    private func card(_ project: Project) -> some View {
        // ZStack (not a Button nested in the NavigationLink label) so the
        // ▶ and the navigation are independent tap targets — nesting a Button
        // inside a NavigationLink label makes taps ambiguous in SwiftUI.
        ZStack(alignment: .topTrailing) {
            NavigationLink {
                ProjectDetailView(project: project)
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Circle()
                        .fill(project.client?.color.swiftUIColor ?? .blue)
                        .frame(width: 10, height: 10)
                    Spacer(minLength: 16)
                    Text(project.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .foregroundStyle(.primary)
                    if let client = project.client {
                        Text(client.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(width: 134, height: 104, alignment: .leading)
                .padding(12)
                .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 14))
            }
            .buttonStyle(.plain)

            Button {
                TimerActions.start(project: project, currencyCode: currencyCode, in: modelContext)
            } label: {
                Image(systemName: "play.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Color(red: 0.98, green: 0.49, blue: 0.13), in: .circle)
            }
            .buttonStyle(.plain)
            .padding(10)
        }
    }
}
```

Note: the inner play `Button` calls `TimerActions.start` directly. If a different project is running, `TimerActions.start` finalizes it and starts this one; this matches the existing one-tap-start behavior elsewhere. (Switching semantics with a confirmation are handled on the Project Detail screen and the bar; the quick-resume row favors immediacy.)

- [ ] **Step 3: Confirm `TodayView` still imports what it needs**

`TodayView.swift` already imports `SwiftUI`, `SwiftData`, `BillableCore`. `WidgetKit` was already removed in the project-detail branch. Ensure no references remain to the removed `TimerService`/`TimerActions` calls that lived in the deleted closures (the `JumpBackInSection` is the only `TimerActions` user now).

- [ ] **Step 4: Build + verify**

Run the app build command (no new files, but run `xcodegen generate` is unnecessary — only `TodayView.swift` changed). Expected: BUILD SUCCEEDED.
Reinstall + launch. Verify Today shows: date header, "Jump back in" row (when recents exist) with working ▶ + tap-to-detail, and the Hours/Earnings/Uninvoiced summary. Confirm the old in-Today timer card is gone and the running timer now shows only in the floating bar.

- [ ] **Step 5: Commit**

```bash
git add App/Sources/Features/Today/TodayView.swift
git commit -m "feat(today): refocus on daily summary + jump-back-in recents"
```

---

## Task 4: Extract the clients list for embedding

`ClientsView` currently wraps its content in its own `NavigationStack`, which can't be nested inside `WorkView`'s stack. Extract the inner content into a reusable view.

**Files:**
- Modify: `App/Sources/Features/Clients/ClientsView.swift`

- [ ] **Step 1: Split out `ClientsListContent`**

In `ClientsView.swift`, move everything currently inside the `NavigationStack { ... }` (the `Group`/empty-state/`listContent`, the `.navigationTitle`, `.toolbar`, `.sheet`, `.confirmationDialog`) into a new `struct ClientsListContent: View` that does **not** wrap itself in a `NavigationStack`. Move the `@Query`s, `@State`, `lastInvoiceByClientID`, `deleteClient`, `startAddClient`, `listContent`, and the `ClientRow` helper into `ClientsListContent`. Then redefine `ClientsView` as a thin wrapper that provides the stack:

```swift
struct ClientsView: View {
    var body: some View {
        NavigationStack {
            ClientsListContent()
        }
    }
}
```

`ClientsListContent` keeps `.navigationTitle("Clients")`, `.toolbar`, `.sheet`, and `.confirmationDialog` (these all work inside whatever `NavigationStack` the host provides). `ClientRow` stays `private` alongside `ClientsListContent`.

- [ ] **Step 2: Build**

Run the app build command. Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Verify Clients still works (still a tab at this point)**

Reinstall + launch. The Clients tab behaves exactly as before (list, add, archive/restore, delete, tap → client detail). This confirms the extraction is behavior-preserving before Task 5 swaps the tab.

- [ ] **Step 4: Commit**

```bash
git add App/Sources/Features/Clients/ClientsView.swift
git commit -m "refactor(clients): extract ClientsListContent for embedding"
```

---

## Task 5: `WorkView` + swap the Clients tab

**Files:**
- Create: `App/Sources/Features/Work/WorkView.swift`
- Modify: `App/Sources/App/RootView.swift` (swap tab 1 Clients → Work)

- [ ] **Step 1: Create `WorkView`**

Create `App/Sources/Features/Work/WorkView.swift`:

```swift
import SwiftUI
import SwiftData
import BillableCore

struct WorkView: View {
    private enum Mode: String, CaseIterable { case projects = "Projects", clients = "Clients" }

    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [BusinessProfile]
    @Query(filter: #Predicate<Project> { !$0.isArchived }, sort: \Project.name)
    private var activeProjects: [Project]
    @Query(Self.runningDescriptor) private var runningEntries: [TimeEntry]

    @State private var mode: Mode = .projects
    @State private var search = ""

    private static var runningDescriptor: FetchDescriptor<TimeEntry> {
        var d = FetchDescriptor<TimeEntry>(predicate: #Predicate { $0.endedAt == nil })
        d.fetchLimit = 1
        return d
    }

    private var currencyCode: String {
        profiles.first?.currencyCode ?? Locale.current.currency?.identifier ?? "USD"
    }

    var body: some View {
        NavigationStack {
            Group {
                if mode == .projects {
                    projectsList
                } else {
                    ClientsListContent()
                }
            }
            .navigationTitle("Work")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("View", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                }
            }
        }
    }

    // MARK: Projects browser

    private var filteredProjects: [Project] {
        guard !search.isEmpty else { return activeProjects }
        return activeProjects.filter {
            $0.name.localizedCaseInsensitiveContains(search)
            || ($0.client?.name.localizedCaseInsensitiveContains(search) ?? false)
        }
    }

    /// Projects grouped by client name (sorted), for sectioned display.
    private var grouped: [(client: String, projects: [Project])] {
        let byClient = Dictionary(grouping: filteredProjects) { $0.client?.name ?? "No client" }
        return byClient.keys.sorted().map { ($0, byClient[$0]!.sorted { $0.name < $1.name }) }
    }

    @ViewBuilder
    private var projectsList: some View {
        if activeProjects.isEmpty {
            ContentUnavailableView {
                Label("No projects yet", systemImage: "folder")
            } description: {
                Text("Add a client and a project to start tracking.")
            }
        } else {
            List {
                ForEach(grouped, id: \.client) { group in
                    Section(group.client) {
                        ForEach(group.projects) { project in
                            ProjectBrowserRow(
                                project: project,
                                currencyCode: currencyCode,
                                isRunning: runningEntries.first?.project?.persistentModelID == project.persistentModelID,
                                anotherRunning: runningEntries.first != nil
                                    && runningEntries.first?.project?.persistentModelID != project.persistentModelID,
                                onPlay: {
                                    if runningEntries.first != nil
                                        && runningEntries.first?.project?.persistentModelID != project.persistentModelID {
                                        TimerActions.switchTo(project: project, currencyCode: currencyCode, in: modelContext)
                                    } else {
                                        TimerActions.start(project: project, currencyCode: currencyCode, in: modelContext)
                                    }
                                }
                            )
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Search projects or clients")
        }
    }
}

private struct ProjectBrowserRow: View {
    let project: Project
    let currencyCode: String
    let isRunning: Bool
    let anotherRunning: Bool
    let onPlay: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            NavigationLink {
                ProjectDetailView(project: project)
            } label: {
                HStack(spacing: 12) {
                    Circle()
                        .fill(project.client?.color.swiftUIColor ?? .blue)
                        .frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.name)
                        Text(statsLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Button(action: onPlay) {
                Image(systemName: isRunning ? "waveform" : "play.fill")
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(
                        (isRunning ? Color.green : Color(red: 0.98, green: 0.49, blue: 0.13)),
                        in: .circle
                    )
            }
            .buttonStyle(.plain)
            .disabled(isRunning)
            .accessibilityLabel(isRunning ? "Running" : (anotherRunning ? "Switch to this project" : "Start timer"))
        }
    }

    private var statsLine: String {
        let stats = ProjectStats.compute(for: project)
        let hours = Int(stats.lifetimeSeconds / 3600)
        let mins = (Int(stats.lifetimeSeconds) % 3600) / 60
        let time = "\(hours)h \(String(format: "%02d", mins))m"
        guard project.isBillable else { return time }
        return "\(time) · \(stats.lifetimeValue.formatted(.currency(code: currencyCode)))"
    }
}
```

Note: `ProjectStats.compute(for:)` is called per visible row at render — acceptable for 6–15 projects. The play button is disabled (shown as a waveform) for the already-running project; otherwise it starts or switches.

- [ ] **Step 2: Swap the tab in RootView**

In `App/Sources/App/RootView.swift`, replace the Clients tab item (tag 1) with Work:

```swift
                WorkView()
                    .tabItem { Label("Work", systemImage: "square.stack.3d.up") }
                    .tag(1)
```

(Leave tags 0, 2, 3, 4 and all `.onChange` routing unchanged — only tab 1's content/label changed.)

- [ ] **Step 3: Register + build**

Run `xcodegen generate` (new file), then the app build command. Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Verify on simulator**

Reinstall + launch with `--pretend-pro`. Verify:
- Tab bar reads `Today · Work · Invoices · Reports · Settings`.
- Work → Projects: projects grouped by client with `Hours · $` per row; search filters by project/client; ▶ starts (or switches if another runs); the running project's button shows the waveform/disabled state; tapping a row opens Project Detail.
- Work → Clients toggle: the full client list + add/archive/restore/delete + tap → client detail (same as the old Clients tab).
- The floating bar still works over the Work tab.

- [ ] **Step 5: Commit**

```bash
git add App/Sources/Features/Work/WorkView.swift App/Sources/App/RootView.swift Billable.xcodeproj/project.pbxproj
git commit -m "feat(work): add Work tab (project browser + clients toggle), replace Clients"
```

---

## Task 6: Migrate `StartTimerSheet` recents to the shared helper

**Files:**
- Modify: `App/Sources/Features/Timer/StartTimerSheet.swift`

- [ ] **Step 1: Replace the inline recents logic**

In `StartTimerSheet.swift`, the computed `recentProjects` currently fetches and dedupes inline. Replace its body to delegate ranking to the shared helper (keep the same 30-day fetch window and top-3 cap):

```swift
    private var recentProjects: [Project] {
        let cutoff = Date.now.addingTimeInterval(-30 * 24 * 3600)
        let descriptor = FetchDescriptor<TimeEntry>(
            predicate: #Predicate { entry in entry.startedAt > cutoff },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        let entries = (try? modelContext.fetch(descriptor)) ?? []
        return RecentProjects.rank(from: entries, limit: 3)
    }
```

This removes the hand-rolled `seen`/`ordered` dedupe loop in favor of `RecentProjects.rank` (Task 1), so Today and the sheet share one implementation.

- [ ] **Step 2: Build**

Run the app build command. Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Verify**

Reinstall + launch. Open the StartTimerSheet (e.g. from a project's Switch action or Today's flows): the "Recent" section still shows up to 3 most-recent projects, unchanged.

- [ ] **Step 4: Commit**

```bash
git add App/Sources/Features/Timer/StartTimerSheet.swift
git commit -m "refactor(timer): StartTimerSheet recents use shared RecentProjects"
```

---

## Final verification

- [ ] **Core suite:** `cd Packages/BillableCore && swift test` → all green (existing + `RecentProjectsTests`).
- [ ] **Full app build:** the app build command → BUILD SUCCEEDED.
- [ ] **End-to-end simulator sweep** (reinstall + `--pretend-pro`):
  - Tabs: `Today · Work · Invoices · Reports · Settings`.
  - Today: daily tiles + jump-back-in recents (▶ + tap-to-detail); no in-Today timer card.
  - Work: project browser (grouped, searchable, ▶/switch, tap→detail) + Clients toggle (full management).
  - Floating bar: appears on every tab while running, ticks live, expands to the full card (Break/Resume/Switch/Done), disappears when stopped.
  - Start a timer from Today recents and from Work; switch between projects; confirm the bar and Project Detail stay consistent.
  - Notification deep-links still land on the correct tabs.
