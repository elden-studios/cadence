# Phase 1 Design — Invoice Professionalism (A1 + A2 + A8)

**Status:** Approved, ready for implementation plan
**Author:** Claude + Louay
**Date:** 27 May 2026
**Parent state:** v1.4 quality-of-life release (merged to main, commit `30f7ce4`, tag `v1.4`)
**Parent backlog:** `2026-05-27-post-v1.3-backlog.md`
**Parent phase plan:** `2026-05-27-post-v1.3-enhancement-phases.md`
**Branch target:** `feature/v1.5-invoice-professionalism` off `main`
**Confidence:** 95%+

## Context

Three High-value items from the post-v1.3 backlog, grouped because they all
strengthen the invoice's perceived professionalism — the surface the customer's
customer actually sees:

- **A1** — Logo upload on Business Profile, rendered in PDF header
- **A2** — Tax ID / VAT number on Business Profile, rendered in PDF header
- **A8** — Inline edit of line-item descriptions on `InvoicePreviewView`

Per the [2026-05-27 monetization assessment](2026-05-27-post-v1.3-backlog.md),
this bundle captures roughly 85% of the ~25% overall app-value lift from the
full A-list backlog.

## Goals

- Issuer can upload, preview, replace, and remove a logo. The logo renders in
  the top-left of every PDF invoice (Sent or Paid). Stored compressed in
  the model and snapshotted onto Invoice at finalize time.
- Issuer can enter a Tax ID / VAT number (with a free-text label like "VAT",
  "GST", "CR No.") on Business Profile. The number renders in the issuer
  header block on the PDF.
- Issuer can edit each line item's description in the Invoice Preview screen
  before finalizing. Hours, rate, and amount remain immutable. PDF preview
  re-renders live as the user types. Empty descriptions block finalization.

## Non-goals

- Sending persisted drafts from `InvoiceDetailView`. This is a pre-existing
  v1.3 gap (recurring-materialized drafts have no UI to promote to Sent). Out
  of scope for this phase. Tracked separately as a future item.
- Editing hours / rate / amount on line items. Snapshot philosophy preserved
  for financial sanctity.
- Editing line items on already-Sent or Paid invoices. Immutable post-finalize
  per existing design.
- Logo crop / rotate / multi-format conversion. PhotosPicker output, resized,
  is enough.
- Tax ID format validation. Stored as user-typed strings, like IBAN/SWIFT in
  v1.4.
- Multiple tax IDs (e.g., separate VAT and EIN). One label + one number.

## Section 1 — Model changes

### BusinessProfile

File: `Packages/BillableCore/Sources/BillableCore/Models/BusinessProfile.swift`

**Already present (from earlier work):**

```swift
public var logoData: Data?
```

No changes to `logoData`. Existing storage is fine.

**Add (two optional Strings, default `""`, paralleling the v1.4 bank fields):**

```swift
public var taxIDLabel: String = ""   // e.g. "VAT", "GST", "CR No.", "EIN", "TRN"
public var taxIDNumber: String = ""  // e.g. "GB123456789", "300012345600003"
```

**Add computed helper:**

```swift
/// True when the issuer has a tax registration number to display.
/// `taxIDLabel` alone does not count — a label without a number is meaningless.
public var hasTaxID: Bool {
    !taxIDNumber.trimmingCharacters(in: .whitespaces).isEmpty
}
```

**Update `BusinessProfile.init(...)`:** add two new trailing parameters with
default `""`:

```swift
public init(
    // ...existing...
    bankSWIFT: String = "",
    taxIDLabel: String = "",
    taxIDNumber: String = "",
    createdAt: Date = .now,
    updatedAt: Date = .now
) {
    // ...existing...
    self.taxIDLabel = taxIDLabel
    self.taxIDNumber = taxIDNumber
}
```

All existing call sites compile unchanged.

### Invoice

File: `Packages/BillableCore/Sources/BillableCore/Models/Invoice.swift`

**Already present:**

```swift
public var issuerLogoSnapshot: Data?
```

No changes.

**Add (matching snapshot pattern for tax ID):**

```swift
public var issuerTaxIDLabelSnapshot: String = ""
public var issuerTaxIDNumberSnapshot: String = ""
```

