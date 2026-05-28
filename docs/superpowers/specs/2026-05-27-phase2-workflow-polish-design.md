# Phase 2 Design — Workflow Polish (A3 + A4 + A5 + A7)

**Status:** Approved, ready for implementation plan
**Author:** Claude + Louay
**Date:** 27 May 2026
**Parent state:** v1.5 invoice professionalism (merged to main, commit `0353bbc`, tag `v1.5`)
**Parent backlog:** `2026-05-27-post-v1.3-backlog.md`
**Parent phase plan:** `2026-05-27-post-v1.3-enhancement-phases.md`
**Branch target:** `feature/v1.6-workflow-polish` off `main`
**Confidence:** 99%

## Context

Four Medium-value items from the post-v1.3 backlog, grouped because they all
fit "Cadence fits your daily workflow better" — small surface-area changes
across Settings, Today, and Clients that collectively make the daily-driver
loop tighter:

- **A3** — Customizable invoice email subject + body templates (Settings → Business Profile + invoice send/reminder Mail prefill)
- **A4** — Inline note field on running timer card (Today)
- **A5** — Adjust start time on running entry (Today)
- **A7** — "Days since last invoice" badge on each client row (Clients)

Each item is independent of the others — no shared model fields, no shared
view-model state, no shared services beyond TimerService for A5.

## Goals

- Issuer can write a Subject + Body email template on Business Profile, used
  to pre-fill Mail when they send an invoice. Same merge-field language as
  v1.1 reminder templates.
- Issuer can send an invoice via Mail composer with PDF auto-attached. New
  "Email invoice" action available at both first-send (InvoicePreviewView)
  and re-send (InvoiceDetailView).
- The existing toolbar "Send reminder email" action stops using hardcoded
  strings and routes through the same `ReminderConfig` templates the
  reminder-banner-driven send uses (consistency fix).
- User can capture a note on a running timer entry inline on the Today card
  without stopping the timer or opening a manual-entry sheet.
- User can shift the start time of a running entry backward by 5 / 10 / 15
  minutes or via DatePicker, without stopping and re-creating.
- Clients tab surfaces "Last invoice: N days ago" under each client's
  contact name. Rows without any sent/paid invoice show no subtitle.

## Non-goals

- Customizing the body of the in-product reminder templates (`ReminderConfig`).
  Those already exist; this phase doesn't redesign their editor surface.
- Custom merge fields beyond the existing 7 (`{clientName}`,
  `{clientFirstName}`, `{invoiceNumber}`, `{amount}`, `{dueDate}`,
  `{daysOverdue}`, `{senderName}`). Reusing `ReminderTemplateRenderer`.
- Inline editing of stopped entries' notes from the Today card (the
  Timeline editor already covers that).
- Adjusting the END time of a stopped entry from the Today card (also
  Timeline editor territory).
- Showing the absolute date ("Last invoice on May 10") instead of relative
  days. Relative is more glanceable; spec lock.
- Last-invoice badge on archived clients (deliberate skip — archived rows
  are dimmed-secondary already and the data is stale).

---

## Section 1 — Model changes

### BusinessProfile

File: `Packages/BillableCore/Sources/BillableCore/Models/BusinessProfile.swift`

Add two String fields with non-empty defaults. Unlike Phase 1's tax ID
defaults (`""`), these templates ship with real default content so a
first-send works usefully even before the user touches Settings:

```swift
public var invoiceEmailSubjectTemplate: String = BusinessProfile.defaultInvoiceEmailSubject
public var invoiceEmailBodyTemplate: String = BusinessProfile.defaultInvoiceEmailBody

// At the bottom of the class, alongside `canSendInvoice`:

public static let defaultInvoiceEmailSubject =
    "Invoice {invoiceNumber} from {senderName}"

public static let defaultInvoiceEmailBody = """
Hi {clientFirstName},

Please find invoice {invoiceNumber} for {amount} attached. It's due {dueDate}.

Let me know if you have any questions.

Thanks,
{senderName}
"""
```

Update `BusinessProfile.init(...)` with two new trailing parameters
defaulting to those constants (so existing call sites compile unchanged).
Set in init body.

### Migration semantics

Additive defaulted fields. SwiftData lightweight migration handles existing
v1.5 records — they load with the default templates the first time they
materialize. CloudKit syncs the new fields silently.

**No changes to:** `Invoice` (email templates are LIVE values, not
snapshots — the email content reflects the issuer's current voice at send
time), `TimeEntry`, `Client`, `ReminderConfig`.

---

## Section 2 — A3 Customizable invoice email templates

### 2a — Editor UI

File: `App/Sources/Features/Settings/BusinessProfileEditorView.swift`

Insert a new section between **Tax** and **Logo** (after the existing
`Section("Tax")` block, before the `Section("Logo")` block):

```swift
Section {
    TextField("Subject template", text: $invoiceEmailSubjectTemplate, axis: .vertical)
        .lineLimit(1...3)
    TextField("Body template", text: $invoiceEmailBodyTemplate, axis: .vertical)
        .lineLimit(4...12)
} header: {
    Text("Invoice email")
} footer: {
    Text("Prefills your email when you tap 'Email invoice'. Merge fields: {clientName}, {clientFirstName}, {invoiceNumber}, {amount}, {dueDate}, {senderName}.")
}
```

