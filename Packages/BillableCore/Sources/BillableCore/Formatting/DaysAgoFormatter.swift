import Foundation

/// Returns a human-readable "N days ago" string for a past date.
///
/// "today" for same calendar day OR a date in the future (clock-skew edge case).
/// "yesterday" for exactly 1 calendar day before.
/// "N days ago" for 2+ calendar days before.
///
/// `prefix` is concatenated before the relative portion. Pass `"Last invoice: "`
/// to get strings like "Last invoice: 12 days ago".
public enum DaysAgoFormatter {
    public static func string(for date: Date, prefix: String, now: Date = .now, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: date, to: now).day ?? 0
        switch days {
        case ..<0:  return "\(prefix)today"   // future-dated; clock skew edge case
        case 0:     return "\(prefix)today"
        case 1:     return "\(prefix)yesterday"
        default:    return "\(prefix)\(days) days ago"
        }
    }
}
