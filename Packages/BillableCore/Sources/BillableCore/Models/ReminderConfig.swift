import Foundation
import SwiftData

/// Mirrored singleton @Model holding global reminder configuration.
///
/// Only one row should exist per user. UI ensures this by checking for an
/// existing row before creating a new one (see `PaymentRemindersView` in
/// Phase 5). Mirrored across the user's iCloud devices so settings follow
/// them between iPhone and iPad.
@Model
public final class ReminderConfig {
    @Attribute(.unique) public var id: UUID

    /// Active offset days from `Invoice.dueAt`. Default `[3, 7, 14]`. UI shows
    /// a fixed chip set `[3, 7, 14, 30]` and toggles membership in this array.
    public var enabledOffsets: [Int]

    /// Reminder email subject template. Supports merge fields:
    /// `{clientName}`, `{clientFirstName}`, `{invoiceNumber}`, `{amount}`,
    /// `{dueDate}`, `{daysOverdue}`, `{senderName}`.
    public var subjectTemplate: String

    /// Reminder email body template. Same merge fields as subject.
    public var bodyTemplate: String

    /// Master on/off switch. When false, `ReminderService.scheduleForInvoice`
    /// becomes a no-op even if `enabledOffsets` is non-empty. Default: off.
    /// User must explicitly enable in Settings → Payment reminders.
    public var masterEnabled: Bool

    public init(
        id: UUID = UUID(),
        enabledOffsets: [Int] = [3, 7, 14],
        subjectTemplate: String = ReminderConfig.defaultSubjectTemplate,
        bodyTemplate: String = ReminderConfig.defaultBodyTemplate,
        masterEnabled: Bool = false
    ) {
        self.id = id
        self.enabledOffsets = enabledOffsets
        self.subjectTemplate = subjectTemplate
        self.bodyTemplate = bodyTemplate
        self.masterEnabled = masterEnabled
    }

    /// Construct a config with all default values. Equivalent to
    /// `ReminderConfig()` but communicates intent at the call site.
    public static func defaultConfig() -> ReminderConfig {
        ReminderConfig()
    }

    public static let defaultSubjectTemplate = "Friendly reminder: {invoiceNumber}"

    public static let defaultBodyTemplate = """
Hi {clientFirstName},

Just a quick nudge — invoice {invoiceNumber} for {amount} was due on {dueDate}, \
and it looks like it's a few days outstanding. If you've already sent it, \
please disregard. If not, no rush — just wanted to flag.

Attached is the invoice again for convenience.

Thanks!
{senderName}
"""
}
