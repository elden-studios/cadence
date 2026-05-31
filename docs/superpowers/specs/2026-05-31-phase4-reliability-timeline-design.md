# Phase 4 — Reliability Foundation & Timeline (design)

**Date:** 2026-05-31
**Status:** Draft (design) → implementation
**Baseline:** real `main` = `origin/main` `df4a6d6` (Phases 1–3 merged). Branch `feature/phase4-reliability-timeline`.
**Source:** verified backlog — items F12, F2/F16/F22, F9/F24/F40, F13, F14. Final committed phase of the 4-phase program.

Phase 4 hardens reliability: a single user-facing error channel for the silent failure paths, wiring the timeline's dead-end "Edit" affordance, closing the ManualEntry data-loss / future-date / side-effect-bypass gaps (incl. the deferred root cause of Phase 2's fetch edge-cases), and de-duplicating the duration formatter.

---

## Scope (4 work-streams)

| # | Item | Source | Priority |
|---|------|--------|----------|
| 1 | Shared error-surface (modal alert) for silent failures | F12 | High |
| 2 | Timeline "Edit"/tap → ManualEntrySheet; running-block drag fix | F2/F16/F22 | High |
| 3 | ManualEntry: future-date guard + break-data warning + TimerActions side-effects | F9/F24/F40, F13 | Medium |
| 4 | One `DurationFormatting` helper; replace 8 duplicated sites | F14 | Medium |

**Non-goals:** Phases 5–8; reworking the timer/recurrence engines. Reuse `ManualEntrySheet`, `TimerActions`, existing alert idiom.

---

## Item 1 — Shared error-surface (modal alert) [F12]

### Problem
Writes/finalize/destructive paths swallow failures (`try?`/empty `catch`) with no user signal: `InvoiceDetailView.markPaid`, `TimerActions.start/switchTo/takeBreak/resume/stop`, `ManualEntrySheet` create. Phase 1 added a *local* `finalizeError` alert in `InvoicePreviewView`; Phase 3 added a *local* `saveErrorAlert` in `InvoiceGeneratorView` — two one-off channels. There's no shared channel, so most failures stay silent.

