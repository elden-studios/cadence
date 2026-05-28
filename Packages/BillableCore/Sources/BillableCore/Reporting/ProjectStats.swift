import Foundation

/// Lifetime, on-the-fly aggregation of a single project's tracked time.
///
/// Pure value type computed from `project.entries` — nothing is stored on the
/// model. Mirrors the reduce pattern in `ReportsAggregator`. `lifetimeValue`
/// is the value of tracked time at the project's CURRENT rate (the same live
/// computation the timer shows) — it is NOT a billed/invoiced figure and moves
/// if the rate changes.
public struct ProjectStats: Equatable, Sendable {
    public let lifetimeSeconds: TimeInterval
    public let lifetimeValue: Decimal
    public let uninvoicedAmount: Decimal
    public let sessionCount: Int
    public let activeDayCount: Int
    public let firstTrackedDay: Date?

    public static func compute(
        for project: Project,
        asOf: Date = .now,
        calendar: Calendar = .current
    ) -> ProjectStats {
        var seconds: TimeInterval = 0
        var value: Decimal = 0
        var uninvoiced: Decimal = 0
        var days = Set<Date>()
        var earliest: Date?

        for entry in project.entries {
            seconds += entry.duration(asOf: asOf)
            let amount = entry.amount(asOf: asOf)   // 0 for non-billable projects
            value += amount
            if entry.invoiceID == nil { uninvoiced += amount }
            days.insert(calendar.startOfDay(for: entry.startedAt))
            earliest = earliest.map { Swift.min($0, entry.startedAt) } ?? entry.startedAt
        }

        return ProjectStats(
            lifetimeSeconds: seconds,
            lifetimeValue: value,
            uninvoicedAmount: uninvoiced,
            sessionCount: project.entries.count,
            activeDayCount: days.count,
            firstTrackedDay: earliest
        )
    }
}
