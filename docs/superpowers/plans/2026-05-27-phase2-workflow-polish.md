# Phase 2 Workflow Polish — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship A3 (customizable invoice email templates + MFMailComposeViewController-backed send + reminder consistency fix), A4 (inline note on running timer card), A5 (adjust start time on running entry), and A7 (days-since-last-invoice badge on client rows) as a single coherent "workflow polish" release on top of v1.5.

**Architecture:** Additive only. Two `String` fields on `BusinessProfile` with non-empty default email templates. One new `TimerService.adjustStart` static method + `AdjustError` enum. One new `MailComposerView.swift` SwiftUI wrapper over `MFMailComposeViewController` with built-in `mailto:` fallback for accounts-not-configured. UI extensions across `BusinessProfileEditorView` (templates editor), `InvoiceDetailView` (Email invoice action + reminder unify), `InvoicePreviewView` (Finalize&email primary + Finalize&share overflow), `TodayView.RunningTimerCard` (notes binding + chevron-affordance + AdjustStartTimePickerSheet), and `ClientsView` (parent @Query + ClientRow subtitle). All schema changes are SwiftData lightweight migrations — existing v1.5 records load with the default templates and no migration code.

**Tech Stack:** Swift 6 · SwiftUI · SwiftData · MessageUI (`MFMailComposeViewController`) · Swift Testing (`@Suite` / `@Test` / `#expect`) · XCTest UI · Xcode 26 / iOS 26.5

**Spec:** `docs/superpowers/specs/2026-05-27-phase2-workflow-polish-design.md` (commit `39e98da`, confidence 99%)

**Parent state:** v1.5 invoice professionalism (merged to `main`, commit `0353bbc`, tag `v1.5`)

**Branch:** `feature/v1.6-workflow-polish` (worktree off `main`)

**Review pattern:** Mirror Phase 1 — full implementer + spec reviewer + code-quality reviewer on the four complex tasks (Tasks 1, 5, 6, 8). Implementer + spec reviewer only on mechanical tasks (Tasks 2, 3, 4, 7, 9). Tasks 0, 10, 11 are run inline (worktree setup, acceptance sweep, PR/merge).

**Precondition:** At the time of writing this plan, `main` has 3 uncommitted files with small Phase-1 polish edits (`BusinessProfileEditorView.swift`, `InvoicePreviewView.swift`, `App/BillableUITests/InvoicePreviewLineItemEditUITests.swift`). These are NOT Phase 2 work. Task 0 surfaces them: the implementer asks the user whether to (a) commit them to `main` first, (b) carry them along on the feature branch, or (c) stash them. Do not begin Task 1 until that decision is made.

---

## File Structure

### Created files

| Path | Responsibility |
|---|---|
| `App/Sources/Shared/MailComposerView.swift` | SwiftUI `UIViewControllerRepresentable` wrapper over `MFMailComposeViewController`. Pure UIKit bridge — no business logic, no fallback handling (caller responsibility). |
| `Packages/BillableCore/Tests/BillableCoreTests/BusinessProfileEmailTemplatesTests.swift` | Unit tests for the new `invoiceEmailSubjectTemplate` / `invoiceEmailBodyTemplate` fields + default-template merge-field correctness via `ReminderTemplateRenderer`. |
| `Packages/BillableCore/Tests/BillableCoreTests/TimerServiceAdjustStartTests.swift` | Unit tests for `TimerService.adjustStart` covering the happy path + `startInFuture` + `entryNotRunning` errors. |
| `Packages/BillableCore/Sources/BillableCore/Formatting/DaysAgoFormatter.swift` | New BillableCore namespace with a pure `string(for:prefix:now:calendar:)` function. Extracted from `ClientRow` so it's unit-testable without a SwiftUI view tree. Used by A7's row subtitle. |
| `Packages/BillableCore/Tests/BillableCoreTests/DaysAgoFormatterTests.swift` | Unit tests for `DaysAgoFormatter.string(for:prefix:now:)` covering today / yesterday / N days / future-dated edge cases. |

### Modified files

| Path | Why |
|---|---|
| `Packages/BillableCore/Sources/BillableCore/Models/BusinessProfile.swift` | Add `invoiceEmailSubjectTemplate` + `invoiceEmailBodyTemplate` fields with non-empty defaults. Two new init params. |
| `Packages/BillableCore/Sources/BillableCore/Timing/TimerService.swift` | Add `AdjustError` enum + `adjustStart(entry:to:in:)` static method alongside the existing `start/stop/switchTo/logCompletedEntry`. |
| `App/Sources/Features/Settings/BusinessProfileEditorView.swift` | Add "Invoice email" section between Tax and Logo with Subject + Body templates. |
| `App/Sources/Features/Invoicing/InvoiceDetailView.swift` | Add `presentEmailInvoice()` + `ensurePDFData()` helpers, new toolbar + actionButtons "Email invoice" entries, `showingMailComposer` sheet, refactor `sendReminder()` to use ReminderConfig templates (instead of hardcoded strings). |
| `App/Sources/Features/Invoicing/InvoicePreviewView.swift` | Split toolbar: primary "Finalize & email" + overflow menu containing "Finalize & share". Add `finalizeAndEmail()`, extract `drainPendingEdits()`, add `mailtoURLFromComponents` helper, `showingMailComposer` sheet. |
| `App/Sources/Features/Today/TodayView.swift` | A4: change `RunningTimerCard.entry` from `let` to `@Bindable var`, add note `TextField` below project name with `notesBinding` adapter. A5: add `@Environment(\.modelContext)`, wrap elapsed counter in tappable Button with chevron icon, add `confirmationDialog` + `AdjustStartTimePickerSheet` (new private struct in same file). |
| `App/Sources/Features/Clients/ClientsView.swift` | A7: add `@Query(sort: \Invoice.issuedAt, order: .reverse) allInvoices` + `lastInvoiceByClientID` computed map at parent. Pass per-row `lastInvoiceDate` into `ClientRow`. Extend `ClientRow` with the conditional subtitle. Extract `daysAgoLabel(for:now:)` as `static func` for testability. |

---

## Task 0: Worktree + branch setup

**Files:**
- No file changes. Sets up the isolated workspace + surfaces the precondition.

- [ ] **Step 1: Verify we're on `main`**

Run:
```bash
cd "/Users/lbazerbashi/Elden Studios/billable"
git rev-parse --abbrev-ref HEAD
```

Expected: `main`.

- [ ] **Step 2: Inspect uncommitted changes on main and surface to user**

Run:
```bash
git status --short
git diff --stat
```

Expected output (approximately):
```
 M App/BillableUITests/InvoicePreviewLineItemEditUITests.swift
 M App/Sources/Features/Invoicing/InvoicePreviewView.swift
 M App/Sources/Features/Settings/BusinessProfileEditorView.swift
?? .superpowers/
```

