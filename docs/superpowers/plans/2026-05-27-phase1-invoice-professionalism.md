# Phase 1 Invoice Professionalism — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship A1 (logo upload editor UI), A2 (tax ID / VAT number on profile + PDF), and A8 (inline edit of line-item descriptions on InvoicePreviewView) as a single coherent "invoice professionalism" release on top of v1.4.

**Architecture:** Additive only. Two `String = ""` fields on `BusinessProfile` (`taxIDLabel`, `taxIDNumber`) and two matching `…Snapshot` fields on `Invoice`. One new image-processing helper (pure CoreGraphics, no UIImage) plus a PhotosPicker UI on the existing Business Profile editor. One new editable `lineItemsEditor` subview on `InvoicePreviewView`, backed by a `[UUID: String]` pending-edits dictionary and a 200ms `.task(id:)` debounce so PDF re-render perf is invariant to invoice size. All schema changes are SwiftData lightweight migrations — existing v1.4 records load with empty defaults and no migration code.

**Tech Stack:** Swift 6 · SwiftUI · SwiftData · PhotosUI · ImageIO + CoreGraphics · Swift Testing (`@Suite` / `@Test` / `#expect`) · XCTest UI · Xcode 26 / iOS 26.5

**Spec:** `docs/superpowers/specs/2026-05-27-phase1-invoice-professionalism-design.md` (commit `ad2738c`, confidence 97%)

**Parent state:** v1.4 quality-of-life release (merged to `main`, commit `30f7ce4`, tag `v1.4`)

**Branch:** `feature/v1.5-invoice-professionalism` (worktree off `main`)

**Review pattern:** Single combined review per task. Phase 1 touches no paid-product gates, no subscription state, and no CloudKit-mirrored schema mechanics — all changes are additive editor / template / model fields.

---

## File Structure

### Created files

| Path | Responsibility |
|---|---|
| `Packages/BillableCore/Tests/BillableCoreTests/BusinessProfileTaxIDTests.swift` | Unit tests for the new `taxIDLabel`, `taxIDNumber`, and `hasTaxID` behavior on `BusinessProfile`. |
| `Packages/BillableCore/Tests/BillableCoreTests/InvoiceTaxIDSnapshotTests.swift` | Unit tests asserting that `Invoice` carries the tax ID snapshots and `InvoiceBuilder.createDraft` populates them from a `BusinessProfile`. |
| `Packages/BillableCore/Tests/BillableCoreTests/LogoImageProcessorTests.swift` | Unit tests for the standalone `processLogoData(_:)` helper (downscale, alpha-aware encode, nil on garbage input, no upscale). |
| `App/BillableUITests/InvoicePreviewLineItemEditUITests.swift` | UI test for the A8 editable-description flow on `InvoicePreviewView`. |

### Modified files

| Path | Why |
|---|---|
| `Packages/BillableCore/Sources/BillableCore/Models/BusinessProfile.swift` | Add `taxIDLabel` + `taxIDNumber` + `hasTaxID` computed. Extend `init` with two trailing default-`""` params. |
| `Packages/BillableCore/Sources/BillableCore/Models/Invoice.swift` | Add `issuerTaxIDLabelSnapshot` + `issuerTaxIDNumberSnapshot`. Extend `init` with two trailing default-`""` params. |
| `Packages/BillableCore/Sources/BillableCore/Invoicing/InvoiceBuilder.swift` | Populate the two tax ID snapshots from `profile.taxID…` at `Invoice(...)` construction. |
| `Packages/BillableCore/Sources/BillableCore/Invoicing/InvoiceTemplate.swift` | Extend `InvoiceTemplateData` with `taxIDLabel` + `taxIDNumber` + `hasTaxID`. Add render block in the issuer header (under email). Update `InvoiceTemplateData.from(_:)` to copy from snapshots. |
| `App/Sources/Features/Invoicing/InvoicePreviewView.swift` | A2: pass `profile.taxIDLabel` / `taxIDNumber` into the live `templateData`. A8: convert `lineItems` from `let` to `@State`, add `lineItemsEditor` subview, add `pendingDescriptionEdits` + `.task(id:)` debounce + validation helpers, disable toolbar Finalize when validation fails. |
| `App/Sources/Features/Settings/BusinessProfileEditorView.swift` | A1: add `Logo` section (PhotosPicker + preview + Remove button) and `processLogoData` helper. A2: add Tax ID label + number fields inside the existing Tax section, with disambiguating footer. Add new imports (`PhotosUI`, `ImageIO`, `UniformTypeIdentifiers`). |
| `Packages/BillableCore/Sources/BillableCore/Persistence/MarketingData.swift` | Seed plausible KSA-region sample tax ID values into the demo `BusinessProfile` and into both demo `Invoice` constructions so screenshots show the new field. |
| `Packages/BillableCore/Tests/BillableCoreTests/InvoicePDFRendererTests.swift` | Add tests asserting the tax ID line renders correctly under three states (label+number, number-only, both empty). |

---

## Task 0: Worktree + branch setup

**Files:**
- No file changes. Sets up the isolated workspace.

- [ ] **Step 1: Verify we're on `main` and clean**

Run:
```bash
cd "/Users/lbazerbashi/Elden Studios/billable"
git status --short
git rev-parse --abbrev-ref HEAD
```

Expected: working tree clean (or only `.superpowers/` untracked — session metadata, ignored). Branch is `main`. If not, stop and ask.

- [ ] **Step 2: Pull latest main**

Run:
```bash
git fetch origin && git pull --ff-only origin main
```

Expected: "Already up to date." or a clean fast-forward.

- [ ] **Step 3: Create the worktree on a new branch**

Run:
```bash
git worktree add .worktrees/v1.5-invoice-professionalism -b feature/v1.5-invoice-professionalism
```

Expected: "Preparing worktree (new branch 'feature/v1.5-invoice-professionalism')" plus "HEAD is now at <sha>".

- [ ] **Step 4: cd into the worktree for the rest of the plan**

Run:
```bash
cd ".worktrees/v1.5-invoice-professionalism"
git rev-parse --abbrev-ref HEAD
```

Expected: `feature/v1.5-invoice-professionalism`. All subsequent task steps run from this directory.

- [ ] **Step 5: Verify baseline tests pass before any change**

Run:
```bash
swift test --package-path Packages/BillableCore 2>&1 | tail -5
```

Expected: a line like `Test run with 178 tests in 25 suites passed`.

---

## Task 1: BusinessProfile — tax ID fields (TDD)

**Files:**
- Create: `Packages/BillableCore/Tests/BillableCoreTests/BusinessProfileTaxIDTests.swift`
- Modify: `Packages/BillableCore/Sources/BillableCore/Models/BusinessProfile.swift`

- [ ] **Step 1: Write the failing tests**

Create `Packages/BillableCore/Tests/BillableCoreTests/BusinessProfileTaxIDTests.swift`:

```swift
import Foundation
import Testing
@testable import BillableCore

@Suite("BusinessProfile tax ID")
struct BusinessProfileTaxIDTests {

    @Test("Default BusinessProfile() has empty taxIDLabel and taxIDNumber")
    func defaultsAreEmpty() {
        let profile = BusinessProfile()
        #expect(profile.taxIDLabel == "")
        #expect(profile.taxIDNumber == "")
    }

    @Test("Default BusinessProfile.hasTaxID is false")
    func defaultHasTaxIDFalse() {
        let profile = BusinessProfile()
        #expect(profile.hasTaxID == false)
    }

    @Test("Setting taxIDNumber flips hasTaxID to true")
    func numberFlipsHelper() {
        let profile = BusinessProfile(taxIDNumber: "GB123456789")
        #expect(profile.hasTaxID == true)
    }

    @Test("Setting only taxIDLabel does not flip hasTaxID — label without number is meaningless")
    func labelAloneIsFalse() {
        let profile = BusinessProfile(taxIDLabel: "VAT")
        #expect(profile.hasTaxID == false)
    }

    @Test("Whitespace-only taxIDNumber does not flip hasTaxID")
    func whitespaceOnlyIsFalse() {
        let profile = BusinessProfile(taxIDNumber: "   ")
        #expect(profile.hasTaxID == false)
    }

    @Test("Both fields set: hasTaxID true, both values preserved")
    func bothSet() {
        let profile = BusinessProfile(taxIDLabel: "VAT", taxIDNumber: "GB123456789")
        #expect(profile.hasTaxID == true)
        #expect(profile.taxIDLabel == "VAT")
        #expect(profile.taxIDNumber == "GB123456789")
    }
}
```

- [ ] **Step 2: Run tests, verify they fail**

Run:
```bash
swift test --package-path Packages/BillableCore --filter BusinessProfileTaxIDTests 2>&1 | tail -10
```

