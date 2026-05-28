# Invoice-per-Project — Design (Approach B)

**Date:** 2026-05-28
**Status:** Approved — ready for implementation planning
**Scope:** Manual invoice generation becomes project-scoped: pick a client → pick a project → one invoice for that project, with an optional Scope-of-work block, plus an "Invoice all projects" convenience.
**Out of scope:** Per-project *recurring* invoices (deferred fast-follow); Approach C (one consolidated invoice with per-project sections); auto-remembering scope per project.

---

## 1. Problem

Today the invoice generator ([InvoiceGeneratorView.swift](../../../App/Sources/Features/Invoicing/InvoiceGeneratorView.swift)) lets the user pick a **client only**. `InvoiceBuilder.eligibleEntries(for: client, …)` rolls **every** billable, un-invoiced entry across **all** the client's projects into **one** invoice (grouped per-entry or per-project). There is no way to invoice a single project on its own, and no place to state the scope of work for a project. A consultant with several projects under one client cannot bill them separately.

## 2. Goals

- Generate **one invoice per project** (each with its own number, due date, status, total).
- Add an optional **Scope of work** description that renders on the invoice (the client-facing document — presentation matters).
- An **"Invoice all projects"** action that creates one draft per project with billable time, in a single tap.
- Keep the design **additive** so the existing client-combined builder keeps working for the (deferred) recurrence path and legacy invoices.

## 3. Non-goals

- No change to per-project *recurring* schedules (deferred — see §8).
- No consolidated multi-project invoice (Approach C).
- No change to tax, reminders, PDF sharing, or the Sent/Paid lifecycle beyond rendering the new fields.

## 4. Decisions (locked during brainstorming)

| Topic | Decision |
|---|---|
| Shape | **B — one invoice per project** (not A "filter into one invoice", not C "sections in one invoice"). |
| Multi-project | **"Invoice all projects"** creates a separate **draft** per project that has billable time. |
| Scope | Optional **Scope of work** text, entered in the generator, rendered above the line items. No auto-remember in v1. |
| Combined path | The client-combined builder is **retained** (used by deferred recurrence + legacy invoices); only the **manual UI** becomes per-project. Per-project is purely additive. |
| Recurring | **Deferred.** Recurrence keeps materializing client-combined drafts as today; per-project recurring is a fast-follow. |
| Migration | **None** — new `Invoice` fields are nullable with defaults; existing/recurrence/legacy invoices have `project == nil` and render as today. |

## 5. Data model

Add to `Invoice` ([Invoice.swift](../../../Packages/BillableCore/Sources/BillableCore/Models/Invoice.swift)) — all nullable, defaulted (lightweight migration):

```swift
public var project: Project?             // live ref; nil for client-combined / recurrence / legacy invoices
public var projectNameSnapshot: String?  // frozen name for rendering (mirrors clientNameSnapshot)
public var scopeOfWork: String?          // optional scope-of-work text
```

Add the three to the `init` (defaults `nil`) and assign them. `InvoiceLineItem` is **unchanged** (line items already carry their description/hours/rate; the project context now lives on the invoice).

`projectNameSnapshot` is the source of truth for rendering (frozen, survives project rename/delete), exactly like `clientNameSnapshot`. `project` is the live link for filtering/navigation.

## 6. Generation flow

`InvoiceGeneratorView` gains a **Project** step:

- After the Client picker, add a **Project picker** listing the selected client's non-archived projects. Selecting a project drives the line-item preview from that project's time.
- Add a **Scope of work** text field (optional, multi-line) under the project.
- Line items come from `eligibleEntries(for: project, …)`; the existing per-entry / per-project **grouping** toggle still applies *within* the one project.
- **Preview → Send** path unchanged (`InvoicePreviewView`), now passing the project + scope through.
- **"Invoice all projects"** button (shown once a client is selected): for each project of that client with eligible entries in the range, create a Draft invoice (`createDraft` with that project, `scopeOfWork: nil`). Result: N drafts in the Drafts list; the user opens each to add scope and Send. A toast/summary reports how many drafts were created.

The existing **Recurring** section in the generator stays client-level and unchanged (see §8).

## 7. `InvoiceBuilder` changes

[InvoiceBuilder.swift](../../../Packages/BillableCore/Sources/BillableCore/Invoicing/InvoiceBuilder.swift) — additive:

- **New** `eligibleEntries(for project: Project, in range: InvoiceDateRange, context:)` — identical to the client version but filters `entry.project?.persistentModelID == project.persistentModelID` (and `project.isBillable`, not-archived, completed, un-invoiced). The existing `eligibleEntries(for client:)` **stays** (recurrence uses it).
- **New** `projectsWithEligibleEntries(for client: Client, in range:, context:) -> [Project]` — the client's projects that have ≥1 eligible entry; powers "Invoice all" and can disable empty projects in the picker.
- **Extend** `createDraft(…)` with `project: Project? = nil` and `scopeOfWork: String? = nil`; set `invoice.project`, `invoice.projectNameSnapshot = project?.name`, `invoice.scopeOfWork`. Defaults keep the client-combined callers (recurrence) unchanged.
- `finalizeAndSend` unchanged.

## 8. Recurrence interaction (deferred, must not break)

`RecurrenceService` ([RecurrenceService.swift:123](../../../Packages/BillableCore/Sources/BillableCore/Recurrence/RecurrenceService.swift)) materializes a recurrence template into a **client-combined** draft via `eligibleEntries(for: client) → buildLineItems → createDraft`. Because the client-combined builder is **retained** and `createDraft`'s new params default to `nil`, recurrence keeps working unchanged and its invoices have `project == nil` (render as today). The generator's recurring section stays client-level for v1. Per-project recurring is the fast-follow.

## 9. Invoice rendering (client-facing — the priority)

The invoice document (preview + detail + PDF: [InvoicePreviewView.swift](../../../App/Sources/Features/Invoicing/InvoicePreviewView.swift), [InvoiceDetailView.swift](../../../App/Sources/Features/Invoicing/InvoiceDetailView.swift), and any shared document/PDF view they use):

- When `projectNameSnapshot != nil`: show a **Project** tag under Bill-to (project name; client color dot).
- When `scopeOfWork` is non-empty: show a **Scope of work** block above the line-items table (matches the approved mockup — `.superpowers/brainstorm/.../invoice-b-refined.html`).
- When both are nil (combined / recurrence / legacy invoices): render exactly as today (no project tag, no scope block).
- **Scope is editable while the invoice is a Draft** (InvoiceDetailView text field) and frozen once Sent — so "Invoice all" drafts (created with `scopeOfWork: nil`) can get their scope before sending.
- The cached PDF (`pdfDataCached`) must regenerate to include these — ensure the render path picks up the new fields. Visual polish via the **frontend-design** skill at implementation time.

## 10. Edge cases

- **Project with no eligible time:** excluded from "Invoice all"; in the single-project flow show the existing "no billable, completed entries" empty state.
- **Scope empty:** omit the block entirely (no empty header).
- **Archived projects:** excluded from the picker (consistent with current project filtering).
- **Double-invoicing:** unchanged — `finalizeAndSend` stamps each source entry's `invoiceID` on Send; a per-project draft only contains that project's entries.
- **"Invoice all" numbering:** drafts show the provisional `previewNextInvoiceNumber`; the real number is consumed per-invoice on Send (existing draft behavior). Note in UI that draft numbers are provisional.
- **Legacy + recurrence invoices:** `project/projectNameSnapshot/scopeOfWork == nil` → render unchanged.

## 11. Testing

**BillableCore (`swift test`):**
- `eligibleEntries(for: project)` returns only that project's billable, completed, un-invoiced entries in range (and excludes other projects of the same client).
- `projectsWithEligibleEntries` lists exactly the projects with ≥1 eligible entry.
- `createDraft` with a project sets `project`, `projectNameSnapshot`, and `scopeOfWork`; without them leaves all three nil (client-combined path).
- Recurrence regression: `RecurrenceService` materialization still produces a client-combined draft with `project == nil` (existing recurrence tests stay green).
- Existing `InvoiceBuilderTests` stay green.

**UI (build + simulator):** project picker + scope field in the generator; "Invoice all" creates N drafts; preview/detail/PDF render the project tag + scope block when present and unchanged when nil.

## 12. Files affected

| File | Change |
|---|---|
| `Packages/BillableCore/.../Models/Invoice.swift` | Add `project` / `projectNameSnapshot` / `scopeOfWork` (+ init) |
| `Packages/BillableCore/.../Invoicing/InvoiceBuilder.swift` | `eligibleEntries(for: project)`, `projectsWithEligibleEntries`, `createDraft` project+scope params |
| `App/Sources/Features/Invoicing/InvoiceGeneratorView.swift` | Project picker, scope field, "Invoice all" action; recurring section unchanged |
| `App/Sources/Features/Invoicing/InvoicePreviewView.swift` | Pass + render project + scope |
| `App/Sources/Features/Invoicing/InvoiceDetailView.swift` | Render project + scope; edit `scopeOfWork` while Draft (+ PDF regen) |
| `Packages/BillableCore/Tests/...` | Builder tests above; recurrence regression |

## 13. Implementation note

The invoice document's visual treatment of the Project tag + Scope block should be built with the **frontend-design** skill to the polish bar the user flagged (the invoice is the client-facing artifact).
