import Foundation

/// Which span of time entries a recurrence's materialized invoice covers.
public enum RangeRule: String, Equatable, Sendable {
    case previousMonth
    case previousWeek
    case previousBiweek

    /// Resolve the rule against a fire date into an `InvoiceDateRange`.
    /// Convention: `[start, end)` half-open interval.
    public func resolve(
        from fireDate: Date,
        calendar: Calendar = .current
    ) -> InvoiceDateRange {
        switch self {
        case .previousMonth:
            let startOfFireMonth = calendar.date(
                from: calendar.dateComponents([.year, .month], from: fireDate)
            )!
            let startOfPrevMonth = calendar.date(
                byAdding: .month, value: -1, to: startOfFireMonth
            )!
            return InvoiceDateRange(start: startOfPrevMonth, end: startOfFireMonth)

        case .previousWeek:
            let startOfFireWeek = calendar.date(
                from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: fireDate)
            )!
            let startOfPrevWeek = calendar.date(byAdding: .day, value: -7, to: startOfFireWeek)!
            return InvoiceDateRange(start: startOfPrevWeek, end: startOfFireWeek)

        case .previousBiweek:
            let startOfFireWeek = calendar.date(
                from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: fireDate)
            )!
            let startOfPrevBiweek = calendar.date(byAdding: .day, value: -14, to: startOfFireWeek)!
            return InvoiceDateRange(start: startOfPrevBiweek, end: startOfFireWeek)
        }
    }

    /// Implied range rule from a cadence (used when the UI does not expose
    /// the range rule directly in v1.1).
    public static func implied(from cadence: RecurrenceCadence) -> RangeRule {
        switch cadence {
        case .monthly:  .previousMonth
        case .weekly:   .previousWeek
        case .biweekly: .previousBiweek
        }
    }
}
