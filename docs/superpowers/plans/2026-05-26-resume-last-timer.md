# Resume Last Timer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Resume Acme Corp · Project X" pill to Today that lets freelancers restart tracking the last stopped project with one tap, when within 60 min of stopping and same calendar day.

**Architecture:** A static helper `TimeEntry.shouldShowResumePill(lastStopped:now:)` encapsulates the visibility rules. `TodayActiveTimerSection` gains a second `@Query` for the most recent stopped entry, renders a `ResumePill` subview when conditions are met. Tapping calls `TimerService.start(project:in:)` — the same helper Start Timer + App Intents already use. No new `@Model`, no schema migration.

**Tech Stack:** SwiftUI + SwiftData + Swift Testing + BillableCore.

**Spec:** `docs/superpowers/specs/2026-05-26-resume-last-timer-design.md`

**Review pattern:** all 3 tasks get combined review (no paid product surface, mechanical implementation).

---

## File Structure

### Modified
- `Packages/BillableCore/Sources/BillableCore/Models/TimeEntry.swift` — add static `shouldShowResumePill(lastStopped:now:calendar:)` extension method
- `App/Sources/Features/Today/TodayView.swift` — add `@Query` for most-recent stopped entry in `TodayActiveTimerSection`; add `ResumePill` subview; wire tap to call `TimerService.start`

### Tests added
- `Packages/BillableCore/Tests/BillableCoreTests/ResumePillVisibilityTests.swift` — NEW, 6 test cases covering the static helper

### Not modified
- `TimeEntry` model schema (no new fields)
- `TimerService` (already exposes `start(project:in:)` from prior work — we use it as-is)

---

## Task 1 — Static helper + 6 unit tests (TDD, combined review)

**Files:**
- Modify: `Packages/BillableCore/Sources/BillableCore/Models/TimeEntry.swift` — add extension
- Create: `Packages/BillableCore/Tests/BillableCoreTests/ResumePillVisibilityTests.swift`

---

- [ ] **Step 1.1: Write the failing tests**

Create `Packages/BillableCore/Tests/BillableCoreTests/ResumePillVisibilityTests.swift`:

```swift
import Testing
import Foundation
import SwiftData
@testable import BillableCore

@Suite("Resume pill visibility")
@MainActor
struct ResumePillVisibilityTests {

    private func makeContext() throws -> ModelContext {
        let schema = Schema(BillableModelContainer.mirroredTypes
                          + BillableModelContainer.localOnlyTypes)
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        return ModelContext(container)
    }

    private func makeStoppedEntry(
        in context: ModelContext,
        endedAt: Date,
        withProject: Bool = true
    ) -> TimeEntry {
        let project: Project?
        if withProject {
            let client = Client(name: "Acme")
            context.insert(client)
            let p = Project(name: "Project X", hourlyRate: 100, client: client)
            context.insert(p)
            project = p
        } else {
            project = nil
        }
        let entry = TimeEntry(
            startedAt: endedAt.addingTimeInterval(-1800),
            endedAt: endedAt,
            project: project
        )
        context.insert(entry)
        return entry
    }

    @Test("nil last entry → no pill")
    func nilLastEntry() {
        #expect(TimeEntry.shouldShowResumePill(lastStopped: nil, now: .now) == false)
    }

    @Test("entry without project → no pill")
    func noProject() throws {
        let context = try makeContext()
        let entry = makeStoppedEntry(in: context, endedAt: .now, withProject: false)
        #expect(TimeEntry.shouldShowResumePill(lastStopped: entry, now: .now) == false)
    }

    @Test("stopped 30 min ago, same day → pill shown")
    func recentSameDay() throws {
        let context = try makeContext()
        let now = Date(timeIntervalSince1970: 1_780_000_000)  // arbitrary, midday
        let endedAt = now.addingTimeInterval(-30 * 60)
        let entry = makeStoppedEntry(in: context, endedAt: endedAt)
        #expect(TimeEntry.shouldShowResumePill(lastStopped: entry, now: now) == true)
    }

    @Test("stopped 90 min ago → no pill (over window)")
    func tooOld() throws {
        let context = try makeContext()
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let endedAt = now.addingTimeInterval(-90 * 60)
        let entry = makeStoppedEntry(in: context, endedAt: endedAt)
        #expect(TimeEntry.shouldShowResumePill(lastStopped: entry, now: now) == false)
    }

    @Test("stopped 30 min ago but yesterday → no pill (crossed midnight)")
    func crossedMidnight() throws {
        let context = try makeContext()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // Now = 2026-05-27 00:30 UTC; endedAt = 2026-05-27 00:00... wait, same day.
        // To cross midnight: now = 2026-05-27 00:15, endedAt = 2026-05-26 23:45 → 30 min apart, different days.
        let nowComponents = DateComponents(year: 2026, month: 5, day: 27, hour: 0, minute: 15)
        let endedAtComponents = DateComponents(year: 2026, month: 5, day: 26, hour: 23, minute: 45)
        let now = calendar.date(from: nowComponents)!
        let endedAt = calendar.date(from: endedAtComponents)!
        let entry = makeStoppedEntry(in: context, endedAt: endedAt)
        #expect(TimeEntry.shouldShowResumePill(lastStopped: entry, now: now, calendar: calendar) == false)
    }

    @Test("entry still running (endedAt == nil) → no pill")
    func stillRunning() throws {
        let context = try makeContext()
        let client = Client(name: "Acme")
        context.insert(client)
        let project = Project(name: "Project X", hourlyRate: 100, client: client)
        context.insert(project)
        let entry = TimeEntry(startedAt: .now, endedAt: nil, project: project)
        context.insert(entry)
        #expect(TimeEntry.shouldShowResumePill(lastStopped: entry, now: .now) == false)
    }
}
```

