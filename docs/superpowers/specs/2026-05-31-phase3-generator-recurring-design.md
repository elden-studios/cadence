# Phase 3 — Invoice Generator & Recurring (design)

**Date:** 2026-05-31
**Status:** Draft (design) → implementation
**Baseline:** real `main` = `origin/main` `9e09fe9` (Phases 1+2 merged). Branch `feature/phase3-generator-recurring`.
**Source:** verified backlog `docs/reviews/2026-05-31-cadence-verified-backlog.md` — items F38, F36, F7, F39, NEW-S6-1, NEW-S6-2, NEW-S6-3, NEW-S6-4, NEW-S6-5. Phase 3 of the program (Phases 1+2 shipped in #16/#17).

Phase 3 makes the invoice generator's commit controls honest and adds the consolidated per-client invoice. Almost everything is in `App/Sources/Features/Invoicing/InvoiceGeneratorView.swift`; the consolidated path reuses `InvoiceBuilder.eligibleEntries(for: client)` and `InvoicePreviewView(project: nil)` which already exist.

---

## Scope (9 items)

| # | Item | Source | Priority |
|---|------|--------|----------|
| 1 | Consolidated "All projects (one invoice)" option | F38 | High |
| 2 | Non-billable-only client: accurate empty-state message | F36 | High |
| 3 | Recurrence save failure surfaces an error (not silent) | NEW-S6-1 | High |
| 4 | Recurring mode hides the controls it ignores (Period/preview) + clarifies client-wide scope | NEW-S6-2 | High |
| 5 | Generator commit controls unambiguous; reset `makeRecurring` on client change | F7 | Medium |
| 6 | Batch "separate drafts" carries the typed Scope of work | F39 | Medium |
| 7 | Recurring mode de-emphasizes the per-project picker (recurrence is client-wide) | NEW-S6-3 | Medium |
| 8 | Batch button hidden in recurring mode | NEW-S6-4 | Medium |
| 9 | "Save schedule" disabled when the client has no billable work | NEW-S6-5 | Low |

**Non-goals:** Phases 4–8; the monetization-gate reconciliation (#4/F18, a doc/feature decision); changing `RecurrenceTemplate`'s data model (it's client-scoped by design). Reuse `InvoiceBuilder` + `InvoicePreviewView`; no new screens.

---

## The Project section, redesigned (Items 1, 5)

Today the Project section (`:106-124`) has a single-project `Picker` plus an always-present "Invoice all projects (separate drafts)" button — both reachable at once, and there's no consolidated option. Replace with **three mutually-clear choices** driven by one selection state.

**State:** introduce `enum ProjectScope: Hashable { case project(Project); case allConsolidated }` and replace `@State selectedProject: Project?` usage in the picker with a `@State projectScope: ProjectScope?` (keep a computed `selectedProject: Project?` returning the single case for the existing eligible-entry/preview wiring). The picker offers:
- `Choose` (nil)
- One row per billable project → `.project(p)`
- **`All projects · one invoice`** → `.allConsolidated` (only shown when `projectsWithEligible.count > 1`)

**Preview behavior:**
- `.project(p)` → existing path: `InvoicePreviewView(project: p, lineItems: <p's eligible>, sourceEntries: <p's eligible>, scopeOfWork:)`.
- `.allConsolidated` → `InvoicePreviewView(project: nil, lineItems: buildLineItems(from: eligibleEntries(for: client, range), grouping:), sourceEntries: <client's eligible across billable projects>, scopeOfWork:)`. A single invoice; `perProject` grouping naturally renders one line per project. `canPreview` becomes: scope chosen (single or consolidated) + profile + non-empty lineItems + canSendInvoice.
- The **"Invoice all projects (separate drafts)"** batch button remains as the *distinct* third action (N drafts), now unambiguous alongside the consolidated option — and hidden in recurring mode (Item 8).

This single redesign delivers F38 (consolidated) and F7 (the three commit paths are now explicit and mutually exclusive rather than two silently co-active controls).

### Testing
BillableCore already covers `eligibleEntries(for: client)` + `buildLineItems`. Add/confirm a unit test that consolidated line items across 2 billable projects = the union (per-project grouping → 2 lines). UI: build + manual — picking "All projects · one invoice" previews a single invoice with a line per project; picking one project previews just that project; "separate drafts" still makes N drafts.

---

## Item 2 — Non-billable-only client empty-state (F36)
`refreshProjectsAndActive()` (`:417-424`) computes `activeProjects` filtered by `!isArchived && isBillable`, and the UI shows "This client has no active projects." (`:108-109`) when that's empty. For a client whose active projects are all non-billable, that's false. **Fix:** compute the count of all active (non-archived) projects separately; branch the empty-state: if no active projects at all → "This client has no active projects."; if active projects exist but none billable → "This client's active projects are all non-billable — only billable time can be invoiced." (Add a `hasAnyActiveProject` derived value; don't change the billable filter used for the picker.)

---

## Item 3 — Recurrence save error surfacing (NEW-S6-1)
`saveRecurrence()`'s catch (`:519-531`) rolls back, logs, and returns silently. **Fix:** add `@State private var saveErrorAlert = false` and present it in the catch (reuse the `.alert` pattern already in the view). Message: "Couldn't save the recurring schedule. Your data wasn't changed — try again." (Keeps the rollback; just adds the user signal. A shared error presenter is Phase 4 — this is the local stopgap, consistent with Phase 1/2.)

---

## Items 4, 7, 8 — Recurring mode shows only what it uses
When `makeRecurring` is ON, the saved schedule derives its own period from the cadence (`RangeRule.implied`), is **client-wide**, and ignores the selected project and the eligible-entries preview. Today those controls stay visible/editable and mislead. **Fix — collapse to recurring-relevant controls when `makeRecurring`:**
- **Hide the Period section** (`:131-143`) and the **eligible-entries preview** rows (`:153-164`) — they don't apply to a schedule. (NEW-S6-2)
- **De-emphasize the per-project picker:** when recurring, hide/disable the project Picker and the consolidated/batch buttons, and show a caption: *"Recurring invoices cover all billable projects for this client, each period."* (NEW-S6-3, NEW-S6-4 — the batch button is hidden by being inside the non-recurring branch.)
- Keep visible: Client, Scope, Notes, the Recurring section, the profile/name banners.

Implementation: wrap the Period + eligible-entries + project-action controls in `if !makeRecurring { … }` and add the caption in the recurring branch. This one structural change covers NEW-S6-2/3/4.

---

## Item 5 (cont.) — reset `makeRecurring` on client change (F7)
`makeRecurring` (`:28`) is never reset when the client changes (`onChange(of: selectedClient)`, `:259-266`). **Fix:** set `makeRecurring = false` (and clear `projectScope`) in that handler so a stale recurring toggle doesn't carry across clients.

---

## Item 6 — Batch carries scope (F39)
`invoiceAllProjects()` hardcodes `scopeOfWork: nil` (`:466`). **Fix:** pass `trimmedScope` into each batch `createDraft` (it's already computed). (The per-draft scope is the same typed value; acceptable — and far better than silently dropping it.) Drop the "add a scope" line from the success alert if scope was provided.

---

## Item 9 — "Save schedule" needs billable work (NEW-S6-5)
`saveDisabled` (`:95-97`) only checks client/profile/saving. A schedule for a client with **no billable projects** would generate empty invoices forever. **Fix:** extend `saveDisabled` (or the Save button's `.disabled`) to also require the client to have ≥1 billable project (`!activeProjects.isEmpty`, since `activeProjects` is already the billable set). Show the same non-billable caption from Item 2 in the recurring branch when there's nothing to schedule.

---

## Cross-item notes
- **One PR**, almost entirely `InvoiceGeneratorView.swift`; the consolidated path reuses existing `InvoiceBuilder`/`InvoicePreviewView`. A BillableCore test may be added for consolidated line items.
- **Test command:** `xcodebuild -project Billable.xcodeproj -scheme Billable -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build/DerivedData build`; `swift test --package-path Packages/BillableCore`.
- **TDD** for any BillableCore logic (consolidated line items); view changes are build- + screenshot-verified where feasible (the generator is reachable via the Invoices `+`).