Expected: build error like `value of type 'BusinessProfile' has no member 'taxIDLabel'` (or similar). Tests don't compile yet.

- [ ] **Step 3: Add the fields and computed helper to `BusinessProfile`**

Open `Packages/BillableCore/Sources/BillableCore/Models/BusinessProfile.swift`. Locate the `// MARK: - Bank details (v1.4)` block (lines 26–42). Insert a new block immediately after the `hasBankDetails` computed property (just before the `createdAt` declaration around line 44):

```swift
    // MARK: - Tax ID (v1.5 / Phase 1)

    public var taxIDLabel: String = ""   // e.g. "VAT", "GST", "CR No.", "EIN", "TRN"
    public var taxIDNumber: String = ""  // e.g. "GB123456789", "300012345600003"

    /// True when the issuer has a tax registration number to display.
    /// `taxIDLabel` alone does not count — a label without a number is meaningless.
    public var hasTaxID: Bool {
        !taxIDNumber.trimmingCharacters(in: .whitespaces).isEmpty
    }
```

- [ ] **Step 4: Extend the `init(...)` signature with the two new trailing params**

In the same file, find the `public init(` block (line 47). Insert two new parameters between `bankSWIFT: String = "",` and `createdAt: Date = .now,`:

```swift
        bankSWIFT: String = "",
        taxIDLabel: String = "",
        taxIDNumber: String = "",
        createdAt: Date = .now,
```

Then in the init body (after `self.bankSWIFT = bankSWIFT`, around line 84), add the assignments:

```swift
        self.bankSWIFT = bankSWIFT
        self.taxIDLabel = taxIDLabel
        self.taxIDNumber = taxIDNumber
        self.createdAt = createdAt
```

- [ ] **Step 5: Run tests, verify they pass**

Run:
```bash
swift test --package-path Packages/BillableCore --filter BusinessProfileTaxIDTests 2>&1 | tail -10
```

Expected: `Test Suite 'BusinessProfile tax ID' passed`, 6 tests passing.

- [ ] **Step 6: Run the full BillableCore test suite to confirm no regressions**

Run:
```bash
swift test --package-path Packages/BillableCore 2>&1 | tail -5
```

Expected: total test count is 178 + 6 = 184 (or higher if other tasks have already added tests). All passing.

- [ ] **Step 7: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Models/BusinessProfile.swift Packages/BillableCore/Tests/BillableCoreTests/BusinessProfileTaxIDTests.swift
git commit -m "feat(model): add taxIDLabel + taxIDNumber + hasTaxID to BusinessProfile

