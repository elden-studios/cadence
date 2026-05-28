# Today Timer Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Today timer's stop-only model with Break / Resume / "Done for now", logging one entry per session with break time excluded, and propagate the new `duration()` meaning + On-Break state across the dashboard, widgets, day-timeline, and CSV.

**Architecture:** A work session is one `TimeEntry`. Worked time is banked in a new `accumulatedSeconds` field across work segments; `activeSegmentStartedAt` marks the live segment (nil ⇒ On Break). `duration()` becomes worked time (breaks excluded), with a wall-clock fallback so manual/legacy entries are unaffected (no migration). `TimerService` gains `takeBreak`/`resume`; "Done for now" reuses stop semantics; "Complete Project" is a separate action reusing `Project.isArchived`.

**Tech Stack:** Swift 6, SwiftData, SwiftUI, Swift Testing (`@Suite`/`@Test`/`#expect`). Core domain in `Packages/BillableCore` (run `cd Packages/BillableCore && swift test`); app UI in `App/Sources` (verify by build + simulator). Spec: `docs/superpowers/specs/2026-05-28-today-timer-redesign-design.md`.

**Worktree note:** The spec + this plan live on `main`. Create a feature branch/worktree for the *code* before Task 1 (the execution sub-skill will prompt for this).

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `Packages/BillableCore/Sources/BillableCore/Models/TimeEntry.swift` | Session state + worked-time math | Add fields, `isWorking`/`isOnBreak`, redefine `duration()` |
| `Packages/BillableCore/Sources/BillableCore/Timing/TimerService.swift` | Start/break/resume/stop/switch/reconcile | New methods + banked finalize + reconcile + errors |
| `App/Sources/Features/Today/TodayView.swift` | Today card + summary | Direction-A card, Working/On-Break/Idle, remove ResumePill, summary→worked |
| `App/Sources/App/BillableApp.swift` | Launch wiring | Call reconcile on launch |
| `App/Sources/Features/Projects/ProjectEditorView.swift` | Project screen | "Complete project" + confirm |
| `App/Sources/Features/Clients/ClientDetailView.swift` | Project archive list | Add confirm to existing Archive swipe |
| `App/Sources/LiveActivity/TimerActivityController.swift` + `Packages/.../LiveActivity/TimerActivityAttributes.swift` | Live Activity | On-Break state |
| `Widgets/Sources/CurrentTimerWidget.swift` | Running widget | On-Break presentation |
| `Widgets/Sources/TodaySummaryWidget.swift` | Today widget | Worked-time totals |
| `App/Sources/Features/Timeline/DayTimelineView.swift` + `TimeBlockView.swift` | Day timeline | Pulse off `isWorking`; flatten on edit |
| `Packages/BillableCore/Sources/BillableCore/Reporting/CSVExporter.swift` | Export | Clarify worked-time column |
| `App/Sources/Features/Timer/ManualEntrySheet.swift` | Manual entry edit | Flatten `accumulatedSeconds` on start/end edit |

---

# Phase 1 — Core model & service (BillableCore, TDD)

### Task 1: `TimeEntry` break fields + worked-time `duration()`

**Files:**
- Modify: `Packages/BillableCore/Sources/BillableCore/Models/TimeEntry.swift`
- Test: `Packages/BillableCore/Tests/BillableCoreTests/TimeEntryDurationTests.swift` (create)

- [ ] **Step 1: Write the failing tests**

Create `Packages/BillableCore/Tests/BillableCoreTests/TimeEntryDurationTests.swift`:

```swift
import Foundation
import Testing
@testable import BillableCore

@Suite("TimeEntry duration (worked time)")
struct TimeEntryDurationTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Working: banked + current segment")
    func workingDuration() {
        let e = TimeEntry(startedAt: t0, accumulatedSeconds: 600, activeSegmentStartedAt: t0)
        #expect(e.duration(asOf: t0.addingTimeInterval(60)) == 660)
        #expect(e.isWorking)
        #expect(!e.isOnBreak)
    }

    @Test("On break: frozen at banked")
    func onBreakDuration() {
        let e = TimeEntry(startedAt: t0, accumulatedSeconds: 600, activeSegmentStartedAt: nil)
        #expect(e.duration(asOf: t0.addingTimeInterval(9999)) == 600)
        #expect(e.isOnBreak)
        #expect(!e.isWorking)
    }

    @Test("Finished with banked time returns banked, not wall-clock")
    func finishedBanked() {
        let e = TimeEntry(startedAt: t0, endedAt: t0.addingTimeInterval(3600), accumulatedSeconds: 1800)
        #expect(e.duration() == 1800)
    }

    @Test("Finished manual/legacy (no banked) falls back to wall-clock")
    func finishedFallback() {
        let e = TimeEntry(startedAt: t0, endedAt: t0.addingTimeInterval(3600), accumulatedSeconds: 0)
        #expect(e.duration() == 3600)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Packages/BillableCore && swift test --filter TimeEntryDurationTests`
Expected: FAIL — `accumulatedSeconds`/`activeSegmentStartedAt`/`isWorking`/`isOnBreak` don't exist yet (compile error).

- [ ] **Step 3: Add fields + derived state + redefine `duration()`**

In `TimeEntry.swift`, add the two stored properties after `invoiceID` (line 17 area):

```swift
    /// Worked seconds banked from completed work segments (before the current
    /// active segment / before each break). The source of truth for billable
    /// time once breaks exist. 0 for manual/legacy entries (see `duration`).
    public var accumulatedSeconds: Double = 0

    /// Start of the current *working* segment. `nil` while On Break or finished.
    public var activeSegmentStartedAt: Date? = nil
```

