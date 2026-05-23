import Foundation
import SwiftData

/// Local-only bookkeeping for a pending iOS notification.
///
/// Stored in a SwiftData configuration that is NOT mirrored to CloudKit because
/// iOS notification state is device-specific. Each device rebuilds its own
/// rows via `Scheduler.resyncOnLaunch()` from the mirrored truth on
/// `RecurrenceTemplate` and `InvoiceReminderSchedule`.
@Model
public final class ScheduledNotification {
    /// Also used as the `UNNotificationRequest.identifier`.
    @Attribute(.unique) public var id: UUID

    /// When iOS should deliver the notification (absolute UTC moment).
    public var fireAt: Date

    /// "recurrence" | "reminder" — discriminator for `payloadID`.
    public var payloadType: String

    /// FK to either `RecurrenceTemplate.id` (when `payloadType == "recurrence"`)
    /// or `InvoiceReminderSchedule.id` (when `payloadType == "reminder"`).
    public var payloadID: UUID

    public init(
        id: UUID = UUID(),
        fireAt: Date,
        payloadType: String,
        payloadID: UUID
    ) {
        self.id = id
        self.fireAt = fireAt
        self.payloadType = payloadType
        self.payloadID = payloadID
    }
}