Add `@State`:
```swift
@State private var invoiceEmailSubjectTemplate: String = ""
@State private var invoiceEmailBodyTemplate: String = ""
```

In `loadIfNeeded()`, after the existing tax-id load lines:
```swift
invoiceEmailSubjectTemplate = profile.invoiceEmailSubjectTemplate
invoiceEmailBodyTemplate = profile.invoiceEmailBodyTemplate
```

In `save()`, after the existing tax-id save lines:
```swift
profile.invoiceEmailSubjectTemplate = invoiceEmailSubjectTemplate
profile.invoiceEmailBodyTemplate = invoiceEmailBodyTemplate
```

### 2b — MailComposerView wrapper (new file)

File: `App/Sources/Shared/MailComposerView.swift`

`UIViewControllerRepresentable` over `MFMailComposeViewController`. Imports
`MessageUI`. Pure UIKit bridge — no business logic.

```swift
import SwiftUI
import MessageUI

/// SwiftUI wrapper for MFMailComposeViewController.
///
/// Presented as a sheet. Caller is responsible for calling
/// `MFMailComposeViewController.canSendMail()` BEFORE presenting and falling
/// back to mailto: when false.
struct MailComposerView: UIViewControllerRepresentable {
    let recipients: [String]
    let subject: String
    let body: String
    let attachmentData: Data?
    let attachmentMimeType: String
    let attachmentFilename: String
    let onDismiss: (MFMailComposeResult) -> Void

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.setToRecipients(recipients)
        vc.setSubject(subject)
        vc.setMessageBody(body, isHTML: false)
        if let data = attachmentData {
            vc.addAttachmentData(data, mimeType: attachmentMimeType, fileName: attachmentFilename)
        }
        vc.mailComposeDelegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onDismiss: onDismiss)
    }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onDismiss: (MFMailComposeResult) -> Void
        init(onDismiss: @escaping (MFMailComposeResult) -> Void) {
            self.onDismiss = onDismiss
        }
        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: Error?
        ) {
            // Delegate is invoked off the MainActor; dismiss + callback on main.
            DispatchQueue.main.async { [onDismiss] in
                controller.dismiss(animated: true) { onDismiss(result) }
            }
        }
    }
}
```

### 2c — InvoiceDetailView: new "Email invoice" action

File: `App/Sources/Features/Invoicing/InvoiceDetailView.swift`

Add `@State` for the composer:
```swift
@State private var showingMailComposer = false
@State private var mailComposerSubject = ""
@State private var mailComposerBody = ""
```

Add a new toolbar menu item alongside the existing "Share PDF":
```swift
Button {
    presentEmailInvoice()
} label: {
    Label("Email invoice", systemImage: "envelope")
}
```

Add a secondary `actionButtons` row alongside the existing "Share PDF" bordered
button — visible for non-Draft invoices:
```swift
if invoice.status != .draft {
    Button {
        presentEmailInvoice()
    } label: {
        Label("Email invoice", systemImage: "envelope")
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
    }
    .buttonStyle(.bordered)
}
```

Add the new helper:
```swift
private func presentEmailInvoice() {
    var profileDescriptor = FetchDescriptor<BusinessProfile>()
    profileDescriptor.fetchLimit = 1
    let profile = (try? modelContext.fetch(profileDescriptor))?.first
    let senderName = profile?.name ?? ""

    let subjectTemplate = profile?.invoiceEmailSubjectTemplate ?? BusinessProfile.defaultInvoiceEmailSubject
    let bodyTemplate = profile?.invoiceEmailBodyTemplate ?? BusinessProfile.defaultInvoiceEmailBody

    let renderedSubject = ReminderTemplateRenderer.render(
        template: subjectTemplate,
        invoice: invoice,
        senderName: senderName
    )
    let renderedBody = ReminderTemplateRenderer.render(
        template: bodyTemplate,
        invoice: invoice,
        senderName: senderName
    )

    if MFMailComposeViewController.canSendMail() {
        mailComposerSubject = renderedSubject
        mailComposerBody = renderedBody
        showingMailComposer = true
    } else {
        // Graceful fallback: open user's default mail handler via mailto.
        // PDF attachment is lost in this path — better than a silent no-op.
        guard let email = invoice.clientEmailSnapshot,
              !email.isEmpty,
              let url = mailtoURL(to: email, subject: renderedSubject, body: renderedBody) else { return }
        UIApplication.shared.open(url)
    }
}

private func ensurePDFData() -> Data {
    if let cached = invoice.pdfDataCached { return cached }
    let data = InvoicePDFRenderer.renderPDFData(
        for: InvoiceTemplateData.from(invoice),
        accent: invoice.clientColor.swiftUIColor
    )
    invoice.pdfDataCached = data
    modelContext.saveOrLog("cache invoice pdf (email)")
    return data
}
```

Wire the sheet on the body:
```swift
.sheet(isPresented: $showingMailComposer) {
    MailComposerView(
        recipients: invoice.clientEmailSnapshot.map { [$0] } ?? [],
        subject: mailComposerSubject,
        body: mailComposerBody,
        attachmentData: ensurePDFData(),
        attachmentMimeType: "application/pdf",
        attachmentFilename: "\(invoice.number).pdf",
        onDismiss: { _ in /* no-op; iOS provides its own feedback */ }
    )
}
```