If you see ONLY these three files with `M` (`.superpowers/` is session metadata, ignored), STOP and ask the user how to handle them:
- (a) Commit them to `main` first with a `chore(phase1-polish): …` message
- (b) Carry them along on the feature branch (they'll show up in the worktree)
- (c) Stash them with `git stash push -u -m "phase1 polish — defer"`

If you see ANY OTHER uncommitted files, STOP and ask the user — they may be in-flight work.

If you see NO uncommitted files, proceed to Step 3.

- [ ] **Step 3: Pull latest main**

Run:
```bash
git fetch origin && git pull --ff-only origin main
```

Expected: "Already up to date." or a clean fast-forward.

- [ ] **Step 4: Create the worktree on a new branch**

Run:
```bash
git worktree add .worktrees/v1.6-workflow-polish -b feature/v1.6-workflow-polish
```

Expected: "Preparing worktree (new branch 'feature/v1.6-workflow-polish')" plus a "HEAD is now at <sha>".

- [ ] **Step 5: cd into the worktree for the rest of the plan**

Run:
```bash
cd ".worktrees/v1.6-workflow-polish"
git rev-parse --abbrev-ref HEAD
```

Expected: `feature/v1.6-workflow-polish`. All subsequent task steps run from this directory.

- [ ] **Step 6: Verify baseline tests pass before any change**

Run:
```bash
swift test --package-path Packages/BillableCore 2>&1 | tail -3
```

Expected: `Test run with 199 tests in 29 suites passed` (or similar — same count as main HEAD). All passing.

---

## Task 1: BusinessProfile email template fields (TDD)

**Files:**
- Create: `Packages/BillableCore/Tests/BillableCoreTests/BusinessProfileEmailTemplatesTests.swift`
- Modify: `Packages/BillableCore/Sources/BillableCore/Models/BusinessProfile.swift`

- [ ] **Step 1: Write the failing tests**

Create `Packages/BillableCore/Tests/BillableCoreTests/BusinessProfileEmailTemplatesTests.swift`:

```swift
import Foundation
import SwiftData
import Testing
@testable import BillableCore

@Suite("BusinessProfile email templates")
@MainActor
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

    @Test("Default body template renders all merge fields end-to-end with no unsubstituted braces")
    func defaultBodyRendersCleanly() throws {
        let container = try BillableModelContainer.inMemory()
        let context = ModelContext(container)
        let profile = BusinessProfile(name: "Studio Lina")
        context.insert(profile)
        let client = Client(name: "Acme Corp", color: .blue, contactName: "Pat Smith")
        context.insert(client)
        let invoice = Invoice(
            number: "INV-0042",
            dueAt: Date(timeIntervalSinceReferenceDate: 760_000_000),
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
}
```

- [ ] **Step 2: Run tests, verify they fail**

Run:
```bash
swift test --package-path Packages/BillableCore --filter BusinessProfileEmailTemplatesTests 2>&1 | tail -10
```

Expected: build error like `value of type 'BusinessProfile' has no member 'invoiceEmailSubjectTemplate'` (or similar). Tests don't compile yet.

- [ ] **Step 3: Add the fields and defaults to `BusinessProfile`**

Open `Packages/BillableCore/Sources/BillableCore/Models/BusinessProfile.swift`. Locate the `// MARK: - Tax ID (v1.5 / Phase 1)` block (around line 44-53). Insert a new block immediately AFTER the `hasTaxID` computed property and BEFORE the `createdAt` declaration:

```swift
    // MARK: - Invoice email templates (v1.6 / Phase 2)

    public var invoiceEmailSubjectTemplate: String = BusinessProfile.defaultInvoiceEmailSubject
    public var invoiceEmailBodyTemplate: String = BusinessProfile.defaultInvoiceEmailBody
```

- [ ] **Step 4: Add the default-template static constants at the bottom of the class**

In the same file, find the existing `public static func canSendInvoice(profile:)` static method (at the bottom of the class, before the closing `}` of `BusinessProfile`). Insert the two default-template constants immediately after `canSendInvoice` (still inside the class body):

```swift
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

- [ ] **Step 5: Extend the `init(...)` signature with two new trailing params**

In the same file, find the `public init(` block (around line 58). The current trailing params end with:
```swift
        taxIDNumber: String = "",
        createdAt: Date = .now,
        updatedAt: Date = .now
```

Insert two new params between `taxIDNumber` and `createdAt`:
```swift
        taxIDNumber: String = "",
        invoiceEmailSubjectTemplate: String = BusinessProfile.defaultInvoiceEmailSubject,
        invoiceEmailBodyTemplate: String = BusinessProfile.defaultInvoiceEmailBody,
        createdAt: Date = .now,
        updatedAt: Date = .now
```

Then in the init body, find the line `self.taxIDNumber = taxIDNumber` and insert the two corresponding assignments immediately after it:
```swift
        self.taxIDNumber = taxIDNumber
        self.invoiceEmailSubjectTemplate = invoiceEmailSubjectTemplate
        self.invoiceEmailBodyTemplate = invoiceEmailBodyTemplate
        self.createdAt = createdAt
```

- [ ] **Step 6: Run tests, verify they pass**

Run:
```bash
swift test --package-path Packages/BillableCore --filter BusinessProfileEmailTemplatesTests 2>&1 | tail -10
```

Expected: `Test Suite 'BusinessProfile email templates' passed`, 5 tests passing.

- [ ] **Step 7: Run the full BillableCore test suite — no regressions**

Run:
```bash
swift test --package-path Packages/BillableCore 2>&1 | tail -3
```

Expected: 199 + 5 = 204 tests passing.

- [ ] **Step 8: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Models/BusinessProfile.swift Packages/BillableCore/Tests/BillableCoreTests/BusinessProfileEmailTemplatesTests.swift
git commit -m "feat(model): invoiceEmailSubjectTemplate + invoiceEmailBodyTemplate on BusinessProfile

Two additive String fields with non-empty defaults that pre-fill
the invoice email composer in v1.6. Unlike Phase 1's tax-ID fields
(which default to ''), these ship with real merge-field-bearing
templates so a fresh user's first send is useful without touching
Settings.

Reuses the existing v1.1 ReminderTemplateRenderer for substitution —
same 7 merge field tokens.

Closes A3 model layer in Phase 2 spec.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 2: TimerService.adjustStart + tests (TDD)

**Files:**
- Create: `Packages/BillableCore/Tests/BillableCoreTests/TimerServiceAdjustStartTests.swift`
- Modify: `Packages/BillableCore/Sources/BillableCore/Timing/TimerService.swift`

- [ ] **Step 1: Write the failing tests**

Create `Packages/BillableCore/Tests/BillableCoreTests/TimerServiceAdjustStartTests.swift`:

```swift
import Foundation
import SwiftData
import Testing
@testable import BillableCore

@Suite("TimerService.adjustStart")
@MainActor
struct TimerServiceAdjustStartTests {

    private func freshContext() throws -> (ModelContext, Client, Project) {
        let container = try BillableModelContainer.inMemory()
        let context = ModelContext(container)
        let client = Client(name: "Acme", color: .blue)
        let project = Project(name: "P", hourlyRate: 100, client: client)
        context.insert(client)
        context.insert(project)
        try context.save()
        return (context, client, project)
    }

    @Test("Shifts startedAt backward by the given offset")
    func shiftsBackward() throws {
        let (context, _, project) = try freshContext()
        let original = Date(timeIntervalSince1970: 1_000_000)
        let entry = TimeEntry(project: project, startedAt: original, endedAt: nil)
        context.insert(entry)
        try context.save()

        let newStart = original.addingTimeInterval(-600)  // 10 minutes earlier
        try TimerService.adjustStart(entry: entry, to: newStart, in: context)

        #expect(entry.startedAt == newStart)
    }

    @Test("Throws startInFuture when newStart is at or after Date.now")
    func rejectsFutureStart() throws {
        let (context, _, project) = try freshContext()
        let entry = TimeEntry(project: project, startedAt: .now.addingTimeInterval(-300), endedAt: nil)
        context.insert(entry)
        try context.save()

        let future = Date.now.addingTimeInterval(3600)
        #expect(throws: TimerService.AdjustError.startInFuture) {
            try TimerService.adjustStart(entry: entry, to: future, in: context)
        }
    }

    @Test("Throws entryNotRunning on stopped entries")
    func rejectsStoppedEntries() throws {
        let (context, _, project) = try freshContext()
        let entry = TimeEntry(
            project: project,
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            endedAt: Date(timeIntervalSince1970: 1_001_000)
        )
        context.insert(entry)
        try context.save()

        #expect(throws: TimerService.AdjustError.entryNotRunning) {
            try TimerService.adjustStart(
                entry: entry,
                to: Date(timeIntervalSince1970: 999_000),
                in: context
            )
        }
    }

    @Test("Updates updatedAt to the present moment after a successful shift")
    func updatesTimestamp() throws {
        let (context, _, project) = try freshContext()
        let entry = TimeEntry(project: project, startedAt: .now.addingTimeInterval(-1800), endedAt: nil)
        // Force the updatedAt to be in the past, so a successful adjustStart should bump it.
        entry.updatedAt = Date(timeIntervalSince1970: 1)
        context.insert(entry)
        try context.save()

        let before = Date.now
        try TimerService.adjustStart(entry: entry, to: .now.addingTimeInterval(-2400), in: context)
        #expect(entry.updatedAt >= before)
    }
}
```

- [ ] **Step 2: Run tests, verify they fail**

Run:
```bash
swift test --package-path Packages/BillableCore --filter TimerServiceAdjustStartTests 2>&1 | tail -10
```

Expected: build error — `TimerService` has no `AdjustError` type or `adjustStart` method.

- [ ] **Step 3: Add the `AdjustError` enum + `adjustStart` method to `TimerService`**

Open `Packages/BillableCore/Sources/BillableCore/Timing/TimerService.swift`. Locate the existing `public enum TimerError` (around line 16). Insert the new `AdjustError` enum immediately after it (still inside `public enum TimerService`):

```swift
    public enum AdjustError: Error, Equatable, Sendable {
        case startInFuture
        case entryNotRunning
    }
