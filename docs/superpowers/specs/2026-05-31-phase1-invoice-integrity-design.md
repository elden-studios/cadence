# Phase 1 — Invoice Integrity (design)

**Date:** 2026-05-31
**Status:** Draft (design); pending user spec review → implementation plan
**Baseline:** real `main` = `origin/main` `2c9acde` (implement on a fresh branch cut from it)
**Supersedes:** `2026-05-29-invoice-integrity-design.md` **Part B** (finalize idempotency) — reworked here into the reorder+reopen design. **Part A** (deletion guard) is carried forward intact.
**Source:** verified backlog `docs/reviews/2026-05-31-cadence-verified-backlog.md` (items F1/F19, F10/F11, F28, F3, F21, F5) + the approved deletion-guard design.

This is the first of four committed phases (Phases 5–8 parked). It is the data-correctness / "don't corrupt the money" core, and it is bounded to the invoicing + client/project-delete surfaces. All target files are **byte-identical between the reviewed snapshot and `main`**, so the evidence below is current.

---

## Scope (7 work items)

| # | Item | Source | Priority |
|---|------|--------|----------|
| 1 | Finalize only on delivery success + Reopen-to-draft | F1, F19 (supersedes old Part B) | High |
| 2 | Centralize the watermark gate + de-duplicate finalize/render twins | F10, F11 | High |
| 3 | Watermark upgrade nudge on InvoiceDetailView | F28 | High |
| 4 | Deletion guard — protect time behind issued invoices | old Part A | High |
| 5 | De-duplicate InvoiceDetail delivery actions; surface Send reminder | F3 | Medium |
| 6 | Archive/delete confirmation proportionality | F5 | Medium |
| 7 | Rename invoice filter Outstanding→Unpaid; float overdue | F21 | Medium |

**Non-goals:** anything in Phases 2–8; schema changes/migrations; a global error-surface primitive (that is Phase 4 — Phase 1 uses local alerts where it must surface a failure); reworking recurring invoices.

---

## Item 1 — Finalize only after delivery is confirmed, + Reopen-to-draft

### Problem
`InvoicePreviewView.finalizeAndEmail` (~364-379) and `finalizeAndShare` (~522-537) call `InvoiceBuilder.createDraft` + `finalizeAndSend` immediately on tap — consuming the invoice number (`profile.consumeNextInvoiceNumber()`, `InvoiceBuilder.swift:219`), flipping Draft→Sent, and stamping every source `TimeEntry.invoiceID` — **before** the mail composer / share sheet is even presented. The composer/share dismiss handlers call `dismiss()+onDone()` regardless of outcome. `InvoiceStatusMachine` is one-way (`markSent` guards `.draft`; no reverse). So **cancelling a send strands a phantom "Sent" invoice** with a consumed number and entries marked invoiced — silently dropping the uninvoiced balance shown on Today/ProjectDetail for work that was never billed, with no recovery anywhere.

### Design

**A. Reorder — finalize on delivery success.** Both signals are available:
- **Email:** `MailComposerView.onDismiss` already returns `MFMailComposeResult` (`MailComposerView.swift:28,64`). Run `finalizeAndSend` only when `result == .sent`. On `.cancelled` / `.saved` / `.failed`, do **not** finalize.
- **Share:** `ShareSheet` (`InvoicePreviewView.swift:579`) is a bare `UIActivityViewController` with no completion handler. Add `completionWithItemsHandler`; run `finalizeAndSend` only when `completed == true`.

**Draft lifecycle (avoid phantom drafts too):** create the draft **once** on first finalize tap and store the reference (`createDraft` uses the *preview* number and does **not** consume — only `finalizeAndSend` consumes). Render the PDF from that draft, present the composer/share. On success → `finalizeAndSend(storedDraft)`. On cancel/failure → keep the stored draft and **reuse it** on retry (no second draft, no second number). This realizes the old Part B's "draft reuse + exactly one number" goal as a side effect of the reorder.

**Decision (explicit):** chosen approach is **persist-on-tap + reuse** (minimal surgery; aligns with the existing `createDraft` flow). If the user abandons the preview without a successful send, the (unconsumed-number) draft simply **remains in the Drafts filter** — resumable or deletable, never auto-removed. This trades at most one lingering draft per abandoned session for a much smaller, lower-risk change than the considered alternative (render from a transient, non-persisted invoice and persist only on success); the plan may adopt that alternative if draft-clutter proves annoying in practice.

**Re-entrancy:** add a synchronous `isFinalizing` guard set before any `await` (and reset via `defer`), and disable the finalize buttons on it — closes the rapid-double-tap window during the async render/present (carried from old Part B).