Two additive String fields (default \"\") parallel to the v1.4 bank
fields. Computed hasTaxID gates display: number-only is enough; label
alone is meaningless.

Closes A2 model layer in Phase 1 spec.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 2: Invoice — tax ID snapshot fields (TDD)

**Files:**
- Create: `Packages/BillableCore/Tests/BillableCoreTests/InvoiceTaxIDSnapshotTests.swift`
- Modify: `Packages/BillableCore/Sources/BillableCore/Models/Invoice.swift`

- [ ] **Step 1: Write the failing tests**

Create `Packages/BillableCore/Tests/BillableCoreTests/InvoiceTaxIDSnapshotTests.swift`:

```swift
import Foundation
import Testing
@testable import BillableCore

@Suite("Invoice tax ID snapshots")
struct InvoiceTaxIDSnapshotTests {

    @Test("Invoice with no explicit tax ID snapshot args has empty snapshots")
    func defaultsAreEmpty() {
        let invoice = Invoice(
            number: "INV-0001",
            dueAt: Date(timeIntervalSince1970: 0),
            clientNameSnapshot: "Acme",
            issuerNameSnapshot: "Studio",
            issuerAddressSnapshot: "123 Main",
            issuerEmailSnapshot: "hi@studio.example",
            paymentTermsSnapshot: "Net 14",
            taxLabelSnapshot: "Tax",
            taxRateSnapshot: 0,
            currencyCodeSnapshot: "USD"
        )
        #expect(invoice.issuerTaxIDLabelSnapshot == "")
        #expect(invoice.issuerTaxIDNumberSnapshot == "")
    }

    @Test("Invoice preserves explicit tax ID snapshots")
    func explicitSnapshotsPreserved() {
        let invoice = Invoice(
            number: "INV-0001",
            dueAt: Date(timeIntervalSince1970: 0),
            clientNameSnapshot: "Acme",
            issuerNameSnapshot: "Studio",
            issuerAddressSnapshot: "123 Main",
            issuerEmailSnapshot: "hi@studio.example",
            issuerTaxIDLabelSnapshot: "VAT",
            issuerTaxIDNumberSnapshot: "GB123456789",
            paymentTermsSnapshot: "Net 14",
            taxLabelSnapshot: "Tax",
            taxRateSnapshot: 0,
            currencyCodeSnapshot: "USD"
        )
        #expect(invoice.issuerTaxIDLabelSnapshot == "VAT")
        #expect(invoice.issuerTaxIDNumberSnapshot == "GB123456789")
    }
}
```

- [ ] **Step 2: Run tests, verify they fail**

Run:
```bash
swift test --package-path Packages/BillableCore --filter InvoiceTaxIDSnapshotTests 2>&1 | tail -10
```

Expected: build error — `Invoice` has no member `issuerTaxIDLabelSnapshot` (or the init doesn't accept the new params).

- [ ] **Step 3: Add the two new fields to `Invoice`**

Open `Packages/BillableCore/Sources/BillableCore/Models/Invoice.swift`. Locate the existing bank-detail snapshot block (lines 39–43). Insert two new fields immediately after `issuerBankSWIFTSnapshot` (line 43), before `paymentTermsSnapshot` (line 44):

```swift
    public var issuerBankSWIFTSnapshot: String = ""
    public var issuerTaxIDLabelSnapshot: String = ""
    public var issuerTaxIDNumberSnapshot: String = ""
    public var paymentTermsSnapshot: String
```

- [ ] **Step 4: Extend the `init(...)` signature**

In the same file, find the `public init(` block (line 72). Insert two new parameters between `issuerBankSWIFTSnapshot: String = "",` (line 90) and `paymentTermsSnapshot: String,` (line 91):

```swift
        issuerBankSWIFTSnapshot: String = "",
        issuerTaxIDLabelSnapshot: String = "",
        issuerTaxIDNumberSnapshot: String = "",
        paymentTermsSnapshot: String,
```

In the init body (around line 118, after `self.issuerBankSWIFTSnapshot = issuerBankSWIFTSnapshot`), add the assignments:

```swift
        self.issuerBankSWIFTSnapshot = issuerBankSWIFTSnapshot
        self.issuerTaxIDLabelSnapshot = issuerTaxIDLabelSnapshot
        self.issuerTaxIDNumberSnapshot = issuerTaxIDNumberSnapshot
        self.paymentTermsSnapshot = paymentTermsSnapshot
```

- [ ] **Step 5: Run tests, verify they pass**

Run:
```bash
swift test --package-path Packages/BillableCore --filter InvoiceTaxIDSnapshotTests 2>&1 | tail -10
```

Expected: 2 tests passing.

- [ ] **Step 6: Run the full BillableCore test suite — no regressions**

Run:
```bash
swift test --package-path Packages/BillableCore 2>&1 | tail -5
```

Expected: all tests pass. New count: previous + 2.

- [ ] **Step 7: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Models/Invoice.swift Packages/BillableCore/Tests/BillableCoreTests/InvoiceTaxIDSnapshotTests.swift
git commit -m "feat(model): add issuerTaxID snapshot fields to Invoice

Two additive String snapshot fields (default \"\") parallel to the
existing issuerBank…Snapshot fields. Freezes the tax registration
info at invoice finalize time so historical invoices keep rendering
correctly even if the user later edits or clears their tax ID.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 3: InvoiceBuilder.createDraft — propagate tax ID (TDD)

**Files:**
- Modify: `Packages/BillableCore/Sources/BillableCore/Invoicing/InvoiceBuilder.swift`
- Modify: `Packages/BillableCore/Tests/BillableCoreTests/InvoiceBuilderTests.swift`

- [ ] **Step 1: Add a failing test to `InvoiceBuilderTests.swift`**

Append to `Packages/BillableCore/Tests/BillableCoreTests/InvoiceBuilderTests.swift` (inside any existing `@Suite` or add a new one — match the existing file's pattern):

```swift
@Suite("InvoiceBuilder tax ID propagation")
@MainActor
struct InvoiceBuilderTaxIDTests {

    @Test("createDraft snapshots profile.taxIDLabel and taxIDNumber onto the Invoice")
    func taxIDSnapshot() throws {
        let container = try ModelContainer(
            for: BusinessProfile.self, Client.self, Project.self,
                 TimeEntry.self, Invoice.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let profile = BusinessProfile(
            name: "Studio",
            email: "hi@studio.example",
            taxIDLabel: "VAT",
            taxIDNumber: "GB123456789"
        )
        context.insert(profile)
        let client = Client(name: "Acme", color: .blue)
        context.insert(client)

        let lineItems = [InvoiceLineItem(description: "Work", hours: 1, hourlyRate: 100)]
        let invoice = try InvoiceBuilder.createDraft(
            for: client,
            lineItems: lineItems,
            profile: profile,
            context: context
        )

        #expect(invoice.issuerTaxIDLabelSnapshot == "VAT")
        #expect(invoice.issuerTaxIDNumberSnapshot == "GB123456789")
    }

    @Test("createDraft snapshots empty tax ID when profile has empty fields")
    func emptyTaxIDSnapshot() throws {
        let container = try ModelContainer(
            for: BusinessProfile.self, Client.self, Project.self,
                 TimeEntry.self, Invoice.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let profile = BusinessProfile(name: "Studio", email: "hi@studio.example")
        context.insert(profile)
        let client = Client(name: "Acme", color: .blue)
        context.insert(client)

        let invoice = try InvoiceBuilder.createDraft(
            for: client,
            lineItems: [InvoiceLineItem(description: "Work", hours: 1, hourlyRate: 100)],
            profile: profile,
            context: context
        )

        #expect(invoice.issuerTaxIDLabelSnapshot == "")
        #expect(invoice.issuerTaxIDNumberSnapshot == "")
    }

    @Test("createDraft continues to snapshot profile.logoData (A1 regression guard)")
    func logoSnapshotRegression() throws {
        let container = try ModelContainer(
            for: BusinessProfile.self, Client.self, Project.self,
                 TimeEntry.self, Invoice.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let logoBytes = Data([0xFF, 0xD8, 0xFF, 0xE0])  // arbitrary non-empty
        let profile = BusinessProfile(name: "Studio", email: "hi@studio.example", logoData: logoBytes)
        context.insert(profile)
        let client = Client(name: "Acme", color: .blue)
        context.insert(client)

        let invoice = try InvoiceBuilder.createDraft(
            for: client,
            lineItems: [InvoiceLineItem(description: "Work", hours: 1, hourlyRate: 100)],
            profile: profile,
            context: context
        )

        #expect(invoice.issuerLogoSnapshot == logoBytes)
    }
}
```

Add `import SwiftData` at the top of the file if not already imported.

- [ ] **Step 2: Run tests, verify the new tax ID tests fail**

Run:
```bash
swift test --package-path Packages/BillableCore --filter InvoiceBuilderTaxIDTests 2>&1 | tail -15
```

Expected: 2 tax ID tests FAIL (`""` ≠ `"VAT"`). The logo regression test PASSES (logo is already snapshotted by current code).

- [ ] **Step 3: Wire `profile.taxID…` into `InvoiceBuilder.createDraft`'s `Invoice(...)` call**

Open `Packages/BillableCore/Sources/BillableCore/Invoicing/InvoiceBuilder.swift`. Locate the `Invoice(` constructor inside `createDraft` (around lines 126–151). Insert two new arguments between `issuerBankSWIFTSnapshot: profile.bankSWIFT,` and `paymentTermsSnapshot: profile.paymentTerms,`:

```swift
            issuerBankSWIFTSnapshot: profile.bankSWIFT,
            issuerTaxIDLabelSnapshot: profile.taxIDLabel,
            issuerTaxIDNumberSnapshot: profile.taxIDNumber,
            paymentTermsSnapshot: profile.paymentTerms,
```

- [ ] **Step 4: Run tests, verify they pass**

Run:
```bash
swift test --package-path Packages/BillableCore --filter InvoiceBuilderTaxIDTests 2>&1 | tail -10
```

Expected: 3 tests passing.

- [ ] **Step 5: Run the full BillableCore test suite — no regressions**

Run:
```bash
swift test --package-path Packages/BillableCore 2>&1 | tail -5
```

Expected: all passing.

- [ ] **Step 6: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Invoicing/InvoiceBuilder.swift Packages/BillableCore/Tests/BillableCoreTests/InvoiceBuilderTests.swift
git commit -m "feat(invoice): propagate profile tax ID into Invoice snapshots

InvoiceBuilder.createDraft now passes profile.taxIDLabel and
profile.taxIDNumber into the new Invoice snapshot fields. Includes
a regression test for the existing logoData snapshot path (which
was already wired but had no explicit test).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 4: InvoiceTemplateData + PDF rendering (TDD)

**Files:**
- Modify: `Packages/BillableCore/Sources/BillableCore/Invoicing/InvoiceTemplate.swift`
- Modify: `Packages/BillableCore/Tests/BillableCoreTests/InvoicePDFRendererTests.swift`

- [ ] **Step 1: Add failing PDF tests for tax ID rendering**

Open `Packages/BillableCore/Tests/BillableCoreTests/InvoicePDFRendererTests.swift`. Append the following inside the existing `@Suite("InvoicePDFRenderer")` struct (alongside the existing bank-detail tests):

```swift
    @Test("renders 'VAT GB123456789' in header when label and number are both set")
    func taxID_labelAndNumber() {
        var data = fixtureData()
        data.taxIDLabel = "VAT"
        data.taxIDNumber = "GB123456789"
        let bytes = InvoicePDFRenderer.renderPDFData(for: data, accent: .blue)
        let doc = PDFDocument(data: bytes)!
        let text = doc.string ?? ""
        #expect(text.contains("VAT GB123456789"))
    }

    @Test("renders just the number (no leading space) when label is empty")
    func taxID_numberOnly() {
        var data = fixtureData()
        data.taxIDLabel = ""
        data.taxIDNumber = "GB123456789"
        let bytes = InvoicePDFRenderer.renderPDFData(for: data, accent: .blue)
        let doc = PDFDocument(data: bytes)!
        let text = doc.string ?? ""
        #expect(text.contains("GB123456789"))
        // No leading space artifact: the number must NOT be preceded by a space-then-newline pattern
        // (a "\n GB…" would indicate a stray empty-label concatenation).
        #expect(!text.contains(" GB123456789"))
    }

    @Test("does NOT render tax ID line when number is empty")
    func taxID_omittedWhenNumberEmpty() {
        var data = fixtureData()
        data.taxIDLabel = "VAT"
        data.taxIDNumber = ""
        let bytes = InvoicePDFRenderer.renderPDFData(for: data, accent: .blue)
        let doc = PDFDocument(data: bytes)!
        let text = doc.string ?? ""
        #expect(!text.contains("VAT"))
        #expect(!text.contains("GB123456789"))
    }

    @Test("does NOT render tax ID line when both fields empty")
    func taxID_omittedWhenBothEmpty() {
        let data = fixtureData()  // defaults already empty
        let bytes = InvoicePDFRenderer.renderPDFData(for: data, accent: .blue)
        let doc = PDFDocument(data: bytes)!
        // Smoke: PDF still renders, no crash.
        #expect(!(doc.string ?? "").isEmpty)
    }

    @Test("trims whitespace label to avoid double-spacing")
    func taxID_trimsLabelWhitespace() {
        var data = fixtureData()
        data.taxIDLabel = "VAT "   // trailing space
        data.taxIDNumber = "GB123"
        let bytes = InvoicePDFRenderer.renderPDFData(for: data, accent: .blue)
        let doc = PDFDocument(data: bytes)!
        let text = doc.string ?? ""
        #expect(text.contains("VAT GB123"))
        #expect(!text.contains("VAT  GB123"))  // no double space
    }
```

- [ ] **Step 2: Run tests, verify they fail**

Run:
```bash
swift test --package-path Packages/BillableCore --filter InvoicePDFRenderer 2>&1 | tail -15
```

Expected: 5 new tests fail with `value of type 'InvoiceTemplateData' has no member 'taxIDLabel'` (build error). Existing PDF tests still pass.

- [ ] **Step 3: Add the tax ID fields to `InvoiceTemplateData`**

Open `Packages/BillableCore/Sources/BillableCore/Invoicing/InvoiceTemplate.swift`. Locate the bank fields block in `InvoiceTemplateData` (lines 335–346). Insert tax ID fields immediately after the `hasBankDetails` computed property (around line 347), before `watermark` (line 348):

```swift
    public var bankSWIFT: String = ""

    public var hasBankDetails: Bool {
        !bankBeneficiaryName.isEmpty
            || !bankName.isEmpty
            || !bankIBAN.isEmpty
            || !bankSWIFT.isEmpty
    }

    public var taxIDLabel: String = ""
    public var taxIDNumber: String = ""

    public var hasTaxID: Bool {
        !taxIDNumber.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public var watermark: String?  // nil for Pro/trial, "Sent with Cadence" for free
```

- [ ] **Step 4: Update `InvoiceTemplateData.from(_ invoice:)` to copy snapshots**

In the same file, locate the `InvoiceTemplateData.from(_ invoice:)` factory (around line 397). After the existing bank-field assignments (line 427: `data.bankSWIFT = invoice.issuerBankSWIFTSnapshot`), add:

```swift
        data.bankSWIFT = invoice.issuerBankSWIFTSnapshot
        data.taxIDLabel = invoice.issuerTaxIDLabelSnapshot
        data.taxIDNumber = invoice.issuerTaxIDNumberSnapshot
        return data
```

- [ ] **Step 5: Render the tax ID row in the issuer header block**

In the same file, locate the `header` computed view (lines 51–85). Inside the leading `VStack(alignment: .leading, spacing: 6)`, after the existing `issuerEmail` row block (lines 68–72), insert the tax ID render block. The final shape of the issuer VStack should look like this — replace lines 53–73 with:

```swift
            VStack(alignment: .leading, spacing: 6) {
                if let logo = data.issuerLogo, let image = imageFromData(logo) {
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(height: 44)
                        .padding(.bottom, 4)
                }
                Text(data.issuerName)
                    .font(.system(size: 16, weight: .semibold))
                if !data.issuerAddress.isEmpty {
                    Text(data.issuerAddress)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if !data.issuerEmail.isEmpty {
                    Text(data.issuerEmail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if data.hasTaxID {
                    Text(taxIDDisplay)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
```

- [ ] **Step 6: Add the `taxIDDisplay` helper**

In the same file, near the existing private helpers (`formatMoney`, `formatHours`, `formatPercent` around lines 271–285), add the helper:

```swift
    /// "VAT GB123456789" if label+number; "GB123456789" if only number.
    /// Trims leading/trailing whitespace on the label to avoid double spaces.
    private var taxIDDisplay: String {
        let trimmedLabel = data.taxIDLabel.trimmingCharacters(in: .whitespaces)
        return trimmedLabel.isEmpty
            ? data.taxIDNumber
            : "\(trimmedLabel) \(data.taxIDNumber)"
    }
```

- [ ] **Step 7: Run tests, verify all 5 new + existing pass**

Run:
```bash
swift test --package-path Packages/BillableCore --filter InvoicePDFRenderer 2>&1 | tail -15
```

Expected: all PDF tests pass (existing + 5 new).

- [ ] **Step 8: Run the full BillableCore test suite — no regressions**

Run:
```bash
swift test --package-path Packages/BillableCore 2>&1 | tail -5
```

Expected: all passing.

- [ ] **Step 9: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Invoicing/InvoiceTemplate.swift Packages/BillableCore/Tests/BillableCoreTests/InvoicePDFRendererTests.swift
git commit -m "feat(invoice): render tax ID row in PDF issuer header

InvoiceTemplateData gains taxIDLabel + taxIDNumber + hasTaxID
(matching the bank-fields pattern). InvoiceTemplate renders a
single Text row under the issuer email when hasTaxID is true.

taxIDDisplay helper trims label whitespace to avoid double-space
artifacts; empty label → just the number; empty number → no row.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 5: InvoicePreviewView — pass tax ID into live templateData

**Files:**
- Modify: `App/Sources/Features/Invoicing/InvoicePreviewView.swift`

- [ ] **Step 1: Locate the templateData computed property**

Run:
```bash
grep -n "data.bankSWIFT\|return data" App/Sources/Features/Invoicing/InvoicePreviewView.swift
```

Expected: around line 79 (`data.bankSWIFT = profile.bankSWIFT`) and line 80 (`return data`).

- [ ] **Step 2: Add tax ID pass-through**

In `App/Sources/Features/Invoicing/InvoicePreviewView.swift`, locate the bank-field assignment block (lines 75–79). Replace those lines plus the `return data` line with:

```swift
        data.bankBeneficiaryName = profile.bankBeneficiaryName
        data.bankName = profile.bankName
        data.bankLocation = profile.bankLocation
        data.bankIBAN = profile.bankIBAN
        data.bankSWIFT = profile.bankSWIFT
        data.taxIDLabel = profile.taxIDLabel
        data.taxIDNumber = profile.taxIDNumber
        return data
```

- [ ] **Step 3: Build the app target to confirm it compiles**

Run:
```bash
xcodebuild -project Billable.xcodeproj -scheme Billable -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "error:|warning:|BUILD SUCCEEDED|BUILD FAILED" | head -5
```

Expected: `** BUILD SUCCEEDED **`, no warnings.

- [ ] **Step 4: Commit**

```bash
git add App/Sources/Features/Invoicing/InvoicePreviewView.swift
git commit -m "feat(invoice): pass profile tax ID into live preview template

InvoicePreviewView.templateData now propagates profile.taxIDLabel
and profile.taxIDNumber into the live InvoiceTemplate render. The
preview screen now shows the same tax ID line a finalized invoice
would (modulo the snapshot/live distinction).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 6: MarketingData seeder — sample tax ID values

**Files:**
- Modify: `Packages/BillableCore/Sources/BillableCore/Persistence/MarketingData.swift`

- [ ] **Step 1: Add tax ID values to the demo profile**

Open `Packages/BillableCore/Sources/BillableCore/Persistence/MarketingData.swift`. Locate the `let profile = BusinessProfile(` construction (around line 16). Add two new arguments after `bankSWIFT: "CHASUS33"` (around line 32), before the closing `)`:

```swift
            bankSWIFT: "CHASUS33",
            taxIDLabel: "EIN",
            taxIDNumber: "12-3456789"
```

(Studio Lina is fictionally US-based in the seed data, so EIN is the right Tax ID label.)

- [ ] **Step 2: Add tax ID snapshots to both demo Invoices**

In the same file, locate the `let sentInvoice = Invoice(` construction (around line 115). After the `issuerBankSWIFTSnapshot: "CHASUS33",` line, add:

```swift
            issuerBankSWIFTSnapshot: "CHASUS33",
            issuerTaxIDLabelSnapshot: "EIN",
            issuerTaxIDNumberSnapshot: "12-3456789",
```

Then do the same for the `let draftInvoice = Invoice(` construction further down — add the same two lines after its `issuerBankSWIFTSnapshot`.

- [ ] **Step 3: Build to verify compilation**

Run:
```bash
swift build --package-path Packages/BillableCore 2>&1 | tail -5
```

Expected: build succeeds.

- [ ] **Step 4: Run the full test suite**

Run:
```bash
swift test --package-path Packages/BillableCore 2>&1 | tail -5
```

Expected: all passing.

- [ ] **Step 5: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Persistence/MarketingData.swift
git commit -m "feat(marketing): seed sample tax ID into demo profile + invoices

EIN 12-3456789 on Studio Lina (the US-based fictional issuer) so
App Store screenshots taken with --seed-marketing show the new
tax-ID line in the rendered PDF header.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 7: processLogoData helper — pure CoreGraphics + tests (TDD)

**Files:**
- Create: `Packages/BillableCore/Tests/BillableCoreTests/LogoImageProcessorTests.swift`
- Modify: `App/Sources/Features/Settings/BusinessProfileEditorView.swift` (imports + helper added in a later step; first we colocate the helper into BillableCore so it's testable)

> **Design note:** `processLogoData` is defined here in BillableCore (not on the editor view) for two reasons: (1) it has no view dependency — pure Data → Data — and (2) hosting it in the package makes it unit-testable without bringing up the iOS app target. The editor view will call it via the package's public surface in Task 9.

- [ ] **Step 1: Create the failing tests**

Create `Packages/BillableCore/Tests/BillableCoreTests/LogoImageProcessorTests.swift`:

```swift
import Foundation
import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import BillableCore

@Suite("LogoImageProcessor")
struct LogoImageProcessorTests {

    // Helper: generate a synthetic source image of (w x h) px, with or without alpha.
    private func makeImageData(width: Int, height: Int, hasAlpha: Bool) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 = hasAlpha
            ? CGImageAlphaInfo.premultipliedLast.rawValue
            : CGImageAlphaInfo.noneSkipLast.rawValue
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        )!
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: hasAlpha ? 0.7 : 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cg = context.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    private func dimensions(of data: Data) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { return nil }
        return (image.width, image.height)
    }

    @Test("Downscales 4000x3000 source so largest dim ≤ 1024")
    func downscalesLargeSource() {
        let source = makeImageData(width: 4000, height: 3000, hasAlpha: false)
        let processed = LogoImageProcessor.process(source)
        #expect(processed != nil)
        let (w, h) = dimensions(of: processed!)!
        #expect(max(w, h) <= 1024)
        // Aspect ratio preserved approximately (within 1px rounding)
        let ratio = Double(w) / Double(h)
        #expect(abs(ratio - 4.0 / 3.0) < 0.02)
    }

    @Test("Does NOT upscale a 32x32 source")
    func doesNotUpscale() {
        let source = makeImageData(width: 32, height: 32, hasAlpha: false)
        let processed = LogoImageProcessor.process(source)
        #expect(processed != nil)
        let (w, h) = dimensions(of: processed!)!
        #expect(w == 32 && h == 32)
    }

    @Test("Encodes JPEG for opaque source")
    func encodesJPEGForOpaque() {
        let source = makeImageData(width: 100, height: 100, hasAlpha: false)
        let processed = LogoImageProcessor.process(source)
        #expect(processed != nil)
        // JPEGs start with FF D8 FF
        let header = processed!.prefix(3)
        #expect(Array(header) == [0xFF, 0xD8, 0xFF])
    }

    @Test("Encodes PNG for transparent source")
    func encodesPNGForTransparent() {
        let source = makeImageData(width: 100, height: 100, hasAlpha: true)
        let processed = LogoImageProcessor.process(source)
        #expect(processed != nil)
        // PNGs start with 89 50 4E 47 (\x89PNG)
        let header = processed!.prefix(4)
        #expect(Array(header) == [0x89, 0x50, 0x4E, 0x47])
    }

    @Test("Returns nil for non-image data")
    func returnsNilForGarbage() {
        let garbage = Data("not an image, just words".utf8)
        let processed = LogoImageProcessor.process(garbage)
        #expect(processed == nil)
    }
}
```

- [ ] **Step 2: Run tests, verify they fail**

Run:
```bash
swift test --package-path Packages/BillableCore --filter LogoImageProcessor 2>&1 | tail -10
```

Expected: build error — `cannot find 'LogoImageProcessor' in scope`.

- [ ] **Step 3: Create the public helper in BillableCore**

Create `Packages/BillableCore/Sources/BillableCore/Invoicing/LogoImageProcessor.swift`:

```swift
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Resizes and re-encodes a logo image for storage on `BusinessProfile.logoData`.
///
/// Pure CoreGraphics + ImageIO — no UIImage. Safe under Swift 6 strict
/// concurrency, callable from any actor / task.
///
/// `CGImageSourceCreateThumbnailAtIndex` is the memory-safe path for large
/// source images: a 50 MP photo would be ~150 MB decoded, but the thumbnail
/// path decodes directly at the target size (~4 MB at 1024 px).
public enum LogoImageProcessor {

    /// Max pixels on the longest dimension. Output is bounded by this; smaller
    /// inputs are NOT upscaled.
    public static let maxDimension: CGFloat = 1024

    /// Resize so largest dim ≤ `maxDimension` and re-encode as PNG (if the
    /// source has alpha) or JPEG quality 0.85 (otherwise). Returns nil on
    /// failure (e.g., non-image data, unsupported format).
    public static func process(_ data: Data) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceShouldCache: false,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOptions as CFDictionary) else {
            return nil
        }

        // Alpha-aware encode: PNG if alpha present, JPEG otherwise.
        let alphaInfo = cgImage.alphaInfo
        let hasAlpha = alphaInfo != .none && alphaInfo != .noneSkipFirst && alphaInfo != .noneSkipLast
        let utType: CFString = hasAlpha
            ? UTType.png.identifier as CFString
            : UTType.jpeg.identifier as CFString

        let outData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(outData as CFMutableData, utType, 1, nil) else {
            return nil
        }
        let properties: [CFString: Any] = hasAlpha
            ? [:]
            : [kCGImageDestinationLossyCompressionQuality: 0.85]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return outData as Data
    }
}
```

- [ ] **Step 4: Run tests, verify they pass**

Run:
```bash
swift test --package-path Packages/BillableCore --filter LogoImageProcessor 2>&1 | tail -10
```

Expected: 5 tests passing.

- [ ] **Step 5: Run the full BillableCore suite — no regressions**

Run:
```bash
swift test --package-path Packages/BillableCore 2>&1 | tail -5
```

Expected: all passing.

- [ ] **Step 6: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Invoicing/LogoImageProcessor.swift Packages/BillableCore/Tests/BillableCoreTests/LogoImageProcessorTests.swift
git commit -m "feat(logo): pure-CoreGraphics image processor for upload pipeline

LogoImageProcessor.process(_ data: Data) -> Data? handles the
PhotosPicker → BusinessProfile.logoData transformation:

- CGImageSourceCreateThumbnailAtIndex (memory-safe; decodes directly
  at target size rather than loading the full source)
- Largest dimension clamped to 1024 px; never upscales
- Alpha-aware: PNG if source has transparency, JPEG 0.85 otherwise
- Pure CoreGraphics + ImageIO + UTType; no UIImage, fully Sendable

Five unit tests cover downscale, no-upscale, JPEG/PNG selection,
and garbage-input behavior.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 8: BusinessProfileEditorView — Logo section UI

**Files:**
- Modify: `App/Sources/Features/Settings/BusinessProfileEditorView.swift`

- [ ] **Step 1: Add new imports**

Open `App/Sources/Features/Settings/BusinessProfileEditorView.swift`. Replace the existing import block (lines 1–3) with:

```swift
import SwiftUI
import SwiftData
import PhotosUI
import BillableCore
```

(`ImageIO` and `UniformTypeIdentifiers` are NOT needed here — the encoding lives in `LogoImageProcessor`.)

- [ ] **Step 2: Add `@State` declarations for logo + picker**

In the same file, locate the existing `@State` block (lines 13–33). After `@State private var bankSWIFT: String = ""` (line 31) and before `@State private var hasLoaded = false` (line 33), insert:

```swift
    @State private var bankSWIFT: String = ""

    @State private var logoData: Data?
    @State private var logoPickerItem: PhotosPickerItem?

    @State private var hasLoaded = false
```

- [ ] **Step 3: Add the Logo section to the Form**

In the same file, locate the `Section { ... } header: { Text("Bank details") } footer: { ... }` block (around lines 80–97). Insert a new Logo section IMMEDIATELY BEFORE it:

```swift
            Section {
                if let data = logoData, let image = uiImageFromData(data) {
                    HStack {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 80, height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary, lineWidth: 1))
                        Spacer()
                        Button(role: .destructive) {
                            logoData = nil
                            logoPickerItem = nil
                        } label: {
                            Text("Remove")
                        }
                    }
                }
                PhotosPicker(
                    selection: $logoPickerItem,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    Label(logoData == nil ? "Upload logo" : "Change logo",
                          systemImage: "photo.on.rectangle.angled")
                }
                .onChange(of: logoPickerItem) { _, newItem in
                    Task { await loadAndProcessLogo(from: newItem) }
                }
            } header: {
                Text("Logo")
            } footer: {
                Text("Shown in the top-left of every invoice PDF. Square logos work best.")
            }

            Section {
                TextField("Beneficiary name", text: $bankBeneficiaryName)
                    // ... rest of the existing Bank details section ...
```

(The "Section { TextField("Beneficiary name"..." block above is the existing Bank details section — don't actually re-type it; just insert the Logo section before it.)

- [ ] **Step 4: Add the `loadAndProcessLogo` + `uiImageFromData` helpers**

In the same file, locate `private func newProfile() -> BusinessProfile { ... }` (around line 154). Add two new helper methods just before it:

```swift
    private func loadAndProcessLogo(from item: PhotosPickerItem?) async {
        guard let item else { return }
        guard let rawData = try? await item.loadTransferable(type: Data.self) else { return }
        // Process off the main actor to avoid blocking the UI on a large source image.
        let processed = await Task.detached(priority: .userInitiated) {
            LogoImageProcessor.process(rawData)
        }.value
        guard let processed else { return }
        await MainActor.run { logoData = processed }
    }

    private func uiImageFromData(_ data: Data) -> UIImage? {
        // UIImage is only used here on the main actor for the editor's read-only
        // display. The off-main encoding path uses pure CoreGraphics via
        // LogoImageProcessor.
        UIImage(data: data)
    }

    private func newProfile() -> BusinessProfile {
        let p = BusinessProfile.defaultForCurrentLocale()
        modelContext.insert(p)
        return p
    }
```

- [ ] **Step 5: Wire logo into load and save**

In the same file, locate `loadIfNeeded()` (line 111). The last line in that function body is currently `bankSWIFT = profile.bankSWIFT` immediately before the closing `}`. Insert ONE new line between them:

```swift
        logoData = profile.logoData