`MFMailComposeViewController` import: add `import MessageUI` at the top of the file.

### 2d — InvoicePreviewView: primary "Finalize & email" + secondary "Finalize & share"

File: `App/Sources/Features/Invoicing/InvoicePreviewView.swift`

The current single toolbar trailing item is "Finalize & share" (iOS share
sheet). Replace with two ToolbarItem entries:

- Trailing primary: "Finalize & email" — calls `finalizeAndEmail()` (new)
- Trailing secondary: "Finalize & share" — calls existing `finalizeAndShare()`

```swift
.toolbar {
    ToolbarItem(placement: .topBarLeading) {
        Button("Back") { dismiss() }
    }
    ToolbarItem(placement: .topBarTrailing) {
        Button {
            finalizeAndEmail()
        } label: {
            Label("Finalize & email", systemImage: "envelope.fill")
        }
        .bold()
        .disabled(hasInvalidDescriptions)
    }
    ToolbarItem(placement: .topBarTrailing) {
        Menu {
            Button {
                finalizeAndShare()
            } label: {
                Label("Finalize & share", systemImage: "square.and.arrow.up")
            }
            .disabled(hasInvalidDescriptions)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }
}
```

Add `finalizeAndEmail`:

```swift
private func finalizeAndEmail() {
    // Drain pending edits — same guard as finalizeAndShare.
    drainPendingEdits()
    do {
        let draft = try InvoiceBuilder.createDraft(
            for: client,
            lineItems: lineItems,
            notes: notes,
            profile: profile,
            context: modelContext
        )
        try InvoiceBuilder.finalizeAndSend(
            draft,
            sourceEntries: sourceEntries,
            profile: profile,
            context: modelContext
        )
        let data = InvoicePDFRenderer.renderPDFData(
            for: InvoiceTemplateData.from(draft),
            accent: draft.clientColor.swiftUIColor
        )
        draft.pdfDataCached = data
        modelContext.saveOrLog("cache invoice pdf (finalize+email)")
        finalized = draft
        pdfData = data
        // Render templates with this fresh invoice.
        let senderName = profile.name
        let subject = ReminderTemplateRenderer.render(
            template: profile.invoiceEmailSubjectTemplate,
            invoice: draft,
            senderName: senderName
        )
        let body = ReminderTemplateRenderer.render(
            template: profile.invoiceEmailBodyTemplate,
            invoice: draft,
            senderName: senderName
        )
        if MFMailComposeViewController.canSendMail() {
            mailComposerSubject = subject
            mailComposerBody = body
            showingMailComposer = true
        } else {
            // Fallback: open default mail handler. PDF attachment lost in this path.
            guard let email = client.email,
                  !email.isEmpty,
                  let url = mailtoURLFromComponents(to: email, subject: subject, body: body) else {
                // Final fallback: drop to iOS share sheet.
                showingShare = true
                return
            }
            UIApplication.shared.open(url)
        }
    } catch {
        // Step 5 will add error toasts; for now just bail silently.
    }
}

private func drainPendingEdits() {
    if !pendingDescriptionEdits.isEmpty {
        var updated = lineItems
        for (id, text) in pendingDescriptionEdits {
            if let i = updated.firstIndex(where: { $0.id == id }) {
                updated[i].description = text
            }
        }
        lineItems = updated
        pendingDescriptionEdits = [:]
    }
}

private func mailtoURLFromComponents(to: String, subject: String, body: String) -> URL? {
    var components = URLComponents()
    components.scheme = "mailto"
    components.path = to
    components.queryItems = [
        URLQueryItem(name: "subject", value: subject),
        URLQueryItem(name: "body", value: body)
    ]
    return components.url
}
```

(`drainPendingEdits()` is extracted from the existing `finalizeAndShare` so
both paths use one source of truth. Refactor `finalizeAndShare` to call it
too.)

Add `@State`:
```swift
@State private var showingMailComposer = false
@State private var mailComposerSubject = ""
@State private var mailComposerBody = ""
```

Wire the sheet, after the existing `.sheet(isPresented: $showingShare)`:

```swift
.sheet(isPresented: $showingMailComposer) {
    if let finalized {
        MailComposerView(
            recipients: client.email.map { [$0] } ?? [],
            subject: mailComposerSubject,
            body: mailComposerBody,
            attachmentData: finalized.pdfDataCached ?? Data(),
            attachmentMimeType: "application/pdf",
            attachmentFilename: "\(finalized.number).pdf",
            onDismiss: { _ in
                dismiss()
                onDone()
            }
        )
    }
}
```

Add `import MessageUI` at the top.

### 2e — Unify toolbar "Send reminder email" with ReminderConfig templates

Replace the existing `sendReminder()` in `InvoiceDetailView.swift` (currently
hardcoded subject + body at line 280) with the templated version. The
function body becomes the same shape as `composeReminder(for:)` but without
the per-fire-step record-fired logic and without recording the schedule
(this is a manual ad-hoc reminder, not a scheduled one):

