# Today Timer Redesign — Break / Resume / Done-for-now

**Date:** 2026-05-28
**Status:** Approved — ready for implementation planning
**Scope:** Running-timer experience on the Today screen + a clarifying "Complete Project" action.
**Out of scope:** Invoice-per-project changes (tracked as a separate spec/cycle).

---

## 1. Problem

Today's timer is a single `start → stop` machine. When the user hits Stop:

- The running card collapses abruptly and the "Start timer" button appears — an unpolished transition.
- There is no way to **pause** a session and keep the accumulated time; "stop" is the only exit.
- A separate "Resume" pill ([TodayView.swift:227](../../../App/Sources/Features/Today/TodayView.swift)) tries to fill the gap, but it just starts a brand-new entry and is gated (60 min, same day), so it often isn't visible when expected.

The user wants a **Pause/Resume** model where pausing preserves the count, and a clearly-labelled stop that means "done for now" (session saved, counter reset) — explicitly **not** "the project is finished."

## 2. Goals

- Add a true **Break / Resume** capability that freezes and continues the worked count.
- Replace the abrupt collapse with a **persistent card that morphs** between states.
- Use vocabulary that describes the *act*, and keep "logging time" cleanly separate from "completing a project."
- Keep the data clean for per-day reporting and invoicing (breaks excluded from billable time).

## 3. Non-goals

- No change to manual time entry, invoicing, or reports beyond what `duration()` already feeds.
- No new "completed vs archived" project state — "Complete" reuses the existing `isArchived`.
- No Siri/AppIntent for break (possible future addition).

---

## 4. Decisions (locked during brainstorming)

| Topic | Decision |
|---|---|
| Direction | **A — "Stopwatch card"**: Break as the big primary button; Switch + Done-for-now in a row beneath. |
| Vocabulary | Status **Working / On Break**; primary **Take a Break** ⇄ **Resume**; stop **Done for now**. |
| Break logging | **One entry per session, breaks excluded** from billable time. |
| Finish vs complete | **Separate concepts.** The timer only logs the session; **Complete Project** is its own action on the project screen, and it alone shows the "are you sure?" confirm. |
| Resume pill | **Removed** — Break/Resume supersedes it. |
| Migration | **None required** — manual/legacy entries fall back to wall-clock duration. |
| Breaks vs timeline | **Accept solid block** — the day-timeline shows one wall-clock block per session (worked-hours label), no break gaps; manual geometry edits flatten breaks. (No per-break timestamps stored.) |

---

## 5. State machine

```
            ┌─────────── Start ───────────┐
            ▼                              │
  ┌──────────────┐  Take a Break  ┌──────────────┐
  │   WORKING    │ ─────────────▶ │   ON BREAK   │
  │ (count ticks)│ ◀───────────── │ (count frozen)│
  └──────────────┘    Resume      └──────────────┘
        │  │                              │
 Done   │  └──────── Switch ──────────────┤   (Switch = finalize current + Start new)
 for    │                                 │ Done for now
 now    ▼                                 ▼
     ┌──────────────────────────────────────┐
     │  IDLE  (session logged as one entry,  │
     │         breaks excluded; counter 0)   │
     └──────────────────────────────────────┘
```

- **Active session** = a `TimeEntry` with `endedAt == nil` (covers both Working and On Break).
- **Working** = active session with `activeSegmentStartedAt != nil`.
- **On Break** = active session with `activeSegmentStartedAt == nil`.

---

## 6. UI design (Direction A)

All states share **one persistent card frame** that cross-fades + slightly slides between states (`withAnimation`), instead of collapsing. Final visual polish is delegated to the **frontend-design** skill during implementation.

**Working**
- Header: client (color dot + name) · status badge **WORKING** (green).
- Project name · large tabular time (ticking) · amount (right).
- Primary button (full width): **☕ Take a Break** (orange accent).
- Row: **⇄ Switch** (outlined, blue) · **Done for now** (outlined, ink — *not* red; it saves time).

**On Break**
- Status badge **ON BREAK** (amber). Time is **dimmed and frozen**; amount frozen.
- Primary button becomes **▶ Resume** (green).
- Same secondary row (Switch · Done for now).

