# Project Detail — Information-Architecture Redesign

**Date:** 2026-05-29
**Status:** Approved (design); pending spec review → implementation plan
**Branch:** `feature/project-detail-ia` (off `main` @ `716e33c`)

## Problem

`ProjectDetailView` is a single `ScrollView` → `VStack` rendering, top to bottom:

1. Hero (lifetime hours + $)
2. Engagement line
3. Uninvoiced tile
4. Timer controls (Break / Resume / Done, or Start / Switch)
5. Create-invoice button
6. **Sessions list** — up to 50, then a "See all N sessions" button that expands the list inline to *all* entries
7. **Complete / Restore project** button

Two concrete consequences:

- **"Complete project" sits below the entire sessions list.** With 30+ sessions the user must scroll past all history to complete (or restore) a project. With "See all" expanded, the scroll is unbounded.
- **The running-timer controls are mid-scroll** (below hero + uninvoiced), so pausing/stopping a running timer requires scrolling on a screen whose length grows with history.

The screen mixes *fixed-height* content (hero, timer, uninvoiced, CTA) with one *unbounded* element (sessions), and places primary actions after it. That is the information-architecture defect.

## Goals

1. Every actionable control is reachable **without scrolling through session history**.
2. The one unbounded element (sessions) lives where long scrolling is appropriate.
3. **No custom floating/overlay chrome** — actions use the system navigation toolbar or a pushed screen, so nothing can overlap the navigation bar.
4. Follow standard iOS / SwiftUI conventions; apply the `frontend-design` skill during implementation for the visual pass.
5. Preserve all existing behavior (complete/restore semantics, archived/empty states, invoice scoping, session editing).

Non-goals (sequenced as separate specs, explicitly out of scope here):

- Today "Jump back in" cards showing hours/$ (#2).
- Invoice ↔ client/project deletion integrity (#3).
- Recurring × invoice-per-project and finalize-idempotency (pending verification, #4/#5).
- A global in-app running-timer pill across tabs (#6) — only the *in-screen* timer placement is addressed here.

## Design

### Layout (revised top-to-bottom inside the ScrollView)

1. **Hero** — lifetime hours + `$value at $rate/h`. Unchanged.
2. **Engagement line** — started · days worked · completion range / Archived. Unchanged.
3. **Timer area — moved up**, immediately under the engagement line (above the uninvoiced tile). Running → `RunningTimerCard` (Break/Resume/Done/Switch); idle & active → Start/Switch button; archived → omitted. The most time-sensitive control is now reachable without scrolling.
4. **Uninvoiced tile + "Create invoice"** — grouped (the amount and the CTA that acts on it). Shown only when `isBillable && !isArchived` (unchanged condition).
5. **Sessions (preview)** — the **5 most recent** entries, month-grouped, each row tappable to edit via `ManualEntrySheet(editing:)`. When `totalCount > 5`, a **"See all N sessions ›"** row **pushes** `ProjectSessionsView` (a navigation destination — *not* an inline expand). Empty → "No time tracked yet."

### Toolbar (system navigation bar)

Replace the single "Edit" button with one **trailing overflow menu** (`Menu` with `ellipsis.circle` / `ellipsis`):

- **Edit project** → presents `ProjectEditorView` sheet (existing).
- Lifecycle action:
  - Active project: **Complete project** (`role: .destructive`) → existing confirmation dialog → `completeProject()`.
  - Archived project: **Restore project** → `restoreProject()`.

"Complete/Restore" leaves the scroll body entirely. Because these live in the system toolbar, there is no custom view that can overlap the navigation bar.

### New component — `ProjectSessionsView`

A pushed full-screen list of a project's complete session history.

- **Input:** `@Bindable var project: Project` (or the project's entries via the same model context).
- **Content:** all `project.entries` sorted `startedAt` descending, grouped by month (reuse the existing `groupedByMonth` logic), rendered with the existing `sessionRow` presentation.
- **Row tap:** opens `ManualEntrySheet(editing: entry)` (same as the detail preview rows).
- **Title:** "Sessions"; `navigationBarTitleDisplayMode(.inline)`.
- **Currency:** same resolution as the detail screen (`profiles.first?.currencyCode ?? …`).
- **Live ticking:** if the project's timer is running and that entry appears in the list, the row may tick; reuse the detail screen's pattern (wrap only when a running entry belongs to this project). Acceptable to render `asOf: .now` without per-second ticking on this secondary screen if simpler — ticking here is not required (the running entry is normally the top row and the user came here for history). Implementation chooses the simpler correct option; document the choice.

### Refactors enabled

- Remove `@State private var sessionLimit` and the inline "expand to all" behavior from `ProjectDetailView`; the preview is a fixed 5, the full list is its own screen.
- Extract a shared `groupedByMonth(_:)` and `sessionRow(_:asOf:)` so both `ProjectDetailView` and `ProjectSessionsView` use one implementation (move to a small shared file or a shared extension to avoid duplication).

## Data flow

- No model/schema changes. No migration.
- `ProjectStats.compute(for:asOf:)`, `TimerActions`, `RunningTimerCard`, `ManualEntrySheet`, `InvoiceGeneratorView` are reused unchanged.
- The 5-session preview reads `project.entries`, sorts, takes `prefix(5)`, groups by month. `ProjectSessionsView` reads the same relationship without the prefix.
- Navigation to `ProjectSessionsView` via `NavigationLink` / `navigationDestination` within the existing `NavigationStack` that hosts `ProjectDetailView`.

## Error handling / edge cases

- **Archived project:** timer area omitted; uninvoiced tile + Create-invoice hidden; toolbar menu shows **Restore**; sessions preview + "See all" still available (history remains viewable).
- **Empty project (no entries):** "No time tracked yet"; no "See all" row.
- **Exactly ≤5 sessions:** show them; no "See all" row.
- **Running timer belongs to another project:** timer area shows "Switch to this project" (unchanged).
- **Complete while a timer runs on this project:** out of scope for this spec (tracked under #7 archived-with-running-timer cleanup); behavior unchanged here.
- **No overlap guarantee:** all new affordances are either in the system toolbar or a pushed screen — no `safeAreaInset`/overlay bars are introduced.

## Testing

Unit / view-model level (BillableCore where logic is extracted):

- `groupedByMonth` produces correct month buckets/order for a known entry set (already covered; keep).
- Preview selection: given N entries, the detail preview contains exactly `min(5, N)` and "See all" appears iff `N > 5`.

UI / behavior:

- Detail screen: with >5 sessions, "Complete project" is reachable via the toolbar menu without scrolling; "See all N sessions" pushes `ProjectSessionsView`.
- `ProjectSessionsView` renders all entries, month-grouped, newest first; tapping a row opens the editor.
- Toolbar menu: Edit opens editor; Complete (active) shows confirmation then archives and pops; Restore (archived) restores.
- Archived and empty states render per the rules above.

## Implementation notes

- Use the `frontend-design` skill during implementation for the visual polish of the redesigned detail screen and the new sessions screen (spacing, hierarchy, the overflow menu, the "See all" affordance).
- Keep `ProjectDetailView` shorter by extracting `ProjectSessionsView` and the shared session helpers into their own file(s).
- Build + test command:
  `xcodebuild -project Billable.xcodeproj -scheme Billable -configuration Debug -destination 'platform=iOS Simulator,id=A946AE5D-C969-4EB2-8384-001B3451A6A4' -derivedDataPath build/DerivedData build`
- Run `xcodegen generate` after adding the new file(s).
