import Foundation
import SwiftData

/// Mirrored @Model. Per-invoice list of when reminder notifications should
/// fire (`fireDates`) and which steps the user has already acted on
/// (`firedDates`).
///
/// Created when `Invoice` transitions to `.sent` via
/// `ReminderService.scheduleForInvoice`. Deleted when the invoice transitions
/// to `.paid` via `ReminderService.cancelForInvoice`.
@Model
public final class InvoiceReminderSchedule {
    @Attribute(.unique) public var id: UUID

    /// The owning invoice. Inverse relationship managed by `Invoice.reminderSchedule`
    /// (added in Task 4.3).
    public var invoice: Invoice?

    /// All scheduled fire moments. Resolved from `ReminderConfig.enabledOffsets`
    /// (or `Client.reminderOffsets`) + `Invoice.dueAt` at the moment of
    /// `markSent`. Each entry is 8:00am local on its offset day.
    public var fireDates: [Date]

    /// Subset of `fireDates` that have already been acted on by the user
    /// (sent a reminder, or dismissed the notification). Both actions prevent
    /// the same step from showing the in-app reminder banner again.
    public var firedDates: [Date]

    public init(
        id: UUID = UUID(),
        invoice: Invoice? = nil,
        fireDates: [Date] = [],
        firedDates: [Date] = []
    ) {
        self.id = id
        self.invoice = invoice
        self.fireDates = fireDates
        self.firedDates = firedDates
    }
}
