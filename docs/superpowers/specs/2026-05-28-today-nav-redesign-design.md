# Today + Navigation Redesign — Design

**Date:** 2026-05-28
**Status:** Approved — ready for implementation planning
**Branch base:** `feature/today-nav-redesign`, cut from `feature/project-detail` (`b8cce19`). This feature **depends on** the project-detail work (it reuses `RunningTimerCard`, `TimerActions`, `ProjectStats`, and `ProjectDetailView`). That branch must land before/with this one.
**Scope:** Make the app project-first. Replace the Clients tab with a project-forward **Work** browser (with a Projects | Clients toggle), refocus **Today** into a real daily summary + quick-resume, and add a persistent **floating timer bar** so the running timer is visible on every screen.
**Out of scope:** Changes to invoicing, Reports, the Project Detail screen itself, the Live Activity / widgets, or the timer engine (`TimerService`). No new data model fields.

---

## 1. Problem

Now that projects have a real home (the Project Detail screen), the navigation around them doesn't fit:

- **Today is misleading.** It presents itself as the timer's home but only shows the *currently running* timer; when idle it's a bare "Start timer" button. It doesn't reflect the project-centric model.
- **Reaching a specific project's timer is deep:** Clients → client → project → Start (4 levels).
- **The Clients tab is dull** for a project-centric app — a flat list of client names with no project or earnings signal.

## 2. Goals

- A **Work** tab that puts projects first: grouped by client, searchable, lifetime hours/$ per project, **one-tap start (▶)**, tap-through to Project Detail. Scales to 6–15 active projects.
- Keep client management reachable via a **Projects | Clients** segmented toggle inside Work (nothing lost).
- **Today** becomes a genuine daily summary (hours/earnings today, uninvoiced) plus a **"Jump back in"** recent-projects row for one-tap resume.
- A **floating timer bar** pinned above the tab bar on the main tabs whenever a timer runs, tappable to expand the full controls. The running timer is always visible — no screen is "misleading."

## 3. Non-goals

- No change to `TimerService`, invoice generation/rendering, Reports, or the Live Activity.
- No new SwiftData fields or migration.
- The Project Detail screen, `ProjectStats`, `TimerActions`, and `RunningTimerCard` are **consumed as-is** (built on the base branch).

## 4. Decisions (locked during brainstorming)

| Topic | Decision |
|---|---|
| Tab bar | `Today · Work · Invoices · Reports · Settings`. **Work replaces Clients** at tab index 1. Indices for Invoices (2) / Reports (3) / Settings (4) are unchanged, so notification routing in `RootView` stays valid. |
| Client management | Lives **inside Work** as a `Projects \| Clients` segmented toggle. "Clients" reuses the existing client list/management UI; "Projects" is the new browser. |
| Today | Refocused to a daily summary + "Jump back in" recents. The running-timer card **leaves Today** — the floating bar owns the live timer. |
| Timer visibility | A **floating timer bar** above the tab bar, shown only while a timer runs; tap expands the existing `RunningTimerCard`. Idle → no bar. |
| Starting a timer | One-tap **▶** on project rows/cards (Work + Today recents) via `TimerActions.start` / `.switchTo`. The full `StartTimerSheet` picker is retained for the bar's "Switch" action and as a fallback. |
| Scale target | 6–15 active projects → Work uses a grouped, searchable list (not a fixed carousel); Today's recents is a short horizontal row (top ~5). |

## 5. Floating timer bar (the one tricky build)

A small persistent bar rendered across the main tabs.