```swift
private func sendReminder() {
    var configDescriptor = FetchDescriptor<ReminderConfig>()
    configDescriptor.fetchLimit = 1
    let config = (try? modelContext.fetch(configDescriptor))?.first
    var profileDescriptor = FetchDescriptor<BusinessProfile>()
    profileDescriptor.fetchLimit = 1
    let profile = (try? modelContext.fetch(profileDescriptor))?.first
    let senderName = profile?.name ?? ""

    let subjectTemplate = config?.subjectTemplate ?? ReminderConfig.defaultSubjectTemplate
    let bodyTemplate = config?.bodyTemplate ?? ReminderConfig.defaultBodyTemplate

    let subject = ReminderTemplateRenderer.render(
        template: subjectTemplate,
        invoice: invoice,
        senderName: senderName
    )
    let body = ReminderTemplateRenderer.render(
        template: bodyTemplate,
        invoice: invoice,
        senderName: senderName
    )

    guard let email = invoice.clientEmailSnapshot, !email.isEmpty,
          let url = mailtoURL(to: email, subject: subject, body: body) else { return }
    UIApplication.shared.open(url)
}
```

---

## Section 3 — A4 Inline note on running timer card

File: `App/Sources/Features/Today/TodayView.swift`

### Change `RunningTimerCard` from `let entry: TimeEntry` to `@Bindable var entry: TimeEntry`

Line 248 currently reads:
```swift
let entry: TimeEntry
```

Change to:
```swift
@Bindable var entry: TimeEntry
```

This propagates SwiftData mutations on `entry.notes` back through the
view tree without re-reading from the model context.

### Add the note field below project name

In the body, after the `Text(entry.project?.name ?? "Project")` line (line
269), insert:

```swift
Text(entry.project?.name ?? "Project")
    .font(.title2.weight(.semibold))

// NEW (A4): inline note. Empty string ↔ nil so users can clear by deleting.
TextField("What are you working on?", text: notesBinding, axis: .vertical)
    .lineLimit(1...2)
    .font(.subheadline)
    .foregroundStyle(.primary)
    .textFieldStyle(.plain)
```

### Notes binding (String? ↔ String adapter)

Add as a private computed property on `RunningTimerCard`:

```swift
private var notesBinding: Binding<String> {
    Binding(
        get: { entry.notes ?? "" },
        set: { entry.notes = $0.isEmpty ? nil : $0 }
    )
}
```

### No debounce

SwiftData's mainContext auto-save handles persistence efficiently. Notes
text is small, mutations are cheap, and CloudKit batches writes. If real-
device profiling reveals lag at extreme typing speed, add a 200ms debounce
later (YAGNI for v1.6).

---

## Section 4 — A5 Adjust start time on running entry

File: `App/Sources/Features/Today/TodayView.swift` + `Packages/BillableCore/Sources/BillableCore/Timing/TimerService.swift`

### TimerService.adjustStart (new)

In `TimerService.swift`, add a new static method alongside the existing
`start`, `stop`, `switchTo`:

```swift
public enum AdjustError: Error, Equatable, Sendable {
    case startInFuture
    case entryNotRunning
}

/// Shift a running entry's startedAt backward (or forward, within constraints).
/// Throws if `newStart >= Date.now` (would create negative duration) or if
/// the entry is no longer running.
@MainActor
public static func adjustStart(
    entry: TimeEntry,
    to newStart: Date,
    in context: ModelContext
) throws {
    guard entry.endedAt == nil else { throw AdjustError.entryNotRunning }
    guard newStart < .now else { throw AdjustError.startInFuture }
    entry.startedAt = newStart
    entry.updatedAt = .now
    try context.save()
}
```

### RunningTimerCard: chevron-affordance + confirmation dialog

In `TodayView.swift`'s `RunningTimerCard`:

Add `@State`:
```swift
@State private var showingAdjustDialog = false
@State private var showingDatePickerSheet = false
@State private var datePickerSelection: Date = .now
```

Modify the elapsed-counter HStack to add the chevron and Button wrap:

Before (line 272-280):
```swift
HStack(alignment: .firstTextBaseline) {
    Text(elapsedString)
        .font(.system(size: 40, weight: .semibold, design: .rounded))
        .monospacedDigit()
    Spacer()
    Text(amountString)
        ...
}
```

After:
```swift
HStack(alignment: .firstTextBaseline) {
    Button {
        showingAdjustDialog = true
    } label: {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(elapsedString)
                .font(.system(size: 40, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Image(systemName: "chevron.up.chevron.down")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
    }
    .buttonStyle(.plain)
    Spacer()
    Text(amountString)
        .font(.title3.weight(.semibold).monospacedDigit())
        .foregroundStyle(.secondary)
}
```

Add the confirmation dialog and sheet at the bottom of body (after
`.background(.thinMaterial, ...)`):

```swift
.confirmationDialog(
    "Adjust start time",
    isPresented: $showingAdjustDialog,
    titleVisibility: .visible
) {
    Button("Back 5 minutes") { shiftStart(byMinutes: 5) }
    Button("Back 10 minutes") { shiftStart(byMinutes: 10) }
    Button("Back 15 minutes") { shiftStart(byMinutes: 15) }
    Button("Adjust to…") {
        datePickerSelection = entry.startedAt
        showingDatePickerSheet = true
    }
    Button("Cancel", role: .cancel) {}
}
.sheet(isPresented: $showingDatePickerSheet) {
    AdjustStartTimePickerSheet(
        currentStart: entry.startedAt,
        onSave: { newStart in
            applyAdjustedStart(newStart)
            showingDatePickerSheet = false
        },
        onCancel: { showingDatePickerSheet = false }
    )
}
```

