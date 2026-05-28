# Project Detail Screen — Design

**Date:** 2026-05-28
**Status:** Approved — ready for implementation planning
**Branch base:** `feature/project-detail`, cut from `origin/main` (`652aaae`) which already contains the invoice-per-project feature.
**Scope:** A dedicated per-project screen showing lifetime totals (hours worked + their live $ value at the current rate), the engagement window (start date, days worked, completion date), a per-project timer, recent sessions, and contextual actions (Start timer, Create invoice, Complete project). Tapping a project opens this screen instead of jumping straight to the edit form.
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
- An **engagement window**: start date (first day tracked), **days worked** (distinct calendar days with a session), and **completion date** (when the user taps *Complete project*).
- Relocate **Complete project** onto this screen (today it lives only on the client list + edit form).
- Totals computed **on the fly** from the project's entries. The **one** new stored field is `Project.completedAt` (nullable → lightweight migration) so the completion date can be shown.

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
| Start date | **First day time was tracked** (earliest entry's `startedAt`). Falls back to `project.createdAt` when no time is tracked yet. |
| Days worked | **Distinct calendar days** that have ≥1 session (so 5 scattered days across two weeks reads as "5 days"), not the calendar span. |
| Completion date | New **`Project.completedAt: Date?`**, stamped when *Complete project* is tapped, cleared on restore. Shown only for completed (archived) projects. |
| Complete project | **Moves to the Project Detail screen only.** Removed from the client-list swipe action **and** from `ProjectEditorView`. Restore (for archived projects) is offered on the detail screen too. |
| Navigation | Tapping a project opens **Project Detail**; editing moves behind an **Edit** button in the nav bar (reuses the existing `ProjectEditorView`, minus its Complete button). |
| Invoice entry points | **Both** — Create invoice on the project screen **and** the existing global **+** in the Invoices tab. |
| Phasing | **None.** Because invoice-per-project is already on the base branch, the Project screen, the timer, and the invoice button ship **together** as one feature. |
| Totals storage | Totals **computed on the fly** from `project.entries` (mirrors `ReportsAggregator`). The only new stored field is `Project.completedAt` (nullable, lightweight migration). |
| Invoices tab | **Unchanged.** "Outstanding" already represents pending (sent, unpaid) invoices. |

## 5. Data

### 5.1 Model change — `Project.completedAt`

Add one nullable field to `Project` ([Project.swift](../../../Packages/BillableCore/Sources/BillableCore/Models/Project.swift)) (lightweight migration; existing rows default `nil`):

```swift
public var completedAt: Date?   // when the user tapped "Complete project"; nil while active
```

Add it to `init` (default `nil`). Lifecycle: completing a project sets `isArchived = true` **and** `completedAt = .now`; restoring sets `isArchived = false` **and** `completedAt = nil`. These always move together — both the complete and restore sites (now on the Project Detail screen) must set both. `isArchived` stays the source of truth for "is this project active"; `completedAt` is purely for display.

### 5.2 Per-project aggregation — `ProjectStats`

Add a small pure value type in BillableCore, computed from a project's entries, unit-testable in isolation (mirrors the reduce pattern in [ReportsAggregator](../../../Packages/BillableCore/Sources/BillableCore/Reporting/ReportsAggregator.swift)):

```swift
public struct ProjectStats {
    public let lifetimeSeconds: TimeInterval   // Σ entry.duration(asOf:) — the hero (hours worked, breaks excluded)
    public let lifetimeValue: Decimal          // Σ entry.amount(asOf:) — value of that time at the CURRENT rate
    public let uninvoicedAmount: Decimal       // Σ amount over entries with invoiceID == nil
    public let sessionCount: Int               // number of entries
    public let activeDayCount: Int             // distinct calendar days with ≥1 entry (by startedAt)
    public let firstTrackedDay: Date?          // earliest entry.startedAt; nil if no entries
    public static func compute(for project: Project, asOf: Date, calendar: Calendar = .current) -> ProjectStats
}
```

- Uses the existing `TimeEntry.duration(asOf:)` / `amount(asOf:)` — breaks already excluded, non-billable projects already yield 0.
- `lifetimeValue` is deliberately **not** named "earnings": it is hours × the project's *current* `hourlyRate`, the same live computation the timer shows. It is not a billed/invoiced record and is expected to move if the rate changes.
- `activeDayCount` groups entries by `calendar.startOfDay(for: entry.startedAt)` and counts the distinct days — the "worked N days" figure.
- `firstTrackedDay` is the earliest `startedAt`; the screen's **start date** is `firstTrackedDay ?? project.createdAt`.
- A running entry contributes live (its `duration`/`amount` tick), so the screen wraps the totals in a `TimelineView(.periodic(from: .now, by: 1))` exactly like `TodaySummarySection` does.
- `uninvoicedAmount` filters `entry.invoiceID == nil`; it powers both the Uninvoiced tile and the "Create invoice · $X" hint.
- Non-billable project → `lifetimeValue` / `uninvoicedAmount` are 0; the screen shows **hours only** and hides money/invoice affordances.

## 6. Project Detail screen

New view: `App/Sources/Features/Projects/ProjectDetailView.swift` (`ProjectDetailView(project:)`).

Top-to-bottom:

1. **Header** — project name + `$rate/h · billable` (or `Non-billable`).
2. **Hero** — **lifetime hours worked** as the large lead number, with **session count** and the live **$ value** (`$4,250 at $75/h`) beside/under it. Warm gradient, matching the timer card's accent. No "earnings" wording. For a non-billable project the $ value is omitted and hours stand alone.
3. **Engagement line** — a caption row: `Started May 1 · 5 days worked` for active projects; `May 1 – May 14 · 5 days worked` once completed (start `–` completion). Uses `firstTrackedDay`/`activeDayCount` and `completedAt`.
4. **Uninvoiced tile** — a single full-width tile (reusing the style of `TodayView`'s `UninvoicedTile`) showing `uninvoicedAmount`. Hidden for non-billable projects.
5. **Action area** (see §7 and §8) — timer control + Create invoice.
6. **Recent sessions** — the project's entries, newest first, grouped by month header; each row shows date · worked hours and (billable) the row's amount. Tapping a row opens the existing `ManualEntrySheet(editing:)` for that entry. Rendered with a lazy `List`/`LazyVStack`; for very long projects show a recent window (e.g. latest 50) with a "See all" disclosure rather than every row at once. (Lifetime totals still aggregate **all** entries — only the rendered list is windowed.)
7. **Lifecycle action** — a **Complete project** button (active projects) / **Restore project** button (archived), near the bottom. Completing confirms via dialog, sets `isArchived = true` + `completedAt = .now`, and pops back; restoring reverses both.
8. **Nav bar** — **Edit** (trailing) presents `ProjectEditorView(client:project:)`; Delete remains available there. The editor's own "Complete project" button is **removed** (lifecycle now lives on this screen).

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
- Active project rows: replace the `editingProject` sheet-on-tap with a `NavigationLink` to `ProjectDetailView(project:)`. The **Delete** swipe stays; the **Archive/Complete** swipe is **removed** (Complete now lives on the detail screen).
- Archived project rows: also navigate to `ProjectDetailView` (read-only; Start/Switch and Create-invoice suppressed; Restore available on the detail screen). The archived-section row no longer needs its Restore swipe, but keeping it is harmless — implementer's choice.
- The `editingProject` sheet state and the `projectToComplete` confirmation dialog are removed from `ClientDetailView` (editing + lifecycle now live on `ProjectDetailView`). New-project creation (`showingNewProject`) is unchanged.

## 10. Edge cases

- **No sessions yet:** hero shows 0h (and $0 for billable); recent-sessions area shows a short empty state; `activeDayCount` is 0 and the start date falls back to `createdAt` (engagement line reads `Created May 1`); Start timer still available.
- **Non-billable project:** the $ value and Uninvoiced tile are hidden; hours + day count retained; Create-invoice hidden.
- **Archived (completed) project:** detail viewable; Start/Switch + Create-invoice suppressed; engagement line shows the `start – completedAt` range; **Restore** available (clears `completedAt`).
- **Completed project with `completedAt == nil`** (legacy rows archived before this field existed): engagement line omits the end date and shows just the start + day count — no backfill attempted.
- **Running entry belongs to this project:** totals and the live session reconcile — the hero ticks while the inline timer runs (both read the same entry's `duration`/`amount`).
- **Project deleted while viewed** (e.g., from another session): navigation pops; standard SwiftData missing-object handling.
- **Cross-day session safety:** unchanged — `TimerService.reconcileActiveSessionOnLaunch` still governs midnight rollover.

## 11. Testing

**BillableCore (`swift test`):**
- `ProjectStats.compute`: `lifetimeSeconds` and `lifetimeValue` sum only this project's entries; `uninvoicedAmount` excludes entries with a non-nil `invoiceID`; a non-billable project yields `lifetimeValue`/`uninvoicedAmount` == 0 but correct hours; a running entry contributes at the given `asOf`; changing the project's rate changes `lifetimeValue` (confirms it is current-rate, not a snapshot).
- `activeDayCount`: multiple entries on the same calendar day count once; entries on different days count separately (test across a timezone-stable boundary). `firstTrackedDay` equals the earliest `startedAt` and is `nil` for a project with no entries.
- Existing `TimerService`, `InvoiceBuilder`, and recurrence tests stay green (no behavior change to those).

**UI (build + simulator):**
- Tapping a project opens Project Detail with correct totals; Edit opens the editor.
- Timer: Start from idle; Switch when another project runs; Break/Resume/Done inline when this project is live; Live Activity + widget reflect it.
- Create invoice opens the generator pre-scoped to the project; the global + still works.
- Engagement line shows correct start date + days worked; **Complete project** stamps `completedAt`, moves the project to Archived, and the line shows the date range; **Restore** clears it.
- Non-billable and archived projects render the suppressed states.

## 12. Files affected

| File | Change |
|---|---|
| `Packages/BillableCore/.../Models/Project.swift` | Add nullable `completedAt: Date?` (+ init default) |
| `Packages/BillableCore/.../Reporting/ProjectStats.swift` (new) | `ProjectStats` value type + `compute(for:asOf:calendar:)` |
| `Packages/BillableCore/Tests/...` | `ProjectStats` tests (totals, `activeDayCount`, `firstTrackedDay`) |
| `App/Sources/Features/Projects/ProjectDetailView.swift` (new) | The screen (hero, engagement line, stats, timer area, sessions, Complete/Restore, Edit) |
| `App/Sources/Features/Projects/ProjectEditorView.swift` | Remove the "Complete project" button (lifecycle moves to detail) |
| `App/Sources/Features/Today/TodayView.swift` | Extract the running-timer card into a shared component reused by Project Detail |
| `App/Sources/Features/Clients/ClientDetailView.swift` | Project rows navigate to `ProjectDetailView`; drop edit-on-tap sheet + Archive swipe + `projectToComplete` dialog |
| `App/Sources/Features/Invoicing/InvoiceGeneratorView.swift` | Add `defaultProject:` init param; seed `selectedProject` |

## 13. Implementation notes

- The running-timer card extraction (Today ↔ Project Detail) is the one piece of shared UI; keep it a single source of truth so the two screens never drift.
- Visual polish (hero gradient, tiles, ledger rows) should hit the app's existing timer-card bar; use the **frontend-design** skill at implementation time.
- Base all work on `feature/project-detail` (off `origin/main`); do not touch shared branches.