**B. Reopen-to-draft (the sent-by-mistake exit).**
- New `InvoiceStatusMachine` transition `reopenToDraft(at:)`: guard `status == .sent` (only sent, never paid) → set `status = .draft`, clear `sentAt`, bump `updatedAt`.
- Caller (new destructive action in `InvoiceDetailView`'s ⋯ menu, shown only for `.sent`): re-mark the invoice's source entries uninvoiced (`entry.invoiceID == invoice.uuid` → `nil`), and **cancel the reminders** that `markSent` scheduled via `didMarkSentHook` (use the existing `ReminderService`/`Scheduler` cancel path — confirm exact API at plan time).
- **Invoice number policy (final — number-reuse retired):** reopening keeps the already-issued number on the now-draft invoice (cosmetic). There is **no in-place re-send path** — `InvoiceDetailView` exposes only Delete/Share on a draft — so a reopened invoice is resolved by deleting it (existing Delete-draft action) or re-generating. **No number-reuse logic and no `finalizeAndSend` change are needed**: a reopened invoice can never reach `finalizeAndSend` a second time, so the earlier "reuse the number on re-finalize / already-numbered check" idea is dropped. A deleted reopened invoice simply leaves a number gap (standard accounting).
- Confirmation dialog before reopen: "Reopen INV-xxxx to draft? Its tracked time becomes uninvoiced again and scheduled reminders are cancelled." Keep `.paid` invoices non-reopenable.

### Error handling
- Finalize failure (render returns empty `Data`, or `finalizeAndSend` throws): surface a local `.alert` ("Couldn't finalize the invoice — try again.") and leave the stored draft intact for retry. (Phase 4 will replace the local alert with the shared error presenter.)
- The existing empty-`Data` guard (don't cache 0 bytes) is preserved and centralized in Item 2.

### Testing
- BillableCore: `reopenToDraft` throws from `.draft` and `.paid`; succeeds from `.sent`, clearing `sentAt`. Cancelled send (result≠`.sent`) leaves status `.draft`, number not consumed, entries still uninvoiced. Successful send consumes exactly one number and marks entries.
- UI: cancel the mail composer → invoice remains a draft, uninvoiced balance unchanged; reopen a sent invoice → entries uninvoiced again + reminders cancelled.

---

## Item 2 — Centralize the watermark gate + de-duplicate finalize/render twins

### Problem
The free-tier `"Sent with Cadence"` watermark is hand-stamped at 6 sites (`InvoicePreviewView.swift:90/384/543`, `InvoiceDetailView.swift:291/458/664`) because `InvoiceTemplateData.from(_:)` leaves `watermark` at its `nil` default; `InvoiceDetailView.cacheIsStale:682` re-types the literal as the cache/render contract. Any path that forgets the line ships a free user an un-watermarked PDF (revenue bypass). `finalizeAndEmail`/`finalizeAndShare` are copy-pasted create+finalize+render+cache blocks; `ensurePDFData` has a `!cached.isEmpty` guard that `ensurePDFOnDisk` lacks (a 0-byte render can reach the share sheet).

### Design
- BillableCore: add `InvoiceTemplateData.watermarkText` constant and `InvoiceTemplateData.from(_ invoice:, watermarked: Bool)` (or `applyWatermark(isPro:)`). Callers pass a bool; the literal lives in one place. `cacheIsStale` references `watermarkText`.
- Extract one `ensureCachedPDF(for invoice:, watermarked: Bool) -> Data` with the single 0-byte guard, and one `deliver(invoice:, channel: .email | .share)` helper. Collapse the four twin functions to thin call sites. (Pairs naturally with Item 1's reorder, which already rewrites these functions.)

### Testing
Extend `InvoicePDFRendererWatermarkTests`: free entitlement → PDF contains the watermark text via the single helper; Pro → absent. `cacheIsStale` flips when entitlement changes. 0-byte render is never cached or written to disk on either delivery path.

---

## Item 3 — Watermark upgrade nudge on InvoiceDetailView

### Problem
`InvoicePreviewView` shows a "Remove watermark with Pro" banner (`:109-131`), but `InvoiceDetailView` — the surface revisited on every re-share / email / payment chase — has watermark logic only inside PDF rendering and **zero** Paywall references. In the watermark-based model the watermark is the entire free→Pro wedge, so the most-repeated exposure never converts.

### Design
Reuse the existing `InvoicePreviewView` watermark banner verbatim on `InvoiceDetailView`, shown when `!subscriptions.canRemoveWatermark` and `invoice.status != .draft`, wired to the existing `PaywallView(trigger: .removeWatermark)` sheet. Pure reuse of an existing control on a higher-traffic surface — no new capability. (Extract the banner into a small shared view so the two screens can't drift.)

### Testing
Snapshot/behavior: banner visible for a free user on a sent invoice; absent for Pro and for drafts; tapping presents the `.removeWatermark` paywall.

---

## Item 4 — Deletion guard (carried from approved Part A)

### Problem
`Client` cascade-deletes `Project`s, `Project` cascade-deletes `TimeEntry`s. `Invoice.client`/`Invoice.project` are nullify-on-delete. So deleting a client/project that backs **sent/paid** invoices keeps the invoice *document* but **destroys the `TimeEntry` audit trail** behind it (tax/audit exposure). The Delete actions (`ClientsView.swift:143`, `ClientDetailView.swift:125`) proceed unconditionally — confirmed unimplemented on main.

### Design (unchanged from 2026-05-29 Part A)
- BillableCore computed helpers (no migration): `Project.hasInvoicedTime` = `entries.contains { $0.invoiceID != nil }`; `Client.hasInvoicedTime` = `projects.contains(\.hasInvoicedTime)`. Keys on `invoiceID` (stamped only at `markSent`, set for per-project and client-combined invoices) — the precise "would destroy issued-invoice substantiation" signal.
- At both delete sites: if `hasInvoicedTime`, Delete does not delete — present an alert ("Can't delete — billing records / This [client/project] has time on sent or paid invoices. Archive it instead to keep your billing records.") with **Archive** + **Cancel**. If not, existing behavior. Draft-only backing → `hasInvoicedTime == false` → deletion allowed (drafts disposable).

### Testing
Per the old spec: helper truth tables (incl. draft-only → false, client-combined → true); deleting a protected client/project surfaces the Archive alert and preserves records; unprotected deletes unchanged.

---

## Item 5 — De-duplicate InvoiceDetail delivery actions; surface Send reminder

### Problem
`InvoiceDetailView` renders "Share PDF" + "Email invoice" as loud body buttons (`actionButtons:322`) **and** again in the ⋯ menu (`:67-99`), while the time-sensitive "Send reminder email" lives only in the menu — hierarchy inverted.

### Design
Keep **Mark as paid** as the single prominent body action on a sent invoice. Put delivery actions (Share / Email) in **one** location only (the ⋯ menu), and promote **Send reminder** to parity beside Email there (not gated behind the past-due banner). The reminder banner (`:147-160`) stays for the past-due nudge. Relabel/reorder of existing controls only.

### Testing
Behavior: each delivery action appears once; Send reminder reachable for any sent invoice; Mark as paid remains the prominent action.

---

## Item 6 — Archive/delete confirmation proportionality

### Problem
On the client swipe (`ClientsView`), recoverable **Archive** fires instantly (no confirm, no undo) while less-frequent **Delete** is dialog-gated — confirmation weight is inverted relative to reversibility; an accidental Archive silently drops the client to a non-interactive dimmed row.

### Design
Make confirmation proportional to reversibility: the irreversible **Delete** keeps its dialog (now also routed through Item 4's guard); the recoverable **Archive** stays low-friction but the swipe order/roles are arranged so the destructive action requires the deliberate gesture. (Smallest change: keep Archive instant but ensure Delete is the full-swipe + dialog; confirm final swipe arrangement at plan time.) Coheres with Item 4 since both touch the same swipe.

### Testing
Behavior: Delete on a protected client → guard alert; Delete on unprotected → existing dialog; Archive → archives (and is recoverable via Restore).

---

## Item 7 — Rename invoice filter Outstanding→Unpaid; float overdue

### Problem
`InvoicesView.Filter.outstanding` shows label "Outstanding" but maps to `status == .sent` (`:15,131-132`) — i.e. sent-but-unpaid — which collides with the "uninvoiced" wording used elsewhere for tracked-but-not-yet-invoiced money. "Overdue" is a first-class status (red OVERDUE pill/banner) but has no filter; the segment silently mixes overdue and not-yet-due.

### Design
Rename the segment label "Outstanding" → **"Unpaid"** (mapping unchanged: `status == .sent`). Keep 4 segments. Within Unpaid, sort `isOverdue()` invoices to the top; the existing red OVERDUE pill already distinguishes them. No new tab, no behavior change beyond label + sort.

### Testing
Behavior: segment reads "Unpaid"; overdue invoices appear first within it; paid/drafts/recurring unchanged.

---

## Cross-item notes

- **One PR.** All items live in the invoicing + client-delete surfaces (`InvoicePreviewView`, `InvoiceDetailView`, `InvoicesView`, `ClientsView`, `ClientDetailView`, `InvoiceBuilder`, `InvoiceStatusMachine`, `InvoiceTemplate`). Items 1+2 rewrite the same finalize/render functions, so they're done together.
- **Branch:** cut a fresh branch from `origin/main` (`2c9acde`) at implementation time — do **not** build on the stale `feature/project-detail-ia`.
- **Test command:** `xcodebuild -project Billable.xcodeproj -scheme Billable -configuration Debug -destination 'platform=iOS Simulator,id=A946AE5D-C969-4EB2-8384-001B3451A6A4' -derivedDataPath build/DerivedData build` (plus the BillableCore Swift test suite).
- **TDD:** each BillableCore change (reopen transition, watermark helper, hasInvoicedTime) gets a failing test first.