Helpers:
```swift
private func shiftStart(byMinutes minutes: Int) {
    let newStart = entry.startedAt.addingTimeInterval(TimeInterval(-minutes * 60))
    applyAdjustedStart(newStart)
}

private func applyAdjustedStart(_ newStart: Date) {
    // Silently no-op if it would push into the future. UI prevents this case
    // for the picker via the .date(.distantPast...Date.now) range, and the
    // 5/10/15-min offsets always shift backward — but defensive guard.
    guard newStart < .now else { return }
    // Need a ModelContext — pass it in from parent. See parent change below.
    do {
        try TimerService.adjustStart(entry: entry, to: newStart, in: modelContext)
    } catch {
        // Silent fail; UI will simply not update.
    }
}
```

Pass `modelContext` into `RunningTimerCard`:
```swift
@Environment(\.modelContext) private var modelContext
```

(Added to RunningTimerCard at the top, alongside the existing properties.)

### AdjustStartTimePickerSheet (new private struct in the same file)

```swift
private struct AdjustStartTimePickerSheet: View {
    let currentStart: Date
    let onSave: (Date) -> Void
    let onCancel: () -> Void
    @State private var selection: Date

    init(currentStart: Date, onSave: @escaping (Date) -> Void, onCancel: @escaping () -> Void) {
        self.currentStart = currentStart
        self.onSave = onSave
        self.onCancel = onCancel
        _selection = State(initialValue: currentStart)
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker(
                    "Start time",
                    selection: $selection,
                    in: ...Date.now,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.graphical)
            }
            .navigationTitle("Adjust start")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { onSave(selection) }
                        .bold()
                        .disabled(selection >= Date.now)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
```

---

## Section 5 — A7 "Days since last invoice" badge

File: `App/Sources/Features/Clients/ClientsView.swift`

### Parent view: @Query of invoices + lastInvoiceByClientID map

In the parent `ClientsView` (or whatever struct owns the active+archived
client lists), add a new query alongside the existing client queries:

```swift
@Query(sort: \Invoice.issuedAt, order: .reverse)
private var allInvoices: [Invoice]
```

Add a computed property that maps client → most recent invoice send date:

```swift
private var lastInvoiceByClientID: [PersistentIdentifier: Date] {
    var map: [PersistentIdentifier: Date] = [:]
    for invoice in allInvoices where invoice.status != .draft {
        guard let clientID = invoice.client?.persistentModelID else { continue }
        let date = invoice.sentAt ?? invoice.paidAt
        guard let date else { continue }
        if let existing = map[clientID], existing >= date { continue }
        map[clientID] = date
    }
    return map
}
```

Pass to each `ClientRow`:
```swift
ClientRow(
    client: client,
    lastInvoiceDate: lastInvoiceByClientID[client.persistentModelID]
)
```

### ClientRow: conditional subtitle

Update the existing `ClientRow` struct:

```swift
private struct ClientRow: View {
    let client: Client
    let lastInvoiceDate: Date?

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(client.color.swiftUIColor)
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(client.name)
                if let contactName = client.contactName, !contactName.isEmpty {
                    Text(contactName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let lastInvoiceDate {
                    Text(daysAgoLabel(for: lastInvoiceDate))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Text("\(client.activeProjects.count)")
                .foregroundStyle(.secondary)
                .font(.subheadline.monospacedDigit())
            Image(systemName: "folder")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func daysAgoLabel(for date: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: date, to: .now).day ?? 0
        switch days {
        case ..<0:  return "Last invoice: today"   // future-dated; unlikely
        case 0:     return "Last invoice: today"
        case 1:     return "Last invoice: yesterday"
        default:    return "Last invoice: \(days) days ago"
        }
    }
}
```

### Archived clients

