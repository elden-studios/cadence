import Foundation
#if os(iOS)
import ActivityKit
#endif

#if os(iOS)

/// ActivityKit attributes for the running-timer Live Activity.
///
/// The attributes block holds values that don't change for the lifetime of the
/// activity (project name, accent color, hourly rate). The nested `ContentState`
/// holds values that update as the timer runs (the `startedAt` instant, which
/// the system uses to drive `Text(timerInterval:)`).
public struct TimerActivityAttributes: ActivityAttributes, Sendable {

    public struct ContentState: Codable, Hashable, Sendable {
        /// The wall-clock moment the timer started. Stays fixed for the life of
        /// the activity; SwiftUI's `Text(timerInterval:)` uses it to render a
        /// system-managed elapsed counter without needing per-second pushes.
        public var startedAt: Date

        /// When `true` the timer is On Break: the elapsed counter must freeze.
        /// The Live Activity view switches from the live `Text(timerInterval:)`
        /// to a static display of `frozenElapsed`.
        public var isOnBreak: Bool

        /// Worked seconds accumulated up to the moment of the break. Only
        /// meaningful when `isOnBreak == true`; ignored while working.
        public var frozenElapsed: TimeInterval

        public init(startedAt: Date, isOnBreak: Bool = false, frozenElapsed: TimeInterval = 0) {
            self.startedAt = startedAt
            self.isOnBreak = isOnBreak
            self.frozenElapsed = frozenElapsed
        }
    }

    public var clientName: String
    public var projectName: String
    /// Stored as the raw `ClientColor.rawValue` so the widget extension can
    /// resolve it via `ClientColor.swiftUIColor` without sharing a Color type.
    public var clientColorRaw: String
    /// Decimal-precision hourly rate, stored as a string for ActivityKit's
    /// JSON encoding (Decimal isn't directly Codable-friendly through Combine).
    public var hourlyRateString: String
    public var currencyCode: String

    public init(
        clientName: String,
        projectName: String,
        clientColorRaw: String,
        hourlyRateString: String,
        currencyCode: String
    ) {
        self.clientName = clientName
        self.projectName = projectName
        self.clientColorRaw = clientColorRaw
        self.hourlyRateString = hourlyRateString
        self.currencyCode = currencyCode
    }

    /// Convenience accessor for the widget extension.
    public var clientColor: ClientColor {
        ClientColor(rawValue: clientColorRaw) ?? .blue
    }

    public var hourlyRate: Decimal {
        Decimal(string: hourlyRateString) ?? 0
    }
}

#endif