```

The resulting tail of `loadIfNeeded()` should read:

```swift
        bankSWIFT = profile.bankSWIFT
        logoData = profile.logoData      // ← new line
    }
```

Then locate `save()` (line 132). Find the existing `profile.bankSWIFT = bankSWIFT` line, followed by the existing `profile.updatedAt = .now` line. Insert ONE new line between them:

```swift
        profile.logoData = logoData
```

The resulting save() snippet should read:

```swift
        profile.bankSWIFT = bankSWIFT
        profile.logoData = logoData      // ← new line
        profile.updatedAt = .now
```

- [ ] **Step 6: Build and confirm**

Run:
```bash
xcodebuild -project Billable.xcodeproj -scheme Billable -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "error:|warning:|BUILD SUCCEEDED|BUILD FAILED" | head -10
```

Expected: `** BUILD SUCCEEDED **`, no warnings.

- [ ] **Step 7: Commit**

```bash
git add App/Sources/Features/Settings/BusinessProfileEditorView.swift
git commit -m "feat(settings): logo upload section on Business Profile editor

Adds a 'Logo' section with:
- PhotosPicker (matches .images)
- Inline 80x80 preview when set, with rounded corners + border
- Destructive 'Remove' button that clears both logoData and the
  PhotosPickerItem state (so re-picking the same image works)

