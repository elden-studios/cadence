# Phase 7 — Project-detail & sessions — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Fix the project-detail/sessions cluster — archived-project billing access, interactive/informative session rows, hero contrast, a per-second stats perf refactor, and a client-reassignment picker — without new features (the client picker is a user-approved in-scope gap-fill on an already-mutable field).

**Architecture:** App-layer (`ProjectDetailView`, `ProjectSessionsView`, `ProjectEditorView`, `WorkView`) + one BillableCore touch (`ProjectStats`, WS3, with an equivalence test). Build- + runtime-gated; WS3 grows the BillableCore test count past 344.

**Tech Stack:** SwiftUI, SwiftData; BillableCore; swift-testing.

**Spec:** `docs/superpowers/specs/2026-06-01-phase7-project-detail-sessions-design.md`. Decisions: archived-billing = split the gate + confirm note; #11 client reassignment = include (forward-only).

**Commands:**
- Unit tests: `swift test --package-path Packages/BillableCore`
- App + widget build: `xcodebuild -project Billable.xcodeproj -scheme Billable -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build/DerivedData build`

**Note for all tasks:** line numbers are current-as-of-writing; re-read the cited region before editing. Tasks 1–4 all touch `ProjectDetailView.swift` → run sequentially (each commits before the next). Keep existing style.

---

## File Structure
- `App/Sources/Features/Projects/ProjectDetailView.swift` — WS1 (gate/dismiss/copy/CTA), WS4 (hero), WS2 (preview row wiring + drop `private` on `TimerTickSchedule`), WS3 (base/ticking wiring).
- `App/Sources/Features/Projects/ProjectSessionsView.swift` — WS2 (`SessionRow` time-of-day + edit/delete + running tick).
- `Packages/BillableCore/Sources/BillableCore/Reporting/ProjectStats.swift` — WS3 (`base` + `ticking` + test).
- `Packages/BillableCore/Tests/BillableCoreTests/ProjectStatsTests.swift` (create) — WS3 equivalence test.
- `App/Sources/Features/Work/WorkView.swift` — WS3 (per-row stats wiring).
- `App/Sources/Features/Projects/ProjectEditorView.swift` — #11 (client picker).

Task order: 1 WS1 → 2 WS4 → 3 WS2 → 4 WS3 → 5 #11.

---

## Task 1 (WS1): ProjectDetail billing gate, lifecycle & CTA

**File:** `App/Sources/Features/Projects/ProjectDetailView.swift`. No unit test; gate = build.

- [ ] **Step 1: Split the archived-billing gate + promote the CTA.** In `content(asOf:…)`, replace the block (currently lines ~121-130):

```swift
            if project.isBillable && !project.isArchived {
                uninvoicedTile(stats: stats)
                Button {
                    showingInvoiceGenerator = true
                } label: {
                    Label("Create invoice", systemImage: "doc.text")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
```

with (keep the tile + Create-invoice visible on an archived project when it still has uninvoiced billable time; promote the CTA to prominent):

```swift
            if project.isBillable && (!project.isArchived || stats.uninvoicedAmount > 0) {
                uninvoicedTile(stats: stats)
                Button {
                    showingInvoiceGenerator = true
                } label: {
                    Label("Create invoice", systemImage: "doc.text")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
```

(The Start-timer control is separately gated on `!project.isArchived` in `timerArea` line ~217 — no timer can start on an archived project. Verified.)

- [ ] **Step 2: Don't strand the user on Complete.** In `completeProject()` (lines ~293-299), make the dismiss conditional so a project with outstanding billable time stays on-screen (the tile + Create-invoice are now visible):

```swift
    private func completeProject() {
        project.isArchived = true
        project.completedAt = .now
        project.updatedAt = .now
        modelContext.saveOrLog("complete project")
        // Stay on the (now-archived) detail when there's still uninvoiced billable
        // time to bill — the uninvoiced tile + Create-invoice remain visible (WS1).
        // Otherwise pop back as before.
        if ProjectStats.compute(for: project).uninvoicedAmount == 0 {
            dismiss()
        }
    }
```