**Idle**
- Same card frame, resting: `00:00:00`, "No timer running", primary **▶ Start timer**.
- Opens the existing `StartTimerSheet`, which already surfaces recent projects, so the last project is a one-tap restart (this replaces the removed Resume pill).

Files: `RunningTimerCard`, `TodayActiveTimerSection`, idle affordance — all in [TodayView.swift](../../../App/Sources/Features/Today/TodayView.swift). Remove `ResumePill`.

---

## 7. Data model — `TimeEntry`

Add two persisted fields ([TimeEntry.swift](../../../Packages/BillableCore/Sources/BillableCore/Models/TimeEntry.swift)):

```swift
public var accumulatedSeconds: Double = 0        // worked time banked across completed segments
public var activeSegmentStartedAt: Date? = nil   // start of current working segment; nil while On Break / finished
```

Derived:

```swift
public var isRunning: Bool   { endedAt == nil }                       // active session (unchanged meaning)
public var isWorking: Bool   { endedAt == nil && activeSegmentStartedAt != nil }
public var isOnBreak: Bool   { endedAt == nil && activeSegmentStartedAt == nil }
```

Redefine `duration(asOf:)` to mean **worked** time (breaks excluded):

```swift
public func duration(asOf referenceDate: Date = .now) -> TimeInterval {
    if let end = endedAt {
        // Finished: live-timer sessions bank worked time; manual/legacy fall back to wall-clock.
        return accumulatedSeconds > 0 ? accumulatedSeconds : max(0, end.timeIntervalSince(startedAt))
    }
    if let segStart = activeSegmentStartedAt {          // Working
        return accumulatedSeconds + max(0, referenceDate.timeIntervalSince(segStart))
    }
    return accumulatedSeconds                            // On Break (frozen)
}
```

`amount(asOf:)` is unchanged (it calls `duration`). **No migration:** existing finished entries have `accumulatedSeconds == 0` and fall back to wall-clock; manual entries continue to do the same.

---

## 8. `TimerService` API ([TimerService.swift](../../../Packages/BillableCore/Sources/BillableCore/Timing/TimerService.swift))

- `start(project:at:notes:)` — sets `startedAt = at`, `activeSegmentStartedAt = at`, `accumulatedSeconds = 0`. (Still finalizes any other active session first.)
- **`takeBreak(at:)`** *(new)* — requires Working. `accumulatedSeconds += max(0, at − activeSegmentStartedAt)`; `activeSegmentStartedAt = nil`. Throws `noRunningTimer` / `alreadyOnBreak`.
- **`resume(at:)`** *(new)* — requires On Break. `activeSegmentStartedAt = at`. Throws `noRunningTimer` / `notOnBreak`.
- `stop(at:)` — "Done for now." If Working, bank final segment; then `activeSegmentStartedAt = nil`, `endedAt = at`. Works from Working **or** On Break.
- `switchTo(project:at:)` — `stop(at:)` then `start(project:at:)` (finalize + start; backward-clock clamped as today).
- `adjustStart(entry:to:)` — shifts `startedAt`; when Working **with no prior breaks** (`accumulatedSeconds == 0`), shift `activeSegmentStartedAt` by the same delta so the live count reflects it. Disallowed On Break (keeps current `entryNotRunning` guard); disallowed once breaks exist (count is no longer a single segment).
- **Stale-session reconcile** *(launch)* — if an active session's `startedAt` is on a previous calendar day, auto-finalize it to its **banked** worked time: set `endedAt = startedAt + accumulatedSeconds`. Any unbanked open segment is discarded rather than fabricating a large overnight duration (so a never-paused session left running overnight logs zero and is dropped). Hook into the existing `reconcileOnLaunch` path; keeps every entry within one day. *(If end-of-day capping is preferred over discarding, decide in the plan.)*

---

## 9. Complete Project (separate action)

