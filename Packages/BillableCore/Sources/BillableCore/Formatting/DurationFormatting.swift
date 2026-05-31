import Foundation

public enum DurationFormatting {
    /// "Xh YYm" from seconds (worked time).
    public static func hoursMinutes(seconds: TimeInterval) -> String {
        let totalMinutes = Int(seconds / 60)
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        return "\(h)h \(String(format: "%02d", m))m"
    }

    /// "Xh YYm" from decimal hours (e.g. ReportsView).
    public static func hoursMinutes(decimalHours: Decimal) -> String {
        let seconds = TimeInterval(truncating: (decimalHours * 3600) as NSDecimalNumber)
        return hoursMinutes(seconds: seconds)
    }
}