```

Then locate the end of the existing static methods (after `logCompletedEntry` ends — search for the last `public static func` block in the file). Insert the new `adjustStart` static method right after the last existing static method, still inside `public enum TimerService`:

```swift
    /// Shift a running entry's startedAt backward (or forward, within constraints).
    /// Throws if `newStart >= Date.now` (would create negative duration) or if
    /// the entry is no longer running.
    ///
    /// Used by the Today screen's RunningTimerCard to let users correct a
    /// "forgot to start the timer" mistake without stopping the entry.
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

- [ ] **Step 4: Run tests, verify they pass**

Run:
```bash
swift test --package-path Packages/BillableCore --filter TimerServiceAdjustStartTests 2>&1 | tail -10
```

Expected: 4 tests passing.

- [ ] **Step 5: Run the full BillableCore test suite — no regressions**

Run:
```bash
swift test --package-path Packages/BillableCore 2>&1 | tail -3
```

Expected: 204 + 4 = 208 tests passing.

- [ ] **Step 6: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Timing/TimerService.swift Packages/BillableCore/Tests/BillableCoreTests/TimerServiceAdjustStartTests.swift
git commit -m "feat(timer): TimerService.adjustStart for running-entry start-time shift

New static method alongside start/stop/switchTo for shifting a
running entry's startedAt backward. Validates entry.endedAt == nil
(running invariant) and newStart < Date.now (no negative duration).

Throws TimerService.AdjustError.entryNotRunning or .startInFuture
on violations. Used by the Today screen's A5 chevron-affordance
confirmationDialog in Phase 2.

Closes A5 service layer in Phase 2 spec.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 3: MailComposerView wrapper (new file)

**Files:**
- Create: `App/Sources/Shared/MailComposerView.swift`

> **Note:** The `App/Sources/Shared/` directory does not exist yet. The `mkdir` step is below.

- [ ] **Step 1: Create the Shared directory**

Run:
```bash
mkdir -p App/Sources/Shared
ls -la App/Sources/Shared
```

Expected: empty directory created.

- [ ] **Step 2: Write the MailComposerView file**

Create `App/Sources/Shared/MailComposerView.swift`:

```swift
import SwiftUI
import MessageUI

/// SwiftUI wrapper for MFMailComposeViewController.
///
/// Presented as a sheet. Caller is responsible for calling
/// `MFMailComposeViewController.canSendMail()` BEFORE presenting and falling
/// back to a `mailto:` URL via `UIApplication.shared.open(...)` when it
/// returns false. Apple's MessageUI header explicitly documents this fallback
/// pattern — see MFMailComposeViewController.h on the iOS 26.5 SDK.
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

- [ ] **Step 3: Verify the build compiles**

Run:
```bash
xcodebuild -project Billable.xcodeproj -scheme Billable -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "error:|warning:|BUILD SUCCEEDED|BUILD FAILED" | head -5
```

Expected: `** BUILD SUCCEEDED **`, no warnings.

If the build fails with `cannot find type 'MailComposerView' in scope` later (in Task 5 or 6), the new file was not picked up by Xcode's auto-folder-membership. Open `Billable.xcodeproj` in Xcode once; Xcode auto-detects new files in folders that match group structure. Confirm the file is in the Billable target's Compile Sources.

- [ ] **Step 4: Commit**

```bash
git add App/Sources/Shared/MailComposerView.swift
git commit -m "feat(mail): MailComposerView SwiftUI wrapper for MFMailComposeViewController

New file at App/Sources/Shared/MailComposerView.swift. Pure UIKit
bridge — no business logic, no canSendMail() gate, no fallback.
Callers in InvoiceDetailView (Email invoice action) and
InvoicePreviewView (Finalize & email primary action) check
canSendMail() themselves and fall back to mailto: URL when false.

Delegate dismisses via DispatchQueue.main.async hop — clean under
Swift 6 strict concurrency. Type-checks against iOS 17 and iOS 18
deployment targets with zero warnings (verified in spec).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 4: BusinessProfileEditorView email templates section

**Files:**
- Modify: `App/Sources/Features/Settings/BusinessProfileEditorView.swift`

- [ ] **Step 1: Add `@State` for the two new template strings**

Open `App/Sources/Features/Settings/BusinessProfileEditorView.swift`. Find the existing `@State` block for tax ID (the `taxIDLabel` / `taxIDNumber` lines from Phase 1, around lines 28-29). Add two new lines immediately after them:

```swift
    @State private var taxIDLabel: String = ""
    @State private var taxIDNumber: String = ""
    @State private var invoiceEmailSubjectTemplate: String = ""
    @State private var invoiceEmailBodyTemplate: String = ""

    @State private var bankBeneficiaryName: String = ""
```

(Only the two `invoiceEmail…` lines are NEW. The `taxID…` and `bankBeneficiaryName` lines are existing Phase 1 state — shown for context to anchor the insertion point.)

- [ ] **Step 2: Add the "Invoice email" section between Tax and Logo**

