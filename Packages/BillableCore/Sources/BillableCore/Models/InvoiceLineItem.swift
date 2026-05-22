import Foundation

/// A frozen snapshot of one line item on an invoice.
///
/// Invoices are immutable once `Sent` (see `Invoice.status`), so line items are
/// stored as encoded value types rather than `@Model` references. This avoids
/// CloudKit merge conflicts and guarantees the customer's archived invoice
/// always renders the same way, even if the underlying project rate changes.
public struct InvoiceLineItem: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// Free-text description (defaults to "<Project name> — <date or date range>").
    public var description: String
    /// Hours billed on this line item, rounded by the user's preference.
    public var hours: Decimal
    /// Rate at the moment the invoice was finalized.
    public var hourlyRate: Decimal
    /// Optional reference back to the originating TimeEntry, used to mark the entry as invoiced.
    /// Stored as a string to remain stable across schema migrations / CloudKit.
    public var sourceTimeEntryRef: String?

    public init(
        id: UUID = UUID(),
        description: String,
        hours: Decimal,
        hourlyRate: Decimal,
        sourceTimeEntryRef: String? = nil
    ) {
        self.id = id
        self.description = description
        self.hours = hours
        self.hourlyRate = hourlyRate
        self.sourceTimeEntryRef = sourceTimeEntryRef
    }

    public var amount: Decimal { hours * hourlyRate }
}