(If `BillableModelContainer.mirroredTypes` / `localOnlyTypes` aren't the exact names — check `Packages/BillableCore/Sources/BillableCore/Persistence/BillableModelContainer.swift` and adapt. They're documented in the v1.1 memory notes.)

- [ ] **Step 1.2: Run tests to verify they fail**

```bash
cd "/Users/lbazerbashi/Elden Studios/billable/.worktrees/v1.3-resume-last"
swift test --package-path Packages/BillableCore --filter ResumePillVisibility 2>&1 | tail -15
```

Expected: compilation FAILS with "type 'TimeEntry' has no member 'shouldShowResumePill'".

- [ ] **Step 1.3: Add the static helper to TimeEntry**

Open `Packages/BillableCore/Sources/BillableCore/Models/TimeEntry.swift`. At the bottom of the file (after the closing brace of the existing `extension TimeEntry` if any, or after the class definition), add a new extension:

```swift
// MARK: - Resume pill visibility

extension TimeEntry {
    /// Whether the "Resume Last" pill should appear on Today, given the most-recently
    /// stopped TimeEntry. Returns false in any of:
    /// - lastStopped is nil
    /// - lastStopped has no endedAt (still running)
    /// - lastStopped has no project (data corruption edge case)
    /// - lastStopped ended more than 60 min ago
    /// - lastStopped ended on a different calendar day than `now`
    ///
    /// Pure function — pass an explicit calendar for tests across time zones.
    public static func shouldShowResumePill(
        lastStopped: TimeEntry?,
        now: Date,
        calendar: Calendar = .current
    ) -> Bool {
        guard let entry = lastStopped else { return false }
        guard let endedAt = entry.endedAt else { return false }
        guard entry.project != nil else { return false }
        let secondsSince = now.timeIntervalSince(endedAt)
        guard secondsSince >= 0, secondsSince < 60 * 60 else { return false }
        guard calendar.isDate(now, inSameDayAs: endedAt) else { return false }
        return true
    }
}
```

- [ ] **Step 1.4: Run tests to verify they pass**

```bash
swift test --package-path Packages/BillableCore --filter ResumePillVisibility 2>&1 | tail -15
```

Expected: all 6 tests PASS.

- [ ] **Step 1.5: Run the full BillableCore suite (no regressions)**

```bash
swift test --package-path Packages/BillableCore 2>&1 | tail -10
```

Expected: 153 tests pass (147 prior + 6 new).

- [ ] **Step 1.6: Commit locally**

