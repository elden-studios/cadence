import SwiftUI
import SwiftData
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
    @State private var currencyCode: String = Locale.current.currency?.identifier ?? "USD"

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

            Section("Currency") {
                Picker("Currency", selection: $currencyCode) {
                    ForEach(CurrencyCatalog.allCodes, id: \.self) { code in
                        Text("\(code) — \(CurrencyCatalog.displayName(for: code))").tag(code)
                    }
                }
                .pickerStyle(.navigationLink)
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
        currencyCode = profile.currencyCode
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
        profile.currencyCode = currencyCode
        profile.updatedAt = .now
        modelContext.saveOrLog("save business profile")
        dismiss()
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