**Update `Invoice.init(...)`** — add two new trailing parameters with default `""`,
positioned after the existing bank-detail snapshot parameters:

```swift
issuerBankSWIFTSnapshot: String = "",
issuerTaxIDLabelSnapshot: String = "",
issuerTaxIDNumberSnapshot: String = "",
paymentTermsSnapshot: String,
// ...existing...
```

Set in the init body. All existing call sites compile unchanged.

### Migration semantics

Additive optional/defaulted fields. SwiftData performs a lightweight automatic
migration on first launch:

- Existing v1.4 `BusinessProfile` records load with `taxIDLabel = ""` and
  `taxIDNumber = ""`. `hasTaxID` is `false`. No PDF render change for invoices
  these profiles produced.
- Existing v1.4 `Invoice` records load with `issuerTaxIDLabelSnapshot = ""`
  and `issuerTaxIDNumberSnapshot = ""`. When re-rendered, their PDFs do not
  include the tax ID block.
- CloudKit syncs the new fields on next push. Devices still on v1.3/v1.4 ignore
  the new fields silently (CloudKit forward-compat with additive schema).

No manual migration code. No data movement.

---

## Section 2 — A1 Logo upload (BusinessProfileEditorView)

File: `App/Sources/Features/Settings/BusinessProfileEditorView.swift`

### Add `@State` for logo + picker item

```swift
@State private var logoData: Data?
@State private var logoPickerItem: PhotosPickerItem?
```

### Add Logo section before the existing Bank details section

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
                logoPickerItem = nil  // ⚠️ Must clear to allow re-picking the same image.
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
```

### Image processing helper

```swift
private func loadAndProcessLogo(from item: PhotosPickerItem?) async {
    guard let item else { return }
    guard let rawData = try? await item.loadTransferable(type: Data.self) else { return }
    // Process off the main actor to avoid blocking the UI on a large source image.
    if let processed = await Task.detached(priority: .userInitiated) {
        processLogoData(rawData)
    }.value {
        await MainActor.run { logoData = processed }
    }
}

/// Resize `data` so its largest dimension ≤ 1024px and re-encode as PNG
/// (if alpha present) or JPEG quality 0.85 (otherwise). Returns nil on failure.
/// Uses CGImageSource thumbnail API to avoid decoding the full image into memory.
private nonisolated func processLogoData(_ data: Data) -> Data? {
    let maxDimension: CGFloat = 1024

    guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

    let thumbOptions: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        // Don't upscale tiny logos.
        kCGImageSourceShouldCache: false,
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOptions as CFDictionary) else {
        return nil
    }

    // Alpha-aware re-encode: PNG if alpha, JPEG otherwise.
    let alphaInfo = cgImage.alphaInfo
    let hasAlpha = alphaInfo != .none && alphaInfo != .noneSkipFirst && alphaInfo != .noneSkipLast

    let uiImage = UIImage(cgImage: cgImage)
    if hasAlpha {
        return uiImage.pngData()
    } else {
        return uiImage.jpegData(compressionQuality: 0.85)
    }
}

