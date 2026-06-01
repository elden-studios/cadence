# Phase 7 — Project-detail & sessions (design)

**Date:** 2026-06-01
**Program:** Cadence product-review fix program (Phases 1–6 shipped; `main` = `9d9d37e`).
**Source:** project-detail/sessions cluster of `docs/reviews/2026-05-31-cadence-verified-backlog.md`, **re-baselined against current `main`** by an 8-agent workflow (PR #13 + Phases 1–6 already touched these screens).
**Branch:** `feature/phase7-project-detail-sessions` (worktree off `origin/main` `9d9d37e`).

## Scope & constraint

Project-detail & sessions **correctness / consistency / UX polish + one perf refactor**. **Hard constraint: no net-new features** — the one charter-boundary item (#11 client reassignment) was **user-approved as in-scope** (it fills a missing form row for an already-mutable model field via an existing picker pattern; reassignment is forward-only).

**Re-baseline result:** all **7 candidate items confirmed genuinely open** on `9d9d37e` (none silently fixed). Already-resolved sub-claims (correctly excluded): the "See all N / Show less" toggle (PR #13 → `prefix(5)` + `NavigationLink`), the bare-"UNINVOICED" scope-label collision (Phase 2 → "· THIS PROJECT" / "· ALL PROJECTS"), and the duplicated `"Xh YYm"` formatter (Phase 4 → shared `DurationFormatting`).

**Files:** `App/Sources/Features/Projects/ProjectDetailView.swift`, `ProjectSessionsView.swift`, `ProjectEditorView.swift`; `App/Sources/Features/Work/WorkView.swift`; `Packages/BillableCore/Sources/BillableCore/Reporting/ProjectStats.swift` (WS3 only — the sole BillableCore touch). Verification = app build + runtime; **WS3 adds a BillableCore equivalence unit test** (so the test count grows from 344).

## Locked decisions

- **Archived-project billing (High) → split the gate + confirmation note.** Show the uninvoiced tile + a "Create invoice" button on an archived project when it still has uninvoiced billable time; add a line to the Complete dialog; don't strand the user.
- **#11 client reassignment → include** (in-scope polish). Forward-only: already-issued invoices keep their frozen client snapshots.
- Clear-cut items use the agents' recommended approach: SessionRow → wire edit/delete; hero → deepen gradient + solid subline; CTA → `.borderedProminent`; SessionRow time-of-day → single-line start time (Option A); running-row → `TimelineView` wrap (Option A); ProjectStats → hoist the static reduce.

---

## WS1 — ProjectDetail billing, lifecycle & CTA  ·  High + Low  ·  `ProjectDetailView.swift`

- **Archived billing gate (item 1, High).** Today the gate at `~:121` hides BOTH the uninvoiced tile and "Create invoice" on `project.isBillable && !project.isArchived`. Change it so they stay visible when there's billable uninvoiced time even if archived:
  - Gate → `if project.isBillable && (!project.isArchived || stats.uninvoicedAmount > 0)`.
  - The **Start-timer** control stays independently gated on `!project.isArchived` (`~:217`) — no timer can start on an archived project (verified separate).
- **Don't strand the user on Complete.** `completeProject()` (`~:293-299`) currently sets `isArchived` + saves + `dismiss()`. Change: **only `dismiss()` when `stats.uninvoicedAmount == 0`** — when there's outstanding billable time, stay on the (now-archived) detail so the still-visible tile + "Create invoice" are right there. (This also resolves the restore/complete dismiss asymmetry — `restoreProject()` already stays.)
- **Complete confirmation copy (`~:108`).** Append a clause so the dialog mentions uninvoiced time, e.g.: *"Marks the project complete and moves it to Archived. Logged time stays on past invoices and reports, and any uninvoiced time stays billable here."*
- **CTA prominence (item 5a, Low).** Promote "Create invoice" (`~:129`) from `.buttonStyle(.bordered)` to `.borderedProminent` so the revenue action reads primary (Start/Switch is already `.borderedProminent`).
- **Cross-screen note:** with the gate split, Today's "UNINVOICED · ALL PROJECTS" total (which already counts archived-project uninvoiced — `TodayView` `uninvoicedDescriptor` has no `isArchived` filter) becomes honest: every dollar it counts now has a billable path on the project detail. **No TodayView change needed** (do not add an `isArchived` filter — that would re-hide owed money).

## WS2 — Sessions interactive + informative  ·  Med + Low + Low  ·  `ProjectSessionsView.swift` (+ `ProjectDetailView.swift`)

`SessionRow` (`ProjectSessionsView.swift:26-50`) is pure display; it's rendered read-only in both the detail preview (`ProjectDetailView.swift:~266-268`) and the full history (`ProjectSessionsView.swift:~77-79`). The same `TimeEntry` objects are already editable/deletable from `DayTimelineView` (`.sheet(item: $selectedEntry){ ManualEntrySheet(editing:) }` + a context-menu delete). Three fixes, all on the shared `SessionRow` / its two `ForEach` call sites:

- **Edit/delete wiring (item 3, Med).** Add `@State private var editingEntry: TimeEntry?` to **both** views; make the row tap-to-edit (set `editingEntry = entry`) for **completed** entries only (running entries are guarded by `ManualEntrySheet`'s existing `isEditingRunningEntry`); add `.swipeActions(edge: .trailing){ Button(role:.destructive) … }` wired to a `delete(entry)` helper that mirrors `DayTimelineView.delete` (`modelContext.delete` + `saveOrLog`); add `.sheet(item: $editingEntry){ ManualEntrySheet(editing: $0) }`. No confirm dialog on delete (matches `DayTimelineView`/`TodayView`).
- **Time-of-day (item 5b, Low).** `SessionRow` (`:~34`) renders only `…weekday().day()`. Extend to a **single-line start time** (Option A): `entry.startedAt.formatted(.dateTime.weekday().day().hour().minute())`. Lowest layout risk; renders for every row incl. the running one.
- **Running-row live tick (item 6, Low).** `ProjectSessionsView` passes `asOf: .now` with no `TimelineView`, so a running session shown via "See all sessions" is frozen. Wrap **only** the running row (`entry.isRunning`) in a `TimelineView(TimerTickSchedule(running: true))` (Option A), mirroring `ProjectDetailView`'s per-row discrimination (`:~267`); completed rows keep the stable pinned date. Hoist the private `TimerTickSchedule` (`ProjectDetailView.swift:~315-322`) to internal/shared scope so both views reference it (or re-declare the tiny stateless struct locally).

## WS3 — ProjectStats live-tick perf  ·  Low  ·  `ProjectStats.swift` (BillableCore) + `ProjectDetailView.swift` + `WorkView.swift`

`ProjectStats.compute(for:asOf:)` reduces over **all** `project.entries` every second inside the per-second `TimelineView` (`ProjectDetailView.swift:~60-61,114`; same pattern `WorkView.swift:~302`), though only the running entry's contribution changes per tick.

- **Goal:** the per-tick path must be **O(1)** in completed-entry count — compute the static portion (completed entries) once, add only the running entry's live delta per tick. Implementer picks the cleanest mechanism after reading `ProjectStats` (either a small BillableCore split API, e.g. a completed-base + a `withRunning(base:running:asOf:)`, or a view-level static-base hoist). **Output must be identical to today's `compute(asOf:)`.**
- **REQUIRED test (the one new automated coverage in Phase 7):** add a BillableCore unit test asserting the split/refactored result **equals** `ProjectStats.compute(for:asOf:)` for a project with a running entry at several `asOf` values (locks the perf refactor's correctness).
- Apply the same fix to `WorkView`'s per-row `statsLine(asOf:)`.

## WS4 — Hero contrast (WCAG AA)  ·  Med  ·  `ProjectDetailView.swift`

The hero (`hero()`, `~:137-160`) renders the 40pt lifetime-hours value in solid `.white` and the subline in `.white.opacity(0.9)` over `LinearGradient(colors: [.timerAccent, .timerAccent.opacity(0.85)], …)`. `timerAccent` is bright orange (`Color(red: 0.98, green: 0.49, blue: 0.13)`) → white is ~2.6:1 (fails large-text AA 3.0:1); the 90%-opacity subline is worse.

- **Fix (pure styling):** deepen the gradient end stop to a darker orange so both stops clear AA with white (agent-suggested `[.timerAccent, Color(red: 0.70, green: 0.30, blue: 0.04)]`, end-stop ~11:1), **and** promote the subline from `.white.opacity(0.9)` to solid `.white`. Verify with Accessibility Inspector at Default/Large/Largest text. The exact darkened RGB is a minor styling choice (contrast headroom vs warmth), not a product fork.

## WS-client (#11) — ProjectEditor client reassignment  ·  Med  ·  `ProjectEditorView.swift` (+ `ProjectDetailView.swift` call site)

`ProjectEditorView` takes `let client: Client` (non-optional constant), renders no client row, and `save()` never writes `client`; `Project.client` is `public var client: Client?` (already mutable). Add a picker reusing the `ManualEntrySheet.projectPicker` pattern (`ManualEntrySheet.swift:~113-157`):

- Add `@Query(filter: #Predicate<Client>{ !$0.isArchived }, sort: \Client.name) private var clients` + `@State private var selectedClient: Client?`.
- In `loadIfNeeded()` set `selectedClient = project?.client ?? client`.
- In `save()`'s existing-project branch add `existing.client = selectedClient`.
- Add a client-grouped `Menu` picker row to the "Project" Form section (checkmark on selection, label shows the selected client name).
- Clean up the call site `ProjectDetailView.swift:~91` (currently synthesizes a throwaway `Client(name: "")` fallback — pass the real current client or drop the now-unneeded param).
- **Forward-only semantics (confirmed acceptable):** reassigning `Project.client` does NOT rewrite already-issued invoices (they carry frozen snapshots; `Invoice.project` is `nullify`-on-delete). New invoices use the new client. Own commit (so it can be reverted cleanly if ever needed).

## Coupling & build order

1. **WS1 + WS4** share `ProjectDetailView.swift` (gate/CTA region + hero) → can be one PR-unit; sequence WS1 then WS4.
2. **WS2** edits the shared `SessionRow` + both `ForEach` call sites and hoists `TimerTickSchedule` — its three sub-fixes are one stream; sequence after WS1 (both touch `ProjectDetailView.swift`).
3. **WS3** is the only BillableCore touch + the only one editing `WorkView.swift`; **land it isolated** (its own commit + the equivalence test).
4. **WS-client (#11)** is self-contained (`ProjectEditorView` + one call-site line); **own commit** (cleanly revertable).

Suggested task order: WS1 → WS4 → WS2 → WS3 → #11 (sequential; several share `ProjectDetailView.swift`).

## Test plan

- App + widget build `** BUILD SUCCEEDED **` after every work-stream + at the end.
- BillableCore `swift test`: **grows past 344** with the WS3 equivalence test; all green.
- **Runtime (seeded sim):** archived billable project with uninvoiced time shows the tile + "Create invoice"; Complete on a project with uninvoiced time stays on the detail (dismisses when nothing outstanding); "Create invoice" reads prominent; SessionRow shows start time-of-day; tap a completed session → editor; swipe → delete; hero text is legible; (DEBUG) the running session ticks live in "See all sessions"; project-editor client picker reassigns + persists.
- **Manual/observation:** hero contrast via Accessibility Inspector; per-tick CPU no longer scales with session count (WS3).

## Out of scope (parked)

- SessionRow start–end **range** (item 5b Option B) — single-line start time ships; range is a follow-up.
- Any retroactive invoice rewrite on client reassignment (forward-only by design).
- **Phase 8** (Onboarding/entity + small clients/currency polish) — the last parked phase.
