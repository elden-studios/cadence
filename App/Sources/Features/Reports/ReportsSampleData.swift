import Foundation

/// Representative demo numbers for the Reports paywall teaser when the user
/// has no reportable data yet. Never persisted; display-only.
enum ReportsSampleData {
    static let outstanding = Decimal(1200)
    static let overdue = Decimal(450)
    static let overdueCount = 2
    static let avgDaysToPay = 14
    static let invoiced = Decimal(3600)
    static let collected = Decimal(2400)
    static let effectiveRate = Decimal(78)

    /// Six-month "collected" sample series (oldest→newest) for the paywall teaser chart when the
    /// user has <2 months of real collected history. Display-only, never persisted. One organic
    /// mid dip (1950) so it reads real, not linear-fake. The FINAL value equals `collected` (2400)
    /// so the chart's last bar agrees with the COLLECTED tile.
    static let collectedLast6Months: [Decimal] = [1800, 2200, 1950, 2600, 3100, 2400]
}