- Add a **Complete project** action on the project's own screen ([ProjectEditorView.swift](../../../App/Sources/Features/Projects/ProjectEditorView.swift)).
- Tapping shows a confirm — **"Are you sure you're done with this project?"** — body: *"'<Project>' will be marked complete and moved to Archived. Your logged time stays on past invoices and reports."*
- On confirm: set `isArchived = true`, dismiss. Reuses the existing Archived-projects list ([ClientDetailView.swift:90](../../../App/Sources/Features/Clients/ClientDetailView.swift)) to reopen.
- The existing swipe **Archive** in `ClientDetailView` stays; add the same confirm to it for consistency.
- This confirm appears **only here** — never on the daily timer.

---

## 10. Live Activity / Dynamic Island

The running timer drives a Live Activity ([TimerActivityController.swift](../../../App/Sources/LiveActivity/TimerActivityController.swift), `TimerActivityAttributes` in BillableCore). It must learn the break state:

- On **Take a Break**: update the activity to a frozen "On Break" presentation (stop the ticking).
- On **Resume**: resume ticking.
- On **Done for now / Switch**: end the activity (as stop does today).

`TimerActivityAttributes.ContentState` likely needs an `isOnBreak` flag and the frozen elapsed value.

---

## 11. Edge cases

- **Backward clock** on break/resume/done — clamp segment deltas to ≥ 0 (mirrors today's stop clamp).
- **Done while On Break** — finalizes with banked `accumulatedSeconds`, no open segment to add.
- **Archived project** — starting on an archived project still throws `projectIsArchived` (unchanged).
- **Zero-work session** — `accumulatedSeconds == 0` finished entries fall back to wall-clock (≈0) and are dropped by existing zero-duration filters.
- **App killed while On Break** — the entry persists (`endedAt == nil`, `activeSegmentStartedAt == nil`); resumes correctly next launch unless stale-reconcile (prior day) finalizes it.

---

## 12. Downstream impact (full-flow review)

Redefining `duration()` to mean *worked* time and making `endedAt == nil` cover **Working or On Break** ripples beyond the card. Audit result:

**Automatically correct (already route through `duration()`):** invoice line items + preview total ([InvoiceBuilder.swift](../../../Packages/BillableCore/Sources/BillableCore/Invoicing/InvoiceBuilder.swift), [InvoiceGeneratorView.swift:281](../../../App/Sources/Features/Invoicing/InvoiceGeneratorView.swift)); all Reports aggregates ([ReportsAggregator.swift](../../../Packages/BillableCore/Sources/BillableCore/Reporting/ReportsAggregator.swift)); the Today "Uninvoiced" tile (uses `amount(asOf:)`).

**Must change (bypass `duration()` or assume running ≠ paused):**

- **Today Hours/Earnings tiles** — `TodaySummarySection` ([TodayView.swift:545](../../../App/Sources/Features/Today/TodayView.swift)) sums wall-clock `end − start`, so it would count break time while invoices/reports do not. Switch to per-entry `duration(asOf:)` (worked time). With per-day entries the midnight-clamp is moot; keep a "today" filter.
- **`TodaySummaryWidget`** ([Widgets/Sources/TodaySummaryWidget.swift](../../../Widgets/Sources/TodaySummaryWidget.swift)) — mirror the same worked-time computation so the widget matches the app.
- **`CurrentTimerWidget`** ([Widgets/Sources/CurrentTimerWidget.swift](../../../Widgets/Sources/CurrentTimerWidget.swift)) — add an On-Break presentation (frozen elapsed + "On Break"); reload via `WidgetCenter` on break/resume/done.
- **Day timeline** ([DayTimelineView.swift](../../../App/Sources/Features/Timeline/DayTimelineView.swift), [TimeBlockView.swift](../../../App/Sources/Features/Timeline/TimeBlockView.swift)):
  - Live/pulse styling must key off `isWorking`, not `isRunning` — On-Break blocks render static with an "On Break" treatment.
  - **Block geometry stays wall-clock** (`startedAt → endedAt`). Per the *Accept solid block* decision, a session with breaks is one solid block labelled with worked hours; gaps are not drawn.
  - **Editing flattens breaks**: any drag/resize/split that mutates `startedAt`/`endedAt` sets `accumulatedSeconds = 0` so `duration()` falls back to the new wall-clock span (split already creates fresh wall-clock entries). Editing a live/On-Break entry via the timeline is disallowed (finalize first).
- **CSV export** ([CSVExporter.swift:90](../../../Packages/BillableCore/Sources/BillableCore/Reporting/CSVExporter.swift)) — the duration column is worked time and can be less than `end − start` when breaks occurred; make the header/notes clear.

**General invariant:** because per-break timestamps are not stored, **any manual mutation of an entry's `startedAt`/`endedAt` must reset `accumulatedSeconds = 0`** (flatten to wall-clock). Applies to the timeline editors and `ManualEntrySheet` edit paths.

**Net trade-off:** the chosen model keeps invoicing/reports clean for free, at the cost of (a) small rework of the dashboard tiles + widgets to use worked time, and (b) the timeline showing breaks as solid blocks. Both accepted; no per-break data is stored, so breaks are invisible to history once a session is logged — by design.

---

## 13. Testing

**BillableCore unit tests (new `TimerServiceBreakTests` + `TimeEntry` duration tests):**
- Take a Break banks the current segment; `isOnBreak` true; `duration` frozen.
- Resume sets a new segment; subsequent `duration` = banked + live.
- Done-for-now from Working totals banked + final segment; from On Break totals banked only.
- Multiple break/resume cycles sum correctly; breaks excluded from `duration`.
- Switch finalizes the current session and starts the new project (no time bleed).
- Backward-clock clamps on break/resume/done.
- Stale cross-day active session auto-finalizes to `startedAt + accumulatedSeconds`.
- `duration()` fallback: manual/legacy finished entry with `accumulatedSeconds == 0` returns wall-clock.

**Consistency (full-flow):**
- Today Hours/Earnings tiles exclude break time and match the worked total used by Reports/invoicing for the same entries.
- Editing an entry's `startedAt`/`endedAt` resets `accumulatedSeconds` to 0 → `duration()` equals the new wall-clock span.

**Update / remove:**
- Update existing stop tests in `TimerServiceTests` for the banked-duration semantics.
- Remove `shouldShowResumePill` and its tests (pill removed).

**UI:** existing 5 UI smoke tests must stay green; optionally add one asserting the Working↔On-Break card swap.

---

## 14. Files affected

| File | Change |
|---|---|
| `Packages/BillableCore/.../Models/TimeEntry.swift` | New fields, `isWorking`/`isOnBreak`, `duration()` redefine |
| `Packages/BillableCore/.../Timing/TimerService.swift` | `takeBreak`/`resume`, `stop`/`switchTo` semantics, stale reconcile, new errors |
| `App/Sources/Features/Today/TodayView.swift` | Direction-A card, Working/On-Break/Idle, morph transition, remove `ResumePill`; **summary Hours/Earnings tiles → worked time** |
| `App/Sources/Features/Projects/ProjectEditorView.swift` | "Complete project" + confirm |
| `App/Sources/Features/Clients/ClientDetailView.swift` | Add confirm to existing Archive swipe |
| `App/Sources/LiveActivity/TimerActivityController.swift` + `TimerActivityAttributes.swift` | Break-aware Live Activity state |
| `App/Sources/Features/Timeline/DayTimelineView.swift` + `TimeBlockView.swift` | Pulse off `isWorking`; On-Break style; block stays wall-clock; geometry edits flatten `accumulatedSeconds` |
| `Widgets/Sources/CurrentTimerWidget.swift` | On-Break presentation + reloads |
| `Widgets/Sources/TodaySummaryWidget.swift` | Worked-time totals (match app) |
| `App/Sources/Features/Timer/ManualEntrySheet.swift` | Reset `accumulatedSeconds = 0` on any start/end edit |
| `Packages/BillableCore/Sources/BillableCore/Reporting/CSVExporter.swift` | Clarify duration column is worked time |
| `Packages/BillableCore/Tests/...` | New break/duration tests; summary/timeline consistency; update stop tests; drop resume-pill tests |

---

## 15. Implementation note

The visual build of the card (Direction A, the morph transition, badges, button styling) should be carried out with the **frontend-design** skill to hit the polish bar the user asked for.