Add both to the initializer signature (after `project:`) and assignments:

```swift
        project: Project? = nil,
        accumulatedSeconds: Double = 0,
        activeSegmentStartedAt: Date? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.notes = notes
        self.isManual = isManual
        self.project = project
        self.accumulatedSeconds = accumulatedSeconds
        self.activeSegmentStartedAt = activeSegmentStartedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
```

Add derived state next to `isRunning` and replace `duration(asOf:)`:

```swift
    public var isRunning: Bool { endedAt == nil }
    /// Active session, currently counting.
    public var isWorking: Bool { endedAt == nil && activeSegmentStartedAt != nil }
    /// Active session, paused (count frozen).
    public var isOnBreak: Bool { endedAt == nil && activeSegmentStartedAt == nil }

    /// WORKED duration in seconds, breaks excluded.
    /// - Finished: banked worked time; manual/legacy entries (no banking) fall
    ///   back to wall-clock end−start.
    /// - Working: banked + the live segment.
    /// - On break: banked (frozen).
    public func duration(asOf referenceDate: Date = .now) -> TimeInterval {
        if let end = endedAt {
            return accumulatedSeconds > 0 ? accumulatedSeconds : max(0, end.timeIntervalSince(startedAt))
        }
        if let segStart = activeSegmentStartedAt {
            return accumulatedSeconds + max(0, referenceDate.timeIntervalSince(segStart))
        }
        return accumulatedSeconds
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Packages/BillableCore && swift test --filter TimeEntryDurationTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Run the full BillableCore suite (catch consumers)**

Run: `cd Packages/BillableCore && swift test`
Expected: PASS. (Existing `amount`/invoice/report tests still pass — they route through `duration()`, and finished entries created by those tests have `accumulatedSeconds == 0` → wall-clock fallback.)

- [ ] **Step 6: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Models/TimeEntry.swift Packages/BillableCore/Tests/BillableCoreTests/TimeEntryDurationTests.swift
git commit -m "feat(core): TimeEntry worked-time duration + break state fields"
```

---

### Task 2: `TimerService.takeBreak` / `resume` + errors

**Files:**
- Modify: `Packages/BillableCore/Sources/BillableCore/Timing/TimerService.swift`
- Test: `Packages/BillableCore/Tests/BillableCoreTests/TimerServiceBreakTests.swift` (create)

- [ ] **Step 1: Write the failing tests**

Create `Packages/BillableCore/Tests/BillableCoreTests/TimerServiceBreakTests.swift`:

```swift
import Foundation
import Testing
import SwiftData
@testable import BillableCore

@Suite("TimerService break/resume")
@MainActor
struct TimerServiceBreakTests {
    private func ctx() throws -> (ModelContext, Project) {
        let container = try BillableModelContainer.inMemory()
        let context = ModelContext(container)
        let client = Client(name: "Acme")
        let p = Project(name: "Site", hourlyRate: 100, client: client)
        context.insert(client); context.insert(p)
        try context.save()
        return (context, p)
    }
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("takeBreak banks the current segment and freezes the count")
    func takeBreakBanks() throws {
        let (context, p) = try ctx()
        _ = try TimerService.start(project: p, at: t0, in: context)
        let onBreak = try TimerService.takeBreak(at: t0.addingTimeInterval(600), in: context)
        #expect(onBreak.isOnBreak)
        #expect(onBreak.accumulatedSeconds == 600)
        #expect(onBreak.duration(asOf: t0.addingTimeInterval(9999)) == 600) // frozen
    }

    @Test("resume continues counting from banked total")
    func resumeContinues() throws {
        let (context, p) = try ctx()
        _ = try TimerService.start(project: p, at: t0, in: context)
        _ = try TimerService.takeBreak(at: t0.addingTimeInterval(600), in: context)
        let resumed = try TimerService.resume(at: t0.addingTimeInterval(1200), in: context)
        #expect(resumed.isWorking)
        #expect(resumed.duration(asOf: t0.addingTimeInterval(1260)) == 660) // 600 banked + 60 live
    }

    @Test("takeBreak throws when already on break")
    func takeBreakAlreadyOnBreak() throws {
        let (context, p) = try ctx()
        _ = try TimerService.start(project: p, at: t0, in: context)
        _ = try TimerService.takeBreak(at: t0.addingTimeInterval(60), in: context)
        #expect(throws: TimerService.TimerError.alreadyOnBreak) {
            _ = try TimerService.takeBreak(at: t0.addingTimeInterval(120), in: context)
        }
    }

    @Test("takeBreak throws when nothing is running")
    func takeBreakNoTimer() throws {
        let (context, _) = try ctx()
        #expect(throws: TimerService.TimerError.noRunningTimer) {
            _ = try TimerService.takeBreak(in: context)
        }
    }

    @Test("resume throws when not on break")
    func resumeNotOnBreak() throws {
        let (context, p) = try ctx()
        _ = try TimerService.start(project: p, at: t0, in: context)
        #expect(throws: TimerService.TimerError.notOnBreak) {
            _ = try TimerService.resume(at: t0.addingTimeInterval(60), in: context)
        }
    }

    @Test("backward clock on takeBreak clamps to zero (no negative bank)")
    func takeBreakBackwardClock() throws {
        let (context, p) = try ctx()
        _ = try TimerService.start(project: p, at: t0, in: context)
        let onBreak = try TimerService.takeBreak(at: t0.addingTimeInterval(-60), in: context)
        #expect(onBreak.accumulatedSeconds == 0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Packages/BillableCore && swift test --filter TimerServiceBreakTests`
