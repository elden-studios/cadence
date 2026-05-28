# Project Detail Screen — Design

**Date:** 2026-05-28
**Status:** Approved — ready for implementation planning
**Branch base:** `feature/project-detail`, cut from `origin/main` (`652aaae`) which already contains the invoice-per-project feature.
**Scope:** A dedicated per-project screen showing lifetime totals (hours worked + their live $ value at the current rate), a per-project timer, recent sessions, and contextual actions (Start timer, Create invoice). Tapping a project opens this screen instead of jumping straight to the edit form.
**Out of scope:** Charts/trend graphs (deferred — the analytical view lives in Reports); per-project recurring schedules; any change to invoice rendering or the invoice lifecycle.

---

## 1. Problem

A project has **no screen of its own**. Tapping a project in [ClientDetailView.swift:57](../../../App/Sources/Features/Clients/ClientDetailView.swift) opens the **edit form** directly. As a result:

- There is **nowhere to see a project's cumulative total** — lifetime hours worked or their accumulated $ value across days/sessions. The live timer shows only the current session; the Today summary is today-only; Reports (Pro) shows time-range-filtered cross-project tables. A user who works a project today, hits "Done for now," and resumes tomorrow has no running lifetime total for that project.
- Starting a timer always routes through the Today tab → `StartTimerSheet` project picker; you cannot start tracking from the project itself.
- Creating an invoice always routes through the Invoices tab; you cannot invoice a project from its own context.

## 2. Goals

- A read-only **Project Detail** screen, reached by tapping a project, surfacing **lifetime hours worked** (with their live $ value at the current rate) as the primary content.
- A **per-project timer**: start (or switch to) this project from its screen; when this project is the live timer, show the running state inline with Break / Resume / Done.
- A **Create invoice** action on the project that opens the generator **pre-scoped to this project**, while the global **+** in the Invoices tab is **retained** (two entry points to the same flow).
- **Recent sessions** for the project, grouped by month (ledger style).
- All totals computed **on the fly** from the project's entries — **no new stored field, no migration**.

## 3. Non-goals

- No per-project charts/trends (Reports remains the analytical surface).
- No change to the Invoices tab beyond what already exists — it is already a status board (Outstanding / Paid / Drafts / Recurring); we are **not** removing its global creation entry point.
- No change to `TimerService`, invoice rendering, or the invoice lifecycle.

## 4. Decisions (locked during brainstorming)

| Topic | Decision |
|---|---|
| Layout | **Hero + ledger**: the hero leads with **lifetime hours worked** (breaks excluded) and **session count**; the live **$ value** sits beside it. Then a single **Uninvoiced** tile, action buttons, and sessions grouped by month. |
| What the $ means | The $ is **`hours × current rate`**, ticking live exactly like the timer — it is the **value of tracked time at the current rate, NOT an "earned"/invoiced figure.** The hero avoids the words "earned"/"earnings"; it shows e.g. `$4,250 at $75/h`. If the rate changes, the displayed value reflects the new rate (because it is not a billed record). The frozen, billed totals live on the invoices themselves. |
| Time scope | **Lifetime total only** (all sessions, all days). Period breakdowns (week/month/all-time) stay in Reports — no period selector on this screen. |
| Navigation | Tapping a project opens **Project Detail**; editing moves behind an **Edit** button in the nav bar (reuses the existing `ProjectEditorView` unchanged). |
| Invoice entry points | **Both** — Create invoice on the project screen **and** the existing global **+** in the Invoices tab. |
| Phasing | **None.** Because invoice-per-project is already on the base branch, the Project screen, the timer, and the invoice button ship **together** as one feature. |
| Totals storage | **Computed on the fly** from `project.entries` (mirrors `ReportsAggregator`). No new `Project` field, no migration. |
| Invoices tab | **Unchanged.** "Outstanding" already represents pending (sent, unpaid) invoices. |

## 5. Data — per-project aggregation