PhotosPicker → loadAndProcessLogo (off main via Task.detached) →
LogoImageProcessor.process (pure CoreGraphics) → main-actor write
to @State logoData → persisted to profile.logoData on Save.

The PDF rendering pipeline already consumed profile.logoData
end-to-end (snapshotted in Invoice.issuerLogoSnapshot during
finalization, rendered by InvoiceTemplate.header). This task only
adds the missing editor UI.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 9: BusinessProfileEditorView — Tax ID fields (A2 UI)

**Files:**
- Modify: `App/Sources/Features/Settings/BusinessProfileEditorView.swift`

- [ ] **Step 1: Add `@State` for tax ID fields**

Open `App/Sources/Features/Settings/BusinessProfileEditorView.swift`. Locate the existing `taxRatePercent` declaration (line 25). After it, before the bank-detail `@State` block (line 27), insert:

```swift
    @State private var taxRatePercent: Double = 0   // displayed as a percentage; converted to Decimal 0..1 on save

    @State private var taxIDLabel: String = ""
    @State private var taxIDNumber: String = ""

    @State private var bankBeneficiaryName: String = ""
```

- [ ] **Step 2: Extend the Tax section with the two new fields + disambiguating footer**

In the same file, locate the existing `Section("Tax") { ... }` block (around line 66). Replace it with:

```swift
            Section {
                TextField("Tax label (Tax, VAT, GST, …)", text: $taxLabel)
                HStack {
                    Text("Rate")
                    Spacer()
                    TextField("0", value: $taxRatePercent, format: .number.precision(.fractionLength(0...3)))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 100)
                    Text("%")
                        .foregroundStyle(.secondary)
                }
                TextField("Tax ID label (VAT, CR, EIN, …)", text: $taxIDLabel)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                TextField("Tax ID / VAT number", text: $taxIDNumber)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
            } header: {
                Text("Tax")
            } footer: {
                Text("Tax label appears next to the rate on invoice totals. Tax ID label appears with your registration number in the issuer header — leave both blank to hide.")
            }
```

- [ ] **Step 3: Wire into load and save**

In `loadIfNeeded()`, find the existing `taxRatePercent = (profile.taxRate as NSDecimalNumber).doubleValue * 100` line, followed by the existing `bankBeneficiaryName = profile.bankBeneficiaryName` line. Insert TWO new lines between them:

```swift
        taxIDLabel = profile.taxIDLabel
        taxIDNumber = profile.taxIDNumber
```

The resulting snippet should read:

```swift
        taxRatePercent = (profile.taxRate as NSDecimalNumber).doubleValue * 100
        taxIDLabel = profile.taxIDLabel        // ← new line
        taxIDNumber = profile.taxIDNumber      // ← new line
        bankBeneficiaryName = profile.bankBeneficiaryName
```

In `save()`, find the existing `profile.taxRate = Decimal(taxRatePercent / 100)` line, followed by the existing `profile.bankBeneficiaryName = bankBeneficiaryName` line. Insert TWO new lines between them:

```swift
        profile.taxIDLabel = taxIDLabel
        profile.taxIDNumber = taxIDNumber
```

The resulting snippet should read:

```swift
        profile.taxRate = Decimal(taxRatePercent / 100)
        profile.taxIDLabel = taxIDLabel              // ← new line
        profile.taxIDNumber = taxIDNumber            // ← new line
        profile.bankBeneficiaryName = bankBeneficiaryName
```

- [ ] **Step 4: Build and confirm**

Run:
```bash
xcodebuild -project Billable.xcodeproj -scheme Billable -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "error:|warning:|BUILD SUCCEEDED|BUILD FAILED" | head -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add App/Sources/Features/Settings/BusinessProfileEditorView.swift
git commit -m "feat(settings): tax ID label + number fields on Business Profile editor

Extends the existing Tax section with two new text fields (label
and number). Disambiguating footer text explains that 'Tax label'
appears in invoice totals while 'Tax ID label' appears with the
registration number in the issuer header — both fields hide the
tax ID row on the PDF when left blank.

Both fields are autocorrection-disabled and uppercased on input
because tax IDs are typically alphanumeric codes (VAT GB123…,
EIN 12-345…, CR 1010012345).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 10: InvoicePreviewView — A8 editable line items (the big one)

**Files:**
- Modify: `App/Sources/Features/Invoicing/InvoicePreviewView.swift`

- [ ] **Step 1: Convert `lineItems` from `let` to `@State`**

Open `App/Sources/Features/Invoicing/InvoicePreviewView.swift`. Locate line 15:

```swift
    let lineItems: [InvoiceLineItem]
```

Replace with:

```swift
    @State private var lineItems: [InvoiceLineItem]
    @State private var pendingDescriptionEdits: [UUID: String] = [:]
```

- [ ] **Step 2: Update the initializer to use `_lineItems = State(initialValue:)`**

In the same file, locate the `init(...)` block (lines 27–41). Replace the body so the new init looks like:

```swift
    init(
        client: Client,
        profile: BusinessProfile,
        lineItems: [InvoiceLineItem],
        sourceEntries: [TimeEntry],
        notes: String?,
        onDone: @escaping () -> Void
    ) {
        self.client = client
        self.profile = profile
        _lineItems = State(initialValue: lineItems)
        self.sourceEntries = sourceEntries
        _notes = State(initialValue: notes)
        self.onDone = onDone
    }
```

- [ ] **Step 3: Add the `lineItemsEditor` subview + helpers**

In the same file, locate the `notesEditor` view (around line 167). Insert a new `lineItemsEditor` view + all its helpers IMMEDIATELY BEFORE `notesEditor`:

```swift
    // MARK: - Line items editor (A8)

    private var lineItemsEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LINE ITEMS")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(lineItems.enumerated()), id: \.element.id) { index, item in
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Description", text: descriptionBinding(at: index), axis: .vertical)
                        .lineLimit(1...3)
                        .textInputAutocapitalization(.sentences)
                    HStack(spacing: 8) {
                        Text(formatLineItemHours(item.hours)).foregroundStyle(.secondary)
                        Text("·").foregroundStyle(.tertiary)
                        Text(formatLineItemMoney(item.hourlyRate)).foregroundStyle(.secondary)
                        Spacer()
                        Text(formatLineItemMoney(item.amount)).fontWeight(.medium)
                    }
                    .font(.caption)
                }
                .padding(10)
                .background(.background, in: .rect(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(
                            isDescriptionEmpty(at: index) ? Color.red.opacity(0.6) : .quaternary,
                            lineWidth: 1
                        )
                )
            }
        }
        // 200ms debounce: flushes pending edits into the lineItems @State so the
        // PDF preview only re-renders when the user pauses typing. Validation
        // (red border, disabled Finalize) stays real-time because both read
        // from pendingDescriptionEdits ?? lineItems via currentDescription(at:).
        .task(id: pendingDescriptionEdits) {
            try? await Task.sleep(for: .milliseconds(200))
            guard !pendingDescriptionEdits.isEmpty else { return }
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

    private func descriptionBinding(at index: Int) -> Binding<String> {
        Binding(
            get: {
                pendingDescriptionEdits[lineItems[index].id] ?? lineItems[index].description
            },
            set: { newValue in
                pendingDescriptionEdits[lineItems[index].id] = newValue
            }
        )
    }

    private func currentDescription(at index: Int) -> String {
        pendingDescriptionEdits[lineItems[index].id] ?? lineItems[index].description
    }

    private func isDescriptionEmpty(at index: Int) -> Bool {
        currentDescription(at: index).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasInvalidDescriptions: Bool {
        lineItems.indices.contains { isDescriptionEmpty(at: $0) }
    }

    private func formatLineItemHours(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        let s = formatter.string(from: NSDecimalNumber(decimal: value)) ?? "\(value)"
        return s + "h"
    }

    private func formatLineItemMoney(_ value: Decimal) -> String {
        value.formatted(.currency(code: profile.currencyCode))
    }
```

- [ ] **Step 4: Insert `lineItemsEditor` in the body VStack**

In the same file, locate the body's ScrollView VStack (around lines 86–113). The current order is:
1. Watermark banner (conditional)
2. `pdfPreviewCard`
3. `notesEditor`

Add `lineItemsEditor` BETWEEN the watermark banner and `pdfPreviewCard`. Replace the existing VStack block with:

```swift
                VStack(alignment: .leading, spacing: 16) {
                    if !subscriptions.canRemoveWatermark {
                        Button {
                            showingRemoveWatermarkPaywall = true
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("This invoice has a watermark.")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text("Remove watermark with Pro →")
                                        .font(.caption)
                                        .foregroundStyle(.tint)
                                }
                                Spacer()
                            }
                            .padding(12)
                            .background(.orange.opacity(0.12), in: .rect(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal)
                    }
                    lineItemsEditor
                    pdfPreviewCard
                    notesEditor
                }
                .padding()
```

- [ ] **Step 5: Disable Finalize toolbar button when validation fails**

In the same file, locate the toolbar `ToolbarItem(placement: .topBarTrailing)` (around line 122). Replace the button with:

```swift
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        finalizeAndShare()
                    } label: {
                        Label("Finalize & share", systemImage: "paperplane.fill")
                    }
                    .bold()
                    .disabled(hasInvalidDescriptions)
                }
