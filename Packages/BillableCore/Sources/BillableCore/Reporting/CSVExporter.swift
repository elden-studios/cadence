import Foundation

/// Generates a CSV blob for tracked time entries. Used by Reports → Share →
/// "TimeEntries.csv" to hand off to an accountant or spreadsheet.
///
/// Format (one header row + N data rows):
/// `date,client,project,start,end,worked_hours,hourly_rate,amount,billable,invoice_number,notes`
///
/// `worked_hours` is the net worked time with break gaps excluded (mirrors
/// `TimeEntry.duration()`). Manual/legacy entries (no break data) fall back to
/// wall-clock end−start.
///
/// Decimal values use the user's locale-free representation (`.`-separator)
/// so the output opens cleanly in Numbers, Excel, and Google Sheets.
public enum CSVExporter {

    public struct Row: Sendable {
        public let date: Date
        public let clientName: String
        public let projectName: String
        public let startedAt: Date
        public let endedAt: Date?
        public let durationHours: Decimal
        public let hourlyRate: Decimal
        public let amount: Decimal
        public let isBillable: Bool
        public let invoiceNumber: String?
        public let notes: String?

        public init(
            date: Date,
            clientName: String,
            projectName: String,
            startedAt: Date,
            endedAt: Date?,
            durationHours: Decimal,
            hourlyRate: Decimal,
            amount: Decimal,
            isBillable: Bool,
            invoiceNumber: String?,
            notes: String?
        ) {
            self.date = date
            self.clientName = clientName
            self.projectName = projectName
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.durationHours = durationHours
            self.hourlyRate = hourlyRate
            self.amount = amount
            self.isBillable = isBillable
            self.invoiceNumber = invoiceNumber
            self.notes = notes
        }
    }

    public static let header = "date,client,project,start,end,worked_hours,hourly_rate,amount,billable,invoice_number,notes"

    public static func csv(for rows: [Row]) -> String {
        csv(for: rows, dateFormatter: makeISOFormatter())
    }

    public static func csv(for rows: [Row], dateFormatter: ISO8601DateFormatter) -> String {
        var lines: [String] = [header]
        for row in rows {
            let dateString = dateFormatter.string(from: row.date).prefix(10)
            let cols: [String] = [
                String(dateString),
                quote(row.clientName),
                quote(row.projectName),
                dateFormatter.string(from: row.startedAt),
                row.endedAt.map(dateFormatter.string(from:)) ?? "",
                decimal(row.durationHours),
                decimal(row.hourlyRate),
                decimal(row.amount),
                row.isBillable ? "true" : "false",
                quote(row.invoiceNumber ?? ""),
                quote(row.notes ?? ""),
            ]
            lines.append(cols.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Build CSV rows from a sequence of `TimeEntry` model objects.
    @MainActor
    public static func rows(
        from entries: [TimeEntry],
        invoiceLookup: [UUID: Invoice]
    ) -> [Row] {
        entries.compactMap { entry in
            guard let project = entry.project,
                  let client = project.client else { return nil }
            let seconds = entry.duration()
            let hours = Decimal(seconds / 3600)
            let amount = entry.amount()
            let invoiceNumber: String? = entry.invoiceID.flatMap { invoiceLookup[$0]?.number }
            return Row(
                date: entry.startedAt,
                clientName: client.name,
                projectName: project.name,
                startedAt: entry.startedAt,
                endedAt: entry.endedAt,
                durationHours: hours,
                hourlyRate: project.hourlyRate,
                amount: amount,
                isBillable: project.isBillable,
                invoiceNumber: invoiceNumber,
                notes: entry.notes
            )
        }
    }

    // MARK: - Helpers

    private static func makeISOFormatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }

    private static func decimal(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 4
        return formatter.string(from: value as NSDecimalNumber) ?? "0"
    }

    /// CSV-escapes a string per RFC 4180: wraps in double-quotes if it contains
    /// comma, quote, or newline; doubles any embedded quotes.
    private static func quote(_ value: String) -> String {
        let needsEscape = value.contains(",") || value.contains("\"") || value.contains("\n")
        if !needsEscape { return value }
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}
