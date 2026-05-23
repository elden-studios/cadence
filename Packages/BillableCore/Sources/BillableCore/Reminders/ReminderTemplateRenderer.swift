import Foundation

/// Pure-function renderer for reminder subject + body templates.
///
/// Replaces merge field tokens with concrete values from an `Invoice`.
/// Unknown tokens are left in the output unchanged — this lets future
/// versions add merge fields without breaking templates that don't use them.
public enum ReminderTemplateRenderer {

    /// Render a template string by substituting all supported merge fields.
    ///
    /// Supported tokens: `{clientName}`, `{clientFirstName}`, `{invoiceNumber}`,
    /// `{amount}`, `{dueDate}`, `{daysOverdue}`, `{senderName}`.
    public static func render(
        template: String,
        invoice: Invoice,
        senderName: String,
        now: Date = .now,
        locale: Locale = .current,
        calendar: Calendar = .current
    ) -> String {
        let clientName = invoice.client?.name ?? invoice.clientNameSnapshot
        let clientFirstName = firstName(
            of: invoice.client?.contactName ?? clientName
        )
        let invoiceNumber = invoice.number

        let amountFormatter = NumberFormatter()
        amountFormatter.numberStyle = .currency
        amountFormatter.currencyCode = invoice.currencyCodeSnapshot
        amountFormatter.locale = locale
        let amount = amountFormatter.string(
            from: invoice.total as NSDecimalNumber
        ) ?? ""

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.locale = locale
        dateFormatter.calendar = calendar
        let dueDate = dateFormatter.string(from: invoice.dueAt)

        let rawDays = calendar.dateComponents(
            [.day], from: invoice.dueAt, to: now
        ).day ?? 0
        let daysOverdue = max(rawDays, 0)

        return template
            .replacingOccurrences(of: "{clientName}",      with: clientName)
            .replacingOccurrences(of: "{clientFirstName}", with: clientFirstName)
            .replacingOccurrences(of: "{invoiceNumber}",   with: invoiceNumber)
            .replacingOccurrences(of: "{amount}",          with: amount)
            .replacingOccurrences(of: "{dueDate}",         with: dueDate)
            .replacingOccurrences(of: "{daysOverdue}",     with: "\(daysOverdue)")
            .replacingOccurrences(of: "{senderName}",      with: senderName)
    }

    /// Extract the first space-separated word from a name. Returns the whole
    /// string if there's no space. Empty input returns empty output.
    private static func firstName(of fullName: String) -> String {
        fullName.split(separator: " ").first.map(String.init) ?? fullName
    }
}
