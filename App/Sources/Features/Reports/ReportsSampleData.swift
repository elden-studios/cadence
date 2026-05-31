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
}