```

- [ ] **Step 6: Build and confirm**

Run:
```bash
xcodebuild -project Billable.xcodeproj -scheme Billable -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "error:|warning:|BUILD SUCCEEDED|BUILD FAILED" | head -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add App/Sources/Features/Invoicing/InvoicePreviewView.swift
git commit -m "feat(invoice): A8 editable line-item descriptions on preview

InvoicePreviewView.lineItems is now @State. New lineItemsEditor
subview renders an editable description per row above the PDF
preview; hours, rate, and amount remain read-only (financial
sanctity preserved).

Edits go through a [UUID: String] pendingDescriptionEdits map and
a 200ms .task(id:) debounce, so the PDF preview re-renders only
when the user pauses typing — perf invariant to invoice size.
Validation reads from pendingDescriptionEdits ?? lineItems, so
the red border and the disabled Finalize button stay real-time.

Finalize & share toolbar button is now disabled when any line
item has an empty / whitespace-only description.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 11: UI test — A8 editable description flow

**Files:**
- Create: `App/BillableUITests/InvoicePreviewLineItemEditUITests.swift`

> **Context:** This test launches the app with `--seed-marketing` (which seeds two demo clients/projects/entries), navigates Generator → Preview, edits one line item description, verifies the PDF preview re-renders, then verifies clearing the description disables Finalize. Existing UI tests in `App/BillableUITests/` provide the pattern (`LaunchTaglineUITests`, `NotificationTapFlowUITests`, `SettingsAboutUITests`).

- [ ] **Step 1: Create the UI test file**

Create `App/BillableUITests/InvoicePreviewLineItemEditUITests.swift`:

```swift
import XCTest

/// UI smoke test for the A8 editable-description flow on InvoicePreviewView.
///
/// 1. Launch with --seed-marketing so the app has clients/projects/entries.
/// 2. Open the Invoices tab, tap +, pick a client + range with eligible entries.
/// 3. Preview shows a LINE ITEMS card above the PDF.
/// 4. Edit one description, confirm the new text appears in the editor.
/// 5. Clear a description; confirm Finalize & share button disables.
final class InvoicePreviewLineItemEditUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func test_invoicePreview_descriptionEdit_andValidation() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--seed-marketing",
            "--pretend-pro",                       // Bypass paywall gates so we can reach Preview
            "--ui-test-skip-onboarding"            // Match the convention in other UI tests
        ]
        app.launch()

        // Navigate Invoices tab → New invoice → Preview.
        // The tab bar exposes tabs by accessibility label; "Invoices" is the
        // canonical label on the Invoices tab.
        app.tabBars.buttons["Invoices"].tap()

        // Tap the "+" plus toolbar item (UIKit nav-bar buttons are exposed as
        // XCUI buttons with their system image's accessibility label).
        let addButton = app.navigationBars.buttons["Add"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 3))
        addButton.tap()

        // InvoiceGeneratorView: select a client + range that has entries.
        // The MarketingData seed creates "Northwind Design" with billable
        // entries in the current month. Tap the Client menu, pick Northwind.
        let clientMenu = app.buttons["Client"]
        XCTAssertTrue(clientMenu.waitForExistence(timeout: 3))
        clientMenu.tap()
        app.buttons["Northwind Design"].tap()

        // Range: default is "This Month"; the seed places entries here. Tap Preview.
        let previewButton = app.buttons["Preview"]
        XCTAssertTrue(previewButton.waitForExistence(timeout: 3))
        previewButton.tap()

        // Preview screen: LINE ITEMS header should be visible above the PDF.
        let lineItemsHeader = app.staticTexts["LINE ITEMS"]
        XCTAssertTrue(lineItemsHeader.waitForExistence(timeout: 5))

        // First Description TextField in the editor.
        let firstDescription = app.textFields["Description"].firstMatch
        XCTAssertTrue(firstDescription.waitForExistence(timeout: 3))

        // Edit the first description: clear and type new text.
        firstDescription.tap()
        firstDescription.press(forDuration: 1.0)  // long-press shows the cut/copy menu
        if app.menuItems["Select All"].waitForExistence(timeout: 1.5) {
            app.menuItems["Select All"].tap()
        }
        firstDescription.typeText("Edited description")

        // The Finalize button at this point: edited but non-empty → enabled.
        let finalize = app.buttons["Finalize & share"]
        XCTAssertTrue(finalize.waitForExistence(timeout: 2))
        XCTAssertTrue(finalize.isEnabled, "Finalize must be enabled when all descriptions are non-empty")

        // Now clear the description completely → validation should disable Finalize.
        firstDescription.tap()
        firstDescription.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 1.5) {
            app.menuItems["Select All"].tap()
        }
        firstDescription.typeText(XCUIKeyboardKey.delete.rawValue)

        // Validation has ~200ms debounce-window but is computed in real time.
        // Give it a half-second cushion before asserting.
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertFalse(finalize.isEnabled, "Finalize must be disabled when any description is empty")
    }
}
```

- [ ] **Step 2: Add the UI test target file to the Xcode project**

Run:
```bash
ls App/BillableUITests/*.swift
```

Expected: the new file appears alongside `LaunchTaglineUITests.swift`, `NotificationTapFlowUITests.swift`, and `SettingsAboutUITests.swift`.

If Xcode doesn't pick the new file up automatically (project.pbxproj usually adds files in the BillableUITests folder), open `Billable.xcodeproj` once in Xcode and confirm the new file is in the `BillableUITests` target's Compile Sources. (No code change needed — Xcode handles file registration on first open.)

- [ ] **Step 3: Run the UI test**

Run:
```bash
xcodebuild test -project Billable.xcodeproj -scheme Billable -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=latest' -only-testing:BillableUITests/InvoicePreviewLineItemEditUITests 2>&1 | tail -25
```

Expected: 1 test passing.

If the simulator can't find the "Add" button, "Description" textField, or any specific element, fall back to using `app.debugDescription` in the test temporarily to inspect the accessibility tree, adjust the locators, and re-run. UI tests are notoriously brittle to accessibility-label changes; this test is intentionally focused on the most stable labels (tab bar items, visible static text).

- [ ] **Step 4: Commit**

