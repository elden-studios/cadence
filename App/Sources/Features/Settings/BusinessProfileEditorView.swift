import SwiftUI
import SwiftData
import PhotosUI
import BillableCore

/// Form-based editor for the user's BusinessProfile (singleton).
/// Creates a profile on first save if one doesn't already exist.
struct BusinessProfileEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \BusinessProfile.createdAt, order: .forward) private var profiles: [BusinessProfile]

    @State private var name: String = ""
    @State private var address: String = ""
    @State private var email: String = ""
    @State private var phone: String = ""

    @State private var paymentTerms: String = "Net 14"
    @State private var defaultDueAfterDays: Int = 14

    @State private var invoiceNumberPrefix: String = "INV-"
    @State private var nextInvoiceNumber: Int = 1

    @State private var taxLabel: String = "Tax"
    @State private var taxRatePercent: Double = 0   // displayed as a percentage; converted to Decimal 0..1 on save

    @State private var taxIDLabel: String = ""
    @State private var taxIDNumber: String = ""

    @State private var invoiceEmailSubjectTemplate: String = ""
    @State private var invoiceEmailBodyTemplate: String = ""

    @State private var bankBeneficiaryName: String = ""
    @State private var bankName: String = ""
    @State private var bankLocation: String = ""
    @State private var bankIBAN: String = ""
    @State private var bankSWIFT: String = ""

    @State private var logoData: Data?
    @State private var logoPickerItem: PhotosPickerItem?
    @State private var logoUIImage: UIImage?
    @State private var logoLoadError: String?

    @State private var hasLoaded = false
    @State private var entityType: EntityType = .freelancer
    @State private var taxExpanded = false
    @State private var showingBlankNameError = false

    var body: some View {
        Form {
            Section {
                Picker("I bill as", selection: $entityType) {
                    ForEach(EntityType.allCases, id: \.self) { type in
                        Text(type.cardTitle).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                TextField(entityType.issuerNameLabel, text: $name)
                    .textInputAutocapitalization(.words)
                    .textContentType(entityType.nameContentType)
                TextField("Email", text: $email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .textContentType(.emailAddress)
                TextField("Phone", text: $phone)
                    .keyboardType(.phonePad)
                TextField("Address", text: $address, axis: .vertical)
                    .lineLimit(2...4)
            } header: {
                Text("Issuer")
            } footer: {
                Text("Freelancer — just you, billing for your own time. Organization — a team billing under one company name. This only changes the labels on your invoices.")
            }

            Section("Payment") {
                TextField("Payment terms", text: $paymentTerms)
                Stepper(value: $defaultDueAfterDays, in: 0...120) {
                    LabeledContent("Default due", value: "\(defaultDueAfterDays) day\(defaultDueAfterDays == 1 ? "" : "s")")
                }
            }

            Section("Invoice numbering") {
                TextField("Prefix", text: $invoiceNumberPrefix)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                Stepper(value: $nextInvoiceNumber, in: 1...999_999) {
                    LabeledContent("Next number", value: format(prefix: invoiceNumberPrefix, number: nextInvoiceNumber))
                }
            }

            Section {
                if entityType.showsTaxByDefault {
                    taxFields
                } else {
                    DisclosureGroup("Add tax (if you charge it)", isExpanded: $taxExpanded) {
                        taxFields
                    }
                }
            } header: {
                Text("Tax")
            } footer: {
                Text("Tax label appears next to the rate on invoice totals. Tax ID label appears with your registration number in the issuer header — leave both blank to hide.")
            }

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
                if let image = logoUIImage {
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
                            logoUIImage = nil
                            logoLoadError = nil
                            // Reset picker selection so re-picking the same photo
                            // changes the .task(id:) value and re-runs processing.
                            logoPickerItem = nil
                        } label: {
                            Text("Remove")
                        }
                    }
                }
                let pickerTitle = logoData == nil ? "Upload logo" : "Change logo"
                PhotosPicker(
                    selection: $logoPickerItem,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    Label(pickerTitle, systemImage: "photo.on.rectangle.angled")
                }
                .task(id: logoPickerItem) {
                    await loadAndProcessLogo(from: logoPickerItem)
                }
                if let logoLoadError {
                    Text(logoLoadError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Logo")
            } footer: {
                Text("Shown in the top-left of every invoice PDF. Square logos work best.")
            }

            Section {
                TextField("Beneficiary name", text: $bankBeneficiaryName)
                    .textInputAutocapitalization(.words)
                TextField("Bank name", text: $bankName)
                    .textInputAutocapitalization(.words)
                TextField("Location (city, country)", text: $bankLocation)
                    .textInputAutocapitalization(.words)
                TextField("IBAN", text: $bankIBAN)
                    .keyboardType(.asciiCapable)
                    .textContentType(nil)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                TextField("SWIFT / BIC (optional)", text: $bankSWIFT)
                    .keyboardType(.asciiCapable)
                    .textContentType(nil)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
            } header: {
                Text("Bank details")
            } footer: {
                Text("Shown on invoices so clients know where to pay. Leave blank to hide.")
            }
        }
        .navigationTitle("Business profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { save() }
                    .bold()
            }
        }
        .onAppear { loadIfNeeded() }
        .onChange(of: entityType) { _, _ in
            // Don't hide a freshly-entered rate behind the collapsed Freelancer
            // DisclosureGroup when toggling Org→Freelancer live. Mirrors the
            // taxExpanded derivation in loadIfNeeded() (both reflect the same rate).
            taxExpanded = taxRatePercent != 0
        }
        .alert("Add a name", isPresented: $showingBlankNameError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Enter your \(entityType == .freelancer ? "name" : "business name") so it can appear on invoices.")
        }
        .task(id: logoData) {
            guard let data = logoData else {
                logoUIImage = nil
                return
            }
            let image = await Task.detached(priority: .userInitiated) {
                UIImage(data: data)
            }.value
            guard !Task.isCancelled else { return }
            logoUIImage = image
            if image == nil {
                // Stored bytes won't decode (e.g. CloudKit sync corruption, format
                // regression). Surface so the user can recover by re-picking.
                logoLoadError = "Couldn't display the saved logo. Pick a new one."
            }
        }
    }

    @ViewBuilder
    private var taxFields: some View {
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
        TextField(entityType.taxIDLabel, text: $taxIDLabel)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.characters)
        // Harden the registration-NUMBER field: identifiers must not feed
        // keyboard learning or AutoFill (spec §6). Not SecureField — the user
        // must be able to verify their own tax ID.
        TextField("Tax ID / VAT number", text: $taxIDNumber)
            .keyboardType(.asciiCapable)
            .textContentType(nil)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.characters)
    }

    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard let profile = profiles.first else { return }
        name = profile.name
        entityType = profile.entityType
        // Auto-expand the freelancer tax section if a non-zero rate already exists
        // (spec §6) — otherwise a saved rate would be hidden behind a collapsed group.
        taxExpanded = profile.taxRate != .zero
        address = profile.address
        email = profile.email
        phone = profile.phone
        paymentTerms = profile.paymentTerms
        defaultDueAfterDays = profile.defaultDueAfterDays
        invoiceNumberPrefix = profile.invoiceNumberPrefix
        nextInvoiceNumber = profile.nextInvoiceNumber
        taxLabel = profile.taxLabel
        taxRatePercent = (profile.taxRate as NSDecimalNumber).doubleValue * 100
        taxIDLabel = profile.taxIDLabel
        taxIDNumber = profile.taxIDNumber
        invoiceEmailSubjectTemplate = profile.invoiceEmailSubjectTemplate
        invoiceEmailBodyTemplate = profile.invoiceEmailBodyTemplate
        bankBeneficiaryName = profile.bankBeneficiaryName
        bankName = profile.bankName
        bankLocation = profile.bankLocation
        bankIBAN = profile.bankIBAN
        bankSWIFT = profile.bankSWIFT
        logoData = profile.logoData
        // Synchronously decode the saved logo on first mount so the preview
        // appears on the first body render — otherwise .task(id: logoData)'s
        // off-main decode produces a visible flicker on every editor open.
        if let data = profile.logoData {
            logoUIImage = UIImage(data: data)
        }
    }

    private func save() {
        // Reject a blank name (spec §5/§6): an empty issuer name produces
        // "Unnamed business" on the PDF and would falsely satisfy canSendInvoice.
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showingBlankNameError = true
            return
        }
        let profile = profiles.first ?? newProfile()
        profile.name = name
        profile.entityType = entityType
        profile.address = address
        profile.email = email
        profile.phone = phone
        profile.paymentTerms = paymentTerms
        profile.defaultDueAfterDays = defaultDueAfterDays
        profile.invoiceNumberPrefix = invoiceNumberPrefix
        profile.nextInvoiceNumber = nextInvoiceNumber
        profile.taxLabel = taxLabel
        profile.taxRate = Decimal(taxRatePercent / 100)
        // Trim tax ID + email templates on save so the stored value matches
        // what's displayed/sent. For the email templates specifically: a
        // trailing newline from a paste (common from Apple Mail / wrapped
        // sources) would otherwise be silently stripped by
        // `effectiveInvoiceEmail*Template` at send time — the editor showed the
        // user one string but the email used another. Trimming at save makes
        // the editor's stored value the ground truth.
        profile.taxIDLabel = taxIDLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.taxIDNumber = taxIDNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.invoiceEmailSubjectTemplate = invoiceEmailSubjectTemplate
            .trimmingCharacters(in: .whitespacesAndNewlines)
        profile.invoiceEmailBodyTemplate = invoiceEmailBodyTemplate
            .trimmingCharacters(in: .whitespacesAndNewlines)
        profile.bankBeneficiaryName = bankBeneficiaryName
        profile.bankName = bankName
        profile.bankLocation = bankLocation
        profile.bankIBAN = bankIBAN
        profile.bankSWIFT = bankSWIFT
        profile.logoData = logoData
        profile.updatedAt = .now
        modelContext.saveOrLog("save business profile")
        dismiss()
    }

    @MainActor
    private func loadAndProcessLogo(from item: PhotosPickerItem?) async {
        guard let item else { return }
        logoLoadError = nil

        let rawData: Data
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                logoLoadError = "Couldn't load that photo. Try another."
                return
            }
            rawData = data
        } catch {
            // Distinguish cancellation (user picked again mid-load) from real
            // failure — try? would swallow CancellationError and surface a lie.
            if !Task.isCancelled {
                logoLoadError = "Couldn't load that photo. Try another."
            }
            return
        }

        guard !Task.isCancelled else { return }
        // Process off the main actor to avoid blocking the UI on a large source image.
        let processed = await Task.detached(priority: .userInitiated) {
            LogoImageProcessor.process(rawData)
        }.value
        guard !Task.isCancelled else { return }
        guard let processed else {
            logoLoadError = "That image format isn't supported. Try a JPEG or PNG."
            return
        }
        logoData = processed
    }

    private func newProfile() -> BusinessProfile {
        let p = BusinessProfile.defaultForCurrentLocale()
        modelContext.insert(p)
        return p
    }

    private func format(prefix: String, number: Int) -> String {
        prefix + String(format: "%04d", number)
    }
}
