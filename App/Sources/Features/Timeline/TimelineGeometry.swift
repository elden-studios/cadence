import Foundation
import CoreGraphics

/// Maps wall-clock time-of-day ↔ y-coordinate on the day canvas.
///
/// The canvas is a vertical strip representing 24 hours. Each hour gets
/// `pointsPerHour` of vertical space. The top edge (y=0) is midnight (start of day);
/// the bottom edge is midnight of the next day.
struct TimelineGeometry {
    /// Default vertical density. 80 pt/hour is dense enough to render 15-min blocks
    /// at a tappable size (~20 pt tall) while keeping the canvas ~5x screen-height
    /// so users still grasp the day at a glance.
    static let defaultPointsPerHour: CGFloat = 80

    let dayStart: Date
    let pointsPerHour: CGFloat

    init(dayStart: Date, pointsPerHour: CGFloat = TimelineGeometry.defaultPointsPerHour) {
        self.dayStart = dayStart
        self.pointsPerHour = pointsPerHour
    }

    var pointsPerMinute: CGFloat { pointsPerHour / 60 }
    var pointsPerSecond: CGFloat { pointsPerHour / 3600 }

    /// Total height of the canvas in points (24 hours).
    var totalHeight: CGFloat { pointsPerHour * 24 }

    /// y-position for a given date relative to `dayStart`. Negative if before midnight,
    /// >totalHeight if after midnight tomorrow. Caller should clamp/clip as needed.
    func y(for date: Date) -> CGFloat {
        let seconds = date.timeIntervalSince(dayStart)
        return CGFloat(seconds) * pointsPerSecond
    }

    /// Date for a given y-position on the canvas.
    func date(at y: CGFloat) -> Date {
        let seconds = TimeInterval(y / pointsPerSecond)
        return dayStart.addingTimeInterval(seconds)
    }

    /// Snap a date to the nearest interval (e.g., 15 min). Pass `1` for no snapping.
    func snap(_ date: Date, toMinutes minutes: Int) -> Date {
        let intervalSeconds = max(1, minutes) * 60
        let seconds = date.timeIntervalSince(dayStart)
        let snapped = (seconds / Double(intervalSeconds)).rounded() * Double(intervalSeconds)
        return dayStart.addingTimeInterval(snapped)
    }
}

/// Snap granularity for drag operations on the timeline.
public enum TimelineSnap: Int, CaseIterable {
    case oneMinute = 1
    case fiveMinutes = 5
    case fifteenMinutes = 15
    case thirtyMinutes = 30

    public var label: String {
        switch self {
        case .oneMinute:      "1 min"
        case .fiveMinutes:    "5 min"
        case .fifteenMinutes: "15 min"
        case .thirtyMinutes:  "30 min"
        }
    }
}