Expected: FAIL — `takeBreak`/`resume`/`alreadyOnBreak`/`notOnBreak` don't exist.

- [ ] **Step 3: Add error cases**

In `TimerService.swift`, extend `TimerError`:

```swift
    public enum TimerError: Error, Equatable {
        case projectIsArchived
        case noRunningTimer
        case alreadyTrackingSameProject
        /// Caller asked to take a break but the active session is already on break.
        case alreadyOnBreak
        /// Caller asked to resume but the active session is not on break.
        case notOnBreak
    }
```

- [ ] **Step 4: Implement `takeBreak` and `resume`**

Add after `stop(...)` in `TimerService.swift`:

```swift
    /// Pause the active session: bank the current working segment and freeze the
    /// count. The entry stays active (`endedAt == nil`) but `isOnBreak`.
    @MainActor
    @discardableResult
    public static func takeBreak(at instant: Date = .now, in context: ModelContext) throws -> TimeEntry {
        guard let running = currentRunningEntry(in: context) else { throw TimerError.noRunningTimer }
        guard let segStart = running.activeSegmentStartedAt else { throw TimerError.alreadyOnBreak }
        running.accumulatedSeconds += max(0, instant.timeIntervalSince(segStart))
        running.activeSegmentStartedAt = nil
        running.updatedAt = instant
        try context.save()
        return running
    }

    /// Resume an On-Break session: start a new working segment.
    @MainActor
    @discardableResult
    public static func resume(at instant: Date = .now, in context: ModelContext) throws -> TimeEntry {
        guard let running = currentRunningEntry(in: context) else { throw TimerError.noRunningTimer }
        guard running.activeSegmentStartedAt == nil else { throw TimerError.notOnBreak }
        running.activeSegmentStartedAt = instant
        running.updatedAt = instant
        try context.save()
        return running
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd Packages/BillableCore && swift test --filter TimerServiceBreakTests`
Expected: PASS (6 tests).

- [ ] **Step 6: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Timing/TimerService.swift Packages/BillableCore/Tests/BillableCoreTests/TimerServiceBreakTests.swift
git commit -m "feat(core): TimerService takeBreak/resume with banked worked time"
```

---

### Task 3: Banked finalize for `start`/`stop`/`switchTo`

Make `start` set the first segment, and make stop/the switch-path bank the final working segment, via a shared `finalize` helper.

**Files:**
- Modify: `Packages/BillableCore/Sources/BillableCore/Timing/TimerService.swift`
- Test: `Packages/BillableCore/Tests/BillableCoreTests/TimerServiceBreakTests.swift` (append)

- [ ] **Step 1: Append failing tests**

Add inside `TimerServiceBreakTests`:

```swift
    @Test("start sets the first working segment")
    func startSetsSegment() throws {
        let (context, p) = try ctx()
        let e = try TimerService.start(project: p, at: t0, in: context)
        #expect(e.isWorking)
        #expect(e.activeSegmentStartedAt == t0)
    }

    @Test("Done-for-now from Working banks final segment as worked time")
    func stopFromWorking() throws {
        let (context, p) = try ctx()
        _ = try TimerService.start(project: p, at: t0, in: context)
        let done = try TimerService.stop(at: t0.addingTimeInterval(900), in: context)
        #expect(done.endedAt == t0.addingTimeInterval(900))
        #expect(done.duration() == 900)
        #expect(done.isOnBreak == false)
    }

    @Test("Done-for-now after breaks totals banked only (excludes break gap)")
    func stopAfterBreaks() throws {
        let (context, p) = try ctx()
        _ = try TimerService.start(project: p, at: t0, in: context)
        _ = try TimerService.takeBreak(at: t0.addingTimeInterval(600), in: context)   // banked 600
        _ = try TimerService.resume(at: t0.addingTimeInterval(1800), in: context)     // 20-min break gap
        let done = try TimerService.stop(at: t0.addingTimeInterval(2400), in: context) // +600 worked
        #expect(done.duration() == 1200) // 600 + 600, the 1200s break excluded
    }

    @Test("Done-for-now while On Break finalizes banked total, no extra segment")
    func stopWhileOnBreak() throws {
        let (context, p) = try ctx()
        _ = try TimerService.start(project: p, at: t0, in: context)
        _ = try TimerService.takeBreak(at: t0.addingTimeInterval(600), in: context)
        let done = try TimerService.stop(at: t0.addingTimeInterval(1200), in: context)
        #expect(done.duration() == 600)
    }
```

- [ ] **Step 2: Run to verify the new tests fail**

Run: `cd Packages/BillableCore && swift test --filter TimerServiceBreakTests`
Expected: FAIL — `startSetsSegment` (segment not set), `stopAfterBreaks` (stop doesn't bank), etc.

- [ ] **Step 3: Add `finalize` helper and rewire start/stop**

In `TimerService.swift`, add a private helper:

```swift
    /// Finalize an active entry at `end`: bank any open working segment, clear
    /// the segment marker, and set `endedAt`. Clamps `end` to ≥ startedAt+1s.
    @MainActor
    private static func finalize(_ entry: TimeEntry, at end: Date) {
        let safeEnd = max(end, entry.startedAt.addingTimeInterval(1))
        if let segStart = entry.activeSegmentStartedAt {
            entry.accumulatedSeconds += max(0, safeEnd.timeIntervalSince(segStart))
            entry.activeSegmentStartedAt = nil
        }
        entry.endedAt = safeEnd
        entry.updatedAt = safeEnd
    }