```bash
git add App/BillableUITests/InvoicePreviewLineItemEditUITests.swift
git commit -m "test(ui): editable line-item description + Finalize validation

UI test launches with --seed-marketing + --pretend-pro, navigates
Invoices → New invoice → Northwind → Preview, asserts the LINE
ITEMS header is present, edits one description (verifies Finalize
stays enabled), then clears it (verifies Finalize disables within
the 200ms debounce window).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 12: Final acceptance sweep

**Files:**
- No file changes. Verification only.

- [ ] **Step 1: Full unit test suite**

Run:
```bash
swift test --package-path Packages/BillableCore 2>&1 | tail -5
```

Expected: total = previous baseline + ~16 new tests (6 BusinessProfile + 2 Invoice + 3 InvoiceBuilder + 5 PDF + 5 LogoImageProcessor). All passing.

- [ ] **Step 2: Full build (Debug + Release)**

Run:
```bash
xcodebuild -project Billable.xcodeproj -scheme Billable -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "error:|warning:|BUILD SUCCEEDED|BUILD FAILED" | head -5
```

Expected: `** BUILD SUCCEEDED **`, zero warnings.

Then:
```bash
xcodebuild -project Billable.xcodeproj -scheme Billable -configuration Release -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "error:|warning:|BUILD SUCCEEDED|BUILD FAILED" | head -5
```

Expected: `** BUILD SUCCEEDED **`, zero warnings.

- [ ] **Step 3: Full XCTest UI suite**

Run:
```bash
xcodebuild test -project Billable.xcodeproj -scheme Billable -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=latest' -only-testing:BillableUITests 2>&1 | tail -15
```

Expected: all UI tests pass — the new `InvoicePreviewLineItemEditUITests`, the existing `LaunchTaglineUITests`, `NotificationTapFlowUITests`, `SettingsAboutUITests`.

- [ ] **Step 4: Manual acceptance — Logo (A1)**

Boot the simulator and run the app via Xcode (Cmd-R) once. Walk through:

1. Open Settings → Business profile.
2. Confirm a "Logo" section is present above "Bank details".
3. Tap "Upload logo" → pick any photo from the simulator's Photo library.
4. Within ~1 second, an 80×80 preview appears with a "Remove" button.
5. Tap "Remove". Both preview and Remove button disappear; "Upload logo" label returns.
6. Re-upload the SAME image — the preview reappears (regression check that `logoPickerItem = nil` reset worked).
7. Tap Save (top-right). Re-open the editor. The logo persists.

If a step fails, fix and re-run from Step 1 of this Task 12.

- [ ] **Step 5: Manual acceptance — Tax ID (A2)**

1. In Business profile → Tax section, confirm two new fields ("Tax ID label", "Tax ID / VAT number") appear below the Rate row.
2. Footer text reads: "Tax label appears next to the rate on invoice totals. Tax ID label appears with your registration number in the issuer header — leave both blank to hide."
3. Enter `VAT` for label, `GB123456789` for number. Save.
4. Create an invoice (Invoices → +, pick a client with billable entries, Preview).
5. The PDF preview now shows `VAT GB123456789` in the issuer header block, below the email line.
6. Go back to Business profile, clear the label only (keep number). Save. Re-preview. PDF shows just `GB123456789` with no leading space.
7. Clear the number too. Save. Re-preview. PDF has no tax ID line — no blank space gap.

- [ ] **Step 6: Manual acceptance — Editable descriptions (A8)**

1. From the InvoicePreviewView (continuation of Step 5), find the LINE ITEMS card above the PDF preview.
2. Each line item shows an editable description + a read-only `Xh · $Y · $Z` row.
3. Edit a description. Within ~200ms the PDF preview updates with the new text.
4. Clear a description to empty. The row's border turns red. The "Finalize & share" toolbar button greys out.
5. Restore the description (type any non-whitespace). Border returns to normal; Finalize re-enables.
6. Tap Finalize & share. The shared PDF carries the edited description.

- [ ] **Step 7: Migration acceptance — v1.4 data loads cleanly**

If you have a simulator with a prior v1.4 install (or a CloudKit-synced device), reinstall the new build OVER the existing data without erasing the simulator. The app must:

- Launch without crashing.
- Show the existing Business Profile with `taxIDLabel == ""` and `taxIDNumber == ""` (since the migration adds defaults).
- Show any existing invoices unchanged in the Invoices list (snapshots load empty tax ID, PDFs re-render without the tax ID line — same look as before).

If you don't have a v1.4 store handy, this step is satisfied by the unit-level "default-init has empty fields" coverage already in Tasks 1 and 2.

- [ ] **Step 8: Commit anything that came out of the manual sweep**

If any tweaks were needed, commit them as targeted patches with descriptive messages. If nothing needed changing, this step is a no-op.

---

## Task 13: Open PR (or merge to main)

**Files:**
- No file changes. Branch management only.

- [ ] **Step 1: Confirm the worktree is clean and up to date**

Run:
```bash
git status --short
git log --oneline main..HEAD | wc -l
```

Expected: clean tree. The commit count should match the number of feature commits (roughly 11–13 depending on how Task 12 sweep tweaks land).

- [ ] **Step 2: Push the branch**

Run:
```bash
git push -u origin feature/v1.5-invoice-professionalism
```

Expected: branch pushes successfully.

- [ ] **Step 3: Open a PR using `gh`**

Run:
```bash
gh pr create --title "Phase 1: invoice professionalism (A1 logo + A2 tax ID + A8 description edit)" --body "$(cat <<'EOF'
## Summary

- **A1 — Logo upload editor UI:** PhotosPicker on Business Profile editor + pure-CoreGraphics image processor (LogoImageProcessor in BillableCore) that downscales to 1024px max and encodes alpha-aware PNG/JPEG. The PDF rendering pipeline was already wired end-to-end since v1.3 — this just adds the missing UI.
- **A2 — Tax ID / VAT number:** Two new BusinessProfile fields (`taxIDLabel`, `taxIDNumber`) plus matching `Invoice.issuerTaxID*Snapshot` fields. Renders as a single row under the issuer email in the PDF header (e.g. "VAT GB123456789"). Hides entirely when number is empty.
- **A8 — Editable line-item descriptions on Preview:** InvoicePreviewView's `lineItems` is now `@State`. New editable card above the PDF preview; hours/rate/amount remain read-only (financial sanctity). Edits flow through a [UUID: String] pending-edits map with a 200ms `.task(id:)` debounce so PDF re-render perf is invariant to invoice size. Empty descriptions disable the Finalize & share button.

Spec: `docs/superpowers/specs/2026-05-27-phase1-invoice-professionalism-design.md`
Plan: `docs/superpowers/plans/2026-05-27-phase1-invoice-professionalism.md`

## Test plan

- [ ] BillableCore: ~16 new unit tests (BusinessProfile tax ID, Invoice snapshots, InvoiceBuilder propagation, PDF render with tax ID, LogoImageProcessor)
- [ ] UI test: editable description + Finalize validation on InvoicePreviewView
- [ ] Manual: logo upload + remove + re-upload-same-image
- [ ] Manual: tax ID renders in PDF header; hides when number is empty
- [ ] Manual: edit description live-updates PDF preview; clearing disables Finalize
- [ ] Migration: v1.4 data loads cleanly with empty defaults on the new fields

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: a PR URL prints. Open it in browser to confirm.

- [ ] **Step 4: Once approved, merge to main (no-ff to preserve history)**

After review, when ready:

```bash
gh pr merge --merge --delete-branch
```

Or do it locally (also preserves a merge commit for context):

```bash
cd "/Users/lbazerbashi/Elden Studios/billable"
git checkout main
git pull --ff-only origin main
git merge --no-ff feature/v1.5-invoice-professionalism -m "Merge v1.5 — invoice professionalism (A1 + A2 + A8)"
git push origin main
git worktree remove ".worktrees/v1.5-invoice-professionalism"
git branch -d feature/v1.5-invoice-professionalism
```

Expected: clean merge, worktree removed, branch deleted locally. Remote branch cleanup follows GitHub's PR settings.

- [ ] **Step 5: Tag the release**

```bash
git tag v1.5
git push origin v1.5
```

(Tag convention matches the existing `v1.4` tag.)

---

## Acceptance criteria (from spec, restated for completeness)

A Phase 1 implementation is complete when:

- [ ] Business Profile editor → "Logo" section shows PhotosPicker, image preview when set, "Remove" button.
- [ ] Tapping Remove clears both `logoData` and `logoPickerItem` state (re-picking same image works).
- [ ] After uploading a 4000×3000 source image, `BusinessProfile.logoData` is ≤ ~150 KB.
- [ ] Business Profile editor → "Tax" section has Tax ID label + Tax ID number fields below the rate row, with the disambiguation footer text visible.
- [ ] InvoicePreviewView, opened from the Generator, shows an editable LINE ITEMS card above the PDF preview, with each row having an editable description and read-only hours/rate/amount.
- [ ] Editing a description live-updates the PDF preview within ~200ms (debounce-bounded).
- [ ] Clearing a description (or whitespace-only) makes that row's border red AND disables the "Finalize & share" toolbar button.
- [ ] Finalize & share writes the edited descriptions into the persisted Invoice.lineItemsData; shared PDF contains the edited text.
- [ ] Generated PDF with `taxIDNumber="GB123456789"` and `taxIDLabel="VAT"` shows "VAT GB123456789" in the issuer header.
- [ ] Generated PDF with `taxIDNumber="GB123456789"` and empty label shows just "GB123456789" (no leading space).
- [ ] Generated PDF with empty tax ID number has no tax ID line.
- [ ] Generated PDF with a logo set shows it in the top-left of the header.
- [ ] App launches cleanly on a device with v1.4 data installed — no crash on lightweight migration.
- [ ] Existing test suite passes. New tests pass.