### Design (decision: modal alert)
- **`@Observable AppErrorPresenter`** (in `BillableCore` or `App/Sources`; pick the location that keeps it injectable + testable — likely `App` since it's UI-presentation, but a pure `@Observable` with `var message: String?` + `func present(_:)` is testable anywhere). API: `func present(_ message: String)` sets `message`; the host clears it on dismiss.
- **Inject once** at the app root (`BillableApp`) into the environment (mirroring `NotificationRouter`), and **host a single `.alert`** on `RootView` (on the `Group`/`mainShell`) reading the presenter: `.alert("Something went wrong", isPresented: <message != nil>, presenting: message) { Button("OK", role: .cancel) {} } message: { Text($0) }`.
- **Route the silent VIEW-layer money/data sites through it** (these are the high-value ones, all `@MainActor` views that can read `@Environment(AppErrorPresenter.self)`):
  - `InvoiceDetailView.markPaid` — on `markPaid()` throw → `present("Couldn't mark the invoice as paid — try again.")`.
  - `InvoicePreviewView` finalize — replace the local `finalizeError` alert with `present(...)` (one channel).
  - `InvoiceGeneratorView.saveRecurrence` — replace the local `saveErrorAlert` with `present(...)`.
  - `ManualEntrySheet` save failure (Item 3) → `present(...)`.
- **`TimerActions`** is a static, non-view dispatcher called from several views; its functions return `nil`/throw on failure. Surface those at the **call sites** (the views already call `TimerActions.start(...)` etc.) by checking the optional return and calling `present(...)` when nil — wire the highest-traffic callers (JumpBackIn, WorkView, ProjectDetail, StartTimerSheet). If wiring every TimerActions caller is disproportionate, cover the money/data sites above + the primary timer-start callers, and note any unrouted site — do NOT change `TimerActions`' signatures destructively.

### Testing
BillableCore unit test for `AppErrorPresenter` (`present` sets `message`; dismiss clears). Build + manual: force a failure (e.g. mark-paid on a deliberately broken context in a debug hook, or rely on review reasoning) → the alert shows. The two migrated local alerts still fire via the shared channel.

---

## Item 2 — Timeline "Edit"/tap wiring [F2/F16/F22]

### Problem
`DayTimelineView`: `onTap`/`onLongPress` (`:172-173`) and context-menu "Edit" (`:190`) all set `selectedEntry` with **no** `.sheet`/destination observing it — "Edit" does nothing but highlight. Dragging a *running* block animates then snaps back (`commitActiveDrag` early-returns on `endedAt == nil`).

### Design
- Add `.sheet(item: $selectedEntry) { ManualEntrySheet(editing: $0) }` so tap / "Edit" opens the existing editor. (`selectedEntry` is `@State TimeEntry?`; `ManualEntrySheet(editing:)` exists.)
- **Running blocks:** suppress the drag gesture for a running entry (`entry.isWorking`/`endedAt == nil`) — don't start `activeDrag` — so it can't animate-then-revert. (Tapping a running block can still open the editor, or be a no-op; the editor itself handles a running entry per Item 3's guard. Pick the least-surprising: allow tap-to-edit; suppress drag.)

### Testing
Build + manual: tap a completed block / "Edit" → editor opens with that entry; editing persists. A running block doesn't drag (no snap-back).

---

## Item 3 — ManualEntry: future guard + break-data + side-effects [F9/F24/F40, F13]

### Problem
`ManualEntrySheet.save()`: when editing and times changed, it zeroes `accumulatedSeconds` + nils `activeSegmentStartedAt` (destroying banked breaks) and force-sets `isManual = true` — silently. The Start `DatePicker` has no upper bound (future-dated entries — the root cause of Phase 2's fetch edge-cases), and `TimerService.logCompletedEntry` doesn't clamp a future start. Save also bypasses `TimerActions`, so widgets/Live Activity don't refresh after a manual edit.

### Design
- **Future guard:** bound the Start `DatePicker` with `in: ...Date.now` (cap at now), and add a guard in `TimerService.logCompletedEntry` (and the edit path) rejecting/clamping `start > now` (mirror `adjustStart`'s existing `<= .now` guard). This kills the future-dated-entry class that Phase 2 worked around.
- **Break-data warning:** when editing an entry that has `accumulatedSeconds > 0` (banked breaks) and the times changed, show a brief `confirmationDialog` ("Editing the times will recalculate this entry from start to end and clear recorded breaks.") before flattening — using the existing confirmation idiom; don't silently destroy.
- **Side-effects (F13):** route `ManualEntrySheet.save()` through a `TimerActions` wrapper (e.g. `TimerActions.logCompleted/editEntry`) that performs the save then `WidgetCenter.shared.reloadAllTimelines()` (and reconciles Live Activity if the edited entry is the running one) — so manual edits and live-timer mutations share one side-effect path. Surface a save failure via the Item 1 presenter.

### Testing
BillableCore: `logCompletedEntry` rejects/clamps a future start; `adjustStart`-style guard covered. UI/manual: editing only notes/project preserves `isManual`/breaks; editing times warns before clearing breaks; future start can't be picked; widgets refresh after a manual edit.

---

## Item 4 — One duration formatter [F14]

### Problem
The `"\(h)h \(String(format: "%02d", m))m"` formatter is reimplemented at 8 view-layer sites (TodayView, ProjectDetailView, ManualEntrySheet, ProjectSessionsView, WorkView, InvoiceGeneratorView, ReportsView [Decimal hours], TodaySummaryWidget) — drift hazard, and ReportsView's variant takes Decimal hours.

### Design
Add `BillableCore` `enum DurationFormatting { static func hoursMinutes(seconds: TimeInterval) -> String; static func hoursMinutes(decimalHours: Decimal) -> String }`. Replace all 8 call sites (the widget target already links BillableCore). EXCLUDE `InvoiceTemplate.formatHours` (intentionally renders decimal hours like "3.5"). TDD the helper (e.g. 0s→"0h 00m", 3661s→"1h 01m", 1.5h→"1h 30m").

### Testing
BillableCore unit tests for both overloads + edge cases. Build: all 8 sites compile against the helper; numbers unchanged.

---

## Cross-item notes
- **Multi-file phase.** Suggested build order to limit same-file churn: (A) error-surface foundation + money sites → (B) timeline wiring → (C) ManualEntry guards + side-effects (uses A's presenter) → (D) formatter dedup (last; touches several files A/C also touched).
- **Test command:** `xcodebuild -project Billable.xcodeproj -scheme Billable -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build/DerivedData build`; `swift test --package-path Packages/BillableCore`.
- **TDD** for BillableCore additions (`AppErrorPresenter` if placed there, `DurationFormatting`, the `logCompletedEntry` future guard). View wiring is build- + review-verified.