```

In `start(...)`, replace the other-running-entry finalize and the new-entry creation:

```swift
        if let running = currentRunningEntry(in: context) {
            if running.project?.persistentModelID == project.persistentModelID {
                return running
            }
            finalize(running, at: start)
        }

        let entry = TimeEntry(
            startedAt: start,
            endedAt: nil,
            notes: notes,
            isManual: false,
            project: project,
            activeSegmentStartedAt: start
        )
        context.insert(entry)
        try context.save()
        return entry
```

Replace the body of `stop(...)`:

```swift
        guard let running = currentRunningEntry(in: context) else {
            throw TimerError.noRunningTimer
        }
        finalize(running, at: end)
        try context.save()
        return running
```

(`switchTo` is unchanged — it calls `start`, which now finalizes via `finalize`.)

- [ ] **Step 4: Run the full suite**

Run: `cd Packages/BillableCore && swift test`
Expected: PASS — new break tests pass AND the existing `TimerServiceTests` (`stopEndsRunning`, `stopClampsBackwardClock`, `startDifferentProjectStopsRunning`, `switchSeamless`) still pass (finalize preserves their assertions: clamp to start+1, seamless endedAt == switch instant).

- [ ] **Step 5: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Timing/TimerService.swift Packages/BillableCore/Tests/BillableCoreTests/TimerServiceBreakTests.swift
git commit -m "feat(core): bank worked time on start/stop/switch via finalize"
```

---

### Task 4: Launch reconcile (stale cross-day + legacy running)

**Files:**
- Modify: `Packages/BillableCore/Sources/BillableCore/Timing/TimerService.swift`
- Test: `Packages/BillableCore/Tests/BillableCoreTests/TimerServiceReconcileTests.swift` (create)

- [ ] **Step 1: Write failing tests**

Create `Packages/BillableCore/Tests/BillableCoreTests/TimerServiceReconcileTests.swift`:

```swift
import Foundation
import Testing
import SwiftData
@testable import BillableCore

@Suite("TimerService reconcile on launch")
@MainActor
struct TimerServiceReconcileTests {
    private func ctx() throws -> (ModelContext, Project) {
        let container = try BillableModelContainer.inMemory()
        let context = ModelContext(container)
        let client = Client(name: "Acme")
        let p = Project(name: "Site", hourlyRate: 100, client: client)
        context.insert(client); context.insert(p)
        try context.save()
        return (context, p)
    }
    private let cal = Calendar.current

    @Test("Cross-day active session finalizes to banked worked time")
    func staleFinalizes() throws {
        let (context, p) = try ctx()
        let yesterday = cal.date(byAdding: .day, value: -1, to: .now)!
        _ = try TimerService.start(project: p, at: yesterday, in: context)
        _ = try TimerService.takeBreak(at: yesterday.addingTimeInterval(3600), in: context) // banked 3600
        try TimerService.reconcileActiveSessionOnLaunch(now: .now, in: context)
        let all = try context.fetch(FetchDescriptor<TimeEntry>())
        #expect(all.count == 1)
        #expect(all[0].endedAt != nil)
        #expect(all[0].duration() == 3600)
        #expect(TimerService.currentRunningEntry(in: context) == nil)
    }

    @Test("Legacy same-day running entry (no segment) becomes Working")
    func legacyRunningAdopted() throws {
        let (context, p) = try ctx()
        // Simulate a pre-upgrade running entry: endedAt nil, no segment, 0 banked.
        let legacy = TimeEntry(startedAt: .now.addingTimeInterval(-300), endedAt: nil, project: p)
        legacy.activeSegmentStartedAt = nil
        legacy.accumulatedSeconds = 0
        context.insert(legacy); try context.save()
        try TimerService.reconcileActiveSessionOnLaunch(now: .now, in: context)
        #expect(legacy.isWorking)
    }

    @Test("Genuine same-day On-Break session is left untouched")
    func sameDayBreakUntouched() throws {
        let (context, p) = try ctx()
        let t = Date.now.addingTimeInterval(-1800)
        _ = try TimerService.start(project: p, at: t, in: context)
        _ = try TimerService.takeBreak(at: t.addingTimeInterval(600), in: context)
        try TimerService.reconcileActiveSessionOnLaunch(now: .now, in: context)
        let running = TimerService.currentRunningEntry(in: context)
        #expect(running != nil)
        #expect(running!.isOnBreak)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd Packages/BillableCore && swift test --filter TimerServiceReconcileTests`
Expected: FAIL — `reconcileActiveSessionOnLaunch` doesn't exist.

- [ ] **Step 3: Implement reconcile**

Add to `TimerService.swift`:

```swift
    /// Call once on app launch. Prevents multi-day sessions and repairs
    /// pre-break-fields running entries.
    /// - Cross-day active session → finalize to its banked worked time
    ///   (`endedAt = startedAt + accumulatedSeconds`), discarding any open
    ///   segment (its true end is unknown).
    /// - Same-day running entry with no segment and 0 banked → treat as Working
    ///   (legacy entry created before break fields existed).
    /// - Genuine same-day On-Break sessions (banked > 0) are left alone.
    @MainActor
    public static func reconcileActiveSessionOnLaunch(
        now: Date = .now,
        calendar: Calendar = .current,
        in context: ModelContext
    ) throws {
        guard let active = currentRunningEntry(in: context) else { return }
        if !calendar.isDate(active.startedAt, inSameDayAs: now) {
            active.activeSegmentStartedAt = nil
            active.endedAt = max(
                active.startedAt.addingTimeInterval(active.accumulatedSeconds),
                active.startedAt.addingTimeInterval(1)
            )
            active.updatedAt = now
        } else if active.activeSegmentStartedAt == nil && active.accumulatedSeconds == 0 {
            active.activeSegmentStartedAt = active.startedAt
            active.updatedAt = now
        }
        try context.save()
    }
```

