import SwiftUI

/// The rendered invoice document. Designed to render identically on screen
/// (as a preview) and offscreen via `ImageRenderer` (to PDF).
///
/// Size is fixed to US Letter (8.5 x 11 in = 612 x 792 pt at 72dpi). The host
/// scales the view to fit the device when displaying interactively; the PDF
/// renderer captures it at full size.
public struct InvoiceTemplate: View {

    public static let pageWidth: CGFloat = 612
    public static let pageHeight: CGFloat = 792

    private let data: InvoiceTemplateData
    private let accent: Color

    public init(data: InvoiceTemplateData, accent: Color) {
        self.data = data
        self.accent = accent
    }

    public var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(accent)
                .frame(height: 6)

            VStack(alignment: .leading, spacing: 28) {
                header
                billToAndMeta
                projectTagAndScope
                lineItemsTable
                totalsBlock
                bankDetailsBlock
                if let notes = data.notes, !notes.isEmpty {
                    notesBlock(notes)
                }
                Spacer(minLength: 0)
                footer
            }
            .padding(.horizontal, 48)
            .padding(.top, 32)
            .padding(.bottom, 28)
        }
        .frame(width: Self.pageWidth, height: Self.pageHeight, alignment: .top)
        .background(Color.white)
        .foregroundStyle(Color(red: 0.1, green: 0.12, blue: 0.16))
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
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
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("INVOICE")
                    .font(.system(size: 28, weight: .bold))
                    .tracking(4)
                    .foregroundStyle(accent)
                Text(data.invoiceNumber)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Bill-to + meta

    private var billToAndMeta: some View {
        HStack(alignment: .top, spacing: 32) {
            VStack(alignment: .leading, spacing: 6) {
                sectionCap("BILL TO")
                Text(data.clientName)
                    .font(.system(size: 14, weight: .semibold))
                if let email = data.clientEmail, !email.isEmpty {
                    Text(email).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let address = data.clientAddress, !address.isEmpty {
                    Text(address).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                metaRow("Issued", data.issuedDateLabel)
                metaRow("Due", data.dueDateLabel)
                metaRow("Terms", data.paymentTerms)
            }
        }
    }

    private func metaRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(1)
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .frame(minWidth: 110, alignment: .trailing)
        }
    }

    // MARK: - Project tag + scope of work

    @ViewBuilder
    private var projectTagAndScope: some View {
        if let projectName = data.projectName {
            let dotColor: Color = {
                if let raw = data.projectColorRaw,
                   let cc = ClientColor(rawValue: raw) {
                    return cc.swiftUIColor
                }
                return accent
            }()
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle().fill(dotColor).frame(width: 8, height: 8)
                    Text(projectName)
                        .font(.system(size: 12, weight: .semibold))
                }
                if let scope = data.scopeOfWork, !scope.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("SCOPE OF WORK")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .tracking(1)
                        Text(scope)
                            .font(.system(size: 11).italic())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.yellow.opacity(0.12), in: .rect(cornerRadius: 6))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Line items

    private var lineItemsTable: some View {
        VStack(spacing: 0) {
            HStack {
                Text("DESCRIPTION").frame(maxWidth: .infinity, alignment: .leading)
                Text("HOURS").frame(width: 70, alignment: .trailing)
                Text("RATE").frame(width: 80, alignment: .trailing)
                Text("AMOUNT").frame(width: 90, alignment: .trailing)
            }
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .tracking(1)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(Color(red: 0.96, green: 0.97, blue: 0.98))
            .overlay(alignment: .bottom) {
                Rectangle().fill(accent.opacity(0.4)).frame(height: 1)
            }

            ForEach(Array(data.lineItems.enumerated()), id: \.offset) { _, item in
                HStack {
                    Text(item.description).frame(maxWidth: .infinity, alignment: .leading)
                    Text(formatHours(item.hours)).frame(width: 70, alignment: .trailing)
                    Text(formatMoney(item.hourlyRate)).frame(width: 80, alignment: .trailing)
                    Text(formatMoney(item.amount)).frame(width: 90, alignment: .trailing)
                }
                .font(.system(size: 11))
                .padding(.vertical, 9)
                .padding(.horizontal, 12)
                .background(.white)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Color.gray.opacity(0.12)).frame(height: 0.5)
                }
            }
        }
    }

    // MARK: - Totals

    private var totalsBlock: some View {
        HStack {
            Spacer()
            VStack(spacing: 6) {
                totalsRow("Subtotal", formatMoney(data.subtotal))
                if data.taxAmount > 0 {
                    totalsRow("\(data.taxLabel) (\(formatPercent(data.taxRate)))", formatMoney(data.taxAmount))
                }
                Rectangle().fill(accent).frame(width: 230, height: 1).padding(.vertical, 4)
                totalsRow("Total", formatMoney(data.total), strong: true)
            }
        }
    }

    private func totalsRow(_ label: String, _ value: String, strong: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.system(size: strong ? 13 : 11, weight: strong ? .semibold : .regular))
                .foregroundStyle(strong ? .primary : .secondary)
            Spacer()
            Text(value)
                .font(.system(size: strong ? 16 : 12, weight: strong ? .bold : .medium))
                .foregroundStyle(strong ? accent : .primary)
        }
        .frame(width: 230)
    }

    // MARK: - Bank details

    @ViewBuilder
    private var bankDetailsBlock: some View {
        if data.hasBankDetails {
            VStack(alignment: .leading, spacing: 6) {
                sectionCap("PAYMENT DETAILS")
                VStack(alignment: .leading, spacing: 3) {
                    if !data.bankBeneficiaryName.isEmpty {
                        bankRow("Beneficiary:", data.bankBeneficiaryName, monospaced: false)
                    }
                    if !data.bankName.isEmpty {
                        bankRow("Bank:", data.bankName, monospaced: false)
                    }
                    if !data.bankLocation.isEmpty {
                        bankRow("Location:", data.bankLocation, monospaced: false)
                    }
                    if !data.bankIBAN.isEmpty {
                        bankRow("IBAN:", data.bankIBAN, monospaced: true)
                    }
                    if !data.bankSWIFT.isEmpty {
                        bankRow("SWIFT/BIC:", data.bankSWIFT, monospaced: true)
                    }
                }
            }
        }
    }

    private func bankRow(_ label: String, _ value: String, monospaced: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(monospaced
                      ? .system(size: 11, design: .monospaced)
                      : .system(size: 11))
                .foregroundStyle(.primary)
        }
    }

    // MARK: - Notes + footer

    private func notesBlock(_ notes: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionCap("NOTES")
            Text(notes)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(nil)
        }
    }

    private var footer: some View {
        VStack(spacing: 4) {
            Text("Thank you for your business.")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
            // Watermark footer — free-tier brand stamp. Drawn last so it sits
            // on top of all other content. Pro/trial users have watermark = nil
            // and this branch is skipped entirely.
            if let watermark = data.watermark {
                Text(watermark)
                    .font(.system(size: 9).italic())
                    .foregroundStyle(Color.gray.opacity(0.6))
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    // MARK: - Helpers

    private func sectionCap(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .tracking(1)
    }

    /// "VAT GB123456789" if label+number; "GB123456789" if only number.
    /// Trims whitespace on both fields — stray spaces/newlines pasted from
    /// external sources would otherwise be frozen onto immutable invoice
    /// snapshots and visible on every reprint.
    private var taxIDDisplay: String {
        let trimmedLabel = data.taxIDLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNumber = data.taxIDNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedLabel.isEmpty
            ? trimmedNumber
            : "\(trimmedLabel) \(trimmedNumber)"
    }

    private func formatMoney(_ value: Decimal) -> String {
        value.formatted(.currency(code: data.currencyCode))
    }

    private func formatHours(_ value: Decimal) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }

    private func formatPercent(_ rate: Decimal) -> String {
        let pct = (rate as NSDecimalNumber).doubleValue * 100
        return String(format: "%.2g%%", pct)
    }

    private func imageFromData(_ data: Data) -> Image? {
        #if canImport(UIKit)
        if let ui = UIImage(data: data) {
            return Image(uiImage: ui)
        }
        #elseif canImport(AppKit)
        if let ns = NSImage(data: data) {
            return Image(nsImage: ns)
        }
        #endif
        return nil
    }
}

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// All the data the template needs. Used by both the preview screen and the
/// PDF renderer. Decouples the view from `Invoice` (which is a SwiftData
/// `@Model`, awkward to pass around outside the main actor).
public struct InvoiceTemplateData: Sendable {
    public var issuerName: String
    public var issuerAddress: String
    public var issuerEmail: String
    public var issuerLogo: Data?

    public var clientName: String
    public var clientAddress: String?
    public var clientEmail: String?

    public var invoiceNumber: String
    public var issuedDateLabel: String
    public var dueDateLabel: String
    public var paymentTerms: String

    public var lineItems: [InvoiceLineItem]
    public var notes: String?

    public var subtotal: Decimal
    public var taxLabel: String
    public var taxRate: Decimal
    public var taxAmount: Decimal
    public var total: Decimal
    public var currencyCode: String

    public var bankBeneficiaryName: String = ""
    public var bankName: String = ""
    public var bankLocation: String = ""
    public var bankIBAN: String = ""
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
        !taxIDNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var watermark: String?  // nil for Pro/trial, "Sent with Cadence" for free

    /// Project tag fields — nil for client-combined / recurrence / legacy invoices.
    public var projectName: String?
    public var scopeOfWork: String?
    /// Accent dot colour for the project tag row.
    public var projectColorRaw: String?

    public init(
        issuerName: String,
        issuerAddress: String,
        issuerEmail: String,
        issuerLogo: Data?,
        clientName: String,
        clientAddress: String?,
        clientEmail: String?,
        invoiceNumber: String,
        issuedDateLabel: String,
        dueDateLabel: String,
        paymentTerms: String,
        lineItems: [InvoiceLineItem],
        notes: String?,
        subtotal: Decimal,
        taxLabel: String,
        taxRate: Decimal,
        taxAmount: Decimal,
        total: Decimal,
        currencyCode: String,
        watermark: String? = nil
    ) {
        self.issuerName = issuerName
        self.issuerAddress = issuerAddress
        self.issuerEmail = issuerEmail
        self.issuerLogo = issuerLogo
        self.clientName = clientName
        self.clientAddress = clientAddress
        self.clientEmail = clientEmail
        self.invoiceNumber = invoiceNumber
        self.issuedDateLabel = issuedDateLabel
        self.dueDateLabel = dueDateLabel
        self.paymentTerms = paymentTerms
        self.lineItems = lineItems
        self.notes = notes
        self.subtotal = subtotal
        self.taxLabel = taxLabel
        self.taxRate = taxRate
        self.taxAmount = taxAmount
        self.total = total
        self.currencyCode = currencyCode
        self.watermark = watermark
    }
}

public extension InvoiceTemplateData {
    /// Build template data from a SwiftData `Invoice`.
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