In the same file, locate the existing `Section { ... } header: { Text("Logo") } footer: { ... }` block (the Phase 1 logo section). Insert a new `Section { ... }` IMMEDIATELY BEFORE it:

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

            Section {
                if let data = logoData, let image = uiImageFromData(data) {
                    // ...existing Logo section content...
```

(Only the FIRST `Section { ... } header: { Text("Invoice email") } footer: { ... }` block is NEW. Don't re-type the Logo section — it's existing. The `Section {` line is just shown for context.)

- [ ] **Step 3: Wire into `loadIfNeeded()`**

In the same file, find `loadIfNeeded()`. Find the two `taxIDLabel` / `taxIDNumber` load lines (added in Phase 1, around lines 179-180):
```swift
        taxIDLabel = profile.taxIDLabel
        taxIDNumber = profile.taxIDNumber
```

Insert two new lines immediately after them:
```swift
        taxIDLabel = profile.taxIDLabel
        taxIDNumber = profile.taxIDNumber
        invoiceEmailSubjectTemplate = profile.invoiceEmailSubjectTemplate
        invoiceEmailBodyTemplate = profile.invoiceEmailBodyTemplate
```

- [ ] **Step 4: Wire into `save()`**

In the same file, find `save()`. Find the two `profile.taxIDLabel` / `profile.taxIDNumber` save lines:
```swift
        profile.taxIDLabel = taxIDLabel
        profile.taxIDNumber = taxIDNumber
```

Insert two new lines immediately after them:
```swift
        profile.taxIDLabel = taxIDLabel
        profile.taxIDNumber = taxIDNumber
        profile.invoiceEmailSubjectTemplate = invoiceEmailSubjectTemplate
        profile.invoiceEmailBodyTemplate = invoiceEmailBodyTemplate
```

- [ ] **Step 5: Build and confirm**

Run:
```bash
xcodebuild -project Billable.xcodeproj -scheme Billable -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "error:|warning:|BUILD SUCCEEDED|BUILD FAILED" | head -5
```

Expected: `** BUILD SUCCEEDED **`, no warnings.

- [ ] **Step 6: Commit**

```bash
git add App/Sources/Features/Settings/BusinessProfileEditorView.swift
git commit -m "feat(settings): Invoice email templates section on Business Profile editor

New 'Invoice email' Form section between Tax and Logo with Subject
template (axis: .vertical, 1-3 lines) + Body template (axis: .vertical,
4-12 lines). Footer text documents the 6 user-facing merge fields
({clientName}, {clientFirstName}, {invoiceNumber}, {amount},
{dueDate}, {senderName}).

Both fields wire into loadIfNeeded() and save() following the existing
field-by-field pattern. Section is the A3 editor surface for Phase 2.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 5: InvoiceDetailView Email invoice + sendReminder unify

**Files:**
- Modify: `App/Sources/Features/Invoicing/InvoiceDetailView.swift`

- [ ] **Step 1: Add `import MessageUI` at the top**

Open `App/Sources/Features/Invoicing/InvoiceDetailView.swift`. Insert `import MessageUI` between the existing `import UserNotifications` (line 5) and `import BillableCore` (line 6):

```swift
import SwiftUI
import SwiftData
import PDFKit
import StoreKit
import UserNotifications
import MessageUI
import BillableCore
```

- [ ] **Step 2: Add the three new `@State` properties for the mail composer**

Find the existing `@State` block at the top of the view struct (lines 15-20). After the last existing `@State` (currently `pendingMailFireDate`), add three new lines:

```swift
    @State private var showingShare = false
    @State private var showingDeleteConfirm = false
    @State private var pendingMailSubject: String = ""
    @State private var pendingMailBody: String = ""
    @State private var pendingMailRecipients: [String] = []
    @State private var pendingMailFireDate: Date?
    @State private var showingMailComposer = false
    @State private var mailComposerSubject = ""
    @State private var mailComposerBody = ""
```

(Only the last three lines — `showingMailComposer` / `mailComposerSubject` / `mailComposerBody` — are NEW. The rest are existing context.)

- [ ] **Step 3: Add the new "Email invoice" toolbar menu item**

In the same file, locate the toolbar menu where "Share PDF" lives (around line 63-66). Wrap or insert a new button. The existing structure is:
```swift
.toolbar {
    ToolbarItem(placement: .topBarTrailing) {
        Menu {
            Button {
                showingShare = true
            } label: {
                Label("Share PDF", systemImage: "square.and.arrow.up")
            }
            if invoice.status == .sent { /* Send reminder email */ }
            if invoice.status == .draft { /* Delete draft */ }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }
}
```

Insert a new "Email invoice" button immediately after "Share PDF" and BEFORE the `if invoice.status == .sent` block, gated on `status != .draft`:
```swift
            Button {
                showingShare = true
            } label: {
                Label("Share PDF", systemImage: "square.and.arrow.up")
            }
            if invoice.status != .draft {
                Button {
                    presentEmailInvoice()
                } label: {
                    Label("Email invoice", systemImage: "envelope")
                }
            }
            if invoice.status == .sent {
                // ...existing Send reminder email button...
            }
```

(Only the `if invoice.status != .draft { Button { ... } }` block is NEW.)

- [ ] **Step 4: Add the new "Email invoice" bordered button to `actionButtons`**

Find the existing `actionButtons` view (around line 211). The current shape includes the "Share PDF" bordered button. Add a sibling "Email invoice" button immediately after the existing "Share PDF" button, also gated on `status != .draft`:

```swift
    @ViewBuilder
    private var actionButtons: some View {
        VStack(spacing: 10) {
            if invoice.status == .sent {
                Button {
                    markPaid()
                } label: {
                    Label("Mark as paid", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
            Button {
                showingShare = true
            } label: {
                Label("Share PDF", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)

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
        }
    }
```

(Only the trailing `if invoice.status != .draft { Button { ... } }` block is NEW.)

- [ ] **Step 5: Add the `presentEmailInvoice()` + `ensurePDFData()` helpers**

In the same file, locate `private func sendReminder()` (around line 280) — we'll modify it in Step 7. For now, insert two new helper methods IMMEDIATELY BEFORE `sendReminder()`:

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

    private func sendReminder() {
        // ...existing implementation will be replaced in Step 7...
    }
```

- [ ] **Step 6: Wire the mail composer sheet on the body**

Find the existing `.sheet(isPresented: $showingShare)` modifier on the body (around line 85). Add a new sheet modifier IMMEDIATELY AFTER it:

```swift
        .sheet(isPresented: $showingShare) {
            if let url = ensurePDFOnDisk() {
                ShareSheet(items: [url])
                    .ignoresSafeArea()
            }
        }
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

(Only the second `.sheet(isPresented: $showingMailComposer)` block is NEW.)

- [ ] **Step 7: Replace `sendReminder()` body to use ReminderConfig templates**

Find `private func sendReminder()` (now around line 280-290 after Step 5 added helpers above it). The current implementation uses hardcoded subject + body strings. Replace the ENTIRE function body with:

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

- [ ] **Step 8: Build and confirm**

Run:
```bash
xcodebuild -project Billable.xcodeproj -scheme Billable -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "error:|warning:|BUILD SUCCEEDED|BUILD FAILED" | head -10
```

Expected: `** BUILD SUCCEEDED **`, no warnings.

- [ ] **Step 9: Commit**

```bash
git add App/Sources/Features/Invoicing/InvoiceDetailView.swift
git commit -m "feat(invoice): Email invoice action on InvoiceDetailView + reminder unify

Two new features in one file:

* A3 (new): 'Email invoice' button in both the toolbar menu and the
  actionButtons row, visible for any non-Draft invoice. Tapping renders
  the BusinessProfile.invoiceEmailSubjectTemplate / bodyTemplate via
  ReminderTemplateRenderer and presents MailComposerView with the PDF
  auto-attached. Gates on canSendMail(); falls back to mailto: URL
  (no attachment) when Mail isn't configured. ensurePDFData() helper
  reads pdfDataCached or re-renders and caches.

* sendReminder() consistency fix: was using hardcoded subject + body
  strings; now routes through ReminderConfig.subjectTemplate /
  bodyTemplate + ReminderTemplateRenderer — same source-of-truth as
  the banner-driven composeReminder(). Edits the user makes in
  Settings → Payment reminders now also apply to the toolbar
  'Send reminder email' action.

Closes A3 detail surface + A3 reminder-consistency in Phase 2 spec.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 6: InvoicePreviewView Finalize & email + Finalize & share split

**Files:**
- Modify: `App/Sources/Features/Invoicing/InvoicePreviewView.swift`

- [ ] **Step 1: Add `import MessageUI`**

Open `App/Sources/Features/Invoicing/InvoicePreviewView.swift`. Insert `import MessageUI` between `import SwiftData` (line 2) and `import BillableCore` (line 3):

```swift
import SwiftUI
import SwiftData
import MessageUI
import BillableCore
```

- [ ] **Step 2: Add the three new `@State` properties**

Find the existing `@State` block at the top (lines 15-24). Add three new lines after the last existing `@State`:

```swift
    @State private var showingRemoveWatermarkPaywall = false
    @State private var showingMailComposer = false
    @State private var mailComposerSubject = ""
    @State private var mailComposerBody = ""
```

(Only the last three lines are NEW.)

- [ ] **Step 3: Restructure the trailing toolbar**

Find the existing toolbar block (around lines 122-134). The current shape is:

```swift
.toolbar {
    ToolbarItem(placement: .topBarLeading) {
        Button("Back") { dismiss() }
    }
    ToolbarItem(placement: .topBarTrailing) {
        Button {
            finalizeAndShare()
        } label: {
            Label("Finalize & share", systemImage: "paperplane.fill")
        }
        .bold()
        .disabled(hasInvalidDescriptions)
    }
}
```

Replace with the two-trailing-item form:

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

- [ ] **Step 4: Wire the mail composer sheet on the body**

Find the existing `.sheet(isPresented: $showingShare)` modifier (around lines 136-145). Add a new sheet modifier IMMEDIATELY AFTER it:

```swift
.sheet(isPresented: $showingShare) {
    if let pdfData,
       let url = writeToTemp(pdfData, suggestedName: templateData.invoiceNumber) {
        ShareSheet(items: [url])
            .ignoresSafeArea()
            .onDisappear {
                dismiss()
                onDone()
            }
    }
}
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

(Only the second `.sheet(isPresented: $showingMailComposer)` block is NEW.)

- [ ] **Step 5: Extract `drainPendingEdits()` from the existing `finalizeAndShare()`**

Find the existing `private func finalizeAndShare()` (around line 288). The first block of the function body currently drains pending edits inline:

```swift
    private func finalizeAndShare() {
        // Drain pending in-flight edits before snapshotting. Closes a race
        // where a user taps Finalize within the 200ms debounce window — without
        // this drain, the pre-edit description would be persisted instead of
        // the user's last keystrokes.
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
        do {
            let draft = try InvoiceBuilder.createDraft(
                ...
```

Refactor so the drain logic lives in a private helper, called by both `finalizeAndShare` and the new `finalizeAndEmail`. Replace the top of `finalizeAndShare` with a single call:

```swift
    private func finalizeAndShare() {
        drainPendingEdits()
        do {
            let draft = try InvoiceBuilder.createDraft(
                ...
```

Then add `drainPendingEdits()` as a new private helper. Put it immediately after `finalizeAndShare` (before the existing `writeToTemp` helper):

```swift
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
```

- [ ] **Step 6: Add the `finalizeAndEmail()` method**

In the same file, add the new method IMMEDIATELY AFTER `drainPendingEdits()`:

```swift
    private func finalizeAndEmail() {
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

            // Render templates against the freshly-finalized invoice.
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
                // Fallback: open default mail handler. PDF attachment lost.
                guard let email = client.email,
                      !email.isEmpty,
                      let url = mailtoURLFromComponents(to: email, subject: subject, body: body) else {
                    // Final fallback: drop back to iOS share sheet.
                    showingShare = true
                    return
                }
                UIApplication.shared.open(url)
            }
        } catch {
            // Silent failure for now; Phase 1 noted error toasts as future work.
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

- [ ] **Step 7: Build and confirm**

Run:
```bash
xcodebuild -project Billable.xcodeproj -scheme Billable -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "error:|warning:|BUILD SUCCEEDED|BUILD FAILED" | head -10
```

Expected: `** BUILD SUCCEEDED **`, no warnings.

- [ ] **Step 8: Commit**

```bash
git add App/Sources/Features/Invoicing/InvoicePreviewView.swift
git commit -m "feat(invoice): Finalize & email primary + Finalize & share overflow

Toolbar restructure on InvoicePreviewView:
- Primary trailing item is now 'Finalize & email' (envelope.fill icon)
- Secondary trailing ellipsis menu contains 'Finalize & share' (iOS
  share sheet — preserves the existing first-send-to-any-app flow)
- Both are disabled when hasInvalidDescriptions

New finalizeAndEmail() function: drains pending edits, creates draft,
finalizes, renders + caches PDF, renders subject + body via
ReminderTemplateRenderer with the BusinessProfile.invoiceEmail*
templates, then either presents MailComposerView (canSendMail()) or
opens mailto: URL (no attachment) or falls back to the existing iOS
share sheet (no email client at all).

Extracted drainPendingEdits() as a shared helper used by both
finalizeAndShare (existing) and finalizeAndEmail (new).

Closes A3 preview surface in Phase 2 spec — this is the highest-value
moment for the new templates (first send of any invoice).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 7: TodayView RunningTimerCard A4 (inline note)

**Files:**
- Modify: `App/Sources/Features/Today/TodayView.swift`

- [ ] **Step 1: Change `let entry: TimeEntry` to `@Bindable var entry: TimeEntry`**

Open `App/Sources/Features/Today/TodayView.swift`. Find `private struct RunningTimerCard: View` (around line 247). The first stored property is currently:

```swift
private struct RunningTimerCard: View {
    let entry: TimeEntry
    let asOf: Date
    let currencyCode: String
    let onStop: () -> Void
    let onSwitch: () -> Void
```

Change the first line:

```swift
private struct RunningTimerCard: View {
    @Bindable var entry: TimeEntry
    let asOf: Date
    let currencyCode: String
    let onStop: () -> Void
    let onSwitch: () -> Void
```

- [ ] **Step 2: Add the inline note `TextField` below the project name**

In the same file, find the body of `RunningTimerCard` (around line 254-296). Locate the project-name `Text`:

```swift
            Text(entry.project?.name ?? "Project")
                .font(.title2.weight(.semibold))
```

Insert the new TextField IMMEDIATELY AFTER it:

```swift
            Text(entry.project?.name ?? "Project")
                .font(.title2.weight(.semibold))

            // A4: inline note. Empty string ↔ nil so users can clear by deleting.
            TextField("What are you working on?", text: notesBinding, axis: .vertical)
                .lineLimit(1...2)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .textFieldStyle(.plain)
```

- [ ] **Step 3: Add the `notesBinding` computed property**

In the same file, find the private computed properties on `RunningTimerCard` (around lines 301-309, where `elapsedString` and `amountString` live). Insert a new private computed property IMMEDIATELY BEFORE `elapsedString`:

```swift
    private var notesBinding: Binding<String> {
        Binding(
            get: { entry.notes ?? "" },
            set: { entry.notes = $0.isEmpty ? nil : $0 }
        )
    }

    private var elapsedString: String {
        let seconds = Int(entry.duration(asOf: asOf))
        // ...rest of existing function...
```

- [ ] **Step 4: Build and confirm**

Run:
```bash
xcodebuild -project Billable.xcodeproj -scheme Billable -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "error:|warning:|BUILD SUCCEEDED|BUILD FAILED" | head -5
```

Expected: `** BUILD SUCCEEDED **`, no warnings.

- [ ] **Step 5: Commit**

```bash
git add App/Sources/Features/Today/TodayView.swift
git commit -m "feat(today): inline note field on running timer card

A4: New TextField below the project name on RunningTimerCard, bound
to entry.notes via a String? <-> String adapter. Empty string clears
to nil so deletion fully resets. Auto-saves via SwiftData's mainContext
on every keystroke — same pattern as every other model-bound field in
the app (no debounce; CloudKit batches writes).

Changed entry from 'let' to '@Bindable var' so notes mutations propagate
through the SwiftUI observation tree. Pattern matches the existing
ClientDetailView (@Bindable var client) and InvoiceDetailView
(@Bindable var invoice).

Closes A4 in Phase 2 spec.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 8: TodayView RunningTimerCard A5 (chevron + adjust dialog)

**Files:**
- Modify: `App/Sources/Features/Today/TodayView.swift`

- [ ] **Step 1: Add `@Environment(\.modelContext)` and three new `@State` properties to `RunningTimerCard`**

Open `App/Sources/Features/Today/TodayView.swift`. Find `private struct RunningTimerCard: View` (around line 247). The current property list ends with `let onSwitch: () -> Void`. Add the new environment + state properties immediately after:

```swift
private struct RunningTimerCard: View {
    @Bindable var entry: TimeEntry
    let asOf: Date
    let currencyCode: String
    let onStop: () -> Void
    let onSwitch: () -> Void

    @Environment(\.modelContext) private var modelContext

    @State private var showingAdjustDialog = false
    @State private var showingDatePickerSheet = false
```

(`@Bindable var entry` was already changed in Task 7. The four new lines — `@Environment`, two `@State` — are this task's additions.)

- [ ] **Step 2: Wrap the elapsed counter in a tappable Button with a chevron icon**

In the same file, find the elapsed-counter HStack inside the body (around lines 272-280):

```swift
            HStack(alignment: .firstTextBaseline) {
                Text(elapsedString)
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Spacer()
                Text(amountString)
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
```

Replace the `Text(elapsedString)` with a Button-wrapped HStack containing the text + chevron:

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

- [ ] **Step 3: Add the `.confirmationDialog` and `.sheet` modifiers**

Find the trailing `.background(.thinMaterial, in: .rect(cornerRadius: 16))` modifier at the end of the body (around line 299). Add two new modifiers AFTER it:

```swift
        .background(.thinMaterial, in: .rect(cornerRadius: 16))
        .confirmationDialog(
            "Adjust start time",
            isPresented: $showingAdjustDialog,
            titleVisibility: .visible
        ) {
            Button("Back 5 minutes") { shiftStart(byMinutes: 5) }
            Button("Back 10 minutes") { shiftStart(byMinutes: 10) }
            Button("Back 15 minutes") { shiftStart(byMinutes: 15) }
            Button("Adjust to…") {
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
    }
```

- [ ] **Step 4: Add the `shiftStart` and `applyAdjustedStart` helper methods**

Find the existing private computed properties on `RunningTimerCard` (where `notesBinding`, `elapsedString`, `amountString` live, around lines 301-309 after Task 7). Insert two new private methods IMMEDIATELY BEFORE `notesBinding`:

```swift
    private func shiftStart(byMinutes minutes: Int) {
        let newStart = entry.startedAt.addingTimeInterval(TimeInterval(-minutes * 60))
        applyAdjustedStart(newStart)
    }

    private func applyAdjustedStart(_ newStart: Date) {
        // Defensive guard: never write a future start. The DatePicker sheet
        // already restricts to .now-or-earlier; the 5/10/15-min offsets always
        // go backward. This guard is for unforeseen call paths.
        guard newStart < .now else { return }
        do {
            try TimerService.adjustStart(entry: entry, to: newStart, in: modelContext)
        } catch {
            // Silent fail; UI simply won't update. Phase 1 noted error toasts
            // as future work.
        }
    }

    private var notesBinding: Binding<String> {
        // ...existing implementation from Task 7...
```

- [ ] **Step 5: Add the `AdjustStartTimePickerSheet` private struct at the end of the file**

In the same file, scroll to the END of `RunningTimerCard` (look for its closing `}` after `amountString`). Add the new private struct IMMEDIATELY AFTER `RunningTimerCard`'s closing `}` and BEFORE the next `// MARK:` or struct definition:

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

- [ ] **Step 6: Build and confirm**

Run:
```bash
xcodebuild -project Billable.xcodeproj -scheme Billable -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "error:|warning:|BUILD SUCCEEDED|BUILD FAILED" | head -10
```

Expected: `** BUILD SUCCEEDED **`, no warnings.

- [ ] **Step 7: Commit**

```bash
git add App/Sources/Features/Today/TodayView.swift
git commit -m "feat(today): A5 start-time adjust via chevron + confirmationDialog

The elapsed counter on RunningTimerCard is now tappable, signaled by
a chevron.up.chevron.down icon next to it. Tapping presents a
confirmationDialog with:
- Back 5 minutes
- Back 10 minutes
- Back 15 minutes
- Adjust to… → AdjustStartTimePickerSheet (DatePicker, graphical
  style, .date + .hourAndMinute components, restricted to ≤ Date.now,
  Save button disabled for future selections, .medium/.large detents)
- Cancel

All shifts route through TimerService.adjustStart (added in Task 2)
so the running-entry invariant + no-future-start checks are enforced
in one place. Errors are silently swallowed (matches existing
finalizeAndShare error-handling pattern; error toasts deferred).

Closes A5 in Phase 2 spec.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 9: ClientsView A7 ("Days since last invoice" badge)

**Files:**
- Modify: `App/Sources/Features/Clients/ClientsView.swift`
- Create: `Packages/BillableCore/Tests/BillableCoreTests/ClientRowDaysAgoLabelTests.swift` (see Step 4 placement decision)

- [ ] **Step 1: Add `@Query` of invoices + `lastInvoiceByClientID` map to `ClientsView`**

Open `App/Sources/Features/Clients/ClientsView.swift`. The existing top-of-struct has two `@Query`s for `activeClients` and `archivedClients` (around lines 9-13). Add a new `@Query` for invoices immediately after them:

```swift
struct ClientsView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(filter: #Predicate<Client> { !$0.isArchived }, sort: \Client.name)
    private var activeClients: [Client]

    @Query(filter: #Predicate<Client> { $0.isArchived }, sort: \Client.name)
    private var archivedClients: [Client]

    @Query(sort: \Invoice.issuedAt, order: .reverse)
    private var allInvoices: [Invoice]
```

(Only the third `@Query` is NEW. Match the existing two for style.)

Then add a private computed property somewhere near the top of the struct (after the @State block — find one with `deletionCandidate` or similar):

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

- [ ] **Step 2: Pass `lastInvoiceDate` into each Active `ClientRow`**

In the body of `ClientsView`, find the active-section `ForEach` (around line 101). Currently:
```swift
                ForEach(activeClients) { client in
                    NavigationLink {
                        ClientDetailView(client: client)
                    } label: {
                        ClientRow(client: client)
                    }
                    .swipeActions(edge: .trailing) { /* ...existing... */ }
                }
```

Update the `ClientRow(...)` call to pass the lookup:
```swift
                    } label: {
                        ClientRow(
                            client: client,
                            lastInvoiceDate: lastInvoiceByClientID[client.persistentModelID]
                        )
                    }
```

For the Archived section's `ForEach` (around line 129), keep `lastInvoiceDate: nil` so the badge is hidden:
```swift
                    ForEach(archivedClients) { client in
                        ClientRow(client: client, lastInvoiceDate: nil)
                            .foregroundStyle(.secondary)
                            .swipeActions(edge: .trailing) { /* ...existing... */ }
                    }
```

- [ ] **Step 3: Create the BillableCore Formatting directory + DaysAgoFormatter source file**

Run:
```bash
mkdir -p Packages/BillableCore/Sources/BillableCore/Formatting
```

Create `Packages/BillableCore/Sources/BillableCore/Formatting/DaysAgoFormatter.swift`:

```swift
import Foundation

/// Returns a human-readable "N days ago" string for a past date.
///
/// "today" for same calendar day OR a date in the future (clock-skew edge case).
/// "yesterday" for exactly 1 calendar day before.
/// "N days ago" for 2+ calendar days before.
///
/// `prefix` is concatenated before the relative portion. Pass `"Last invoice: "`
/// to get strings like "Last invoice: 12 days ago".
public enum DaysAgoFormatter {
    public static func string(for date: Date, prefix: String, now: Date = .now, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: date, to: now).day ?? 0
        switch days {
        case ..<0:  return "\(prefix)today"   // future-dated; clock skew edge case
        case 0:     return "\(prefix)today"
        case 1:     return "\(prefix)yesterday"
        default:    return "\(prefix)\(days) days ago"
        }
    }
}
```

Create `Packages/BillableCore/Tests/BillableCoreTests/DaysAgoFormatterTests.swift`:

```swift
import Foundation
import Testing
@testable import BillableCore

@Suite("DaysAgoFormatter")
struct DaysAgoFormatterTests {

    @Test("Returns prefix + 'today' for same calendar day")
    func sameDay() {
        let now = Date(timeIntervalSinceReferenceDate: 760_000_000)
        let sameDayEarlier = now.addingTimeInterval(-3600)
        #expect(DaysAgoFormatter.string(for: sameDayEarlier, prefix: "Last invoice: ", now: now)
                == "Last invoice: today")
    }

    @Test("Returns prefix + 'yesterday' for 1 day ago")
    func yesterday() {
        let now = Date(timeIntervalSinceReferenceDate: 760_000_000)
        let oneDayAgo = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        #expect(DaysAgoFormatter.string(for: oneDayAgo, prefix: "Last invoice: ", now: now)
                == "Last invoice: yesterday")
    }

    @Test("Returns prefix + 'N days ago' for 2+ days")
    func multipleDays() {
        let now = Date(timeIntervalSinceReferenceDate: 760_000_000)
        let twelveDaysAgo = Calendar.current.date(byAdding: .day, value: -12, to: now)!
        #expect(DaysAgoFormatter.string(for: twelveDaysAgo, prefix: "Last invoice: ", now: now)
                == "Last invoice: 12 days ago")
    }

    @Test("Future-dated invoices (clock skew edge case) still read as 'today'")
    func futureDated() {
        let now = Date(timeIntervalSinceReferenceDate: 760_000_000)
        let futureInvoice = now.addingTimeInterval(3600)
        #expect(DaysAgoFormatter.string(for: futureInvoice, prefix: "Last invoice: ", now: now)
                == "Last invoice: today")
    }

    @Test("Empty prefix yields just the relative portion")
    func emptyPrefix() {
        let now = Date(timeIntervalSinceReferenceDate: 760_000_000)
        let oneDayAgo = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        #expect(DaysAgoFormatter.string(for: oneDayAgo, prefix: "", now: now) == "yesterday")
    }
}
```

- [ ] **Step 4: Update `ClientRow` to accept `lastInvoiceDate` and render the subtitle via `DaysAgoFormatter`**

In `App/Sources/Features/Clients/ClientsView.swift`, locate `private struct ClientRow: View` (around line 149). Replace the entire struct with:

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
                    Text(DaysAgoFormatter.string(for: lastInvoiceDate, prefix: "Last invoice: "))
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
}
```

The struct adds the `lastInvoiceDate: Date?` stored property and the third conditional `Text(...)` row inside the inner VStack. Other rows are unchanged. `DaysAgoFormatter` resolves through `import BillableCore` (already imported at the top of `ClientsView.swift`).

- [ ] **Step 5: Run the new tests + verify they pass**

Run:
```bash
swift test --package-path Packages/BillableCore --filter DaysAgoFormatterTests 2>&1 | tail -10
```

Expected: 5 tests passing.

- [ ] **Step 6: Run the full BillableCore test suite + verify no regressions**

Run:
```bash
swift test --package-path Packages/BillableCore 2>&1 | tail -3
```

Expected: 208 + 5 = 213 tests passing.

- [ ] **Step 7: Build the app target + confirm the new `Text(DaysAgoFormatter.string(...))` renders**

Run:
```bash
xcodebuild -project Billable.xcodeproj -scheme Billable -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "error:|warning:|BUILD SUCCEEDED|BUILD FAILED" | head -5
```

Expected: `** BUILD SUCCEEDED **`, no warnings.

- [ ] **Step 8: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Formatting/DaysAgoFormatter.swift Packages/BillableCore/Tests/BillableCoreTests/DaysAgoFormatterTests.swift App/Sources/Features/Clients/ClientsView.swift
git commit -m "feat(clients): Days since last invoice subtitle on ClientRow (A7)

ClientsView now @Query's all invoices and builds a per-client
lastInvoiceByClientID map (sent/paid only, draft excluded). The map
is passed per-row to ClientRow as an optional Date.

ClientRow shows 'Last invoice: 12 days ago' (or 'today'/'yesterday')
as a tertiary-color caption2 subtitle directly below the existing
contactName line. Skipped entirely when lastInvoiceDate is nil
(client has never been invoiced) — no extra row, no empty space.
Archived clients always get nil so the badge never appears there.

New BillableCore namespace DaysAgoFormatter (pure function over
Calendar.dateComponents([.day]:from:to:)) handles the today /
yesterday / N-days / future-dated semantics. Five unit tests in
DaysAgoFormatterTests cover each branch.

Closes A7 in Phase 2 spec.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 10: Final acceptance sweep

**Files:**
- No file changes. Verification only.

- [ ] **Step 1: Full unit test suite**

Run:
```bash
swift test --package-path Packages/BillableCore 2>&1 | tail -3
```

Expected: 199 baseline + 5 (Task 1 BusinessProfileEmailTemplatesTests) + 4 (Task 2 TimerServiceAdjustStartTests) + 5 (Task 9 DaysAgoFormatterTests) = **213 tests passing**.

- [ ] **Step 2: Full build — Debug**

Run:
```bash
xcodebuild -project Billable.xcodeproj -scheme Billable -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "error:|warning:|BUILD SUCCEEDED|BUILD FAILED" | head -5
```

Expected: `** BUILD SUCCEEDED **`, zero warnings.

- [ ] **Step 3: Full build — Release**

Run:
```bash
xcodebuild -project Billable.xcodeproj -scheme Billable -configuration Release -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "error:|warning:|BUILD SUCCEEDED|BUILD FAILED" | head -5
```

Expected: `** BUILD SUCCEEDED **`, zero warnings.

- [ ] **Step 4: Full XCTest UI suite — confirm Phase 1 UI test still passes**

Run:
```bash
xcodebuild test -project Billable.xcodeproj -scheme Billable -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' -only-testing:BillableUITests 2>&1 | tail -15
```

Expected: all UI tests pass — `LaunchTaglineUITests`, `NotificationTapFlowUITests`, `SettingsAboutUITests`, `InvoicePreviewLineItemEditUITests`. **5 of 5 passing.**

(If a simulator named "iPhone 17 Pro" is not available, use `'platform=iOS Simulator,OS=latest'` for loosest matching.)

- [ ] **Step 5: Manual acceptance — A3 (Email invoice + template editor)**

Boot the simulator with `--seed-marketing --pretend-pro --reset-store`:
```bash
xcrun simctl boot "iPhone 17 Pro" 2>/dev/null || true
xcodebuild -project Billable.xcodeproj -scheme Billable -configuration Debug -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' build 2>&1 | tail -3
xcrun simctl install booted "$(find ~/Library/Developer/Xcode/DerivedData -name 'Billable.app' -path '*iphonesimulator*Debug*' -newer /tmp -type d 2>/dev/null | head -1)"
xcrun simctl launch booted com.eldenstudios.billable --seed-marketing --pretend-pro --reset-store
open -a Simulator
```

Walk through:

1. Settings → Business profile → scroll to "Invoice email" section. Confirm Subject + Body fields are present with the disambiguating footer text.
2. Edit Subject to `"Test {invoiceNumber} from {senderName}"`. Save.
3. Re-open Business profile. Confirm the edited Subject persisted.
4. Open Invoices → tap INV-0010 (paid Northwind) → confirm toolbar menu shows "Email invoice" and actionButtons row shows the new "Email invoice" bordered button.
5. Tap "Email invoice". With Mail configured on the simulator: composer opens with Subject = "Test INV-0010 from Studio Lina", Body filled from default template, PDF attached, To = riley@northwind.example.
6. Without Mail configured on the simulator (test by removing the account or wiping accounts via Settings.app on the sim): tapping "Email invoice" should open the simulator's default mail handler via mailto: with Subject + Body filled but no attachment.
7. Open the Toolbar menu on the same INV-0010. Tap "Send reminder email" → confirms it now uses ReminderConfig.subjectTemplate (default "Friendly reminder: {invoiceNumber}") instead of the old hardcoded "Reminder: Invoice INV-0010 still outstanding".

- [ ] **Step 6: Manual acceptance — A3 first-send via InvoicePreviewView**

In the same simulator session:
1. Invoices → + (top right) → pick Apex Analytics → change Range to "This week" → tap "Finalize & email" (primary trailing button, envelope icon).
2. Confirm the Mail composer opens with the templated Subject + Body and the freshly-rendered PDF attached.
3. Cancel the composer. Back to Invoices. Repeat the + flow but this time tap the overflow `…` menu and pick "Finalize & share" → iOS share sheet opens with the PDF URL (no email prefill).

- [ ] **Step 7: Manual acceptance — A4 + A5 (running timer card)**

In the same simulator session, the running timer should be Apex Analytics → Dashboard MVP (per marketing seed).

1. On the Today card: confirm an inline note TextField is visible below the project name with placeholder "What are you working on?".
2. Type "Adding Phase 2 polish". Switch to another tab and back. Confirm the note persisted.
3. Quit the app, relaunch with `--seed-marketing --pretend-pro` (no `--reset-store`). Confirm the note survives a relaunch.
4. Tap the elapsed counter on the running card. Confirm the confirmationDialog opens with Back 5/10/15 minutes + Adjust to… + Cancel.
5. Tap "Back 10 minutes". Elapsed counter jumps forward by 10 minutes.
6. Tap the chevron next to the counter again → "Adjust to…" → DatePicker sheet opens. Pick a time 30 minutes earlier than current start. Tap Save.
7. Confirm Save is disabled if you try to pick a future time.

- [ ] **Step 8: Manual acceptance — A7 (Days since last invoice)**

In the same simulator session:
1. Open the Clients tab.
2. Confirm Northwind Design shows "Last invoice: N days ago" as a tertiary-color caption2 row below "Riley Chen" — N depends on when INV-0010 was issued in the seed.
3. Confirm Apex Analytics, Helio Labs, Pinecone Studio (or whichever has no sent invoices) show NO last-invoice line — just name + contactName + project count.
4. Archive a client (swipe right → Archive). Confirm the Archived section's row for that client does NOT show a last-invoice subtitle (even if it has one in real data).

- [ ] **Step 9: Migration acceptance — v1.5 data loads cleanly**

If you have a simulator with a prior v1.5 install (or a CloudKit-synced device), reinstall the new build OVER the existing data WITHOUT erasing the simulator. The app must:

- Launch without crashing.
- Show the existing Business Profile with `invoiceEmailSubjectTemplate` and `invoiceEmailBodyTemplate` populated with the default templates (since the migration adds defaults).
- Show existing invoices unchanged — re-rendering them works the same way as before.
- Show client list with the new subtitle on rows that have invoices.

If you don't have a v1.5 store handy, this step is satisfied by the unit-level "default-init carries default templates" coverage in `BusinessProfileEmailTemplatesTests`.

- [ ] **Step 10: Commit any sweep follow-ups**

If any tweaks came out of the manual walkthrough, commit them as targeted patches. If nothing needed changing, this step is a no-op.

---

## Task 11: PR / merge / tag

**Files:**
- No file changes. Branch management only.

- [ ] **Step 1: Confirm the worktree is clean and ahead of main**

Run:
```bash
git status --short
git log --oneline main..HEAD | wc -l
```

Expected: clean tree (or only `.superpowers/` untracked). 9-11 feature commits depending on whether Step 10 of Task 10 added any sweep patches.

- [ ] **Step 2: Push the branch**

Run:
```bash
git push -u origin feature/v1.6-workflow-polish
```

Expected: branch pushes successfully.

- [ ] **Step 3: Open a PR using `gh`**

Run:
```bash
gh pr create --title "Phase 2: workflow polish (A3 email templates + A4 running note + A5 start adjust + A7 days-since-invoice)" --body "$(cat <<'EOF'
## Summary

- **A3 — Customizable invoice email templates:** Two new BusinessProfile String fields with non-empty default templates. New MailComposerView SwiftUI wrapper over MFMailComposeViewController. New "Email invoice" action on InvoiceDetailView (re-send) + InvoicePreviewView (primary "Finalize & email" with overflow Share PDF). Existing "Send reminder email" toolbar action now uses ReminderConfig templates instead of hardcoded strings (consistency fix).
- **A4 — Inline note on running timer card:** TextField below project name, bound to entry.notes via String? <-> String adapter. RunningTimerCard's `entry` is now `@Bindable var` so mutations propagate.
- **A5 — Adjust start time on running entry:** TimerService.adjustStart static method with AdjustError.startInFuture / entryNotRunning. Elapsed counter on running card is now tappable (chevron icon indicates affordance), opens confirmationDialog with Back 5/10/15 min + Adjust to… (graphical DatePicker sheet, ≤ Date.now constraint).
- **A7 — Days since last invoice badge:** New DaysAgoFormatter namespace in BillableCore. ClientsView @Query's all invoices and builds a per-client map. ClientRow shows "Last invoice: N days ago" as a tertiary-color caption2 subtitle when applicable. Archived clients never show the badge.

11 commits, ~15 files touched. All work on `feature/v1.6-workflow-polish` branched off `v1.5`.

Spec: `docs/superpowers/specs/2026-05-27-phase2-workflow-polish-design.md`
Plan: `docs/superpowers/plans/2026-05-27-phase2-workflow-polish.md`

## Test plan

- [x] BillableCore: ~14 new unit tests (5 BusinessProfileEmailTemplates, 4 TimerServiceAdjustStart, 5 DaysAgoFormatter) — full suite 199 → 213
- [x] UI test suite: 5/5 still passing (no new UI tests added — A3 requires Mail account, A4/A5/A7 are visual changes covered by manual acceptance)
- [x] Debug build: clean, no warnings
- [x] Release build: clean, no warnings
- [ ] Manual: A3 Email invoice from InvoiceDetailView with + without Mail account configured
- [ ] Manual: A3 first-send via InvoicePreviewView "Finalize & email"
- [ ] Manual: A3 "Send reminder email" uses ReminderConfig templates
- [ ] Manual: A4 inline note persists across app launches
- [ ] Manual: A5 chevron-tap → dialog → all 4 options work
- [ ] Manual: A5 DatePicker disables Save for future times
- [ ] Manual: A7 subtitle shows for clients with sent invoices, hidden for clients without

## Notable design choices

- **Reused ReminderTemplateRenderer** (v1.1) for the new templates — same 7 merge-field tokens, no new infrastructure.
- **MFMailComposeViewController.canSendMail() fallback** to mailto: URL (no attachment) is documented in Apple's own MessageUI header.
- **TimerService.adjustStart** keeps the v1 invariant that all timer ops route through the service; future overlap checks land in one place.
- **DaysAgoFormatter** lives in BillableCore so it's unit-testable without spinning up a SwiftUI view tree.

## Out of scope (tracked separately)

- A6 (Reports insight tiles — Phase 3)
- Custom merge fields beyond the existing 7
- Editing reminder templates from outside PaymentRemindersView
- Mail composer result-toast (cancel/save/sent/failed feedback)
- Note field on stopped entries from the Today card

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: a PR URL prints. Open it in browser to confirm.

- [ ] **Step 4: Once approved, merge to main with `--no-ff`**

After review, when ready:

```bash
cd "/Users/lbazerbashi/Elden Studios/billable"
git checkout main
git pull --ff-only origin main
git merge --no-ff feature/v1.6-workflow-polish -m "Merge v1.6 — workflow polish (A3 email templates + A4 running note + A5 start adjust + A7 days-since-invoice)"
git push origin main
git worktree remove ".worktrees/v1.6-workflow-polish"
git branch -d feature/v1.6-workflow-polish
git push origin --delete feature/v1.6-workflow-polish
```

Expected: clean merge, worktree removed, branch deleted locally + on remote.

- [ ] **Step 5: Tag the release**

```bash
git tag -a v1.6 -m "v1.6 — workflow polish (A3 + A4 + A5 + A7)"
git push origin v1.6
```

(Tag convention matches the existing `v1.5` tag.)

---

## Acceptance criteria (from spec, restated for completeness)

A Phase 2 implementation is complete when:

- [ ] Settings → Business Profile shows a new "Invoice email" section with Subject + Body fields and the merge-field-aware footer
- [ ] Both fields persist to BusinessProfile on Save and reload on re-open
- [ ] InvoiceDetailView toolbar menu shows "Email invoice" alongside "Share PDF" for non-Draft invoices
- [ ] InvoiceDetailView actionButtons row shows an "Email invoice" bordered button alongside "Share PDF" for non-Draft invoices
- [ ] Tapping "Email invoice" with Mail configured opens MFMailComposeViewController with subject + body rendered from the BusinessProfile templates, PDF auto-attached, recipient pre-filled
- [ ] Tapping "Email invoice" with NO Mail account opens default-mail-handler via mailto: (no attachment)
- [ ] InvoicePreviewView has a primary "Finalize & email" trailing toolbar button + a secondary `…` overflow menu containing "Finalize & share"
- [ ] "Finalize & email" creates the draft, finalizes, renders PDF, and presents the mail composer (or falls back as above)
- [ ] "Finalize & share" preserves the existing iOS share sheet flow
- [ ] InvoiceDetailView toolbar "Send reminder email" now uses ReminderConfig templates instead of hardcoded strings
- [ ] Today running timer card has an inline note field below project name; typing saves to TimeEntry.notes and persists across launches
- [ ] Tapping the elapsed counter on the running card opens a confirmation dialog with Back 5/10/15 min + Adjust to… options
- [ ] The chevron icon is visible next to the elapsed counter signaling it's tappable
- [ ] "Adjust to…" opens a DatePicker sheet limited to ≤ today; saving updates startedAt; the Save button is disabled for future dates
- [ ] Saving with a past time updates `entry.startedAt`; Live Activity / elapsed counter immediately reflects the new elapsed time
- [ ] Clients tab Active section shows "Last invoice: N days ago" as a tertiary-color subtitle under contact name for clients with sent or paid invoices
- [ ] Clients with no sent/paid invoice show no subtitle
- [ ] Archived section's ClientRow shows no last-invoice subtitle
- [ ] App launches cleanly on v1.5 data — no crash on lightweight migration
- [ ] Full BillableCore test suite passes (199 + ~14 new = ~213)
