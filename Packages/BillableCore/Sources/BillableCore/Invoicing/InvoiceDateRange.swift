import Foundation

/// A date range used when generating an invoice. Closed-open: `[start, end)`.
public struct InvoiceDateRange: Equatable, Hashable, Sendable {
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    public func contains(_ date: Date) -> Bool {
        date >= start && date < end
    }
}

/// Named presets the user can pick from in the invoice generator.
/// Resolved to a concrete `InvoiceDateRange` via `range(asOf:calendar:)`.
public enum InvoicePeriodPreset: String, CaseIterable, Identifiable, Sendable {
    case thisWeek
    case lastWeek
    case thisMonth
    case lastMonth
    case custom

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .thisWeek:  "This week"
        case .lastWeek:  "Last week"
        case .thisMonth: "This month"
        case .lastMonth: "Last month"
        case .custom:    "Custom"
        }
    }

    /// Resolve to a concrete date range relative to `referenceDate`.
    /// Returns nil for `.custom` (caller supplies their own range).
    public func range(asOf referenceDate: Date = .now, calendar: Calendar = .current) -> InvoiceDateRange? {
        switch self {
        case .thisWeek:
            guard let interval = calendar.dateInterval(of: .weekOfMonth, for: referenceDate) else { return nil }
            return InvoiceDateRange(start: interval.start, end: interval.end)
        case .lastWeek:
            guard let lastWeekDate = calendar.date(byAdding: .weekOfYear, value: -1, to: referenceDate),
                  let interval = calendar.dateInterval(of: .weekOfMonth, for: lastWeekDate) else { return nil }
            return InvoiceDateRange(start: interval.start, end: interval.end)
        case .thisMonth:
            guard let interval = calendar.dateInterval(of: .month, for: referenceDate) else { return nil }
            return InvoiceDateRange(start: interval.start, end: interval.end)
        case .lastMonth:
            guard let lastMonthDate = calendar.date(byAdding: .month, value: -1, to: referenceDate),
                  let interval = calendar.dateInterval(of: .month, for: lastMonthDate) else { return nil }
            return InvoiceDateRange(start: interval.start, end: interval.end)
        case .custom:
            return nil
        }
    }
}
