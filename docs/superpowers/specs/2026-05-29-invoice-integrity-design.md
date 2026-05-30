# Invoice Integrity — Deletion Guard + Finalize Hardening

**Date:** 2026-05-29
**Status:** Approved (design); pending spec review → implementation plan
**Branch:** `feature/project-detail-ia` (shared with the Project Detail spec; may split at plan time)
**Scope items:** #3 (deletion integrity) + #4 (finalize idempotency)

## Problem

### A. Deletion can destroy the records behind issued invoices

- `Client` cascade-deletes its `Project`s (`Client.swift:23`), and `Project` cascade-deletes its `TimeEntry`s (`Project.swift:22`).
- `Invoice.client` / `Invoice.project` are plain optionals (`Invoice.swift:72,76`) with no inverse — SwiftData nullifies them on delete.
- Net effect of deleting a client/project that has issued invoices:
  - The invoice **document survives** (snapshots `clientNameSnapshot`, `lineItemsData` JSON keep it renderable), but
  - its `client` / `project` links go **nil** (grouping/navigation by client/project breaks), and
  - **all backing `TimeEntry`s are destroyed** — the audit trail / substantiation behind sent and paid invoices is permanently lost, and per-entry line items' `sourceTimeEntryRef` dangle.
- There is **no guard**. The destructive "Delete" swipe action on a client (`ClientsView.swift:143`) and the delete-project action (`ClientDetailView.swift:125`) proceed unconditionally.

For a billing app this is a data-integrity/trust defect: a user can irreversibly erase the hours behind a paid invoice (tax/audit exposure).

### B. Invoice finalize (draft→sent) is not re-entrant

- The double-send guard is the view-state `finalized != nil`, set **after** `finalizeAndSend` + PDF render completes (`InvoicePreviewView` ~line 392). The button's `.disabled(finalized != nil)` therefore stays enabled during the async window.
- `markSent()` correctly throws on a non-draft invoice (`InvoiceStatusMachine.swift:23`), but that only protects the *same* invoice. A second tap creates a **new** draft and finalizes it, **consuming a second invoice number** and producing a duplicate sent invoice.
- The catch block does no rollback, so a mid-flight failure can also leave a burned number on retry.

Realistic trigger: rapid double-tap during the async send/render, or a retry after an error. Low frequency, but the outcome (duplicate sent invoice + skipped number) is visible to the client and unprofessional.

## Goals

1. Make it **impossible to destroy the time records behind a sent or paid invoice** through normal UI deletion; steer the user to Archive (which preserves everything).
2. Make invoice finalize **re-entrant-safe**: a rapid double-tap or post-error retry can never create a duplicate sent invoice or burn an extra number.
3. No schema change, no migration. Smallest blast radius.

Non-goals: changing cascade rules / introducing soft-delete at the model layer; reworking recurring invoices; any other backlog item.

## Design

### Part A — Deletion guard (block + steer to Archive)

**New computed helpers (BillableCore, no stored properties, no migration):**

- `Project.hasInvoicedTime: Bool` → `entries.contains { $0.invoiceID != nil }`
- `Client.hasInvoicedTime: Bool` → `projects.contains { $0.hasInvoicedTime }`

Rationale for keying on `TimeEntry.invoiceID`: it is stamped only at `markSent` (sent/paid), and it is set on the underlying entries for **both** per-project and client-combined invoices. So it is the precise, complete signal for "deleting this would destroy issued-invoice substantiation" — more robust than inspecting `Invoice.project`/`Invoice.client`.

**UI behavior at the two delete sites:**

- **Client delete** (`ClientsView.swift:143`, swipe action) and **Project delete** (`ClientDetailView.swift:125`):
  - If `hasInvoicedTime == true`: the destructive Delete does **not** delete. Instead present an alert:
    - Title: "Can't delete — billing records"
    - Message: "This [client/project] has time on sent or paid invoices. Archive it instead to keep your billing records."
    - Actions: **Archive** (performs the existing archive: sets `isArchived = true`) and **Cancel**.
  - If `hasInvoicedTime == false`: existing behavior (the current confirmation, then delete).
- Where a swipe presents both Archive and Delete, the protected case simply routes Delete through the guard; Archive is unchanged.

This is purely additive guard logic — no change to delete semantics for unprotected clients/projects.

### Part B — Finalize hardening

In `InvoicePreviewView` (the finalize entry points `finalizeAndEmail` / `finalizeAndShare`):

1. Add a synchronous re-entrancy flag set **before any `await`**:
   ```swift
   guard !isFinalizing else { return }
   isFinalizing = true
   defer { isFinalizing = false }   // reset so a legitimate retry is possible
   ```
   Set on the main actor before the draft is created/sent, closing the double-tap window. Disable the finalize button on `isFinalizing` (in addition to the existing `finalized != nil`).
2. **Reuse the created draft on retry:** store the draft once created; if finalize is re-entered after a prior failure, reuse the existing draft rather than creating a new one (so no second number is consumed). Combined with `markSent`'s existing status-guard, a second successful send of the same draft throws harmlessly.

Net: the existing `markSent` status-guard + the synchronous re-entrancy flag + draft-reuse make double-finalize impossible in the realistic flows.

## Data flow

- A/B touch UI + small BillableCore computed properties only. No model fields added, no `FetchDescriptor` changes, no migration.
- `hasInvoicedTime` reads already-loaded relationships (`project.entries`, `client.projects`); the delete sites already hold the model object.

## Error handling / edge cases

- **Draft-only invoices:** entries on a project that only appears on *draft* invoices have `invoiceID == nil` → `hasInvoicedTime == false` → deletion allowed (drafts are disposable, no records lost).
- **Client-combined invoices:** caught — the underlying entries still carry `invoiceID`, so the owning project/client reports `hasInvoicedTime == true`.
- **Already-archived** client/project: unaffected (archive is the recommended state anyway).
- **Finalize on a genuinely failed send:** `isFinalizing` resets via `defer`; the user can retry, and the retry reuses the same draft/number.
- **No new overlays/chrome** introduced.

## Testing

BillableCore unit tests:

- `Project.hasInvoicedTime`: false when all entries have `invoiceID == nil`; true when ≥1 entry has a non-nil `invoiceID`; false for a project whose entries back only a draft invoice.
- `Client.hasInvoicedTime`: true iff any of its projects is protected.

Finalize tests (extend existing invoice-builder/preview tests):

- Re-entrant `finalize` call while one is in flight returns without creating a second invoice; exactly one number is consumed.
- Retry after a simulated send failure reuses the same draft (no second number).

UI/behavior:

- Deleting a protected client/project surfaces the Archive alert and does not delete; choosing Archive sets `isArchived` and preserves entries/invoices.
- Deleting an unprotected client/project behaves exactly as before.

## Implementation notes

- Keep the guard helpers in BillableCore so they're unit-testable without the UI.
- Reuse existing archive code paths for the alert's Archive action; do not duplicate archive logic.
- Build/test command:
  `xcodebuild -project Billable.xcodeproj -scheme Billable -configuration Debug -destination 'platform=iOS Simulator,id=A946AE5D-C969-4EB2-8384-001B3451A6A4' -derivedDataPath build/DerivedData build`
