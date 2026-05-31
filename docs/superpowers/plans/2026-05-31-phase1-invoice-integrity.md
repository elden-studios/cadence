# Phase 1 — Invoice Integrity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Cadence's invoicing trustworthy — an invoice can't be marked Sent unless it was actually delivered (and can be reopened if it was sent by mistake), the watermark gate lives in one place, the most-revisited invoice surface sells Pro, deleting a client/project can't destroy the records behind issued invoices, and the invoice list's vocabulary is honest.

**Architecture:** Pure logic lands in `BillableCore` (state-machine transition, computed guard properties, a watermark helper) with unit tests; SwiftUI views are edited in place to call that logic. No schema changes, no migration. Implemented on `feature/phase1-invoice-integrity` (cut from `origin/main` `2c9acde`).

**Tech Stack:** Swift 6 / SwiftUI / SwiftData, `swift-testing` (BillableCore unit tests), `xcodebuild` for the app build, `swift test` for the package.

**Baseline note:** all target files are byte-identical to `main`. Build/verify command (full app):
`xcodebuild -project Billable.xcodeproj -scheme Billable -configuration Debug -destination 'platform=iOS Simulator,id=A946AE5D-C969-4EB2-8384-001B3451A6A4' -derivedDataPath build/DerivedData build`
Package tests: `cd Packages/BillableCore && swift test`

**Design decision carried from the spec (finalize):** the draft is created once on the first finalize tap (reusing the existing `createDraft`, which uses the *preview* number and does **not** consume), the PDF is rendered, and the composer/share is presented. `finalizeAndSend` (which consumes the number, flips Draft→Sent, and stamps entries) runs **only on confirmed delivery** — email `result == .sent`, share `completed == true`. Cancelling leaves a reusable draft; finalize is re-entrancy-guarded.

**Reopen design (simplified):** Reopen-to-draft reverses `.sent → .draft`, re-marks the invoice's source entries uninvoiced, and cancels its scheduled reminders. There is **no in-place re-send path** (drafts expose Delete/Share, not finalize), so a reopened invoice is resolved by deleting it (existing Delete-draft action) or re-generating — no invoice-number-reuse machinery is needed.

---

## File structure

| File | Change | Responsibility |
|------|--------|----------------|
| `Packages/BillableCore/Sources/BillableCore/Invoicing/InvoiceTemplate.swift` | Modify | Add `InvoiceTemplateData.watermarkText` constant + `from(_:watermarked:)` overload (single watermark source) |
| `Packages/BillableCore/Sources/BillableCore/Models/InvoiceStatusMachine.swift` | Modify | Add `reopenToDraft(at:)` transition (`.sent → .draft`) |
| `Packages/BillableCore/Sources/BillableCore/Models/Project.swift` | Modify | Add `hasInvoicedTime` computed property |
| `Packages/BillableCore/Sources/BillableCore/Models/Client.swift` | Modify | Add `hasInvoicedTime` computed property |
| `App/Sources/Features/Invoicing/InvoicePreviewView.swift` | Modify | Finalize-on-delivery-success reorder; re-entrancy guard; use watermark helper |
| `App/Sources/Features/Invoicing/InvoiceDetailView.swift` | Modify | Reopen-to-draft action; reuse watermark helper; shared watermark banner; de-dup delivery actions |
| `App/Sources/Features/Invoicing/Components/WatermarkUpgradeBanner.swift` | Create | Shared "Remove watermark with Pro" banner used by Preview + Detail |
| `App/Sources/Features/Invoicing/InvoicesView.swift` | Modify | Rename `Outstanding`→`Unpaid` label; float overdue to top |
| `App/Sources/Features/Clients/ClientsView.swift` | Modify | Deletion guard at the client delete swipe |
| `App/Sources/Features/Clients/ClientDetailView.swift` | Modify | Deletion guard at the project delete site |
| `Packages/BillableCore/Tests/BillableCoreTests/InvoiceReopenTests.swift` | Create | Tests for `reopenToDraft` |
| `Packages/BillableCore/Tests/BillableCoreTests/HasInvoicedTimeTests.swift` | Create | Tests for the deletion-guard helpers |
| `Packages/BillableCore/Tests/BillableCoreTests/InvoiceWatermarkHelperTests.swift` | Create | Tests for the watermark helper |

**Task order (dependency-respecting):** BillableCore foundation (Tasks 1–3) → InvoicePreview reorder (Task 4) → finalize/render de-dup using the helper (Task 5) → reopen action (Task 6) → shared nudge banner (Task 7) → InvoiceDetail action de-dup (Task 8) → deletion guard (Task 9) → archive/delete proportionality (Task 10) → Unpaid/overdue filter (Task 11).

---

## Task 1: Watermark helper (single source of the gate)

**Files:**
- Modify: `Packages/BillableCore/Sources/BillableCore/Invoicing/InvoiceTemplate.swift` (the `InvoiceTemplateData` extension, ~line 479)
- Test: `Packages/BillableCore/Tests/BillableCoreTests/InvoiceWatermarkHelperTests.swift`

- [ ] **Step 1: Write the failing test**

Create `InvoiceWatermarkHelperTests.swift`:

```swift
import Testing
import SwiftData
@testable import BillableCore

@MainActor
struct InvoiceWatermarkHelperTests {
    private func makeInvoice(in context: ModelContext) -> Invoice {
        let invoice = Invoice(
            number: "INV-0001", issuedAt: .now, dueAt: .now, status: .draft,
            clientNameSnapshot: "C", clientAddressSnapshot: nil, clientEmailSnapshot: nil,
            clientColor: .blue, issuerNameSnapshot: "Me", issuerAddressSnapshot: nil,
            issuerEmailSnapshot: nil, issuerLogoSnapshot: nil,
            issuerBankBeneficiaryNameSnapshot: nil, issuerBankNameSnapshot: nil,
            issuerBankLocationSnapshot: nil, issuerBankIBANSnapshot: nil, issuerBankSWIFTSnapshot: nil,
            issuerTaxIDLabelSnapshot: nil, issuerTaxIDNumberSnapshot: nil,
            paymentTermsSnapshot: "", taxLabelSnapshot: "Tax", taxRateSnapshot: 0,
            currencyCodeSnapshot: "USD", lineItems: [], notes: nil, client: nil, project: nil
        )
        context.insert(invoice)
        return invoice
    }

    @Test func watermarkedTrueStampsTheConstant() throws {
        let container = try BillableModelContainer.inMemory()
        let invoice = makeInvoice(in: container.mainContext)
        let data = InvoiceTemplateData.from(invoice, watermarked: true)
        #expect(data.watermark == InvoiceTemplateData.watermarkText)
    }

    @Test func watermarkedFalseLeavesNil() throws {
        let container = try BillableModelContainer.inMemory()
        let invoice = makeInvoice(in: container.mainContext)
        let data = InvoiceTemplateData.from(invoice, watermarked: false)
        #expect(data.watermark == nil)
    }
}
```

- [ ] **Step 2: Run it; verify it fails**

