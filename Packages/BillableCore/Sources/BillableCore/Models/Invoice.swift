import Foundation
import SwiftData

public enum InvoiceStatus: String, Codable, CaseIterable, Sendable {
    case draft
    case sent
    case paid
}

@Model
public final class Invoice {
    /// Stable, SwiftData-independent identifier. Used by TimeEntry to refer
    /// back to the invoice it was billed on, and by export formats.
    public var uuid: UUID

    /// User-namespaced invoice number string (e.g. "INV-0007").
    public var number: String

    public var issuedAt: Date
    public var dueAt: Date
    public var sentAt: Date?
    public var paidAt: Date?

    public var statusRaw: String

    /// Snapshot of the client at the moment the invoice was created. Denormalized
    /// so the archived invoice renders correctly even if the client is later renamed
    /// or deleted.
    public var clientNameSnapshot: String
    public var clientAddressSnapshot: String?
    public var clientEmailSnapshot: String?
    public var clientColorRaw: String

    /// Snapshot of the business profile (issuer) at the moment of finalization.
    public var issuerNameSnapshot: String
    public var issuerAddressSnapshot: String
    public var issuerEmailSnapshot: String
    public var issuerLogoSnapshot: Data?
    public var issuerBankBeneficiaryNameSnapshot: String = ""
    public var issuerBankNameSnapshot: String = ""
    public var issuerBankLocationSnapshot: String = ""
    public var issuerBankIBANSnapshot: String = ""
    public var issuerBankSWIFTSnapshot: String = ""
    public var paymentTermsSnapshot: String

    public var taxLabelSnapshot: String
    public var taxRateSnapshot: Decimal
    public var currencyCodeSnapshot: String

    /// Line items encoded as JSON Data. Decoded via `lineItems` accessor.
    /// Stored encoded (rather than via @Relationship) because:
    /// 1. Invoices are immutable post-finalization, so we don't need editable item rows.
    /// 2. Sidesteps CloudKit relationship merge complexity on financial records.
    public var lineItemsData: Data

    public var notes: String?

    /// Currently-rendered PDF cache. Regenerable from line items + snapshots,
    /// but cached so the user can share without recomputation.
    public var pdfDataCached: Data?

    /// Per-invoice reminder schedule. Set by `ReminderService.scheduleForInvoice`
    /// at `markSent` transition; cleared by `cancelForInvoice` at `markPaid`.
    @Relationship(deleteRule: .cascade, inverse: \InvoiceReminderSchedule.invoice)
    public var reminderSchedule: InvoiceReminderSchedule?

    public var createdAt: Date
    public var updatedAt: Date

    public var client: Client?

    public init(
        uuid: UUID = UUID(),
        number: String,
        issuedAt: Date = .now,
        dueAt: Date,
        status: InvoiceStatus = .draft,
        clientNameSnapshot: String,
        clientAddressSnapshot: String? = nil,
        clientEmailSnapshot: String? = nil,
        clientColor: ClientColor = .blue,
        issuerNameSnapshot: String,
        issuerAddressSnapshot: String,
        issuerEmailSnapshot: String,
        issuerLogoSnapshot: Data? = nil,
        issuerBankBeneficiaryNameSnapshot: String = "",
        issuerBankNameSnapshot: String = "",
        issuerBankLocationSnapshot: String = "",
        issuerBankIBANSnapshot: String = "",
        issuerBankSWIFTSnapshot: String = "",
        paymentTermsSnapshot: String,
        taxLabelSnapshot: String,
        taxRateSnapshot: Decimal,
        currencyCodeSnapshot: String,
        lineItems: [InvoiceLineItem] = [],
        notes: String? = nil,
        client: Client? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.uuid = uuid
        self.number = number
        self.issuedAt = issuedAt
        self.dueAt = dueAt
        self.statusRaw = status.rawValue
        self.clientNameSnapshot = clientNameSnapshot
        self.clientAddressSnapshot = clientAddressSnapshot
        self.clientEmailSnapshot = clientEmailSnapshot
        self.clientColorRaw = clientColor.rawValue
        self.issuerNameSnapshot = issuerNameSnapshot
        self.issuerAddressSnapshot = issuerAddressSnapshot
        self.issuerEmailSnapshot = issuerEmailSnapshot
        self.issuerLogoSnapshot = issuerLogoSnapshot
        self.issuerBankBeneficiaryNameSnapshot = issuerBankBeneficiaryNameSnapshot
        self.issuerBankNameSnapshot = issuerBankNameSnapshot
        self.issuerBankLocationSnapshot = issuerBankLocationSnapshot
        self.issuerBankIBANSnapshot = issuerBankIBANSnapshot
        self.issuerBankSWIFTSnapshot = issuerBankSWIFTSnapshot
        self.paymentTermsSnapshot = paymentTermsSnapshot
        self.taxLabelSnapshot = taxLabelSnapshot
        self.taxRateSnapshot = taxRateSnapshot
        self.currencyCodeSnapshot = currencyCodeSnapshot
        self.lineItemsData = (try? JSONEncoder().encode(lineItems)) ?? Data("[]".utf8)
        self.notes = notes
        self.client = client
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: - Status

    public var status: InvoiceStatus {
        get { InvoiceStatus(rawValue: statusRaw) ?? .draft }
        set { statusRaw = newValue.rawValue }
    }

    /// Derived. `true` when the invoice is `.sent` and past its `dueAt`.
    /// Overdue is intentionally not stored — it changes with the clock.
    public func isOverdue(asOf referenceDate: Date = .now) -> Bool {
        status == .sent && dueAt < referenceDate
    }

    public var clientColor: ClientColor {
        ClientColor(rawValue: clientColorRaw) ?? .blue
    }

    // MARK: - Line items

    public var lineItems: [InvoiceLineItem] {
        get {
            (try? JSONDecoder().decode([InvoiceLineItem].self, from: lineItemsData)) ?? []
        }
        set {
            lineItemsData = (try? JSONEncoder().encode(newValue)) ?? Data("[]".utf8)
            updatedAt = .now
        }
    }

    // MARK: - Money math

    public var subtotal: Decimal {
        lineItems.reduce(into: Decimal(0)) { $0 += $1.amount }
    }

    public var taxAmount: Decimal {
        subtotal * taxRateSnapshot
    }

    public var total: Decimal {
        subtotal + taxAmount
    }
}
