import Foundation
import SwiftData

/// Pure roll-ups computed from a snapshot of `TimeEntry` rows. Lives in
/// `BillableCore` so it's testable without SwiftData and so the watchOS
/// companion (when it lands) can read the same numbers without re-implementing
/// the math.
public enum ReportsAggregator {

    // MARK: - Time range presets

    public enum TimeRange: String, CaseIterable, Identifiable, Sendable {
        case thisWeek
        case thisMonth
        case thisYear
        case allTime

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .thisWeek:  "Week"
            case .thisMonth: "Month"
            case .thisYear:  "Year"
            case .allTime:   "All"
            }
        }

        public func range(asOf referenceDate: Date = .now, calendar: Calendar = .current) -> ClosedRange<Date> {
            switch self {
            case .thisWeek:
                let interval = calendar.dateInterval(of: .weekOfMonth, for: referenceDate) ?? DateInterval()
                return interval.start...interval.end
            case .thisMonth:
                let interval = calendar.dateInterval(of: .month, for: referenceDate) ?? DateInterval()
                return interval.start...interval.end
            case .thisYear:
                let interval = calendar.dateInterval(of: .year, for: referenceDate) ?? DateInterval()
                return interval.start...interval.end
            case .allTime:
                return Date.distantPast...Date.distantFuture
            }
        }
    }

    // MARK: - Result types

    public struct ClientHours: Identifiable, Sendable {
        public let id: String           // SwiftData store identifier or fallback UUID
        public let clientName: String
        public let clientColorRaw: String
        public let hours: Decimal
        public let amount: Decimal
    }

    public struct ProjectHours: Identifiable, Sendable {
        public let id: String
        public let projectName: String
        public let clientName: String
        public let clientColorRaw: String
        public let isBillable: Bool
        public let hours: Decimal
        public let amount: Decimal
    }

    public struct WeeklyPoint: Identifiable, Sendable {
        public let id: Date
        public let weekStart: Date
        public let amount: Decimal
    }

    public struct Snapshot: Sendable {
        public let totalHours: Decimal
        public let totalEarnings: Decimal
        public let billableHours: Decimal
        public let nonBillableHours: Decimal
        public let uninvoicedAmount: Decimal
        public let clientHours: [ClientHours]
        public let projectHours: [ProjectHours]
        public let earningsTrend: [WeeklyPoint]
        public let currencyCode: String
    }

    // MARK: - Aggregation

    /// Compute a complete report snapshot for the given entries. Filters by `range`,
    /// then groups by client + project, and produces an 8-bucket weekly trend for
    /// the chart (regardless of `range` — the trend is always last-8-weeks).
    public static func snapshot(
        entries: [TimeEntry],
        invoiceLookup: [UUID: Invoice] = [:],
        in range: TimeRange,
        currencyCode: String,
        referenceDate: Date = .now,
        calendar: Calendar = .current
    ) -> Snapshot {
        let bounds = range.range(asOf: referenceDate, calendar: calendar)
        let inRange = entries.filter { entry in
            entry.startedAt >= bounds.lowerBound && entry.startedAt < bounds.upperBound
        }

        // Top-level totals
        var totalSeconds: TimeInterval = 0
        var billableSeconds: TimeInterval = 0
        var nonBillableSeconds: TimeInterval = 0
        var totalEarnings = Decimal(0)

        for entry in inRange {
            let seconds = entry.duration(asOf: referenceDate)
            totalSeconds += seconds
            if entry.project?.isBillable == true {
                billableSeconds += seconds
                totalEarnings += entry.amount(asOf: referenceDate)
            } else {
                nonBillableSeconds += seconds
            }
        }

        // Uninvoiced: NOT scoped to range (the user wants to see all outstanding work).
        let uninvoiced = entries
            .filter { $0.invoiceID == nil }
            .reduce(into: Decimal(0)) { $0 += $1.amount(asOf: referenceDate) }

        // Group by client
        let byClient = Dictionary(grouping: inRange) { entry in
            entry.project?.client?.persistentModelID.storeIdentifier ?? ""
        }
        let clientHours: [ClientHours] = byClient.compactMap { (id, rows) in
            guard let first = rows.first, let client = first.project?.client else { return nil }
            let seconds = rows.reduce(0) { $0 + $1.duration(asOf: referenceDate) }
            let amount = rows.reduce(Decimal(0)) { $0 + $1.amount(asOf: referenceDate) }
            return ClientHours(
                id: id.isEmpty ? UUID().uuidString : id,
                clientName: client.name,
                clientColorRaw: client.colorRaw,
                hours: Decimal(seconds / 3600),
                amount: amount
            )
        }
        .sorted { $0.hours > $1.hours }

        // Group by project
        let byProject = Dictionary(grouping: inRange) { entry in
            entry.project?.persistentModelID.storeIdentifier ?? ""
        }
        let projectHours: [ProjectHours] = byProject.compactMap { (id, rows) in
            guard let first = rows.first, let project = first.project else { return nil }
            let seconds = rows.reduce(0) { $0 + $1.duration(asOf: referenceDate) }
            let amount = rows.reduce(Decimal(0)) { $0 + $1.amount(asOf: referenceDate) }
            return ProjectHours(
                id: id.isEmpty ? UUID().uuidString : id,
                projectName: project.name,
                clientName: project.client?.name ?? "",
                clientColorRaw: project.client?.colorRaw ?? ClientColor.blue.rawValue,
                isBillable: project.isBillable,
                hours: Decimal(seconds / 3600),
                amount: amount
            )
        }
        .sorted { $0.hours > $1.hours }

        // 8-week earnings trend (always, regardless of range — bar chart visual aid).
        let trend = earningsTrend(entries: entries, weeks: 8, asOf: referenceDate, calendar: calendar)

        return Snapshot(
            totalHours: Decimal(totalSeconds / 3600),
            totalEarnings: totalEarnings,
            billableHours: Decimal(billableSeconds / 3600),
            nonBillableHours: Decimal(nonBillableSeconds / 3600),
            uninvoicedAmount: uninvoiced,
            clientHours: clientHours,
            projectHours: projectHours,
            earningsTrend: trend,
            currencyCode: currencyCode
        )
    }

    private static func earningsTrend(
        entries: [TimeEntry],
        weeks: Int,
        asOf referenceDate: Date,
        calendar: Calendar
    ) -> [WeeklyPoint] {
        guard let thisWeekStart = calendar.dateInterval(of: .weekOfMonth, for: referenceDate)?.start else {
            return []
        }

        return (0..<weeks).reversed().compactMap { offset -> WeeklyPoint? in
            guard let weekStart = calendar.date(byAdding: .weekOfYear, value: -offset, to: thisWeekStart),
                  let weekEnd = calendar.date(byAdding: .weekOfYear, value: 1, to: weekStart) else {
                return nil
            }
            let amount = entries
                .filter { entry in
                    entry.startedAt >= weekStart && entry.startedAt < weekEnd
                }
                .reduce(into: Decimal(0)) { $0 += $1.amount(asOf: referenceDate) }
            return WeeklyPoint(id: weekStart, weekStart: weekStart, amount: amount)
        }
    }
}