private func uiImageFromData(_ data: Data) -> UIImage? {
    UIImage(data: data)
}
```

### Wire into load / save

In `loadIfNeeded()`:

```swift
logoData = profile.logoData
```

In `save()`:

```swift
profile.logoData = logoData
```

Logo is saved to the model only when the user taps **Save** — same UX as
all other fields on this form.

### Result: logo path is now end-to-end

The remaining plumbing was already present in earlier code:

- `InvoiceBuilder.createDraft` already passes `profile.logoData` to
  `issuerLogoSnapshot` (line 138).
- `InvoicePreviewView.templateData` already passes `profile.logoData` to
  `issuerLogo` (line 57).
- `InvoiceTemplate.header` already renders the logo at 44pt height (lines
  54-60).
- `InvoiceTemplateData.from(_ invoice:)` already reads
  `invoice.issuerLogoSnapshot` (line 406).

No changes needed in any of those files for A1.

---

## Section 3 — A2 Tax ID / VAT number

### Editor UI

File: `App/Sources/Features/Settings/BusinessProfileEditorView.swift`

**Modify the existing "Tax" section** to include the Tax ID pair, positioned
below the rate row:

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
        Text("%").foregroundStyle(.secondary)
    }
    // NEW (A2)
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

The footer text disambiguates the two labels (both could plausibly be "VAT")
and tells the user the gate ("leave both blank to hide").

### `@State` declarations

Add to `BusinessProfileEditorView`:

```swift
@State private var taxIDLabel: String = ""
@State private var taxIDNumber: String = ""
```

### Wire into load / save

In `loadIfNeeded()`, after `taxRatePercent = ...`:

```swift
taxIDLabel = profile.taxIDLabel
taxIDNumber = profile.taxIDNumber
```

In `save()`, after `profile.taxRate = ...`:

```swift
profile.taxIDLabel = taxIDLabel
profile.taxIDNumber = taxIDNumber
```

### Snapshot propagation in InvoiceBuilder

File: `Packages/BillableCore/Sources/BillableCore/Invoicing/InvoiceBuilder.swift`

In `createDraft(...)`, add two new arguments to the `Invoice(...)` constructor,
after the bank-detail snapshots:

```swift
issuerBankSWIFTSnapshot: profile.bankSWIFT,
issuerTaxIDLabelSnapshot: profile.taxIDLabel,    // NEW
issuerTaxIDNumberSnapshot: profile.taxIDNumber,  // NEW
paymentTermsSnapshot: profile.paymentTerms,
```

### Pass-through in InvoicePreviewView

File: `App/Sources/Features/Invoicing/InvoicePreviewView.swift`

In the `templateData` computed property, after the existing bank-field
assignments:

```swift
data.bankSWIFT = profile.bankSWIFT
data.taxIDLabel = profile.taxIDLabel   // NEW
data.taxIDNumber = profile.taxIDNumber // NEW
return data
```

### `InvoiceTemplateData` field addition

File: `Packages/BillableCore/Sources/BillableCore/Invoicing/InvoiceTemplate.swift`

Add two new fields at the bottom of `InvoiceTemplateData` (after bank fields):

```swift
public var taxIDLabel: String = ""
public var taxIDNumber: String = ""

public var hasTaxID: Bool {
    !taxIDNumber.trimmingCharacters(in: .whitespaces).isEmpty
}
```

Update `InvoiceTemplateData.from(_ invoice:)` factory to copy the snapshots
after init, after the existing bank-detail assignments:

```swift
data.bankSWIFT = invoice.issuerBankSWIFTSnapshot
data.taxIDLabel = invoice.issuerTaxIDLabelSnapshot      // NEW
data.taxIDNumber = invoice.issuerTaxIDNumberSnapshot    // NEW
return data
```

### PDF render

In `InvoiceTemplate.header`, extend the left-side issuer block. Place the
tax ID row after the issuer email row, before the implicit Spacer:

```swift
VStack(alignment: .leading, spacing: 6) {
    if let logo = data.issuerLogo, let image = imageFromData(logo) {
        // existing logo render
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

Helper:

```swift
/// "VAT GB123456789" if both label and number set; "GB123456789" if only number.
/// Trims trailing/leading whitespace on the label to avoid double-spacing.
private var taxIDDisplay: String {
    let trimmedLabel = data.taxIDLabel.trimmingCharacters(in: .whitespaces)
    return trimmedLabel.isEmpty
        ? data.taxIDNumber
        : "\(trimmedLabel) \(data.taxIDNumber)"
}
```

### MarketingData seeder

File: `Packages/BillableCore/Sources/BillableCore/Persistence/MarketingData.swift`

Update the demo `BusinessProfile` construction to include plausible KSA-region
sample values:

```swift
taxIDLabel: "CR",
taxIDNumber: "1010012345",
```

So App Store screenshots show the new field populated.

---

## Section 4 — A8 Line-item description editing (InvoicePreviewView)

File: `App/Sources/Features/Invoicing/InvoicePreviewView.swift`

### Make `lineItems` editable

Today's declaration (line 15):

```swift
let lineItems: [InvoiceLineItem]
```

Change to:

```swift
@State private var lineItems: [InvoiceLineItem]
```

And initialize in `init(...)` (matches the existing `_notes = State(initialValue:)`
pattern at line 39):

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
    _lineItems = State(initialValue: lineItems)  // NEW
    self.sourceEntries = sourceEntries
    _notes = State(initialValue: notes)
    self.onDone = onDone
}
```

The `templateData` computed property continues to read `self.lineItems`, so
edits flow into the rendered template automatically.

`finalizeAndShare` already passes `lineItems` to `InvoiceBuilder.createDraft`
on line 192 — no change needed there. Edits captured in `@State` propagate
into the persisted Invoice's `lineItemsData` at finalize time.

### Editable line items card

Add above the existing `pdfPreviewCard` in the body's VStack:

```swift
ScrollView {
    VStack(alignment: .leading, spacing: 16) {
        if !subscriptions.canRemoveWatermark { /* existing watermark banner */ }
        lineItemsEditor                              // NEW
        pdfPreviewCard
        notesEditor
    }
    .padding()
}
```

The `lineItemsEditor` subview:

```swift
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
                    Text(formatHours(item.hours)).foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.tertiary)
                    Text(formatMoney(item.hourlyRate)).foregroundStyle(.secondary)
                    Spacer()
                    Text(formatMoney(item.amount)).fontWeight(.medium)
                }
                .font(.caption)
            }
            .padding(10)
            .background(.background, in: .rect(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isDescriptionEmpty(at: index) ? Color.red.opacity(0.6) : .quaternary, lineWidth: 1)
            )
        }
    }
}

