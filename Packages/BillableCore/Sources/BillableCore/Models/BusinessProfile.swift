import Foundation
import SwiftData

/// The user's own business identity. Effectively a singleton — there is one
/// `BusinessProfile` per user, used as the issuer on every invoice.
/// Stored in SwiftData so it syncs across the user's devices via CloudKit.
@Model
public final class BusinessProfile {
    public var name: String
    public var address: String
    public var email: String
    public var phone: String
    public var logoData: Data?

    public var paymentTerms: String       // "Net 14", "Due on receipt", free text
    public var defaultDueAfterDays: Int   // used to compute Invoice.dueAt at creation

    public var invoiceNumberPrefix: String  // "INV-"
    public var nextInvoiceNumber: Int       // monotonic counter, locally namespaced

    public var taxLabel: String   // "VAT", "Tax", "GST" — free text
    public var taxRate: Decimal   // 0.0 ... 1.0 (e.g. 0.15 = 15%)

    public var currencyCode: String  // ISO 4217 (e.g. "USD"). v1 single-currency.

    public var createdAt: Date
    public var updatedAt: Date

    public init(
        name: String = "",
        address: String = "",
        email: String = "",
        phone: String = "",
        logoData: Data? = nil,
        paymentTerms: String = "Net 14",
        defaultDueAfterDays: Int = 14,
        invoiceNumberPrefix: String = "INV-",
        nextInvoiceNumber: Int = 1,
        taxLabel: String = "Tax",
        taxRate: Decimal = 0,
        currencyCode: String = "USD",
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.name = name
        self.address = address
        self.email = email
        self.phone = phone
        self.logoData = logoData
        self.paymentTerms = paymentTerms
        self.defaultDueAfterDays = defaultDueAfterDays
        self.invoiceNumberPrefix = invoiceNumberPrefix
        self.nextInvoiceNumber = nextInvoiceNumber
        self.taxLabel = taxLabel
        self.taxRate = taxRate
        self.currencyCode = currencyCode
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Formats the next number and advances the counter. Call at invoice finalization only.
    public func consumeNextInvoiceNumber() -> String {
        let n = nextInvoiceNumber
        nextInvoiceNumber += 1
        updatedAt = .now
        return Self.format(prefix: invoiceNumberPrefix, number: n)
    }

    /// Peek at what the next number would look like, without advancing.
    public var previewNextInvoiceNumber: String {
        Self.format(prefix: invoiceNumberPrefix, number: nextInvoiceNumber)
    }

    private static func format(prefix: String, number: Int) -> String {
        prefix + String(format: "%04d", number)
    }

    /// Returns `true` when the profile is safe to use as an invoice issuer.
    /// A missing or blank business name would produce "Unnamed business" on
    /// the rendered PDF, so we gate Send until the user fills it in.
    public static func canSendInvoice(profile: BusinessProfile?) -> Bool {
        guard let profile else { return false }
        return !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