- [ ] **Step 3: Amend the Complete confirmation copy.** Change the `confirmationDialog` message (line ~108):

```swift
            Text("Marks the project complete and moves it to Archived. Logged time stays on past invoices and reports, and any uninvoiced time stays billable here.")
```

- [ ] **Step 4: Build.** Run the xcodebuild command → `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit.**

```bash
git add App/Sources/Features/Projects/ProjectDetailView.swift
git commit -m "Phase 7 (WS1): bill archived projects' uninvoiced time; prominent CTA; don't strand on Complete"
```

---

## Task 2 (WS4): ProjectDetail hero contrast (WCAG AA)

**File:** `App/Sources/Features/Projects/ProjectDetailView.swift` (`hero(stats:)`). No unit test; gate = build.

- [ ] **Step 1: Promote the subline to solid white.** In `hero`, change line ~150:

```swift
        .foregroundStyle(.white)
```
(was `.foregroundStyle(.white.opacity(0.9))`)

- [ ] **Step 2: Deepen the gradient end stop so white clears AA.** Change the background gradient (line ~155):

```swift
            LinearGradient(colors: [.timerAccent, Color(red: 0.70, green: 0.30, blue: 0.04)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
```
(was `colors: [.timerAccent, .timerAccent.opacity(0.85)]`). Keeps the warm orange→deep-orange fade; the darker end stop pushes white-on-gradient comfortably past the 3:1 large-text AA threshold across the whole card.

- [ ] **Step 3: Build.** → `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit.**

```bash
git add App/Sources/Features/Projects/ProjectDetailView.swift
git commit -m "Phase 7 (WS4): deepen hero gradient + solid subline for WCAG AA contrast"
```

---

## Task 3 (WS2): Session rows — editable, time-of-day, live running tick

**Files:** `App/Sources/Features/Projects/ProjectSessionsView.swift` (primary), `App/Sources/Features/Projects/ProjectDetailView.swift` (preview wiring + make `TimerTickSchedule` non-private). No unit test; gate = build.

- [ ] **Step 1: Add start time-of-day to the shared `SessionRow`.** In `ProjectSessionsView.swift`, change `SessionRow.body` line ~34:

```swift
            Text(entry.startedAt.formatted(.dateTime.weekday().day().hour().minute()))
```
(was `.dateTime.weekday().day()`). This shows e.g. "Mon 2 9:30 AM" on every row in both the preview and the full history (shared view).

- [ ] **Step 2: Make `TimerTickSchedule` reachable from `ProjectSessionsView`.** In `ProjectDetailView.swift` line ~315, drop `private`:

```swift
struct TimerTickSchedule: TimelineSchedule, Equatable {
```
(was `private struct TimerTickSchedule…`). It stays in the same module; `ProjectSessionsView` can now reference it.

- [ ] **Step 3: Wire edit + delete + live tick in `ProjectSessionsView`.** Add `@Environment(\.modelContext)` and an editing state, wrap the running row in a `TimelineView`, and add tap-to-edit + swipe-delete. Replace the `struct ProjectSessionsView` body region. New property declarations (after `let currencyCode: String`):

```swift
    @Environment(\.modelContext) private var modelContext
    @State private var editingEntry: TimeEntry?
```

Replace the inner `ForEach(entries)` loop (lines ~76-79) with:

```swift
                        ForEach(entries) { entry in
                            sessionRow(entry)
                        }
```

Add these helpers inside `ProjectSessionsView` (after `body`):

```swift
    @ViewBuilder
    private func sessionRow(_ entry: TimeEntry) -> some View {
        Group {
            if entry.isRunning {
                TimelineView(TimerTickSchedule(running: true)) { ctx in
                    SessionRow(entry: entry, asOf: ctx.date,
                               currencyCode: currencyCode, isBillable: project.isBillable)
                }
            } else {
                SessionRow(entry: entry, asOf: entry.endedAt ?? entry.startedAt,
                           currencyCode: currencyCode, isBillable: project.isBillable)
                    .contentShape(Rectangle())
                    .onTapGesture { editingEntry = entry }
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { delete(entry) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func delete(_ entry: TimeEntry) {
        modelContext.delete(entry)
        modelContext.saveOrLog("delete session")
    }
```

Add the editor sheet to the `ScrollView` (e.g. directly after `.navigationBarTitleDisplayMode(.inline)`):

```swift
        .sheet(item: $editingEntry) { entry in
            NavigationStack { ManualEntrySheet(editing: entry) }
        }
```

(Tap-to-edit is wired only on completed rows — the running row stays live and is adjusted via the timer card, consistent with `ManualEntrySheet`'s running-entry guard. Verify `ManualEntrySheet(editing:)` is the correct initializer and whether it expects to be wrapped in a `NavigationStack` — match how `DayTimelineView` presents it; adjust the wrapper if `DayTimelineView` presents it bare.)

- [ ] **Step 4: Wire edit + delete in the `ProjectDetailView` preview rows.** In `ProjectDetailView.swift`: add `@State private var editingEntry: TimeEntry?` near the other `@State` (line ~22). In `recentSessions`, replace the inner `ForEach(entries)` SessionRow (lines ~261-269) so completed rows are tappable + swipe-deletable (running row stays as-is, already ticking via the outer TimelineView):

```swift
                    ForEach(entries) { entry in
                        SessionRow(entry: entry,
                                   asOf: entry.isRunning ? asOf : (entry.endedAt ?? entry.startedAt),
                                   currencyCode: currencyCode, isBillable: project.isBillable)
                            .contentShape(Rectangle())
                            .onTapGesture { if !entry.isRunning { editingEntry = entry } }
                            .swipeActions(edge: .trailing) {
                                if !entry.isRunning {
                                    Button(role: .destructive) { deleteSession(entry) } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                    }
```

Add a delete helper in `ProjectDetailView` (in the `// MARK: Actions` section):

```swift
    private func deleteSession(_ entry: TimeEntry) {
        modelContext.delete(entry)
        modelContext.saveOrLog("delete session")
    }
```

Add the editor sheet alongside the other `.sheet` modifiers (after line ~99):

```swift
        .sheet(item: $editingEntry) { entry in
            NavigationStack { ManualEntrySheet(editing: entry) }
        }
```

- [ ] **Step 5: Build.** → `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit.**

```bash
git add App/Sources/Features/Projects/ProjectSessionsView.swift App/Sources/Features/Projects/ProjectDetailView.swift
git commit -m "Phase 7 (WS2): session rows tap-to-edit + swipe-delete + time-of-day + live running tick"
```

---

## Task 4 (WS3): ProjectStats per-tick perf (O(1)) + equivalence test

**Files:** `Packages/BillableCore/Sources/BillableCore/Reporting/ProjectStats.swift`, `Packages/BillableCore/Tests/BillableCoreTests/ProjectStatsTests.swift` (create), `App/Sources/Features/Projects/ProjectDetailView.swift`, `App/Sources/Features/Work/WorkView.swift`.

**Context:** `compute(for:asOf:)` reduces over all `project.entries` every second. But `sessionCount`, `activeDayCount`, `firstTrackedDay` are asOf-independent, and completed entries' `duration()/amount()` are asOf-independent too — only the running entry's contribution ticks. So a `base` (computed once) + a per-tick `ticking(running:asOf:)` (O(1)) reproduce `compute` exactly. Keep `compute` as the unchanged reference.

- [ ] **Step 1: Write the failing equivalence test.** Create `Packages/BillableCore/Tests/BillableCoreTests/ProjectStatsTests.swift`:

```swift
import Foundation
import Testing
import SwiftData
@testable import BillableCore

@Suite("ProjectStats base + ticking equivalence")
@MainActor
struct ProjectStatsTests {
    @Test("base().ticking(running:asOf:) equals compute(asOf:) for a project with a running entry")
    func baseTickingEqualsCompute() throws {
        let container = try BillableModelContainer.inMemory()
        let context = ModelContext(container)
        let client = Client(name: "Acme")
        let project = Project(name: "Alpha", hourlyRate: 100, isBillable: true, client: client)
        context.insert(client); context.insert(project)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // two completed entries (one invoiced, one not) + one running entry
        let c1 = TimeEntry(startedAt: now.addingTimeInterval(-7200), endedAt: now.addingTimeInterval(-3600),
                           isManual: true, project: project, accumulatedSeconds: 3600)
        c1.invoiceID = UUID()                                   // invoiced → excluded from uninvoiced
        let c2 = TimeEntry(startedAt: now.addingTimeInterval(-3600), endedAt: now.addingTimeInterval(-1800),
                           isManual: true, project: project, accumulatedSeconds: 1800)
        let running = TimeEntry(startedAt: now.addingTimeInterval(-600), endedAt: nil,
                                project: project, accumulatedSeconds: 0, activeSegmentStartedAt: now.addingTimeInterval(-600))
        context.insert(c1); context.insert(c2); context.insert(running)
        try context.save()

        let base = ProjectStats.base(for: project)
        for offset in [0.0, 1.0, 60.0, 3600.0] {
            let asOf = now.addingTimeInterval(offset)
            let fast = base.ticking(running: running, asOf: asOf)
            let reference = ProjectStats.compute(for: project, asOf: asOf)
            #expect(fast == reference)
        }
        // No running entry → base alone equals compute.
        #expect(ProjectStats.base(for: project).ticking(running: nil, asOf: now)
                == ProjectStats.compute(for: project, asOf: now))
    }
}
```

- [ ] **Step 2: Run → FAIL (compile: `base`/`ticking` missing).** `swift test --package-path Packages/BillableCore --filter ProjectStatsTests` → expect compile failure.

- [ ] **Step 3: Add `base` + `ticking` to `ProjectStats`.** In `ProjectStats.swift`, add below `compute`:

```swift
    /// asOf-independent base: full session/day/first metrics over ALL entries, but
    /// time/value/uninvoiced summed over COMPLETED entries only. The running entry's
    /// live contribution is added per tick via `ticking(running:asOf:)`. Compute once
    /// (outside a per-second TimelineView); call `ticking` each tick. (Phase 7 / WS3)
    public static func base(for project: Project, calendar: Calendar = .current) -> ProjectStats {
        var seconds: TimeInterval = 0
        var value: Decimal = 0
        var uninvoiced: Decimal = 0
        var days = Set<Date>()
        var earliest: Date?
        for entry in project.entries {
            days.insert(calendar.startOfDay(for: entry.startedAt))
            earliest = earliest.map { Swift.min($0, entry.startedAt) } ?? entry.startedAt
            guard entry.endedAt != nil else { continue }   // running entry's time added in `ticking`
            seconds += entry.duration()
            let amount = entry.amount()
            value += amount
            if entry.invoiceID == nil { uninvoiced += amount }
        }
        return ProjectStats(
            lifetimeSeconds: seconds, lifetimeValue: value, uninvoicedAmount: uninvoiced,
            sessionCount: project.entries.count, activeDayCount: days.count, firstTrackedDay: earliest)
    }

    /// `base` plus the running entry's live duration/value at `asOf` (O(1)). Returns
    /// self unchanged when there is no running entry.
    public func ticking(running: TimeEntry?, asOf: Date) -> ProjectStats {
        guard let running, running.endedAt == nil else { return self }
        let s = running.duration(asOf: asOf)
        let a = running.amount(asOf: asOf)
        return ProjectStats(
            lifetimeSeconds: lifetimeSeconds + s,
            lifetimeValue: lifetimeValue + a,
            uninvoicedAmount: uninvoicedAmount + (running.invoiceID == nil ? a : 0),
            sessionCount: sessionCount,
            activeDayCount: activeDayCount,
            firstTrackedDay: firstTrackedDay)
    }
```

- [ ] **Step 4: Run → PASS.** `swift test --package-path Packages/BillableCore --filter ProjectStatsTests` → PASS. Then full `swift test --package-path Packages/BillableCore` → all green (≥345).

- [ ] **Step 5: Use base/ticking in `ProjectDetailView`.** In `body`, compute the base once alongside the hoisted sort/group (after line ~52):

```swift
        let statsBase = ProjectStats.base(for: project)
```
Pass it into `content`: change the call (line ~61) to `content(asOf: context.date, statsBase: statsBase, groupedEntries: groupedEntries, totalCount: totalCount)` and the signature (line ~113) to add `statsBase: ProjectStats`. Replace the per-tick compute (line ~114):

```swift
        let stats = statsBase.ticking(running: runningEntryForProject, asOf: asOf)
```
(removes `ProjectStats.compute(for: project, asOf: asOf)` from the per-second closure). NOTE: `completeProject()` (WS1 Task 1) still calls `ProjectStats.compute(for: project)` directly — that's a one-shot on a button tap, leave it.

- [ ] **Step 6: Use base/ticking in `WorkView`.** Read `WorkView.swift` around the per-row `TimelineView` (~252) and `statsLine(asOf:)` (~302). Compute `ProjectStats.base(for: project)` once per row outside that row's `TimelineView`, and inside use `base.ticking(running: <the row's running entry>, asOf:)` instead of `ProjectStats.compute(for: project, asOf: asOf)`. Match the existing structure (the row already knows its project + whether it's the running one). If the row doesn't already resolve its running entry, derive it as `project.entries.first { $0.isRunning }` for the base/ticking call.

- [ ] **Step 7: Build + full test.** `swift test --package-path Packages/BillableCore` → all pass (≥345). `xcodebuild … build` → `** BUILD SUCCEEDED **`.

- [ ] **Step 8: Commit.**

```bash
git add Packages/BillableCore/Sources/BillableCore/Reporting/ProjectStats.swift Packages/BillableCore/Tests/BillableCoreTests/ProjectStatsTests.swift App/Sources/Features/Projects/ProjectDetailView.swift App/Sources/Features/Work/WorkView.swift
git commit -m "Phase 7 (WS3): O(1) per-tick ProjectStats via base+ticking split (+ equivalence test)"
```

---

## Task 5 (#11): ProjectEditor client reassignment

**Files:** `App/Sources/Features/Projects/ProjectEditorView.swift`, `App/Sources/Features/Projects/ProjectDetailView.swift` (call site). No unit test; gate = build.

- [ ] **Step 1: Read the picker pattern.** Read `ManualEntrySheet.swift` ~113-157 (the client-grouped `Menu` project/client picker) and confirm its exact shape (Menu label + per-client rows + checkmark). Also `grep -rn "ProjectEditorView(" App` to find ALL call sites (at least `ProjectDetailView.swift:91` + the New-Project flow).

- [ ] **Step 2: Make `client` optional + add picker state.** In `ProjectEditorView.swift`: change `let client: Client` (line 11) to `let client: Client?`. Add near the other `@State` (after line ~24):

```swift
    @Query(filter: #Predicate<Client> { !$0.isArchived }, sort: \Client.name) private var clients: [Client]
    @State private var selectedClient: Client?
```
(Add `import SwiftData` is already present.)

- [ ] **Step 3: Default the selection in `loadIfNeeded()`.** Add at the end of `loadIfNeeded()` (after line ~82, and also handle the new-project case where `project` is nil — the current `guard let project else { return }` returns early for new projects, so set `selectedClient` BEFORE that guard):

Replace `loadIfNeeded()` with:

```swift
    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        selectedClient = project?.client ?? client
        guard let project else { return }
        name = project.name
        hourlyRateInput = (project.hourlyRate as NSDecimalNumber).doubleValue
        isBillable = project.isBillable
        notes = project.notes ?? ""
    }
```

- [ ] **Step 4: Add the client picker row to the "Project" section.** In the `Section("Project")` (lines ~28-31), after the name `TextField`, add a `Menu` picker matching the ManualEntrySheet pattern, e.g.:

```swift
                Menu {
                    ForEach(clients) { c in
                        Button { selectedClient = c } label: {
                            if selectedClient?.persistentModelID == c.persistentModelID {
                                Label(c.name, systemImage: "checkmark")
                            } else {
                                Text(c.name)
                            }
                        }
                    }
                } label: {
                    LabeledContent("Client") {
                        Text(selectedClient?.name ?? "Select client")
                            .foregroundStyle(selectedClient == nil ? .secondary : .primary)
                    }
                }
```
(Adapt to the exact ManualEntrySheet styling if it differs — match it.)

- [ ] **Step 5: Persist the selection in `save()`.** In the existing-project branch (lines ~93-98) add `existing.client = selectedClient`. In the new-project branch (lines ~100-107) change `client: client` to `client: selectedClient`:

```swift
        if let existing = project {
            existing.name = trimmedName
            existing.hourlyRate = rate
            existing.isBillable = isBillable
            existing.notes = storedNotes
            existing.client = selectedClient
            existing.updatedAt = .now
        } else {
            let new = Project(
                name: trimmedName, hourlyRate: rate, isBillable: isBillable,
                notes: storedNotes, client: selectedClient
            )
            modelContext.insert(new)
        }
```

- [ ] **Step 6: Fix the call site(s).** In `ProjectDetailView.swift:91`, change `ProjectEditorView(client: project.client ?? Client(name: ""), project: project)` to:

```swift
                ProjectEditorView(client: project.client, project: project)
```
For any New-Project-flow call site found in Step 1, passing a non-optional `Client` to the now-`Client?` parameter still compiles unchanged — leave it.

- [ ] **Step 7: Build.** → `** BUILD SUCCEEDED **`.

- [ ] **Step 8: Commit.**

```bash
git add App/Sources/Features/Projects/ProjectEditorView.swift App/Sources/Features/Projects/ProjectDetailView.swift
git commit -m "Phase 7 (#11): client picker in ProjectEditor (reassign a project's client; forward-only)"
```

---

## Final verification (after all tasks)

- [ ] `swift test --package-path Packages/BillableCore` → all pass (≥345; new `ProjectStatsTests`).
- [ ] App + widget `xcodebuild … build` → `** BUILD SUCCEEDED **`.
- [ ] Runtime (seeded sim): archived billable project w/ uninvoiced → tile + prominent "Create invoice" visible; Complete on a project w/ uninvoiced stays on detail, w/o dismisses; tap a completed session → editor; swipe → delete; SessionRow shows start time; "See all sessions" mid-run ticks live; hero text legible; project editor reassigns client + persists.

## Self-Review

**1. Spec coverage:** WS1→Task 1 (gate split + dismiss + copy + CTA); WS4→Task 2 (hero); WS2→Task 3 (edit/delete + time-of-day + running tick, both screens, `TimerTickSchedule` un-private'd); WS3→Task 4 (base/ticking + test + ProjectDetail + WorkView); #11→Task 5. ✅
**2. Placeholder scan:** every code step shows concrete before/after; the two read-first spots (WorkView structure in Task 4 Step 6; ManualEntrySheet picker shape + call-site grep in Task 5 Step 1) explicitly say to match existing code. ✅
**3. Type consistency:** `ProjectStats.base(for:)`/`ticking(running:asOf:)` defined in Task 4 Step 3 and called identically in the test (Step 1), ProjectDetailView (Step 5), WorkView (Step 6). `editingEntry: TimeEntry?` + `deleteSession`/`delete` consistent. `client: Client?` propagated to both `save()` branches + the call site. The `completeProject` one-shot `ProjectStats.compute` (Task 1) intentionally stays. ✅

**Implementer note:** confirm `ManualEntrySheet(editing:)` presentation style (wrapped in `NavigationStack` vs bare) against `DayTimelineView`'s usage and match it in both new `.sheet(item:)` sites.
