import Foundation

/// How often a `RecurrenceTemplate` fires.
public enum RecurrenceCadence: Equatable, Hashable, Sendable {
    case monthly(dayOfMonth: Int)       // 1...31, with clamp-to-last-day for short months
    case weekly(weekday: Weekday)
    case biweekly(weekday: Weekday)

    public enum Weekday: String, Sendable {
        case sunday = "sun", monday = "mon", tuesday = "tue", wednesday = "wed"
        case thursday = "thu", friday = "fri", saturday = "sat"

        /// Apple Calendar `weekday` component (Sunday = 1, Monday = 2, ..., Saturday = 7).
        public var calendarComponent: Int {
            switch self {
            case .sunday: 1; case .monday: 2; case .tuesday: 3
            case .wednesday: 4; case .thursday: 5; case .friday: 6
            case .saturday: 7
            }
        }
    }

    /// Stored form on `RecurrenceTemplate.cadence` (a `String` SwiftData column).
    /// Format:
    /// - "monthlyDay:N" where N is the 1-31 day of month
    /// - "weekly:WWW" where WWW is the 3-char weekday code
    /// - "biweekly:WWW"
    public var rawValue: String {
        switch self {
        case .monthly(let d):  "monthlyDay:\(d)"
        case .weekly(let w):   "weekly:\(w.rawValue)"
        case .biweekly(let w): "biweekly:\(w.rawValue)"
        }
    }

    public static func from(raw: String) -> RecurrenceCadence? {
        let parts = raw.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let kind = String(parts[0])
        let value = String(parts[1])
        switch kind {
        case "monthlyDay":
            guard let d = Int(value), (1...31).contains(d) else { return nil }
            return .monthly(dayOfMonth: d)
        case "weekly":
            guard let w = Weekday(rawValue: value) else { return nil }
            return .weekly(weekday: w)
        case "biweekly":
            guard let w = Weekday(rawValue: value) else { return nil }
            return .biweekly(weekday: w)
        default:
            return nil
        }
    }
}

/// UI-state taxonomy paralleling `RecurrenceCadence`'s case shape, for use
/// in segmented pickers that don't yet hold a day-of-month or weekday value.
/// Maps to `RecurrenceCadence` once the picker fields resolve.
public enum RecurrenceCadenceKind: String, CaseIterable, Identifiable, Sendable {
    case weekly, biweekly, monthly

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .weekly:   "Weekly"
        case .biweekly: "Biweekly"
        case .monthly:  "Monthly"
        }
    }

    /// Derive the picker kind from an existing typed cadence.
    public init(_ cadence: RecurrenceCadence) {
        switch cadence {
        case .monthly:  self = .monthly
        case .weekly:   self = .weekly
        case .biweekly: self = .biweekly
        }
    }
}