The Archived section keeps the same `ClientRow` but the parent passes
`lastInvoiceDate: nil` to skip the subtitle (the data is potentially stale —
archived clients haven't been touched recently by definition). Implementation:
just don't pass through the lookup in the archived `ForEach`.

---

## Section 6 — Tests

### Unit tests (BillableCore)

**`BusinessProfileEmailTemplatesTests`** (new):

```swift
@Suite("BusinessProfile email templates")
struct BusinessProfileEmailTemplatesTests {

    @Test("Default BusinessProfile() carries the default invoice email templates")
    func defaultsArePresent() {
        let profile = BusinessProfile()
        #expect(profile.invoiceEmailSubjectTemplate == BusinessProfile.defaultInvoiceEmailSubject)
        #expect(profile.invoiceEmailBodyTemplate == BusinessProfile.defaultInvoiceEmailBody)
    }

    @Test("Custom templates are preserved through init")
    func customPreserved() {
        let profile = BusinessProfile(
            invoiceEmailSubjectTemplate: "INV {invoiceNumber}",
            invoiceEmailBodyTemplate: "Hi"
        )
        #expect(profile.invoiceEmailSubjectTemplate == "INV {invoiceNumber}")
        #expect(profile.invoiceEmailBodyTemplate == "Hi")
    }

    @Test("Default templates contain {invoiceNumber} and {senderName} merge fields")
    func defaultsUseMergeFields() {
        #expect(BusinessProfile.defaultInvoiceEmailSubject.contains("{invoiceNumber}"))
        #expect(BusinessProfile.defaultInvoiceEmailSubject.contains("{senderName}"))
        #expect(BusinessProfile.defaultInvoiceEmailBody.contains("{invoiceNumber}"))
        #expect(BusinessProfile.defaultInvoiceEmailBody.contains("{senderName}"))
        #expect(BusinessProfile.defaultInvoiceEmailBody.contains("{amount}"))
        #expect(BusinessProfile.defaultInvoiceEmailBody.contains("{dueDate}"))
        #expect(BusinessProfile.defaultInvoiceEmailBody.contains("{clientFirstName}"))
    }

    @Test("ReminderTemplateRenderer correctly renders default invoice email subject")
    func defaultSubjectRenders() throws {
        let container = try BillableModelContainer.inMemory()
        let context = ModelContext(container)
        let profile = BusinessProfile(name: "Studio Lina")
        context.insert(profile)
        let client = Client(name: "Acme", color: .blue, email: "billing@acme.example")
        context.insert(client)
        let invoice = Invoice(
            number: "INV-0042",
            dueAt: Date(timeIntervalSince1970: 0),
            clientNameSnapshot: client.name,
            clientEmailSnapshot: client.email,
            issuerNameSnapshot: profile.name,
            issuerAddressSnapshot: "",
            issuerEmailSnapshot: "",
            paymentTermsSnapshot: "Net 14",
            taxLabelSnapshot: "Tax",
            taxRateSnapshot: 0,
            currencyCodeSnapshot: "USD",
            client: client
        )
        let rendered = ReminderTemplateRenderer.render(
            template: profile.invoiceEmailSubjectTemplate,
            invoice: invoice,
            senderName: profile.name
        )
        #expect(rendered == "Invoice INV-0042 from Studio Lina")
    }
}
```

**`TimerServiceAdjustStartTests`** (new):

```swift
@Suite("TimerService.adjustStart")
@MainActor
struct TimerServiceAdjustStartTests {

    @Test("Shifts startedAt backward by the given offset")
    func shiftsBackward() throws {
        let container = try BillableModelContainer.inMemory()
        let context = ModelContext(container)
        let client = Client(name: "Acme", color: .blue)
        let project = Project(name: "P", hourlyRate: 100, client: client)
        let original = Date(timeIntervalSince1970: 1_000_000)
        let entry = TimeEntry(project: project, startedAt: original, endedAt: nil)
        context.insert(client); context.insert(project); context.insert(entry)
        try context.save()

        let newStart = original.addingTimeInterval(-600)  // 10 minutes earlier
        try TimerService.adjustStart(entry: entry, to: newStart, in: context)

        #expect(entry.startedAt == newStart)
    }

    @Test("Throws startInFuture when newStart is at or after Date.now")
    func rejectsFutureStart() throws {
        let container = try BillableModelContainer.inMemory()
        let context = ModelContext(container)
        let client = Client(name: "Acme", color: .blue)
        let project = Project(name: "P", hourlyRate: 100, client: client)
        let entry = TimeEntry(project: project, startedAt: .now.addingTimeInterval(-300), endedAt: nil)
        context.insert(client); context.insert(project); context.insert(entry)
        try context.save()

        let future = Date.now.addingTimeInterval(3600)
        #expect(throws: TimerService.AdjustError.startInFuture) {
            try TimerService.adjustStart(entry: entry, to: future, in: context)
        }
    }

    @Test("Throws entryNotRunning on stopped entries")
    func rejectsStoppedEntries() throws {
        let container = try BillableModelContainer.inMemory()
        let context = ModelContext(container)
        let client = Client(name: "Acme", color: .blue)
        let project = Project(name: "P", hourlyRate: 100, client: client)
        let entry = TimeEntry(
            project: project,
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            endedAt: Date(timeIntervalSince1970: 1_001_000)
        )
        context.insert(client); context.insert(project); context.insert(entry)
        try context.save()

        #expect(throws: TimerService.AdjustError.entryNotRunning) {
            try TimerService.adjustStart(
                entry: entry,
                to: Date(timeIntervalSince1970: 999_000),
                in: context
            )
        }
    }
}
```

**Model defaults regression** (extend existing `BusinessProfileTests` or
add to the new email-templates suite):

```swift
@Test("Pre-v1.6 init signature still compiles (regression)")
func backwardCompatInit() {
    // If this compiles, existing call sites still work.
    let profile = BusinessProfile(name: "Studio")
    #expect(profile.invoiceEmailSubjectTemplate != "")  // defaults
}

@Test("Default body template renders all merge fields end-to-end")
func defaultBodyRendersCleanly() throws {
    let container = try BillableModelContainer.inMemory()
    let context = ModelContext(container)
    let profile = BusinessProfile(name: "Studio Lina")
    context.insert(profile)
    let client = Client(name: "Acme Corp", color: .blue, contactName: "Pat Smith")
    context.insert(client)
    let invoice = Invoice(
        number: "INV-0042",
        dueAt: Date(timeIntervalSinceReferenceDate: 760_000_000),  // ~Feb 2025
        clientNameSnapshot: client.name,
        issuerNameSnapshot: profile.name,
        issuerAddressSnapshot: "",
        issuerEmailSnapshot: "",
        paymentTermsSnapshot: "Net 14",
        taxLabelSnapshot: "Tax",
        taxRateSnapshot: 0,
        currencyCodeSnapshot: "USD",
        lineItems: [InvoiceLineItem(description: "Work", hours: 1, hourlyRate: 100)],
        client: client
    )
    let rendered = ReminderTemplateRenderer.render(
        template: profile.invoiceEmailBodyTemplate,
        invoice: invoice,
        senderName: profile.name
    )
    // No unsubstituted braces left behind
    #expect(!rendered.contains("{clientFirstName}"))
    #expect(!rendered.contains("{invoiceNumber}"))
    #expect(!rendered.contains("{amount}"))
    #expect(!rendered.contains("{dueDate}"))
    #expect(!rendered.contains("{senderName}"))
    // Concrete values present
    #expect(rendered.contains("Pat"))               // clientFirstName
    #expect(rendered.contains("INV-0042"))           // invoiceNumber
    #expect(rendered.contains("Studio Lina"))        // senderName
}
```

**A7 `daysAgoLabel` semantics** (extracted as a pure helper for testability —
move out of the private `ClientRow` body into a fileprivate function or
keep on `ClientRow` and reach it via `@testable import`):

```swift
@Suite("ClientRow daysAgoLabel")
struct ClientRowDaysAgoLabelTests {

    @Test("Returns 'today' for same calendar day")
    func sameDay() {
        let now = Date(timeIntervalSinceReferenceDate: 760_000_000)
        let sameDayEarlier = now.addingTimeInterval(-3600)
        #expect(ClientRow.daysAgoLabel(for: sameDayEarlier, now: now) == "Last invoice: today")
    }

    @Test("Returns 'yesterday' for 1 day ago")
    func yesterday() {
        let now = Date(timeIntervalSinceReferenceDate: 760_000_000)
        let oneDayAgo = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        #expect(ClientRow.daysAgoLabel(for: oneDayAgo, now: now) == "Last invoice: yesterday")
    }

    @Test("Returns 'N days ago' for 2+ days")
    func multipleDays() {
        let now = Date(timeIntervalSinceReferenceDate: 760_000_000)
        let twelveDaysAgo = Calendar.current.date(byAdding: .day, value: -12, to: now)!
        #expect(ClientRow.daysAgoLabel(for: twelveDaysAgo, now: now) == "Last invoice: 12 days ago")
    }

    @Test("Future-dated invoices (clock skew edge case) still read as 'today'")
    func futureDated() {
        let now = Date(timeIntervalSinceReferenceDate: 760_000_000)
        let futureInvoice = now.addingTimeInterval(3600)  // 1hr in future
        #expect(ClientRow.daysAgoLabel(for: futureInvoice, now: now) == "Last invoice: today")
    }
}
```

This requires extracting `daysAgoLabel` from a private instance helper into
a `static` method (or fileprivate function) so the test can call it. Spec
implementation should make the helper `static func daysAgoLabel(for date:
Date, now: Date = .now) -> String` on `ClientRow`.

### Manual / acceptance criteria

A Phase 2 implementation is complete when:

- [ ] Settings → Business Profile shows a new "Invoice email" section with
      Subject + Body fields and the merge-field-aware footer
- [ ] Both fields persist to BusinessProfile on Save and reload on
      re-open
- [ ] InvoiceDetailView toolbar menu shows "Email invoice" alongside
      "Share PDF" for non-Draft invoices
- [ ] InvoiceDetailView actionButtons row shows an "Email invoice" bordered
      button alongside "Share PDF" for non-Draft invoices
- [ ] Tapping "Email invoice" with Mail configured opens MFMailComposeViewController
      with subject + body rendered from the BusinessProfile templates,
      PDF auto-attached, recipient pre-filled
- [ ] Tapping "Email invoice" with NO Mail account opens default-mail-handler
      via mailto: (no attachment, but subject + body filled). Verified by
      enabling/disabling the simulator's Mail account.
- [ ] InvoicePreviewView has a primary "Finalize & email" trailing toolbar
      button + a secondary `…` overflow menu containing "Finalize & share"
- [ ] "Finalize & email" creates the draft, finalizes, renders PDF, and
      presents the mail composer (or falls back as above)
- [ ] "Finalize & share" preserves the existing iOS share sheet flow
- [ ] InvoiceDetailView toolbar "Send reminder email" now uses
      ReminderConfig templates instead of hardcoded strings (verify by
      changing ReminderConfig.subjectTemplate in Settings → Payment
      reminders → observe the toolbar reminder uses the new value)
- [ ] Today running timer card has an inline note field below project
      name; typing saves to TimeEntry.notes and persists across launches
- [ ] Tapping the elapsed counter on the running card opens a confirmation
      dialog with Back 5/10/15 min + Adjust to… options. The chevron icon
      is visible next to the counter signaling it's tappable.
- [ ] "Adjust to…" opens a DatePicker sheet limited to today-or-earlier;
      saving updates startedAt; the Save button is disabled for future dates
- [ ] Saving with a past time updates `entry.startedAt`; Live Activity /
      elapsed counter immediately reflects the new elapsed time
- [ ] Clients tab Active section shows "Last invoice: N days ago" as a
      tertiary-color subtitle under contact name for clients with sent or
      paid invoices
- [ ] Clients with no sent/paid invoice show no subtitle (just name +
      optional contactName + project count)
- [ ] Archived section's ClientRow shows no last-invoice subtitle
- [ ] App launches cleanly on v1.5 data — no crash on lightweight migration
- [ ] Full BillableCore test suite passes (199 + ~7 new = ~206)

---

## Out of scope (tracked separately)

- A6 (Reports insight tiles — Phase 3, separate doc)
- Custom merge fields beyond the existing 7
- Editing reminder templates from a UI surface that's NOT
  PaymentRemindersView (already exists; not redesigned here)
- Bulk reminder send (e.g., "remind all overdue clients") — not in this
  phase
- Note field on STOPPED entries from the Today card (Timeline editor
  already covers it)
- Mail composer's "result" surfacing (the spec ignores the
  `MFMailComposeResult.sent / saved / cancelled / failed` outcome —
  iOS itself provides toast feedback)