- [ ] **Step 4: Run tests to verify pass**

Run: `cd Packages/BillableCore && swift test --filter TimerServiceReconcileTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Run the full BillableCore suite**

Run: `cd Packages/BillableCore && swift test`
Expected: PASS (all suites).

- [ ] **Step 6: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Timing/TimerService.swift Packages/BillableCore/Tests/BillableCoreTests/TimerServiceReconcileTests.swift
git commit -m "feat(core): launch reconcile for stale + legacy active sessions"
```

---

# Phase 2 — Today screen UI (Direction A)

> UI here is not unit-tested in this repo. Each task ends with a **build** and a **simulator verification**. The card's visual finish (badges, button styling, the morph transition) should be done with the **frontend-design** skill — the code below is the functional structure; treat styling as the starting point, not the final pixel spec.

**Simulator setup (reused below):**
```bash
xcodebuild -project Billable.xcodeproj -scheme Billable -configuration Debug \
  -destination 'id=A946AE5D-C969-4EB2-8384-001B3451A6A4' -derivedDataPath build/DerivedData build
xcrun simctl install A946AE5D-C969-4EB2-8384-001B3451A6A4 build/DerivedData/Build/Products/Debug-iphonesimulator/Billable.app
xcrun simctl launch A946AE5D-C969-4EB2-8384-001B3451A6A4 com.eldenstudios.billable --seed-marketing --reset-store
```

### Task 5: Redesign `RunningTimerCard` (Working / On Break)

**Files:**
- Modify: `App/Sources/Features/Today/TodayView.swift` (`RunningTimerCard`, lines ~257–469)

- [ ] **Step 1: Add break/resume callbacks to the card**

Change the `RunningTimerCard` stored callbacks (after `let onSwitch`):

```swift
    let onStop: () -> Void          // "Done for now"
    let onSwitch: () -> Void
    let onTakeBreak: () -> Void
    let onResume: () -> Void
```

- [ ] **Step 2: Replace the status badge (Working/On Break)**

Replace the `Text("Running") …` block (lines ~283–287) with:

```swift
                if entry.isOnBreak {
                    Text("ON BREAK")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.orange.opacity(0.18), in: .capsule)
                        .foregroundStyle(.orange)
                } else {
                    Text("WORKING")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.green.opacity(0.18), in: .capsule)
                        .foregroundStyle(.green)
                }
```

- [ ] **Step 3: Dim the time when On Break**

In the elapsed-time `Text(elapsedString)` (line ~304), add after `.monospacedDigit()`:

```swift
                            .foregroundStyle(entry.isOnBreak ? .secondary : .primary)
```

- [ ] **Step 4: Replace the Stop/Switch button row**

Replace the `HStack(spacing: 10) { … Stop … Switch … }` (lines ~319–332) with:

```swift
            if entry.isOnBreak {
                Button(action: onResume) {
                    Label("Resume", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            } else {
                Button(action: onTakeBreak) {
                    Label("Take a Break", systemImage: "cup.and.saucer.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
            HStack(spacing: 10) {
                Button(action: onSwitch) {
                    Label("Switch", systemImage: "arrow.triangle.2.circlepath").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button(action: onStop) {
                    Text("Done for now").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
```

- [ ] **Step 5: Build**

Run the build command from the Simulator setup block.
Expected: BUILD SUCCEEDED. (Call site still passes only `onStop`/`onSwitch` → compile error is expected and fixed in Task 6; if building standalone, comment the call site temporarily, but prefer doing Task 6 immediately.)

- [ ] **Step 6: Commit**

```bash
git add App/Sources/Features/Today/TodayView.swift
git commit -m "feat(today): RunningTimerCard Working/On-Break controls"
```

---

### Task 6: Wire break/resume, remove Resume pill, add Idle card + morph

**Files:**
- Modify: `App/Sources/Features/Today/TodayView.swift` (`TodayActiveTimerSection`, `TodayView`, remove `ResumePill`)

- [ ] **Step 1: Update `TodayActiveTimerSection` callbacks + card call**

Replace the callbacks block (lines ~190–193) and the `body` running branch / else branch (lines ~197–224):

```swift
    let currencyCode: String
    let onStop: () -> Void
    let onSwitch: () -> Void
    let onTakeBreak: () -> Void
    let onResume: () -> Void
    let onStart: () -> Void

    var body: some View {
        Group {
            if let running = runningEntries.first {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    RunningTimerCard(
                        entry: running, asOf: context.date, currencyCode: currencyCode,
                        onStop: onStop, onSwitch: onSwitch, onTakeBreak: onTakeBreak, onResume: onResume
                    )
                    .id(running.persistentModelID)
                }
            } else {
                IdleTimerCard(onStart: onStart)
            }
        }
        .animation(.snappy(duration: 0.28), value: runningEntries.first?.persistentModelID)
        .animation(.snappy(duration: 0.28), value: runningEntries.first?.activeSegmentStartedAt)
    }
```

- [ ] **Step 2: Delete the Resume pill + its query**

Remove the `ResumePill` struct (lines ~227–255) and the `lastStoppedDescriptor` / `stoppedEntries` query + `lastStopped` (lines ~170–195 fragments). The `else` branch no longer references them.

- [ ] **Step 3: Add the Idle card**

Add a new struct (near `RunningTimerCard`):

```swift
private struct IdleTimerCard: View {
    let onStart: () -> Void
    var body: some View {
        VStack(spacing: 10) {
            Text("00:00:00")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Text("No timer running").font(.subheadline).foregroundStyle(.secondary)
            Button(action: onStart) {
                Label("Start timer", systemImage: "play.fill")
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.thinMaterial, in: .rect(cornerRadius: 16))
    }
}
```