```bash
git add Packages/BillableCore/Sources/BillableCore/Models/TimeEntry.swift \
        Packages/BillableCore/Tests/BillableCoreTests/ResumePillVisibilityTests.swift
git commit -m "feat(today): shouldShowResumePill helper + 6 unit tests (task 1)

Pure-function visibility check for the Resume Last pill. Encapsulates
the 5 conditions: non-nil lastStopped, endedAt set, project present,
within 60 min, same calendar day.

Tests cover all 5 edge cases. Pass an explicit Calendar for the
cross-midnight test (uses UTC to make the day-boundary deterministic).

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

DO NOT push.

---

## Task 2 — TodayView @Query + ResumePill subview (combined review)

**Files:**
- Modify: `App/Sources/Features/Today/TodayView.swift` — add `@Query` for most-recent stopped entry in `TodayActiveTimerSection`; add `ResumePill` subview; integrate into the body when no running timer

---

- [ ] **Step 2.1: Locate `TodayActiveTimerSection` and its current @Query**

```bash
cd "/Users/lbazerbashi/Elden Studios/billable/.worktrees/v1.3-resume-last"
grep -n "TodayActiveTimerSection\|runningEntries\|RunningTimerCard" App/Sources/Features/Today/TodayView.swift | head -10
```

You should see (around line 162):
- `private struct TodayActiveTimerSection: View {` — the subview wrapping the running timer card
- `@Query(filter: #Predicate<TimeEntry> { $0.endedAt == nil })` — for running entries
- `RunningTimerCard` rendered inside a `TimelineView`

The Resume pill should be added inside `TodayActiveTimerSection`'s body. When `runningEntries.first` is nil, render the pill (if appropriate); otherwise render the existing `RunningTimerCard`.

- [ ] **Step 2.2: Add the second @Query + render the pill conditionally**

In `App/Sources/Features/Today/TodayView.swift`, modify `TodayActiveTimerSection` to add a second `@Query` for the most recent stopped entry and render the pill conditionally.

Replace the existing `TodayActiveTimerSection` struct body with:

```swift
private struct TodayActiveTimerSection: View {
    @Query(filter: #Predicate<TimeEntry> { $0.endedAt == nil })
    private var runningEntries: [TimeEntry]

    @Query(
        filter: #Predicate<TimeEntry> { $0.endedAt != nil },
        sort: \TimeEntry.endedAt,
        order: .reverse
    )
    private var stoppedEntries: [TimeEntry]

    let currencyCode: String
    let onStop: () -> Void
    let onSwitch: () -> Void
    let onResume: (Project) -> Void

    private var lastStopped: TimeEntry? { stoppedEntries.first }

    var body: some View {
        if let running = runningEntries.first {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                RunningTimerCard(entry: running, asOf: context.date, currencyCode: currencyCode, onStop: onStop, onSwitch: onSwitch)
            }
        } else {
            // No running timer — maybe show the Resume pill.
            TimelineView(.periodic(from: .now, by: 60)) { context in
                if TimeEntry.shouldShowResumePill(lastStopped: lastStopped, now: context.date),
                   let last = lastStopped,
                   let project = last.project {
                    ResumePill(project: project, onTap: { onResume(project) })
                } else {
                    EmptyView()
                }
            }
        }
    }
}
```

Notes:
- The second `@Query` doesn't use `fetchLimit` (SwiftData may or may not support it cleanly in `#Predicate` based `@Query`). Sorting `endedAt` desc means `stoppedEntries.first` is the most recent. Acceptable for the size of the local entry set (single user, hundreds-to-thousands of entries max).
- The `TimelineView(.periodic(from: .now, by: 60))` makes the pill re-evaluate visibility every 60 seconds — so it auto-hides when the freshness window expires while Today is open.
- The new `onResume: (Project) -> Void` callback is passed in from the parent view. It receives the project to resume.

- [ ] **Step 2.3: Add the `ResumePill` subview**

In the same file, add the `ResumePill` struct right above `RunningTimerCard`:

```swift
private struct ResumePill: View {
    let project: Project
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "play.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
                Circle()
                    .fill(project.client?.color.swiftUIColor ?? .gray)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Resume \(project.client?.name ?? "—") · \(project.name)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text("Continue tracking where you left off")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 2.4: Wire the `onResume` callback at the call site**

Find where `TodayActiveTimerSection` is instantiated in `TodayView` (search for `TodayActiveTimerSection(`):

```bash
grep -n "TodayActiveTimerSection(" App/Sources/Features/Today/TodayView.swift
```

Currently it's called with `currencyCode`, `onStop`, `onSwitch`. Update the call site to pass the new `onResume` callback. The callback comes from a new method `resumeLastTimer(project:)` on `TodayView` (we'll add it in Task 3 — for now, add a placeholder that just prints to console so this compiles):

In TodayView's body, at the `TodayActiveTimerSection` instantiation:

```swift
TodayActiveTimerSection(
    currencyCode: currencyCode,
    onStop: stopRunning,
    onSwitch: { /* existing switch handler */ },
    onResume: { project in
        // Placeholder — implemented in Task 3
        print("Resume tapped for project: \(project.name)")
    }
)
```

(Find the actual existing switch handler in the diff — pass whatever it currently passes. Don't change the onStop/onSwitch closures.)

- [ ] **Step 2.5: Build + smoke (pill shows but doesn't function yet)**

```bash
xcodebuild -project Billable.xcodeproj -scheme Billable \
  -destination 'platform=iOS Simulator,id=D4683F48-10D4-479B-9CAD-0CA09781930F' \
  -configuration Debug -derivedDataPath ./build build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

Install + launch the app. Start a timer, then stop it. The Resume pill should appear on Today. Tapping it should print to console (no functional resume yet — that's Task 3).

- [ ] **Step 2.6: Run all tests**

```bash
swift test --package-path Packages/BillableCore 2>&1 | tail -10
xcodebuild test -project Billable.xcodeproj -scheme Billable \
  -destination 'platform=iOS Simulator,id=D4683F48-10D4-479B-9CAD-0CA09781930F' 2>&1 | tail -10
```

Expected: 153 + 1 UI test still pass.

- [ ] **Step 2.7: Commit locally**

```bash
git add App/Sources/Features/Today/TodayView.swift
git commit -m "feat(today): @Query + ResumePill subview (placeholder tap action) (task 2)

Adds a second @Query in TodayActiveTimerSection for the most recent
stopped TimeEntry (sorted by endedAt desc). When no running timer is
active AND shouldShowResumePill returns true, renders a ResumePill
button with the client color dot, project name, and a soft secondary
background.

TimelineView(.periodic(from: .now, by: 60)) drives re-evaluation so
the pill auto-hides when the 60-minute window expires while Today is
open.

Tap handler is a console-print placeholder for now — Task 3 wires
TimerService.start(project:in:).

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

DO NOT push.

---

## Task 3 — Wire the resume action + smoke (combined review)

**Files:**
- Modify: `App/Sources/Features/Today/TodayView.swift` — replace placeholder tap handler with real `TimerService.start(project:in:)` call

---

- [ ] **Step 3.1: Locate the placeholder and the existing TimerService usage**

```bash
cd "/Users/lbazerbashi/Elden Studios/billable/.worktrees/v1.3-resume-last"
grep -n "TimerService\|Resume tapped\|onResume" App/Sources/Features/Today/TodayView.swift
```

You should see the Task 2 placeholder (`print("Resume tapped...")`) and the existing `stopRunning()` method that calls `TimerService.stop(in: modelContext)`.

- [ ] **Step 3.2: Add the `resumeLastTimer(project:)` method**

In `TodayView`, add a private method that wraps the TimerService call:

```swift
private func resumeLastTimer(project: Project) {
    do {
        let entry = try TimerService.start(project: project, in: modelContext)
        Task { await TimerActivityController.shared.startActivity(
            for: entry,
            currencyCode: profiles.first?.currencyCode ?? "USD"
        ) }
        Task { try? await StartTimerIntent(project: project).donate() }
    } catch TimerService.TimerError.projectIsArchived {
        // The project was archived since the last stop. Silently fail — the pill
        // will disappear on next refresh once the user stops or switches.
    } catch {
        // No-op. The pill will remain available; the user can tap again.
    }
}
```

(Adapt to the actual signature of `StartTimerIntent` and `TimerActivityController.startActivity` — check `Packages/BillableCore/Sources/BillableCore/Intents/TimerAppIntents.swift` and `App/Sources/LiveActivity/TimerActivityController.swift` for the right argument patterns. The shape above matches `StartTimerSheet.swift:131`'s flow.)

- [ ] **Step 3.3: Replace the placeholder tap handler**

In `TodayView`'s body where `TodayActiveTimerSection` is instantiated, replace:

```swift
onResume: { project in
    print("Resume tapped for project: \(project.name)")
}
```

with:

```swift
onResume: resumeLastTimer
```

- [ ] **Step 3.4: Build + manual smoke walkthrough**

```bash
xcodebuild -project Billable.xcodeproj -scheme Billable \
  -destination 'platform=iOS Simulator,id=D4683F48-10D4-479B-9CAD-0CA09781930F' \
  -configuration Debug -derivedDataPath ./build build 2>&1 | tail -5
xcrun simctl install D4683F48-10D4-479B-9CAD-0CA09781930F \
  ./build/Build/Products/Debug-iphonesimulator/Billable.app
xcrun simctl launch D4683F48-10D4-479B-9CAD-0CA09781930F com.eldenstudios.billable
```

Manual test:
1. Start a timer (Start Timer → Pick client + project → Submit).
2. Wait a few seconds.
3. Stop the timer.
4. Observe the Resume pill appearing under the (now empty) active-timer area.
5. Tap the pill.
6. Expect: a new running timer appears with the same client + project. The pill disappears.
7. Stop the new timer.
8. Verify the Timeline shows TWO separate blocks with the actual gap between them.

- [ ] **Step 3.5: Run all tests one last time**

```bash
swift test --package-path Packages/BillableCore 2>&1 | tail -10
xcodebuild test -project Billable.xcodeproj -scheme Billable \
  -destination 'platform=iOS Simulator,id=D4683F48-10D4-479B-9CAD-0CA09781930F' 2>&1 | tail -10
```

Expected: 153 BillableCore + 1 UI test pass.

- [ ] **Step 3.6: Commit locally**

```bash
git add App/Sources/Features/Today/TodayView.swift
git commit -m "feat(today): wire ResumePill tap to TimerService.start (task 3)

resumeLastTimer(project:) calls the existing TimerService.start(project:in:)
helper — the same path StartTimerSheet and StartTimerIntent use. Also
starts the Live Activity and donates the App Intent for Siri history,
mirroring StartTimerSheet's flow.

Errors are swallowed: a project archived between stop+resume is a real
edge case but rare; the pill will disappear naturally when the freshness
window expires or a different timer is started.

Resume Last is now fully functional end-to-end. Timeline reflects reality
with two distinct blocks for the original + resumed entries; invoice
generator's adjacent-entry grouping (existing) handles the line-item
collapse.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

DO NOT push.

---

## Final wrap-up checklist (after all 3 tasks pass review)

- [ ] **Verify branch state:**

```bash
cd "/Users/lbazerbashi/Elden Studios/billable/.worktrees/v1.3-resume-last"
git log --oneline main..HEAD
```

Expected: 3 commits, one per task.

- [ ] **Run full test suite:**

```bash
swift test --package-path Packages/BillableCore 2>&1 | tail -5
xcodebuild test -project Billable.xcodeproj -scheme Billable \
  -destination 'platform=iOS Simulator,id=D4683F48-10D4-479B-9CAD-0CA09781930F' 2>&1 | tail -5
```

Expected: 153 BillableCore + 1 UI = all pass.

- [ ] **Push to origin:**

```bash
git push -u origin feature/v1.3-resume-last
```

- [ ] **Dispatch final holistic reviewer.**

- [ ] **After approval:** merge to main with `--no-ff`, decide whether to tag (could batch with other v1.3 polish into a single v1.3 tag later, OR tag as v1.2.1 / v1.3-rc — defer to user).

---

## Acceptance criteria (must all pass)

1. Stop a timer → "Resume Acme Corp · Project X" pill appears on Today (when within freshness window).
2. Tap the pill → a new running timer appears, pill disappears, Timeline shows two blocks with the gap.
3. Wait > 60 min after stop → pill auto-hides on the next 60-second tick.
4. Cross midnight → pill auto-hides.
5. While a timer is running → no pill visible.
6. Last stopped entry has no project (data corruption) → no pill visible.
7. 6 new BillableCore unit tests pass.
8. All existing 147 BillableCore tests + 1 UI test still pass.

---

## Out of scope (deferred to later releases)

Per spec §8:
- Pause/Resume on the entry itself (multi-interval model)
- Cross-day resume
- Multi-entry resume picker
- Resume button on the Timeline editor
- Live Activity wake-up when pill becomes available