Add a small pure value type in BillableCore, computed from a project's entries, unit-testable in isolation (mirrors the reduce pattern in [ReportsAggregator](../../../Packages/BillableCore/Sources/BillableCore/Reporting/ReportsAggregator.swift)):

```swift
public struct ProjectStats {
    public let lifetimeSeconds: TimeInterval   // Σ entry.duration(asOf:) — the hero (hours worked, breaks excluded)
    public let lifetimeValue: Decimal          // Σ entry.amount(asOf:) — value of that time at the CURRENT rate
    public let uninvoicedAmount: Decimal       // Σ amount over entries with invoiceID == nil
    public let sessionCount: Int               // number of entries
    public static func compute(for project: Project, asOf: Date) -> ProjectStats
}
```

- Uses the existing `TimeEntry.duration(asOf:)` / `amount(asOf:)` — breaks already excluded, non-billable projects already yield 0.
- `lifetimeValue` is deliberately **not** named "earnings": it is hours × the project's *current* `hourlyRate`, the same live computation the timer shows. It is not a billed/invoiced record and is expected to move if the rate changes.
- A running entry contributes live (its `duration`/`amount` tick), so the screen wraps the totals in a `TimelineView(.periodic(from: .now, by: 1))` exactly like `TodaySummarySection` does.
- `uninvoicedAmount` filters `entry.invoiceID == nil`; it powers both the Uninvoiced tile and the "Create invoice · $X" hint.
- Non-billable project → `lifetimeValue` / `uninvoicedAmount` are 0; the screen shows **hours only** and hides money/invoice affordances.

## 6. Project Detail screen

New view: `App/Sources/Features/Projects/ProjectDetailView.swift` (`ProjectDetailView(project:)`).

Top-to-bottom:

1. **Header** — project name + `$rate/h · billable` (or `Non-billable`).
2. **Hero** — **lifetime hours worked** as the large lead number, with **session count** and the live **$ value** (`$4,250 at $75/h`) beside/under it. Warm gradient, matching the timer card's accent. No "earnings" wording. For a non-billable project the $ value is omitted and hours stand alone.
3. **Uninvoiced tile** — a single full-width tile (reusing the style of `TodayView`'s `UninvoicedTile`) showing `uninvoicedAmount`. Hidden for non-billable projects.
4. **Action area** (see §7 and §8) — timer control + Create invoice.
5. **Recent sessions** — the project's entries, newest first, grouped by month header; each row shows date · worked hours and (billable) the row's amount. Tapping a row opens the existing `ManualEntrySheet(editing:)` for that entry.
6. **Nav bar** — **Edit** (trailing) presents `ProjectEditorView(client:project:)` as today; the Complete/Archive and Delete actions remain available there.

Live totals via `TimelineView(.periodic)`. The view reads the single running entry via a `@Query` on `endedAt == nil` (same descriptor pattern as `TodayActiveTimerSection`) to decide the timer state.

## 7. Per-project timer

The action area's timer control has two states, both reusing `TimerService` and the side effects that `StartTimerSheet` / `TodayView` already perform (`TimerActivityController`, intent donation, `WidgetCenter.reloadAllTimelines()`):

- **This project is the live timer** (`runningEntry.project == project`): show the inline running state — WORKING/ON BREAK badge, elapsed time, "$X this session", and **Break/Resume** + **Done** controls — calling `TimerService.takeBreak` / `resume` / `stop`. This reuses the same operations as the Today card; the running-card subview should be factored into a shared component so Today and Project Detail render identically rather than duplicating logic.
- **Idle or a different project is running:**
  - Idle → **Start timer** → `TimerService.start(project:)`.
  - A different project is running → **Switch to this project** → `TimerService.switchTo(project:)` (atomic stop+start; no silent data loss).
  - Archived project → Start/Switch hidden (TimerService would throw `projectIsArchived`).

## 8. Create-invoice entry point

- Add `defaultProject: Project? = nil` to `InvoiceGeneratorView.init` (it already has `defaultClient:` and an internal `selectedProject` state + project picker). When provided, seed `selectedProject`.
- The project screen's **Create invoice** button presents `InvoiceGeneratorView(defaultClient: project.client, defaultProject: project)` as a sheet — the generator opens already scoped to this project, with its eligible entries loaded.
- Show the button only for **billable** projects; label it `Create invoice` with a `· $X` uninvoiced hint when `uninvoicedAmount > 0`. With nothing uninvoiced, the generator opens to its existing empty state.
- The **global +** in [InvoicesView.swift:55](../../../App/Sources/Features/Invoicing/InvoicesView.swift) is **unchanged**, as is "Invoice all projects" inside the generator.

## 9. Navigation changes

In `ClientDetailView`:
- Active project rows: replace the `editingProject` sheet-on-tap with a `NavigationLink` to `ProjectDetailView(project:)`. The swipe actions (Delete, Archive/Complete) stay on the row.
- Archived project rows: also navigate to `ProjectDetailView` (read-only; Start/Switch and Create-invoice suppressed). Restore stays a swipe action.
- The `editingProject` sheet state is removed from `ClientDetailView` (editing now lives in `ProjectDetailView`'s nav bar). New-project creation (`showingNewProject`) is unchanged.

## 10. Edge cases

- **No sessions yet:** hero shows $0 / 0h; recent-sessions area shows a short empty state; Start timer still available.
- **Non-billable project:** the $ value and Uninvoiced tile are hidden; hours are retained; Create-invoice hidden.
- **Archived project:** detail viewable; Start/Switch + Create-invoice suppressed; Restore reachable.
- **Running entry belongs to this project:** totals and the live session reconcile — the hero ticks while the inline timer runs (both read the same entry's `duration`/`amount`).
- **Project deleted while viewed** (e.g., from another session): navigation pops; standard SwiftData missing-object handling.
- **Cross-day session safety:** unchanged — `TimerService.reconcileActiveSessionOnLaunch` still governs midnight rollover.

## 11. Testing

**BillableCore (`swift test`):**
- `ProjectStats.compute`: `lifetimeSeconds` and `lifetimeValue` sum only this project's entries; `uninvoicedAmount` excludes entries with a non-nil `invoiceID`; a non-billable project yields `lifetimeValue`/`uninvoicedAmount` == 0 but correct hours; a running entry contributes at the given `asOf`; changing the project's rate changes `lifetimeValue` (confirms it is current-rate, not a snapshot).
- Existing `TimerService`, `InvoiceBuilder`, and recurrence tests stay green (no behavior change to those).

**UI (build + simulator):**
- Tapping a project opens Project Detail with correct totals; Edit opens the editor.
- Timer: Start from idle; Switch when another project runs; Break/Resume/Done inline when this project is live; Live Activity + widget reflect it.
- Create invoice opens the generator pre-scoped to the project; the global + still works.
- Non-billable and archived projects render the suppressed states.

## 12. Files affected

| File | Change |
|---|---|
| `Packages/BillableCore/.../Reporting/ProjectStats.swift` (new) | `ProjectStats` value type + `compute(for:asOf:calendar:)` |
| `Packages/BillableCore/Tests/...` | `ProjectStats` tests |
| `App/Sources/Features/Projects/ProjectDetailView.swift` (new) | The screen (hero, stats, timer area, sessions, Edit) |
| `App/Sources/Features/Today/TodayView.swift` | Extract the running-timer card into a shared component reused by Project Detail |
| `App/Sources/Features/Clients/ClientDetailView.swift` | Project rows navigate to `ProjectDetailView`; drop the edit-on-tap sheet |
| `App/Sources/Features/Invoicing/InvoiceGeneratorView.swift` | Add `defaultProject:` init param; seed `selectedProject` |

## 13. Implementation notes

- The running-timer card extraction (Today ↔ Project Detail) is the one piece of shared UI; keep it a single source of truth so the two screens never drift.
- Visual polish (hero gradient, tiles, ledger rows) should hit the app's existing timer-card bar; use the **frontend-design** skill at implementation time.
- Base all work on `feature/project-detail` (off `origin/main`); do not touch shared branches.