- [ ] **Step 4: Wire the new callbacks in `TodayView`**

In `TodayView`, find where `TodayActiveTimerSection(...)` is constructed and the existing `stopRunning()` / start-sheet handlers (around lines 40–146). Pass the new closures and add handlers:

```swift
            TodayActiveTimerSection(
                currencyCode: currencyCode,
                onStop: stopRunning,
                onSwitch: { showingSwitchSheet = true },
                onTakeBreak: { _ = try? TimerService.takeBreak(in: modelContext) },
                onResume: { _ = try? TimerService.resume(in: modelContext) },
                onStart: { showingStartSheet = true }
            )
```

Remove the now-unused `onResume:(Project)->Void` resume-pill handler and the separate `startActions` button if the Idle card replaces it (keep `showingStartSheet`/`showingSwitchSheet` state and the `.sheet` presentations). Keep `stopRunning()` as-is (it calls `TimerService.stop`, ends the Live Activity, donates the intent) — it is the "Done for now" action.

- [ ] **Step 5: Build + run**

Build, install, launch (Simulator setup block).
Expected: BUILD SUCCEEDED. App launches into the seeded Today screen showing the running card.

- [ ] **Step 6: Verify the full flow on the simulator (look at screenshots)**

```bash
xcrun simctl io A946AE5D-C969-4EB2-8384-001B3451A6A4 screenshot /tmp/timer_working.png
```
- Tap **Take a Break** → screenshot → badge reads ON BREAK, time dim/frozen, button now **Resume**.
- Tap **Resume** → time resumes from where it froze (not from 0).
- Tap **Done for now** → card morphs to the Idle card (00:00:00, Start). No abrupt collapse.
- Tap **Start timer** → project picker → starts → card returns to Working.
Read each screenshot with the Read tool and confirm visually.

- [ ] **Step 7: Commit**

```bash
git add App/Sources/Features/Today/TodayView.swift
git commit -m "feat(today): break/resume wiring, idle card, morph transition; remove resume pill"
```

---

### Task 7: Today Hours/Earnings tiles → worked time

**Files:**
- Modify: `App/Sources/Features/Today/TodayView.swift` (`TodaySummarySection.content`, lines ~542–556)

- [ ] **Step 1: Replace the wall-clock sums with `duration()`**

Replace `todaysSeconds` and `todaysAmount` (lines ~545–556):

```swift
        let todays = allEntries.filter { entry in
            cal.isDate(entry.startedAt, inSameDayAs: referenceDate)
        }
        let todaysSeconds = todays.reduce(into: TimeInterval(0)) { acc, e in
            acc += e.duration(asOf: referenceDate)   // worked time, breaks excluded
        }
        let todaysAmount = todays.reduce(into: Decimal(0)) { acc, e in
            acc += e.amount(asOf: referenceDate)      // uses duration() internally
        }
```

(Per-day entries make the previous midnight-clamp unnecessary; `isDate(_:inSameDayAs:)` is the correct filter now.)

- [ ] **Step 2: Build + run + verify totals match**

Build, install, launch (Simulator setup block). Then:
- Note the **Hours** tile while Working.
- Take a Break for ~10s, confirm the **Hours** tile stops increasing (frozen) and Earnings too.
- Resume; confirm it ticks again.
- Cross-check: the Reports tab "today" total for the same project equals the Today Hours tile (both now worked time).

```bash
xcrun simctl io A946AE5D-C969-4EB2-8384-001B3451A6A4 screenshot /tmp/timer_summary.png
```
Read the screenshot and confirm.

- [ ] **Step 3: Commit**

```bash
git add App/Sources/Features/Today/TodayView.swift
git commit -m "fix(today): summary Hours/Earnings use worked time (breaks excluded)"
```

---

# Phase 3 — Complete Project

### Task 8: "Complete project" action + confirm

**Files:**
- Modify: `App/Sources/Features/Projects/ProjectEditorView.swift`
- Modify: `App/Sources/Features/Clients/ClientDetailView.swift` (add confirm to existing Archive swipe, lines ~66–74)

- [ ] **Step 1: Read both files**

Read `ProjectEditorView.swift` in full and `ClientDetailView.swift` lines 1–110 to locate the form sections and the existing Archive swipe action.

- [ ] **Step 2: Add "Complete project" to `ProjectEditorView`**

Add `@State private var showingCompleteConfirm = false` and, for an existing (non-new) project, a section at the bottom of the form:

```swift
            if !project.isArchived {
                Section {
                    Button("Complete project") { showingCompleteConfirm = true }
                        .frame(maxWidth: .infinity)
                } footer: {
                    Text("Marks the project complete and moves it to Archived. Logged time stays on past invoices and reports.")
                }
            }
```

Attach the confirm to the form:

```swift
        .confirmationDialog(
            "Are you sure you're done with this project?",
            isPresented: $showingCompleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Complete project", role: .destructive) {
                project.isArchived = true
                project.updatedAt = .now
                try? modelContext.save()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
```