Run: `cd Packages/BillableCore && swift test --filter InvoiceWatermarkHelperTests`
Expected: FAIL to compile — `watermarkText` and `from(_:watermarked:)` don't exist yet.
(If the `Invoice(...)` initializer argument list here doesn't match the real initializer, copy the argument list from an existing test, e.g. `InvoiceTests.swift`, before proceeding — keep the test, fix only the constructor call.)

- [ ] **Step 3: Add the constant + overload**

In `InvoiceTemplate.swift`, replace the `public extension InvoiceTemplateData { ... }` block (currently containing only `from(_:)`, ~lines 479–518) so it reads:

```swift
public extension InvoiceTemplateData {
    /// The free-tier watermark string. The single source of truth — render
    /// sites pass a bool, never this literal, and cache-staleness checks
    /// reference this constant.
    static let watermarkText = "Sent with Cadence"

    /// Build template data from a SwiftData `Invoice`, applying the watermark
    /// when `watermarked` is true. Centralizes the entitlement→watermark gate.
    @MainActor
    static func from(_ invoice: Invoice, watermarked: Bool) -> InvoiceTemplateData {
        var data = from(invoice)
        data.watermark = watermarked ? watermarkText : nil
        return data
    }

    /// Build template data from a SwiftData `Invoice` (no watermark applied).
    @MainActor
    static func from(_ invoice: Invoice) -> InvoiceTemplateData {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        var data = InvoiceTemplateData(
            issuerName: invoice.issuerNameSnapshot,
            issuerAddress: invoice.issuerAddressSnapshot,
            issuerEmail: invoice.issuerEmailSnapshot,
            issuerLogo: invoice.issuerLogoSnapshot,
            clientName: invoice.clientNameSnapshot,
            clientAddress: invoice.clientAddressSnapshot,
            clientEmail: invoice.clientEmailSnapshot,
            invoiceNumber: invoice.number,
            issuedDateLabel: formatter.string(from: invoice.issuedAt),
            dueDateLabel: formatter.string(from: invoice.dueAt),
            paymentTerms: invoice.paymentTermsSnapshot,
            lineItems: invoice.lineItems,
            notes: invoice.notes,
            subtotal: invoice.subtotal,
            taxLabel: invoice.taxLabelSnapshot,
            taxRate: invoice.taxRateSnapshot,
            taxAmount: invoice.taxAmount,
            total: invoice.total,
            currencyCode: invoice.currencyCodeSnapshot
        )
        data.bankBeneficiaryName = invoice.issuerBankBeneficiaryNameSnapshot
        data.bankName = invoice.issuerBankNameSnapshot
        data.bankLocation = invoice.issuerBankLocationSnapshot
        data.bankIBAN = invoice.issuerBankIBANSnapshot
        data.bankSWIFT = invoice.issuerBankSWIFTSnapshot
        data.taxIDLabel = invoice.issuerTaxIDLabelSnapshot
        data.taxIDNumber = invoice.issuerTaxIDNumberSnapshot
        data.projectName = invoice.projectNameSnapshot
        data.scopeOfWork = invoice.scopeOfWork
        data.projectColorRaw = invoice.clientColorRaw
        return data
    }
}
```

- [ ] **Step 4: Run the test; verify it passes**

Run: `cd Packages/BillableCore && swift test --filter InvoiceWatermarkHelperTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Invoicing/InvoiceTemplate.swift Packages/BillableCore/Tests/BillableCoreTests/InvoiceWatermarkHelperTests.swift
git commit -m "feat(core): single-source watermark gate via InvoiceTemplateData.from(_:watermarked:)"
```

---

## Task 2: `reopenToDraft` transition

**Files:**
- Modify: `Packages/BillableCore/Sources/BillableCore/Models/InvoiceStatusMachine.swift`
- Test: `Packages/BillableCore/Tests/BillableCoreTests/InvoiceReopenTests.swift`

- [ ] **Step 1: Write the failing test**

Create `InvoiceReopenTests.swift` (mirror the `Invoice(...)` constructor used in `InvoiceTests.swift`):

```swift
import Testing
import Foundation
@testable import BillableCore

@MainActor
struct InvoiceReopenTests {
    @Test func reopenFromSentClearsSentAtAndReturnsDraft() throws {
        let invoice = TestInvoiceFactory.make(status: .draft)
        try invoice.markSent(at: Date(timeIntervalSince1970: 1000))
        #expect(invoice.status == .sent)
        try invoice.reopenToDraft(at: Date(timeIntervalSince1970: 2000))
        #expect(invoice.status == .draft)
        #expect(invoice.sentAt == nil)
        #expect(invoice.updatedAt == Date(timeIntervalSince1970: 2000))
    }

    @Test func reopenThrowsFromDraft() {
        let invoice = TestInvoiceFactory.make(status: .draft)
        #expect(throws: InvoiceTransitionError.self) {
            try invoice.reopenToDraft()
        }
    }

    @Test func reopenThrowsFromPaid() throws {
        let invoice = TestInvoiceFactory.make(status: .draft)
        try invoice.markSent()
        try invoice.markPaid()
        #expect(throws: InvoiceTransitionError.self) {
            try invoice.reopenToDraft()
        }
    }
}
```

If no shared `TestInvoiceFactory` exists, add this minimal helper at the bottom of the test file (or reuse the constructor pattern from `InvoiceTests.swift`):

```swift
enum TestInvoiceFactory {
    @MainActor static func make(status: InvoiceStatus) -> Invoice {
        Invoice(
            number: "INV-0001", issuedAt: .now, dueAt: .now, status: status,
            clientNameSnapshot: "C", clientAddressSnapshot: nil, clientEmailSnapshot: nil,
            clientColor: .blue, issuerNameSnapshot: "Me", issuerAddressSnapshot: nil,
            issuerEmailSnapshot: nil, issuerLogoSnapshot: nil,
            issuerBankBeneficiaryNameSnapshot: nil, issuerBankNameSnapshot: nil,
            issuerBankLocationSnapshot: nil, issuerBankIBANSnapshot: nil, issuerBankSWIFTSnapshot: nil,
            issuerTaxIDLabelSnapshot: nil, issuerTaxIDNumberSnapshot: nil,
            paymentTermsSnapshot: "", taxLabelSnapshot: "Tax", taxRateSnapshot: 0,
            currencyCodeSnapshot: "USD", lineItems: [], notes: nil, client: nil, project: nil
        )
    }
}
```

- [ ] **Step 2: Run it; verify it fails**

Run: `cd Packages/BillableCore && swift test --filter InvoiceReopenTests`
Expected: FAIL — `reopenToDraft` is undefined.

- [ ] **Step 3: Add the transition**

In `InvoiceStatusMachine.swift`, add inside the `extension Invoice { ... }` block, after `markPaid`:

```swift
    /// Reverse a Sent invoice back to Draft (the only legal reverse transition).
    /// Clears `sentAt` and bumps `updatedAt`. Paid invoices cannot be reopened.
    /// The CALLER is responsible for re-marking source entries uninvoiced and
    /// cancelling the invoice's scheduled reminders — this only moves the status.
    public func reopenToDraft(at date: Date = .now) throws {
        guard status == .sent else {
            throw InvoiceTransitionError.illegalTransition(from: status, to: .draft)
        }
        status = .draft
        sentAt = nil
        updatedAt = date
    }
```

- [ ] **Step 4: Run the test; verify it passes**

Run: `cd Packages/BillableCore && swift test --filter InvoiceReopenTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Models/InvoiceStatusMachine.swift Packages/BillableCore/Tests/BillableCoreTests/InvoiceReopenTests.swift
git commit -m "feat(core): add reopenToDraft (Sent->Draft) invoice transition"
```

---

## Task 3: `hasInvoicedTime` deletion-guard helpers

**Files:**
- Modify: `Packages/BillableCore/Sources/BillableCore/Models/Project.swift`, `Client.swift`
- Test: `Packages/BillableCore/Tests/BillableCoreTests/HasInvoicedTimeTests.swift`

- [ ] **Step 1: Write the failing test**

Create `HasInvoicedTimeTests.swift`:

```swift
import Testing
import SwiftData
@testable import BillableCore

@MainActor
struct HasInvoicedTimeTests {
    @Test func projectFalseWhenAllEntriesUninvoiced() throws {
        let container = try BillableModelContainer.inMemory()
        let ctx = container.mainContext
        let project = Project(name: "P", hourlyRate: 100)
        ctx.insert(project)
        let e = TimeEntry(startedAt: .now, endedAt: .now, project: project)
        e.invoiceID = nil
        ctx.insert(e)
        #expect(project.hasInvoicedTime == false)
    }

    @Test func projectTrueWhenAnyEntryInvoiced() throws {
        let container = try BillableModelContainer.inMemory()
        let ctx = container.mainContext
        let project = Project(name: "P", hourlyRate: 100)
        ctx.insert(project)
        let e = TimeEntry(startedAt: .now, endedAt: .now, project: project)
        e.invoiceID = UUID()
        ctx.insert(e)
        #expect(project.hasInvoicedTime == true)
    }

    @Test func clientTrueIffAnyProjectProtected() throws {
        let container = try BillableModelContainer.inMemory()
        let ctx = container.mainContext
        let client = Client(name: "C")
        ctx.insert(client)
        let p1 = Project(name: "P1", hourlyRate: 100, client: client)
        let p2 = Project(name: "P2", hourlyRate: 100, client: client)
        ctx.insert(p1); ctx.insert(p2)
        let e = TimeEntry(startedAt: .now, endedAt: .now, project: p2)
        e.invoiceID = UUID()
        ctx.insert(e)
        #expect(client.hasInvoicedTime == true)
    }
}
```

(Match the real `TimeEntry(...)` initializer — check `TimeEntryTests.swift` and adjust the constructor call only if needed.)

- [ ] **Step 2: Run it; verify it fails**

Run: `cd Packages/BillableCore && swift test --filter HasInvoicedTimeTests`
Expected: FAIL — `hasInvoicedTime` undefined.

- [ ] **Step 3: Add the helpers**

In `Project.swift`, add inside the class (after `entries`):

```swift
    /// True if any tracked entry on this project is on a sent/paid invoice
    /// (`invoiceID` is stamped only at `markSent`). Used to block deletes that
    /// would destroy the records behind issued invoices.
    public var hasInvoicedTime: Bool {
        entries.contains { $0.invoiceID != nil }
    }
```

In `Client.swift`, add inside the class (after `activeProjects`):

```swift
    /// True if any of this client's projects has invoiced time. See
    /// `Project.hasInvoicedTime`.
    public var hasInvoicedTime: Bool {
        projects.contains { $0.hasInvoicedTime }
    }
```

- [ ] **Step 4: Run the test; verify it passes**

Run: `cd Packages/BillableCore && swift test --filter HasInvoicedTimeTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Models/Project.swift Packages/BillableCore/Sources/BillableCore/Models/Client.swift Packages/BillableCore/Tests/BillableCoreTests/HasInvoicedTimeTests.swift
git commit -m "feat(core): add hasInvoicedTime guards on Project/Client"
```

---

## Task 4: Finalize only on confirmed delivery (InvoicePreviewView)

**Files:**
- Modify: `App/Sources/Features/Invoicing/InvoicePreviewView.swift` (`finalizeAndEmail` ~346, `finalizeAndShare` ~511, the mail/share `.sheet` wiring ~177–228, `ShareSheet` ~579)

This is the core fix. The new flow: tap → create-or-reuse draft + render PDF + present composer/share → finalize **only** on success. We keep a `draft` reference and an `isFinalizing` guard.

- [ ] **Step 1: Add finalize state**

In the `@State` block (near line 26), add:

```swift
    @State private var draft: Invoice?          // created on first finalize tap; finalized only on delivery success
    @State private var isFinalizing = false     // synchronous re-entrancy guard
    @State private var finalizeError = false    // local error surface (Phase 4 unifies)
```

(Keep the existing `finalized` — it now means "delivery confirmed".)

- [ ] **Step 2: Add a helper that ensures the draft + rendered PDF exist**

Add this method (near `finalizeAndEmail`):

```swift
    /// Create the draft once (preview number, NOT consumed) and render its PDF.
    /// Returns nil on render failure. Reused across retries so no second draft.
    private func ensureDraftAndPDF() -> (draft: Invoice, pdf: Data)? {
        flushPendingDescriptionEdits()
        let theDraft: Invoice
        if let existing = draft {
            theDraft = existing
        } else {
            do {
                theDraft = try InvoiceBuilder.createDraft(
                    for: client, lineItems: lineItems, project: project,
                    scopeOfWork: scopeOfWork, notes: notes, profile: profile, context: modelContext
                )
                draft = theDraft
            } catch { return nil }
        }
        let data = InvoicePDFRenderer.renderPDFData(
            for: .from(theDraft, watermarked: !subscriptions.canRemoveWatermark),
            accent: theDraft.clientColor.swiftUIColor
        )
        guard !data.isEmpty else { return nil }
        theDraft.pdfDataCached = data
        modelContext.saveOrLog("cache invoice pdf (preview)")
        return (theDraft, data)
    }

    /// Finalize the draft (consume number, Draft->Sent, stamp entries) — called
    /// ONLY after delivery is confirmed.
    private func commitFinalize(_ theDraft: Invoice) {
        guard finalized == nil else { return }
        do {
            try InvoiceBuilder.finalizeAndSend(theDraft, sourceEntries: sourceEntries, profile: profile, context: modelContext)
            finalized = theDraft
        } catch {
            finalizeError = true
        }
    }
```

- [ ] **Step 3: Rewrite `finalizeAndEmail` to present-then-finalize**

Replace the body of `finalizeAndEmail()` (lines ~346–468) with:

```swift
    private func finalizeAndEmail() {
        guard !isFinalizing, finalized == nil else { return }
        guard let recipient = client.email, !recipient.isEmpty else {
            showingNoClientEmailAlert = true
            return
        }
        isFinalizing = true
        defer { isFinalizing = false }
        guard let (theDraft, data) = ensureDraftAndPDF() else { finalizeError = true; return }
        pdfData = data

        let senderName = profile.name
        let subject = ReminderTemplateRenderer.render(template: profile.effectiveInvoiceEmailSubjectTemplate, invoice: theDraft, senderName: senderName)
        let body = ReminderTemplateRenderer.render(template: profile.effectiveInvoiceEmailBodyTemplate, invoice: theDraft, senderName: senderName)

        if MFMailComposeViewController.canSendMail() {
            mailComposerRecipients = [recipient]
            mailComposerSubject = subject
            mailComposerBody = body
            mailComposerAttachment = data
            showingMailComposer = true   // finalize happens in onDismiss when result == .sent
        } else if let url = mailtoURLFromComponents(to: recipient, subject: subject, body: body) {
            // mailto can't confirm send and drops the attachment; treat opening the
            // mail app as delivery intent and finalize, then hand off.
            UIApplication.shared.open(url)
            commitFinalize(theDraft)
            dismiss(); onDone()
        } else {
            showingShare = true          // last-resort: finalize on share completion
        }
    }
```

- [ ] **Step 4: Rewrite `finalizeAndShare`**

Replace the body of `finalizeAndShare()` (lines ~511–564) with:

```swift
    private func finalizeAndShare() {
        guard !isFinalizing, finalized == nil else { return }
        isFinalizing = true
        defer { isFinalizing = false }
        guard let (_, data) = ensureDraftAndPDF() else { finalizeError = true; return }
        pdfData = data
        showingShare = true              // finalize happens in ShareSheet completion
    }
```

- [ ] **Step 5: Gate finalize on the mail result**

In the `.sheet(isPresented: $showingMailComposer)` content (lines ~205–227), change the `onDismiss:` closure to finalize on `.sent`:

```swift
                        onDismiss: { result in
                            showingMailComposer = false
                            mailComposerAttachment = nil
                            mailComposerRecipients = []
                            if result == .sent || result == .saved {
                                if let theDraft = draft { commitFinalize(theDraft) }
                            }
                            dismiss()
                            onDone()
                        }
```

- [ ] **Step 6: Add a completion handler to `ShareSheet` and gate finalize on it**

Change `ShareSheet` (line ~579) to forward completion:

```swift
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    var onComplete: ((Bool) -> Void)? = nil
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.completionWithItemsHandler = { _, completed, _, _ in onComplete?(completed) }
        return vc
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
```

Then in the `.sheet(isPresented: $showingShare)` content (lines ~191–195), pass the handler that finalizes on completion:

```swift
                if let pdfData,
                   let url = writeToTemp(pdfData, suggestedName: templateData.invoiceNumber) {
                    ShareSheet(items: [url], onComplete: { completed in
                        if completed, let theDraft = draft { commitFinalize(theDraft) }
                    })
                    .ignoresSafeArea()
                }
```

Leave the `.sheet`'s `onDismiss:` (dismiss + onDone) as-is — it still fires on close regardless.

- [ ] **Step 7: Add the local error alert**

After the existing `.alert("Add a client email first", ...)` (line ~229), add:

```swift
            .alert("Couldn't finalize the invoice", isPresented: $finalizeError, actions: {
                Button("OK", role: .cancel) {}
            }, message: { Text("Something went wrong creating or sending this invoice. Your tracked time was not changed — try again.") })
```

- [ ] **Step 8: Build and manually verify**

Run the `xcodebuild ... build` command. Expected: BUILD SUCCEEDED.
Manual (simulator): create an invoice → Finalize & email → **Cancel** the composer → the invoice does **not** appear under Unpaid; the Today "UNINVOICED" total is unchanged (entries still uninvoiced); a draft exists under Drafts. Then Finalize & email → actually send → it appears under Unpaid and entries are invoiced.

- [ ] **Step 9: Commit**

```bash
git add App/Sources/Features/Invoicing/InvoicePreviewView.swift
git commit -m "fix(invoicing): finalize an invoice only after delivery is confirmed"
```

---

## Task 5: De-duplicate finalize/render; route every watermark through the helper

**Files:**
- Modify: `App/Sources/Features/Invoicing/InvoiceDetailView.swift` (`liveTemplateData` ~289, `ensurePDFData` ~447, `ensurePDFOnDisk` ~656, `cacheIsStale` ~680)
- Modify: `App/Sources/Features/Invoicing/InvoicePreviewView.swift` (the `templateData` watermark line ~90, already handled by Task 4's `ensureDraftAndPDF`)

- [ ] **Step 1: Replace the three hand-stamped watermark sites in InvoiceDetailView with the helper**

`liveTemplateData` (lines ~289–293) becomes:

```swift
    private var liveTemplateData: InvoiceTemplateData {
        .from(invoice, watermarked: !subscriptions.canRemoveWatermark)
    }
```

In `ensurePDFData` (lines ~457–458) replace:
```swift
        var templateData = InvoiceTemplateData.from(invoice)
        templateData.watermark = subscriptions.canRemoveWatermark ? nil : "Sent with Cadence"
```
with:
```swift
        let templateData = InvoiceTemplateData.from(invoice, watermarked: !subscriptions.canRemoveWatermark)
```

In `ensurePDFOnDisk` (lines ~663–664) make the same replacement. Then add the missing 0-byte guard so the two paths match — change `ensurePDFOnDisk`'s else-branch to not cache/return an empty render:

```swift
        } else {
            let templateData = InvoiceTemplateData.from(invoice, watermarked: !subscriptions.canRemoveWatermark)
            let rendered = InvoicePDFRenderer.renderPDFData(for: templateData, accent: invoice.clientColor.swiftUIColor)
            guard !rendered.isEmpty else { return nil }   // parity with ensurePDFData's guard
            bytes = rendered
            invoice.pdfDataCached = bytes
            modelContext.saveOrLog("cache invoice pdf")
        }
```

- [ ] **Step 2: Make `cacheIsStale` reference the constant**

`cacheIsStale` (line ~682) — replace the literal:

```swift
        let hasWatermark = text.contains(InvoiceTemplateData.watermarkText)
```

- [ ] **Step 3: Replace the last literal in InvoicePreviewView's live-preview `templateData`**

`InvoicePreviewView.templateData` (line ~90) builds `InvoiceTemplateData` from the *profile* (not an Invoice), so it can't use `from(_:watermarked:)` — but it must still stop hard-coding the literal. Replace:

```swift
            watermark: subscriptions.canRemoveWatermark ? nil : "Sent with Cadence"
```
with:
```swift
            watermark: subscriptions.canRemoveWatermark ? nil : InvoiceTemplateData.watermarkText
```

After this, `grep -rn '"Sent with Cadence"' App Packages` must return **only** the `watermarkText` constant definition in `InvoiceTemplate.swift`.

- [ ] **Step 4: Build + run watermark tests**

Run the `xcodebuild ... build` command (BUILD SUCCEEDED) and `cd Packages/BillableCore && swift test --filter Watermark` (existing `InvoicePDFRendererWatermarkTests` still pass).
Manual: as a free user, Share PDF and Email invoice from a sent invoice both produce a watermarked PDF; toggling Pro (DEBUG entitlement) removes it on next render.

- [ ] **Step 5: Commit**

```bash
git add App/Sources/Features/Invoicing/InvoiceDetailView.swift
git commit -m "refactor(invoicing): route watermark through one helper; add 0-byte guard parity"
```

---

## Task 6: Reopen-to-draft action (InvoiceDetailView)

**Files:**
- Modify: `App/Sources/Features/Invoicing/InvoiceDetailView.swift` (toolbar `Menu` ~69–99; add a confirm + handler)

- [ ] **Step 1: Add state for the confirm dialog**

In the `@State` block (~line 16) add:

```swift
    @State private var showingReopenConfirm = false
```

- [ ] **Step 2: Add the menu item for sent invoices**

In the toolbar `Menu` (inside the `if invoice.status == .sent { ... }` region, after the Send-reminder button ~line 88), add:

```swift
                        Button(role: .destructive) {
                            showingReopenConfirm = true
                        } label: {
                            Label("Reopen to draft", systemImage: "arrow.uturn.backward")
                        }
```

- [ ] **Step 3: Add the confirmation dialog + handler**

After the `.toolbar { }` modifier on the body, add:

```swift
        .confirmationDialog("Reopen \(invoice.number) to draft?",
                            isPresented: $showingReopenConfirm, titleVisibility: .visible) {
            Button("Reopen to draft", role: .destructive) { reopenToDraft() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its tracked time becomes uninvoiced again and any scheduled payment reminders are cancelled. The invoice number is kept; delete the draft if you don't need it.")
        }
```

And add the handler method (near `markPaid`):

```swift
    private func reopenToDraft() {
        guard invoice.status == .sent else { return }
        let invoiceUUID = invoice.uuid
        // 1) reverse the status
        do { try invoice.reopenToDraft() } catch { return }
        // 2) re-mark this invoice's source entries uninvoiced
        let descriptor = FetchDescriptor<TimeEntry>(
            predicate: #Predicate { $0.invoiceID == invoiceUUID }
        )
        let entries = (try? modelContext.fetch(descriptor)) ?? []
        for entry in entries { entry.invoiceID = nil; entry.updatedAt = .now }
        invoice.pdfDataCached = nil
        modelContext.saveOrLog("reopen invoice to draft")
        // 3) cancel scheduled reminders for this invoice
        Task { @MainActor in
            let service = ReminderService(center: UNUserNotificationCenter.current(), modelContext: modelContext)
            try? await service.cancelForInvoice(invoice)
        }
    }
```

(Confirm `ReminderService`'s initializer signature against `ReminderService.swift` and `BillableApp.swift:127`'s usage; adjust the `init` args only if they differ.)

- [ ] **Step 4: Build + manually verify**

Build (SUCCEEDED). Manual: open a sent invoice → ⋯ → Reopen to draft → confirm → it moves to Drafts, Today's UNINVOICED total increases by that invoice's amount, and its status banner reads Draft. A `.paid` invoice shows no Reopen option.

- [ ] **Step 5: Commit**

```bash
git add App/Sources/Features/Invoicing/InvoiceDetailView.swift
git commit -m "feat(invoicing): reopen-to-draft exit for a mistakenly-sent invoice"
```

---

## Task 7: Shared watermark upgrade banner on InvoiceDetailView

**Files:**
- Create: `App/Sources/Features/Invoicing/Components/WatermarkUpgradeBanner.swift`
- Modify: `InvoicePreviewView.swift` (replace the inline banner ~109–131), `InvoiceDetailView.swift` (add the banner + paywall sheet)

- [ ] **Step 1: Create the shared banner**

```swift
import SwiftUI

/// "This invoice has a watermark / Remove with Pro" upgrade nudge. Shared by the
/// pre-send preview and the (more-revisited) invoice detail screen so they can't drift.
struct WatermarkUpgradeBanner: View {
    let onTap: () -> Void
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("This invoice has a watermark.")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text("Remove watermark with Pro →").font(.caption).foregroundStyle(.tint)
                }
                Spacer()
            }
            .padding(12)
            .background(.orange.opacity(0.12), in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 2: Use it in InvoicePreviewView**

Replace the inline `if !subscriptions.canRemoveWatermark { Button { ... } ... }` block (lines ~109–131) with:

```swift
                    if !subscriptions.canRemoveWatermark {
                        WatermarkUpgradeBanner { showingRemoveWatermarkPaywall = true }
                            .padding(.horizontal)
                    }
```

- [ ] **Step 3: Add it to InvoiceDetailView**

Add state (~line 16): `@State private var showingRemoveWatermarkPaywall = false`

In the body `VStack` (after `statusBanner`, line ~56) add:

```swift
                if !subscriptions.canRemoveWatermark, invoice.status != .draft {
                    WatermarkUpgradeBanner { showingRemoveWatermarkPaywall = true }
                }
```

Add the paywall sheet alongside the other `.sheet`s (after line ~105):

```swift
        .sheet(isPresented: $showingRemoveWatermarkPaywall) {
            PaywallView(trigger: .removeWatermark)
        }
```

- [ ] **Step 4: Build + verify**

Build (SUCCEEDED). Manual: free user on a sent invoice sees the banner → tap opens the remove-watermark paywall; Pro user and drafts show no banner.

- [ ] **Step 5: Commit**

```bash
git add App/Sources/Features/Invoicing/Components/WatermarkUpgradeBanner.swift App/Sources/Features/Invoicing/InvoicePreviewView.swift App/Sources/Features/Invoicing/InvoiceDetailView.swift
git commit -m "feat(invoicing): surface watermark upgrade nudge on invoice detail"
```

---

## Task 8: De-duplicate InvoiceDetail delivery actions; surface Send reminder

**Files:**
- Modify: `InvoiceDetailView.swift` (`actionButtons` ~322–355; toolbar `Menu` ~69–99)

Decision: **Mark as paid** stays the single prominent body action. Share/Email move to the ⋯ menu only. **Send reminder** is promoted to sit beside Email in the menu (not gated behind the past-due banner).

- [ ] **Step 1: Slim `actionButtons` to Mark-as-paid only**

Replace `actionButtons` (lines ~321–355) with:

```swift
    @ViewBuilder
    private var actionButtons: some View {
        if invoice.status == .sent {
            Button { markPaid() } label: {
                Label("Mark as paid", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
        }
    }
```

- [ ] **Step 2: Ensure the ⋯ menu carries Share + Email + Send reminder**

The toolbar `Menu` (lines ~69–99) already has Share PDF, Email invoice (non-draft), Send reminder email (sent). Leave those — they are now the single home for delivery actions. (Send reminder already appears for `.sent`; this satisfies "parity with Email".) No change needed beyond Step 1 removing the body duplicates.

- [ ] **Step 3: Build + verify**

Build (SUCCEEDED). Manual: a sent invoice shows one prominent "Mark as paid"; Share/Email/Send-reminder all live in ⋯; nothing is duplicated.

- [ ] **Step 4: Commit**

```bash
git add App/Sources/Features/Invoicing/InvoiceDetailView.swift
git commit -m "refactor(invoicing): one home for invoice delivery actions; Mark-as-paid stays primary"
```

---

## Task 9: Deletion guard — protect time behind issued invoices

**Files:**
- Modify: `ClientsView.swift` (client delete confirm ~110–145, swipe ~171–185), `ClientDetailView.swift` (project delete ~115–130)

- [ ] **Step 1: Add guard state + alert to ClientsView**

Add state near `deletionCandidate`:

```swift
    @State private var blockedDeleteName: String?   // non-nil shows the "archive instead" alert
```

In the delete swipe button (line ~172–176) replace the action with a guarded one:

```swift
                        Button(role: .destructive) {
                            if client.hasInvoicedTime {
                                blockedDeleteName = client.name
                            } else {
                                deletionCandidate = client
                            }
                        } label: { Label("Delete", systemImage: "trash") }
```

Add the alert (after the existing delete `confirmationDialog`, ~line 126):

```swift
        .alert("Can't delete — billing records",
               isPresented: Binding(get: { blockedDeleteName != nil },
                                    set: { if !$0 { blockedDeleteName = nil } })) {
            Button("Cancel", role: .cancel) { blockedDeleteName = nil }
        } message: {
            Text("\(blockedDeleteName ?? "This client") has time on sent or paid invoices. Archive it instead to keep your billing records.")
        }
```

- [ ] **Step 2: Guard the project delete in ClientDetailView**

Wrap the existing `deletionCandidate = project` trigger (line ~62) so a protected project shows the same alert. Add state `@State private var blockedDeleteName: String?`, change the trigger to:

```swift
                                if project.hasInvoicedTime {
                                    blockedDeleteName = project.name
                                } else {
                                    deletionCandidate = project
                                }
```

and add the same `.alert(...)` as Step 1 (message uses "project").

- [ ] **Step 3: Build + run helper tests + verify**

Build (SUCCEEDED); `swift test --filter HasInvoicedTime` still passes. Manual: a client/project with a sent invoice → Delete → "Can't delete — billing records" with Archive/Cancel; Archive preserves it; an unprotected client/project deletes via the existing dialog.

- [ ] **Step 4: Commit**

```bash
git add App/Sources/Features/Clients/ClientsView.swift App/Sources/Features/Clients/ClientDetailView.swift
git commit -m "feat(clients): block deleting clients/projects with invoiced time; steer to Archive"
```

---

## Task 10: Archive/delete proportionality (ClientsView swipe)

**Files:**
- Modify: `ClientsView.swift` (active-client swipe ~171–185)

Keep Archive low-friction (it's recoverable) but make sure Delete — now also guarded — reads as the deliberate, destructive action. Minimal change: give Archive a confirmation only when it would hide an active client with tracked time, and keep Delete's existing dialog. (If the team prefers, instead reorder the swipe so Archive is the *default* full-swipe; this step keeps it simple.)

- [ ] **Step 1: Confirm Archive when the client has any tracked time**

Replace the Archive swipe button (lines ~177–184) with:

```swift
                        Button {
                            archiveCandidate = client
                        } label: { Label("Archive", systemImage: "archivebox") }
                        .tint(.gray)
```

Add state `@State private var archiveCandidate: Client?` and a lightweight confirm:

```swift
        .confirmationDialog("Archive \(archiveCandidate?.name ?? "client")?",
                            isPresented: Binding(get: { archiveCandidate != nil },
                                                 set: { if !$0 { archiveCandidate = nil } }),
                            titleVisibility: .visible) {
            Button("Archive") {
                if let c = archiveCandidate { c.isArchived = true; c.updatedAt = .now; modelContext.saveOrLog("archive client") }
                archiveCandidate = nil
            }
            Button("Cancel", role: .cancel) { archiveCandidate = nil }
        } message: { Text("Archived clients move to the Archived section. You can restore them anytime.") }
```

- [ ] **Step 2: Build + verify**

Build (SUCCEEDED). Manual: Archive now asks for a quick confirm (so an accidental swipe doesn't silently hide a client); Restore still works from the Archived section.

- [ ] **Step 3: Commit**

```bash
git add App/Sources/Features/Clients/ClientsView.swift
git commit -m "fix(clients): confirm Archive so an accidental swipe can't silently hide a client"
```

---

## Task 11: Rename invoice filter Outstanding→Unpaid; float overdue

**Files:**
- Modify: `InvoicesView.swift` (`Filter` ~11–21, `filteredInvoices` ~129–140)

- [ ] **Step 1: Rename the case label (keep the raw value stable)**

Change the `.outstanding` label (line ~15) to `"Unpaid"`:

```swift
            case .outstanding: "Unpaid"
```

(Leave the enum case name `outstanding` to avoid churn; only the user-facing label changes. Optionally rename to `unpaid` with a find/replace across this file if preferred — but keep `@State filter = .outstanding` default working.)

- [ ] **Step 2: Float overdue to the top within Unpaid**

Replace the `.outstanding` branch of `filteredInvoices` (lines ~131–132) with a sort that puts overdue first:

```swift
        case .outstanding:
            return invoices
                .filter { $0.status == .sent }
                .sorted { lhs, rhs in
                    if lhs.isOverdue() != rhs.isOverdue() { return lhs.isOverdue() }  // overdue first
                    return lhs.issuedAt > rhs.issuedAt                                 // then newest
                }
```

(Confirm `Invoice.isOverdue()` exists and is callable here — it backs the OVERDUE pill in `InvoiceRow`/`StatusPill`. If it takes a date arg, pass `.now`.)

- [ ] **Step 3: Build + verify**

Build (SUCCEEDED). Manual: the first segment now reads "Unpaid"; overdue invoices sort to the top with their existing red OVERDUE pill; Paid/Drafts/Recurring unchanged.

- [ ] **Step 4: Commit**

```bash
git add App/Sources/Features/Invoicing/InvoicesView.swift
git commit -m "fix(invoicing): rename Outstanding->Unpaid; float overdue to top"
```

---

## Final verification

- [ ] Full build: `xcodebuild ... build` → BUILD SUCCEEDED.
- [ ] Package tests: `cd Packages/BillableCore && swift test` → all pass (incl. the 3 new test files).
- [ ] Grep guard: `grep -rn '"Sent with Cadence"' App Packages` → only the `watermarkText` definition in `InvoiceTemplate.swift`.
- [ ] Manual smoke of the core loop: track → generate invoice → cancel send (stays draft, uninvoiced intact) → send (Unpaid) → reopen (back to draft, uninvoiced restored, reminders cancelled) → delete draft. Delete a client with a paid invoice → blocked, Archive offered.