- **Placement:** in `RootView.mainShell`, attach `.safeAreaInset(edge: .bottom)` to the `TabView`, returning the bar when a running entry exists and `EmptyView` otherwise. `safeAreaInset` insets the tab content above the system tab bar, so the bar sits just above it on every tab without overlapping content. (Chosen over a manual `ZStack` overlay because it handles the tab-content inset automatically.)
- **Data:** a `@Query` for the single running `TimeEntry` (`endedAt == nil`, `fetchLimit = 1`) — same descriptor pattern used elsewhere. The bar shows the project name, a live elapsed time (wrap the time text in `TimelineView(.periodic(from: .now, by: 1))`), a green WORKING / amber ON BREAK dot, and a quick pause/resume affordance.
- **Tap → expand:** tapping the bar presents a sheet (`.presentationDetents([.medium])`) hosting the existing `RunningTimerCard` (wrapped in a `TimelineView` for `asOf`, currency from `BusinessProfile`), with `onStop/onTakeBreak/onResume` → `TimerActions`, and `onSwitch` → `StartTimerSheet(isSwitching: true)`. This reuses the rich card verbatim; the bar is just an always-visible entry point to it.
- **Idle:** when no entry is running, `safeAreaInset` returns `EmptyView` (no bar, no inset).
- **New file:** `App/Sources/Features/Timer/FloatingTimerBar.swift` (the bar + its expand sheet host).

## 6. Work tab

New view `App/Sources/Features/Work/WorkView.swift` hosting a segmented `Picker`:

- **Projects (default):** a `List`/`ScrollView` of the user's non-archived projects **grouped by client** (section header = client name + color dot), sorted by client then project name. Each row: client-color dot, project name, `ProjectStats` lifetime `hours · $value`, and a trailing **▶** button. A `.searchable` field filters by project or client name.
  - **▶ tap:** `TimerActions.start(project:)` if idle, or `.switchTo(project:)` if a different project is running (mirrors `ProjectDetailView`'s logic). The floating bar then reflects it.
  - **Row tap:** `NavigationLink` to `ProjectDetailView(project:)`.
  - **＋ toolbar:** create a project (and create-client entry point), reusing the existing editors.
  - Archived projects: shown in a collapsed "Archived" section or hidden behind a filter (consistent with current `ClientDetailView` behavior).
- **Clients:** reuses the existing `ClientsView` content (the client list + add/edit/archive + navigation to `ClientDetailView`). No behavior change — it's the same management UI, now reached via the toggle instead of a top-level tab.

`ProjectStats.compute(for:asOf:)` powers each row's hours/$. The list wraps in a `TimelineView(.periodic by:1)` only if the running project is visible, to keep its row live without per-second churn on the whole list (mirrors the gating decision in `ProjectDetailView`).

## 7. Today refocused

`TodayView` is rebuilt as a daily summary:

- **Header:** weekday + date (existing).
- **Today tiles:** Hours today + Earnings today (the existing `TodaySummarySection` logic — keep it).
- **Uninvoiced tile:** all-projects uninvoiced (existing `UninvoicedTile` — keep it).
- **"Jump back in":** a horizontal row of the most-recent ~5 projects (reuse the ranking already in `StartTimerSheet.recentProjects` — last ~30 days by most recent entry), each a compact card with client dot, name, and **▶** (start/switch via `TimerActions`). Tapping the card body opens Project Detail.
- **Removed from Today:** the `RunningTimerCard` / `IdleTimerCard` block and the start/switch/break closures — the floating bar now owns the live timer. The `showingStartSheet`/`showingSwitchSheet` plumbing tied to those is removed (the manual-entry "＋" and timeline button stay).
- To avoid duplicating the recents ranking, extract `StartTimerSheet`'s recent-projects logic into a small shared helper (e.g. `RecentProjects.rank(entries:limit:)` in `BillableCore`, fed by a fetch) used by both `StartTimerSheet` and Today. This is the one piece of newly shared, unit-testable logic.

## 8. Components reused (from the base branch, unchanged)

- `RunningTimerCard` — rendered in the floating bar's expand sheet.
- `TimerActions` — all start/switch/break/resume/stop go through it.
- `ProjectStats` — Work rows and Today tiles.
- `ProjectDetailView` — destination for project taps.

## 9. Edge cases

- **No timer running:** no floating bar (no inset); Today's "Jump back in" still shows recents; Work ▶ starts fresh.
- **Tapping ▶ while another project runs:** `switchTo` (atomic stop+start); bar updates reactively.
- **No projects yet:** Work "Projects" shows an empty state with a create-project CTA; Today "Jump back in" hides when there are no recents.
- **On Break:** bar shows amber ON BREAK + frozen time; expand sheet offers Resume.
- **Search with no matches:** standard empty results.
- **Notification routing:** unchanged — `RootView` still routes to Invoices (tab 2) etc.; only tab 1's content changed (Clients → Work).
- **Sheets + bar:** when a full-screen sheet (generator, editors) is up, the bar is naturally covered by the sheet; on dismiss it returns. No special handling needed.

## 10. Testing

**BillableCore (`swift test`):**
- `RecentProjects.rank(entries:limit:)`: returns most-recently-used distinct, non-archived projects, newest first, capped at `limit`; excludes archived; dedupes a project with multiple recent entries.
- Existing suite stays green.

**UI (build + simulator):**
- Tab bar reads `Today · Work · Invoices · Reports · Settings`.
- Work → Projects: projects grouped by client with correct hours/$; ▶ starts/switches; row opens Project Detail; search filters; Clients toggle shows the client list and its management.
- Today: daily tiles + Jump-back-in recents; ▶ resumes; the old timer card is gone.
- Floating bar: appears when a timer runs, shows live time across all tabs, tap expands to the full card (Break/Resume/Switch/Done), disappears when stopped.
- Notification deep-links still land on the right tabs.

## 11. Files affected

| File | Change |
|---|---|
| `App/Sources/App/RootView.swift` | Replace Clients tab with Work (tag 1); attach the floating timer bar via `.safeAreaInset(.bottom)` on the `TabView` |
| `App/Sources/Features/Work/WorkView.swift` (new) | Work tab: `Projects \| Clients` toggle; project browser (grouped, searchable, ▶, tap→detail) |
| `App/Sources/Features/Timer/FloatingTimerBar.swift` (new) | The persistent bar + its expand sheet hosting `RunningTimerCard` |
| `App/Sources/Features/Today/TodayView.swift` | Rebuild as daily summary + "Jump back in"; remove the running/idle timer card block |
| `App/Sources/Features/Timer/StartTimerSheet.swift` | Use the shared `RecentProjects` helper for its recents |
| `Packages/BillableCore/.../Reporting/RecentProjects.swift` (new) | `rank(entries:limit:)` ranking helper |
| `Packages/BillableCore/Tests/...` | `RecentProjects` tests |
| `App/Sources/Features/Clients/ClientsView.swift` | Reused inside Work's Clients toggle (extract if it assumes being a tab root / its own `NavigationStack`) |

## 12. Sequencing & dependency

This branch descends from `feature/project-detail`. Recommended order: land `feature/project-detail` first (its own merge/PR), then this branch rebases onto/merges from updated `main`. All shared symbols (`RunningTimerCard`, `TimerActions`, `ProjectStats`, `ProjectDetailView`) come from that branch.

## 13. Risks

- **Floating bar is the highest-risk piece.** `safeAreaInset` on `TabView` is idiomatic but has edge cases (interaction with `NavigationStack` bars within tabs, keyboard avoidance, sheet presentation from an inset view). Build it first, in isolation, and verify on the simulator across all tabs before wiring the rest.
- **Overlap with the Live Activity.** The bar is an *in-app* surface; the Live Activity/Dynamic Island remains the *out-of-app* one. They're complementary — keep the bar visually distinct and don't duplicate the activity's logic; both read the same running entry.
- **`ClientsView` reuse:** if it currently assumes it's a tab root (own `NavigationStack`/title), it may need light extraction to embed under the Work toggle without nested navigation stacks.

## 14. Implementation notes

- Build order: (1) `RecentProjects` + tests, (2) `FloatingTimerBar` wired into `RootView` and verified across tabs, (3) `WorkView` + tab swap, (4) Today refocus, (5) `StartTimerSheet` recents migration. Each is a build+simulator checkpoint.
- Visual polish (the "wow" bar styling, card depth) uses the **frontend-design** skill at implementation time, to the app's existing timer-card bar.
- Base all work on `feature/today-nav-redesign`; do not touch shared branches.
