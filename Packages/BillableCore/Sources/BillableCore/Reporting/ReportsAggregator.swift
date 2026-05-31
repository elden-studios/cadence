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
        public let id: String           // stable per-object identifier (from persistentModelID)
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

    // MARK: - Money / AR / performance sub-summaries

    public struct MoneySummary: Sendable, Equatable {
        public let tracked: Decimal     // billable time-value in range (hours × current rate)
        public let invoiced: Decimal    // Σ total of non-draft invoices issued in range
        public let collected: Decimal   // Σ total of paid invoices paid in range
    }

    public struct Aging: Sendable, Equatable {
        public let current: Decimal     // sent, not yet due
        public let d1to30: Decimal
        public let d31to60: Decimal
        public let d60plus: Decimal
        public var overdue: Decimal { d1to30 + d31to60 + d60plus }
        public var outstanding: Decimal { current + overdue }
    }

    public struct ARSummary: Sendable, Equatable {
        public let aging: Aging
        public let overdueCount: Int
        public let avgDaysToPay: Double?   // mean(paidAt − issuedAt) in days, over paid-in-range; nil if none
        public var outstanding: Decimal { aging.outstanding }
        public var overdue: Decimal { aging.overdue }
    }

    public struct Performance: Sendable, Equatable {
        public let effectiveRate: Decimal?  // tracked ÷ totalHours ($/h); nil when totalHours == 0
        public let utilization: Double?     // billableHours ÷ totalHours (0...1); nil when totalHours == 0
    }

    public struct TrendPoint: Identifiable, Sendable, Equatable {
        public let id: Date
        public let bucketStart: Date
        public let amount: Decimal       // invoiced total in this bucket
    }

    public enum TrendBucket: Sendable { case day, week, month }  // x-axis granularity for the chart

    public struct Snapshot: Sendable {
        public let money: MoneySummary
        public let ar: ARSummary
        public let performance: Performance
        public let totalHours: Decimal
        public let billableHours: Decimal
        public let nonBillableHours: Decimal
        public let clientHours: [ClientHours]    // unchanged type
        public let projectHours: [ProjectHours]  // unchanged type
        public let revenueTrend: [TrendPoint]
        public let trendBucket: TrendBucket
        public let excludedCurrencyCount: Int     // invoices skipped for non-matching currency
        public let currencyCode: String
        public var hasReportableData: Bool { totalHours > 0 || !revenueTrend.isEmpty || ar.outstanding > 0 || money.invoiced > 0 }
    }

    // MARK: - Aggregation

    /// Compute a complete report snapshot for the given entries + invoices. Time
    /// metrics filter by `range`; the money block draws from invoices whose currency
    /// matches `activeCurrency` (others are excluded and counted).
    public static func snapshot(
        entries: [TimeEntry],
        invoices: [Invoice],
        in range: TimeRange,
        activeCurrency: String,
        referenceDate: Date = .now,
        calendar: Calendar = .current
    ) -> Snapshot {
        let bounds = range.range(asOf: referenceDate, calendar: calendar)
        func inRange(_ d: Date) -> Bool { d >= bounds.lowerBound && d < bounds.upperBound }

        // ---- currency-filtered invoice set ----
        let curInvoices = invoices.filter { $0.currencyCodeSnapshot == activeCurrency }
        let excludedCurrencyCount = invoices.count - curInvoices.count

        // ---- entries in range (existing behaviour) ----
        let inRangeEntries = entries.filter { inRange($0.startedAt) }
        var totalSeconds: TimeInterval = 0, billableSeconds: TimeInterval = 0, nonBillableSeconds: TimeInterval = 0
        var tracked = Decimal(0)
        for entry in inRangeEntries {
            let s = entry.duration(asOf: referenceDate)
            totalSeconds += s
            if entry.project?.isBillable == true { billableSeconds += s; tracked += entry.amount(asOf: referenceDate) }
            else { nonBillableSeconds += s }
        }

        // ---- MoneySummary ----
        let invoiced = curInvoices
            .filter { $0.status != .draft && inRange($0.issuedAt) }
            .reduce(Decimal(0)) { $0 + $1.total }
        let collected = curInvoices
            .filter { $0.status == .paid && ($0.paidAt.map(inRange) ?? false) }
            .reduce(Decimal(0)) { $0 + $1.total }
        let money = MoneySummary(tracked: tracked, invoiced: invoiced, collected: collected)

        // ---- AR (Task 2), Performance (Task 3), Trend (Task 4) ----
        let ar = arSummary(curInvoices, range: range, bounds: bounds, asOf: referenceDate, calendar: calendar)
        let performance = performanceSummary(tracked: tracked, totalHours: Decimal(totalSeconds/3600), billableHours: Decimal(billableSeconds/3600))
        let trend = revenueTrend(curInvoices, range: range, bounds: bounds, asOf: referenceDate, calendar: calendar)

        // ---- per-client / per-project (existing, keep) ----
        let (clientHours, projectHours) = groupings(inRangeEntries, asOf: referenceDate)

        return Snapshot(
            money: money, ar: ar, performance: performance,
            totalHours: Decimal(totalSeconds/3600),
            billableHours: Decimal(billableSeconds/3600),
            nonBillableHours: Decimal(nonBillableSeconds/3600),
            clientHours: clientHours, projectHours: projectHours,
            revenueTrend: trend.points, trendBucket: trend.bucket,
            excludedCurrencyCount: excludedCurrencyCount, currencyCode: activeCurrency)
    }

    // MARK: - Per-client / per-project grouping (existing behaviour, lifted)

    private static func groupings(
        _ inRange: [TimeEntry],
        asOf referenceDate: Date
    ) -> ([ClientHours], [ProjectHours]) {
        // Group by client — key on the full per-object `persistentModelID`, NOT
        // `.storeIdentifier` (the store-wide UUID shared by EVERY object in the
        // store, which would collapse all clients into a single bucket). Entries
        // with no client group under `nil` and are dropped by the guard below
        // (unchanged behaviour — "No client" time isn't shown in clientHours).
        let byClient = Dictionary(grouping: inRange) { $0.project?.client?.persistentModelID }
        let clientHours: [ClientHours] = byClient.compactMap { (_, rows) -> ClientHours? in
            guard let first = rows.first, let client = first.project?.client else { return nil }
            let seconds = rows.reduce(0) { $0 + $1.duration(asOf: referenceDate) }
            let amount = rows.reduce(Decimal(0)) { $0 + $1.amount(asOf: referenceDate) }
            return ClientHours(
                id: "\(client.persistentModelID)",
                clientName: client.name,
                clientColorRaw: client.colorRaw,
                hours: Decimal(seconds / 3600),
                amount: amount
            )
        }
        .sorted { $0.hours > $1.hours }

        // Group by project — same fix: full per-object id, not `.storeIdentifier`.
        let byProject = Dictionary(grouping: inRange) { $0.project?.persistentModelID }
        let projectHours: [ProjectHours] = byProject.compactMap { (_, rows) -> ProjectHours? in
            guard let first = rows.first, let project = first.project else { return nil }
            let seconds = rows.reduce(0) { $0 + $1.duration(asOf: referenceDate) }
            let amount = rows.reduce(Decimal(0)) { $0 + $1.amount(asOf: referenceDate) }
            return ProjectHours(
                id: "\(project.persistentModelID)",
                projectName: project.name,
                clientName: project.client?.name ?? "",
                clientColorRaw: project.client?.colorRaw ?? ClientColor.blue.rawValue,
                isBillable: project.isBillable,
                hours: Decimal(seconds / 3600),
                amount: amount
            )
        }
        .sorted { $0.hours > $1.hours }

        return (clientHours, projectHours)
    }

    // MARK: - AR / Performance / Trend
    //
    // Stubs land here so the file compiles after Task 1's reshape. Tasks 2–4 give
    // them real bodies + tests; Task 5 asserts the integrated result.

    private static func arSummary(_ invoices: [Invoice], range: TimeRange,
                                  bounds: ClosedRange<Date>, asOf now: Date,
                                  calendar: Calendar) -> ARSummary {
        var current = Decimal(0), d1 = Decimal(0), d2 = Decimal(0), d3 = Decimal(0)
        var overdueCount = 0
        for inv in invoices where inv.status == .sent {
            if inv.dueAt >= now { current += inv.total; continue }
            overdueCount += 1
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: inv.dueAt), to: calendar.startOfDay(for: now)).day ?? 0
            switch days {
            case ...30: d1 += inv.total
            case 31...60: d2 += inv.total
            default: d3 += inv.total
            }
        }
        let aging = Aging(current: current, d1to30: d1, d31to60: d2, d60plus: d3)

        let paid = invoices.filter { $0.status == .paid && ($0.paidAt.map { $0 >= bounds.lowerBound && $0 < bounds.upperBound } ?? false) }
        let avg: Double? = paid.isEmpty ? nil : Double(
            paid.compactMap { inv in inv.paidAt.map { calendar.dateComponents([.day], from: calendar.startOfDay(for: inv.issuedAt), to: calendar.startOfDay(for: $0)).day ?? 0 } }.reduce(0, +)
        ) / Double(paid.count)

        return ARSummary(aging: aging, overdueCount: overdueCount, avgDaysToPay: avg)
    }

    static func performanceSummary(tracked: Decimal, totalHours: Decimal, billableHours: Decimal) -> Performance {
        guard totalHours > 0 else { return Performance(effectiveRate: nil, utilization: nil) }
        let rate = tracked / totalHours
        let util = (billableHours as NSDecimalNumber).doubleValue / (totalHours as NSDecimalNumber).doubleValue
        return Performance(effectiveRate: rate, utilization: util)
    }

    private static func revenueTrend(_ invoices: [Invoice], range: TimeRange,
                                     bounds: ClosedRange<Date>, asOf now: Date,
                                     calendar: Calendar) -> (points: [TrendPoint], bucket: TrendBucket) {
        let bucket: TrendBucket = {
            switch range { case .thisWeek: return .day; case .thisMonth: return .week
                           case .thisYear, .allTime: return .month }
        }()
        let comp: Calendar.Component = (bucket == .day) ? .day : (bucket == .week ? .weekOfYear : .month)

        let billed = invoices.filter { $0.status != .draft }
        // For allTime, span earliest issued → now; else span the range bounds.
        let lower = (range == .allTime) ? (billed.map(\.issuedAt).min() ?? now) : bounds.lowerBound
        let upper = (range == .allTime) ? now : min(bounds.upperBound, now)
        guard lower <= upper,
              let firstStart = calendar.dateInterval(of: comp, for: lower)?.start else { return ([], bucket) }

        // Pre-group billed invoices by bucket-start (O(N)) so each bucket is an
        // O(1) lookup instead of re-filtering every invoice per bucket (was O(N×M)).
        let billedByBucket = Dictionary(grouping: billed) { inv in
            calendar.dateInterval(of: comp, for: inv.issuedAt)?.start ?? inv.issuedAt
        }
        var points: [TrendPoint] = []
        var cursor = firstStart
        var guardCount = 0
        while cursor <= upper && guardCount < 400 {
            guard let next = calendar.date(byAdding: comp, value: 1, to: cursor) else { break }
            let amount = (billedByBucket[cursor] ?? []).reduce(Decimal(0)) { $0 + $1.total }
            points.append(TrendPoint(id: cursor, bucketStart: cursor, amount: amount))
            cursor = next; guardCount += 1
        }
        return (points, bucket)
    }
}