(Use the view's existing `@Environment(\.modelContext)` and `@Environment(\.dismiss)`; add them if absent.)

- [ ] **Step 3: Add the same confirm to the `ClientDetailView` Archive swipe**

In `ClientDetailView.swift`, the swipe action currently sets `project.isArchived = true` directly (line ~69). Replace the direct mutation with a confirm. Add `@State private var projectToComplete: Project?`, change the swipe button to `projectToComplete = project`, and add:

```swift
        .confirmationDialog(
            "Are you sure you're done with this project?",
            isPresented: Binding(get: { projectToComplete != nil }, set: { if !$0 { projectToComplete = nil } }),
            titleVisibility: .visible,
            presenting: projectToComplete
        ) { project in
            Button("Complete project", role: .destructive) {
                project.isArchived = true
                project.updatedAt = .now
                try? modelContext.save()
                projectToComplete = nil
            }
            Button("Cancel", role: .cancel) { projectToComplete = nil }
        }
```

- [ ] **Step 4: Build + run + verify**

Build, install, launch. Open a client → a project → "Complete project" → confirm appears → Complete → project moves to the client's "Archived projects" section. Repeat via the swipe action.
```bash
xcrun simctl io A946AE5D-C969-4EB2-8384-001B3451A6A4 screenshot /tmp/complete_project.png
```
Read and confirm.

- [ ] **Step 5: Commit**

```bash
git add App/Sources/Features/Projects/ProjectEditorView.swift App/Sources/Features/Clients/ClientDetailView.swift
git commit -m "feat(projects): Complete Project action with confirm (reuses isArchived)"
```

---

# Phase 4 — Downstream surfaces

### Task 9: Live Activity break-aware

**Files:**
- Modify: `Packages/BillableCore/Sources/BillableCore/LiveActivity/TimerActivityAttributes.swift`
- Modify: `App/Sources/LiveActivity/TimerActivityController.swift`
- Modify: `App/Sources/Features/Today/TodayView.swift` (call controller on break/resume)

- [ ] **Step 1: Read all three files**

Read `TimerActivityAttributes.swift` (full), `TimerActivityController.swift` (full), and the `TodayView` break/resume handlers from Task 6.

- [ ] **Step 2: Add `isOnBreak` + frozen elapsed to ContentState**

In `TimerActivityAttributes.ContentState`, add `var isOnBreak: Bool` and (if the state drives a `Text(timerInterval:)`) a `var frozenElapsed: TimeInterval` for the paused display. Update initializers/usages accordingly.

- [ ] **Step 3: Add update methods on the controller**

In `TimerActivityController`, add `func pause(elapsed: TimeInterval)` and `func resumeActivity(...)` that update the running Activity's content state (`isOnBreak = true/false`). The widget extension's Live Activity view should render a static elapsed + "On Break" when `isOnBreak`.

- [ ] **Step 4: Call them from the Today handlers**

Update the Task 6 handlers:

```swift
                onTakeBreak: {
                    _ = try? TimerService.takeBreak(in: modelContext)
                    if let e = TimerService.currentRunningEntry(in: modelContext) {
                        Task { await TimerActivityController.shared.pause(elapsed: e.duration()) }
                    }
                },
                onResume: {
                    _ = try? TimerService.resume(in: modelContext)
                    Task { await TimerActivityController.shared.resumeActivity() }
                },
```

- [ ] **Step 5: Build + run + verify on the Dynamic Island / Lock Screen**

Build, install, launch. Start a timer, background the app, confirm the Live Activity ticks; Take a Break → it freezes and shows "On Break"; Resume → it ticks again; Done for now → it ends.

- [ ] **Step 6: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/LiveActivity/TimerActivityAttributes.swift App/Sources/LiveActivity/TimerActivityController.swift App/Sources/Features/Today/TodayView.swift
git commit -m "feat(liveactivity): On-Break state for the timer activity"
```

---

### Task 10: Widgets — On-Break + worked totals

**Files:**
- Modify: `Widgets/Sources/CurrentTimerWidget.swift`
- Modify: `Widgets/Sources/TodaySummaryWidget.swift`

- [ ] **Step 1: Read both widget files**

Read both in full to see how they read the running entry / today totals from the App Group container.

- [ ] **Step 2: `CurrentTimerWidget` On-Break display**

Where it renders the running entry, branch on `entry.isOnBreak`: show the frozen `entry.duration()` and an "On Break" label instead of a live `Text(timerInterval:)`. Ensure the timeline provider reloads (it already refreshes on widget timeline; state is read fresh from the container).

- [ ] **Step 3: `TodaySummaryWidget` worked totals**

If it sums `endedAt − startedAt`, switch to `entry.duration(asOf:)` filtered to today (mirror Task 7) so the widget matches the app.

- [ ] **Step 4: Trigger widget reloads on state change**

In `TodayView` break/resume/stop handlers, add `WidgetCenter.shared.reloadAllTimelines()` (import `WidgetKit`) so the widgets refresh promptly.

- [ ] **Step 5: Build + run + verify**

Build, install, launch. Add both widgets to the Home Screen; Take a Break → `CurrentTimerWidget` shows On-Break + frozen time; `TodaySummaryWidget` hours match the app's Today tile.

- [ ] **Step 6: Commit**

```bash
git add Widgets/Sources/CurrentTimerWidget.swift Widgets/Sources/TodaySummaryWidget.swift App/Sources/Features/Today/TodayView.swift
git commit -m "feat(widgets): On-Break state + worked-time totals"
```

---

### Task 11: Day-timeline — pulse off `isWorking`, flatten on edit

**Files:**
- Modify: `App/Sources/Features/Timeline/DayTimelineView.swift`
- Modify: `App/Sources/Features/Timeline/TimeBlockView.swift`

- [ ] **Step 1: Read both files**

Read both in full. Note the `isRunning:` parameter passed to `TimeBlockView` (DayTimelineView ~line 161) and the drag/resize/split handlers (~lines 240–286).

- [ ] **Step 2: Pulse only when Working**

At the `TimeBlockView(isRunning: entry.isRunning, …)` call site, change to `isRunning: entry.isWorking`. (On-Break blocks render static.) Optionally add an "On Break" hint where the running label is shown.

- [ ] **Step 3: Flatten breaks on any geometry edit**

In each handler that mutates `entry.startedAt` / `entry.endedAt` (drag move, resize-start, resize-end, split), add `entry.accumulatedSeconds = 0` after the mutation, so `duration()` falls back to the new wall-clock span. For the **split** path (creates a new `TimeEntry`), ensure both the original and the new entry have `accumulatedSeconds == 0` (new entries default to 0).

- [ ] **Step 4: Disallow editing live/On-Break entries**

Guard the drag/resize/split handlers with `guard entry.endedAt != nil else { return }` (only finished entries are editable on the timeline). A live session is edited via the card, not the timeline.

- [ ] **Step 5: Build + run + verify**

Build, install, launch. Open the timeline (top-left toggle on Today). Confirm: a finished session-with-breaks shows as one solid block; dragging/resizing it updates its duration to the new span; the running entry's block pulses only while Working (static On Break).

- [ ] **Step 6: Commit**

```bash
git add App/Sources/Features/Timeline/DayTimelineView.swift App/Sources/Features/Timeline/TimeBlockView.swift
git commit -m "feat(timeline): pulse off isWorking; flatten breaks on geometry edit"
```

---

### Task 12: CSV clarity + ManualEntrySheet flatten-on-edit

**Files:**
- Modify: `Packages/BillableCore/Sources/BillableCore/Reporting/CSVExporter.swift`
- Modify: `App/Sources/Features/Timer/ManualEntrySheet.swift`

- [ ] **Step 1: CSV column label**

In `CSVExporter.swift`, ensure the duration column header makes clear it is worked time (e.g., `"Worked Hours"` / `"Worked Minutes"`). It already exports `entry.duration()`; only the header/comment needs to convey "breaks excluded." No value change.

- [ ] **Step 2: ManualEntrySheet flatten on edit**

Read `ManualEntrySheet.swift`. If it supports editing an existing entry's start/end (not only creating new ones), set `entry.accumulatedSeconds = 0` when saving an edited start/end so `duration()` equals the new wall-clock span. (New manual entries already have `accumulatedSeconds == 0` — no change needed there.)

- [ ] **Step 3: Build + BillableCore test**

```bash
cd Packages/BillableCore && swift test --filter CSV
```
Expected: existing CSV tests pass (values unchanged). Then build the app (Simulator setup block) → BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Reporting/CSVExporter.swift App/Sources/Features/Timer/ManualEntrySheet.swift
git commit -m "chore(reporting): clarify worked-time CSV column; flatten on manual edit"
```

---

# Phase 5 — Launch wiring + full verification

### Task 13: Call reconcile on launch + full sweep

**Files:**
- Modify: `App/Sources/App/BillableApp.swift` (`performStartupWiring`)

- [ ] **Step 1: Wire reconcile**

In `BillableApp.performStartupWiring()` (it's `@MainActor`, has `container`), add near the top:

```swift
        try? TimerService.reconcileActiveSessionOnLaunch(in: container.mainContext)
```

- [ ] **Step 2: Full BillableCore suite**

Run: `cd Packages/BillableCore && swift test`
Expected: PASS (all suites, including the new break/duration/reconcile tests and the updated stop tests).

- [ ] **Step 3: App build (Debug + Release) — zero warnings**

```bash
xcodebuild -project Billable.xcodeproj -scheme Billable -configuration Debug -destination 'id=A946AE5D-C969-4EB2-8384-001B3451A6A4' build
xcodebuild -project Billable.xcodeproj -scheme Billable -configuration Release -destination 'id=A946AE5D-C969-4EB2-8384-001B3451A6A4' build
```
Expected: BUILD SUCCEEDED, no new warnings (the repo's bar is zero warnings).

- [ ] **Step 4: UI smoke tests**

```bash
xcodebuild -project Billable.xcodeproj -scheme Billable -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:BillableUITests test
```
Expected: 5/5 pass.

- [ ] **Step 5: End-to-end manual flow (look at screenshots)**

Launch with `--seed-marketing --reset-store`. Walk the whole flow: Start → Take a Break (Hours tile + widget freeze, Live Activity "On Break") → Resume → Done for now (Idle card) → Start again → Switch → Complete a project (confirm) → open the timeline (breaks render as solid block, running pulses only when Working). Screenshot key states and read them.

- [ ] **Step 6: Commit**

```bash
git add App/Sources/App/BillableApp.swift
git commit -m "feat(app): reconcile active timer session on launch"
```

---

## Self-Review

- **Spec coverage:** §5 state machine (Tasks 2–3, 6) · §6 UI (Tasks 5–6) · §7 data model (Task 1) · §8 TimerService incl. reconcile (Tasks 2–4, 13) · §9 Complete Project (Task 8) · §10 Live Activity (Task 9) · §11 edge cases (Tasks 3–4, 11) · §12 downstream: summary (7), widgets (10), timeline (11), CSV + manual-edit flatten (12) · §13 testing (each task + Task 13). All covered.
- **Type consistency:** `accumulatedSeconds: Double`, `activeSegmentStartedAt: Date?`, `isWorking`/`isOnBreak`, `duration(asOf:)`, `TimerService.takeBreak`/`resume`/`reconcileActiveSessionOnLaunch`, errors `alreadyOnBreak`/`notOnBreak` — used identically across tasks.
- **Risk note:** UI tasks (5–12) are verified by build + simulator, not unit tests (repo convention). Card visual polish is delegated to frontend-design.
