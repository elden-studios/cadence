import Foundation

/// On-device-only, privacy-pure conversion counters for the Reports paywall.
/// UserDefaults; never transmitted. Read in the DEBUG ActivationMetrics readout.
/// `@MainActor` (matching `BadgeCount`/`ActivationMetrics`) so the read-modify-write
/// increments are serialized — all callers are already main-actor.
@MainActor
enum ReportsConversionMetrics {
    private static let impressionsKey = "reports.paywall.impressions"
    private static let conversionsKey = "reports.paywall.conversions"
    static func recordImpression() { bump(impressionsKey) }
    static func recordConversion() { bump(conversionsKey) }
    static var impressions: Int { UserDefaults.standard.integer(forKey: impressionsKey) }
    static var conversions: Int { UserDefaults.standard.integer(forKey: conversionsKey) }
    private static func bump(_ k: String) { UserDefaults.standard.set(UserDefaults.standard.integer(forKey: k) + 1, forKey: k) }
}