private func descriptionBinding(at index: Int) -> Binding<String> {
    Binding(
        get: { lineItems[index].description },
        set: { newValue in
            lineItems[index].description = newValue
        }
    )
}

private func isDescriptionEmpty(at index: Int) -> Bool {
    lineItems[index].description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

private var hasInvalidDescriptions: Bool {
    lineItems.contains { $0.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

private func formatHours(_ value: Decimal) -> String {
    let formatter = NumberFormatter()
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = 2
    return (formatter.string(from: NSDecimalNumber(decimal: value)) ?? "\(value)") + "h"
}

private func formatMoney(_ value: Decimal) -> String {
    value.formatted(.currency(code: profile.currencyCode))
}
```

### Disable Finalize when validation fails

Update the existing toolbar button:

```swift
ToolbarItem(placement: .topBarTrailing) {
    Button {
        finalizeAndShare()
    } label: {
        Label("Finalize & share", systemImage: "paperplane.fill")
    }
    .bold()
    .disabled(hasInvalidDescriptions)   // NEW
}
```

The red border + disabled toolbar button together make the validation state
obvious without inline error text.

### PDF re-render strategy

`InvoicePreviewView.pdfPreviewCard` (line 150-165) already uses a live SwiftUI
`InvoiceTemplate(data: templateData, ...)` render — not PDFKit-with-cache.
`templateData` is a computed property that reads `self.lineItems`. So:

- User types in a description
- `lineItems[index].description` updates (the `@State` mutation)
- SwiftUI invalidates `templateData`
- `InvoiceTemplate` re-renders with the new description
- User sees the update within one frame (~16ms)

No cache to invalidate; no debounce needed for typical invoices (1-10 line
items, where most freelance work lands).

**Perf fallback if 30+ line items prove laggy in real-device testing:**
add a 200ms `.task(id:)` debounce in `descriptionBinding(at:)`, so the
template re-renders only when the user pauses typing. ~5 lines of code.
The validation state (red border, disabled Finalize button) remains
real-time regardless — only the PDF re-render is debounced.

`pdfDataCached` on the persisted `Invoice` is only populated *after*
finalization (existing line 207 in `finalizeAndShare`). Drafts don't have a
cache to clear because they're not yet persisted at this point in the flow.

---

## Section 5 — Snapshot propagation summary (single reference)

Five files touched for the snapshot pipeline. Each adds the same pair of fields
(tax ID label + number) at the parallel-to-bank-detail position:

| File | Change |
|---|---|
| `Packages/BillableCore/.../Models/BusinessProfile.swift` | Add `taxIDLabel` + `taxIDNumber` fields, `hasTaxID` computed, two new init parameters |
| `Packages/BillableCore/.../Models/Invoice.swift` | Add `issuerTaxIDLabelSnapshot` + `issuerTaxIDNumberSnapshot` fields, two new init parameters |
| `Packages/BillableCore/.../Invoicing/InvoiceBuilder.swift` | Pass `profile.taxID...` into `Invoice(...)` in `createDraft` |
| `App/Sources/Features/Invoicing/InvoicePreviewView.swift` | Assign `data.taxID...` from `profile.taxID...` in `templateData` |
| `Packages/BillableCore/.../Invoicing/InvoiceTemplate.swift` | Add `taxIDLabel` + `taxIDNumber` + `hasTaxID` to `InvoiceTemplateData`; render in header; copy from snapshot in `from(_ invoice:)` |

Logo path needs no propagation changes (already wired end-to-end).
`MarketingData.swift` updated to seed demo tax ID values.

---

## Section 6 — Tests

### Unit tests (BillableCore)

**`BusinessProfileTests`:**

```
@Test("Default BusinessProfile has empty tax ID fields")
@Test("Default BusinessProfile.hasTaxID is false")
@Test("Setting taxIDNumber flips hasTaxID to true")
@Test("Setting only taxIDLabel does not flip hasTaxID (label without number is meaningless)")
@Test("Whitespace-only taxIDNumber does not flip hasTaxID")
```

**`InvoiceBuilderTests`:**

```
@Test("createDraft snapshots profile.taxIDLabel onto issuerTaxIDLabelSnapshot")
@Test("createDraft snapshots profile.taxIDNumber onto issuerTaxIDNumberSnapshot")
@Test("createDraft continues to snapshot profile.logoData onto issuerLogoSnapshot")  // regression guard
```

**`InvoicePDFRendererTests`:**

```
@Test("PDF includes 'VAT GB123456789' when label='VAT' and number='GB123456789'")
@Test("PDF includes 'GB123456789' (no label space) when label='' and number='GB123456789'")
@Test("PDF does NOT include tax ID block when number is empty")
@Test("PDF does NOT include tax ID block when only label is set")
@Test("PDF logo renders without error when issuerLogo is set (non-empty bytes)")  // regression guard
```

**`InvoiceLineItemTests`** (or add to `InvoiceTests`):

```
@Test("Mutating description through Invoice.lineItems setter round-trips the JSON")
@Test("Empty description survives JSON round-trip (regression — we validate on UI, not model)")
```

**Model defaults (catches migration mistakes):**

```
@Test("BusinessProfile() default-init has empty taxIDLabel and taxIDNumber")
@Test("Invoice with no explicit tax ID snapshot args has empty snapshots")
```

These insert a `BusinessProfile()` and an `Invoice(...)` using the
default-`""` init parameters (simulating data that pre-dates Phase 1) and
assert the fields are empty. Catches the most likely migration mistake —
forgetting the default value on a new field — without needing a real v1.4
store fixture. Actual on-device migration from v1.4 → v1.5 is covered by
the manual acceptance check below ("App launches cleanly on a device with
v1.4 data installed").

### Image processing helper (A1)

Test `processLogoData(_:)` standalone (it's `nonisolated`, no UIKit dependency
beyond reading bytes — should be testable):

```
@Test("processLogoData downscales 4000x3000 source to ≤1024 on largest dim")
@Test("processLogoData preserves alpha by encoding PNG for transparent source")
@Test("processLogoData encodes JPEG for opaque source")
@Test("processLogoData returns nil for non-image data")
@Test("processLogoData does not upscale a 32x32 source")  // verify with output dimensions
```

### Manual / UI acceptance criteria

A Phase 1 implementation is complete when:

- [ ] Business Profile editor → "Logo" section shows PhotosPicker, image
      preview when set, "Remove" button.
- [ ] Tapping Remove clears both `logoData` and `logoPickerItem` state
      (verify by re-picking the same image works).
- [ ] After uploading a 4000×3000 source image, `BusinessProfile.logoData`
      is ≤ ~150 KB on disk (verify via Files debug inspection).
- [ ] Business Profile editor → "Tax" section now has Tax ID label + Tax
      ID number text fields below the rate row, with the disambiguation
      footer text visible.
- [ ] InvoicePreviewView, when opened from the Generator, shows an editable
      "LINE ITEMS" card above the PDF preview, with each row having an
      editable description and read-only hours/rate/amount.
- [ ] Editing a description live-updates the PDF preview within one frame
      (no perceptible lag).
- [ ] Clearing a description to empty (or whitespace-only) makes that row's
      border turn red AND disables the "Finalize & share" toolbar button.
- [ ] Finalize & share writes the edited descriptions into the persisted
      `Invoice.lineItemsData`; shared PDF contains the edited text.
- [ ] Generated PDF with `taxIDNumber="GB123456789"` and `taxIDLabel="VAT"`
      shows "VAT GB123456789" in the issuer header block, under the email.
- [ ] Generated PDF with `taxIDNumber="GB123456789"` and `taxIDLabel=""`
      shows just "GB123456789" (no leading space).
- [ ] Generated PDF with empty tax ID shows no tax ID line — no blank space.
- [ ] Generated PDF with a logo set shows it in the top-left of the header
      (existing behavior, regression-tested).
- [ ] App launches cleanly on a device with v1.4 data installed — no crash
      on lightweight migration. Profile fields appear as empty in the editor;
      Invoice fields snapshot as empty for re-rendered older invoices.
- [ ] Existing test suite passes. New tests pass.

---

## Out of scope (tracked separately)

- **Sending persisted drafts from `InvoiceDetailView`.** Currently no "Mark
  sent" / "Finalize" button exists for status == `.draft` on the detail view,
  which means recurring-materialized drafts have no UI path to Sent. This is
  a pre-existing v1.3 gap, not introduced by Phase 1. Worth its own future
  design — likely a small button in `actionButtons` that calls
  `InvoiceBuilder.finalizeAndSend(...)` with `sourceEntries = []` (since
  recurring drafts may not have direct entries).
- **A1: Logo cropping / rotation.** PhotosPicker output, resized, is enough
  for v1.5. Future: drag-and-resize crop UI.
- **A2: Tax ID format validation.** Stored as user-typed strings, like
  IBAN/SWIFT in v1.4. Format validation deferred (jurisdiction-specific,
  hard to get right, low payoff).
- **Multiple tax IDs per issuer** (e.g., separate VAT and EIN for businesses
  registered in multiple jurisdictions). One label + one number for v1.5.

## Risk

- **Schema migration risk:** Low. Additive optional/defaulted fields are the
  standard SwiftData migration case. v1.4 bank fields followed the same
  pattern with no observed issues.
- **PDF layout risk:** Adding a tax ID row to the issuer header block extends
  the left column by ~14pt (one row, 11pt font, ~3pt leading). Total header
  is still well within the page bounds. No reflow expected.
- **A8 perf risk (unmeasured, mitigable):** Live SwiftUI re-render on every
  keystroke is expected to be smooth at 1-10 line items (the common case),
  but unmeasured at 30+. If real-device testing shows lag, add a 200ms
  `.task(id:)` debounce on the description binding so the PDF re-renders
  only when the user pauses. Validation (red border + disabled Finalize)
  stays real-time. ~5 lines of code.
- **A1 strict-concurrency risk:** `processLogoData` uses `UIImage(cgImage:)`
  and `UIImage.pngData()` / `jpegData()`. These are nonisolated and `UIImage`
  is `Sendable` in iOS 17+, but Swift 6 strict concurrency may still warn.
  Fallback: replace UIImage encoding with pure CoreGraphics via
  `CGImageDestinationCreateWithData` + `CGImageDestinationAddImage` +
  `CGImageDestinationFinalize`. Adds ~10 lines, fully Sendable-safe.
- **A1 image-processing crash risk:** Low. `CGImageSource` with
  thumbnail-max-pixel-size is the memory-safe path and is the recommended
  Apple pattern for large source images. `Task.detached` offload keeps the
  main thread responsive.
- **A2 editor naming UX risk:** "Tax label" (for the totals row) and
  "Tax ID label" (for the issuer header) coexist in the same Tax section.
  The disambiguating section footer mitigates but doesn't eliminate
  confusion. If user testing reveals confusion, the fix is to either
  rename one ("Sales tax label" + "Tax ID label") or split into two
  separate sections ("Tax rate" + "Tax registration"). Defer the decision
  until we see real reactions.

## Acceptance: spec is "done" when

- [ ] User has reviewed this document
- [ ] User approves
- [ ] Implementation plan is produced by invoking the writing-plans skill

The implementation plan will sequence the model changes first (one migration),
then editor UI (A1 + A2), then InvoicePreviewView edit surface (A8), then
tests, then a final acceptance sweep.
