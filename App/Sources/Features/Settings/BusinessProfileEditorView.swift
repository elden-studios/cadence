import SwiftUI
import SwiftData
import PhotosUI
import BillableCore

/// Form-based editor for the user's BusinessProfile (singleton).
/// Creates a profile on first save if one doesn't already exist.
struct BusinessProfileEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query private var profiles: [BusinessProfile]

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

    @State private var bankBeneficiaryName: String = ""
    @State private var bankName: String = ""
    @State private var bankLocation: String = ""
    @State private var bankIBAN: String = ""
    @State private var bankSWIFT: String = ""

    @State private var logoData: Data?
    @State private var logoPickerItem: PhotosPickerItem?

    @State private var hasLoaded = false

    var body: some View {
        Form {
            Section("Issuer") {
                TextField("Business name", text: $name)
                    .textInputAutocapitalization(.words)
                TextField("Email", text: $email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .textContentType(.emailAddress)
                TextField("Phone", text: $phone)
                    .keyboardType(.phonePad)
                TextField("Address", text: $address, axis: .vertical)
                    .lineLimit(2...4)
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

            Section("Tax") {
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
            }

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
                            // Reset picker selection too, so re-picking the same
                            // photo still fires .onChange and re-runs processing.
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
                    .textInputAutocapitalization(.words)
                TextField("Bank name", text: $bankName)
                    .textInputAutocapitalization(.words)
                TextField("Location (city, country)", text: $bankLocation)
                    .textInputAutocapitalization(.words)
                TextField("IBAN", text: $bankIBAN)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                TextField("SWIFT / BIC (optional)", text: $bankSWIFT)
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
    }

    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard let profile = profiles.first else { return }
        name = profile.name
        address = profile.address
        email = profile.email
        phone = profile.phone
        paymentTerms = profile.paymentTerms
        defaultDueAfterDays = profile.defaultDueAfterDays
        invoiceNumberPrefix = profile.invoiceNumberPrefix
        nextInvoiceNumber = profile.nextInvoiceNumber
        taxLabel = profile.taxLabel
        taxRatePercent = (profile.taxRate as NSDecimalNumber).doubleValue * 100
        bankBeneficiaryName = profile.bankBeneficiaryName
        bankName = profile.bankName
        bankLocation = profile.bankLocation
        bankIBAN = profile.bankIBAN
        bankSWIFT = profile.bankSWIFT
        logoData = profile.logoData
    }

    private func save() {
        let profile = profiles.first ?? newProfile()
        profile.name = name
        profile.address = address
        profile.email = email
        profile.phone = phone
        profile.paymentTerms = paymentTerms
        profile.defaultDueAfterDays = defaultDueAfterDays
        profile.invoiceNumberPrefix = invoiceNumberPrefix
        profile.nextInvoiceNumber = nextInvoiceNumber
        profile.taxLabel = taxLabel
        profile.taxRate = Decimal(taxRatePercent / 100)
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

    private func format(prefix: String, number: Int) -> String {
        prefix + String(format: "%04d", number)
    }
}