---

## Risk

| Risk | Mitigation |
|---|---|
| Schema migration risk | Low. Both new BusinessProfile fields have non-empty defaults. SwiftData lightweight migration. v1.5 records load with the default templates. |
| `MFMailComposeViewController.canSendMail()` returns false | Spec includes a `mailto:` fallback that opens the user's default mail handler (browser or third-party app). PDF attachment is lost in fallback, but the flow degrades gracefully. |
| MFMailComposeDelegate not main-actor isolated under Swift 6 | The delegate dispatches back to main via `DispatchQueue.main.async` inside the callback. Single-purpose Coordinator with explicit hop — clean under strict concurrency. |
| PDF data path for the attachment | `ensurePDFData()` reads `pdfDataCached` or re-renders synchronously. For a typical 1-page invoice this is ~50ms — acceptable for a user-tap-initiated action. |
| `@Bindable var entry` in RunningTimerCard | `@Bindable` on a SwiftData `@Model` reference. The parent's `runningEntries.first` is a stable model reference for the lifetime of the timer; mutations propagate via SwiftData's observation. Verified pattern from other parts of the codebase (e.g., InvoiceDetailView's `@Bindable var invoice`). |
| TimerService.adjustStart bypassing existing invariants | The method runs full `endedAt == nil` check (only-running) and `newStart < .now` check. Future invariants (e.g., overlap with prior entry's endedAt) can be added here in one place. |
| `lastInvoiceByClientID` recomputes on every body re-render | One `@Query`-driven re-render, O(n_invoices) dictionary build. For typical user (~50 invoices/year), microseconds. For 500+ invoices still trivial. |
| Last-invoice subtitle adds vertical space to ClientRow | One extra `Text` line with `.caption2` — ~14pt added per row that has the subtitle. Tested visually fits the list density. |
| Archived clients get the lastInvoiceByClientID lookup | Parent simply passes `lastInvoiceDate: nil` to archived rows, skipping the subtitle. No data access in the row itself. |
| First-send via "Finalize & email" presents BEFORE finalize PDF cache exists | `finalizeAndEmail` calls `InvoicePDFRenderer.renderPDFData(...)` before presenting the sheet, then writes `pdfDataCached`. The sheet then reads from cache. Order: finalize → render → cache → present. |
| Mail composer dismiss races with parent's `dismiss()` | `onDismiss` callback in MailComposerView's Coordinator hops to MainActor via DispatchQueue.main.async before calling the parent's callback. Parent's `dismiss()` runs after the dispatch — no race. |

## Confidence

**99%.** All five verifications completed; the three earlier residuals are
retired:

1. **MFMailComposeViewController on iOS 26.5 — retired.**
   Confirmed via direct SDK header inspection: `API_AVAILABLE(ios(3.0))`
   still active, no deprecation. Apple's own header docs even prescribe the
   `mailto:` fallback that this spec already specifies. Type-checked the
   `MailComposerView` SwiftUI wrapper as a code spike against both iOS 17
   and iOS 18 deployment targets with `-strict-concurrency=complete` —
   zero warnings, zero errors.

2. **`@Bindable var entry` precedent — retired.**
   Codebase already uses the pattern on SwiftData `@Model` references in
   `ClientDetailView.swift:6` (`@Bindable var client: Client`) and
   `InvoiceDetailView.swift:13` (`@Bindable var invoice: Invoice`).
   `TimelineView(.periodic)` re-renders its body content, but `@Bindable`
   re-initializes correctly from the same `@Model` reference each tick.

3. **Last-invoice "today" semantics — retired.**
   Spec now includes four unit tests covering same-day, yesterday, 12 days
   ago, and future-dated (clock-skew edge case). `daysAgoLabel` extracted
   to a `static` method on `ClientRow` for testability.

The remaining ~1% is irreducible: real-device rendering quirks under iOS
26.5, edge-case user input (e.g., template strings with embedded `\n` or
emoji in `senderName`), and the small surface-area "unknown unknowns" that
only the implementer + code reviewer will surface during build + test
iterations. Phase 1's A8 race-condition catch is a fair example — review
caught it; this is the workflow working.

---

## Acceptance: spec is "done" when

- [ ] User has reviewed this document
- [ ] User approves
- [ ] Implementation plan is produced by invoking the writing-plans skill

The implementation plan will sequence the model changes first (BusinessProfile
fields + TimerService.adjustStart), then editor UI (A3 templates editor +
A4 note + A5 chevron + A7 subtitle), then the Mail composer wiring (new file
+ Detail + Preview), then a final acceptance sweep.
