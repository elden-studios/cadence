import Foundation
import Testing
@testable import BillableCore

@Suite("DurationFormatting")
struct DurationFormattingTests {

    // MARK: - seconds overload

    @Test("Zero seconds → '0h 00m'")
    func zeroSeconds() {
        #expect(DurationFormatting.hoursMinutes(seconds: 0) == "0h 00m")
    }

    @Test("3600s (exactly 1 hour) → '1h 00m'")
    func oneHourExact() {
        #expect(DurationFormatting.hoursMinutes(seconds: 3600) == "1h 00m")
    }

    @Test("3661s (1h 1m 1s) → '1h 01m'")
    func oneHourOneMinute() {
        #expect(DurationFormatting.hoursMinutes(seconds: 3661) == "1h 01m")
    }

    @Test("Sub-minute seconds truncate to whole minutes")
    func subMinuteTruncates() {
        // 90 seconds = 1m30s → truncates to 1m → "0h 01m"
        #expect(DurationFormatting.hoursMinutes(seconds: 90) == "0h 01m")
    }

    @Test("Large value — 10h 30m → '10h 30m'")
    func largeValue() {
        #expect(DurationFormatting.hoursMinutes(seconds: 37800) == "10h 30m")
    }

    // MARK: - decimalHours overload

    @Test("Decimal 0 hours → '0h 00m'")
    func decimalZero() {
        #expect(DurationFormatting.hoursMinutes(decimalHours: 0) == "0h 00m")
    }

    @Test("Decimal 1.5 hours → '1h 30m'")
    func decimalOnePointFive() {
        #expect(DurationFormatting.hoursMinutes(decimalHours: 1.5) == "1h 30m")
    }

    @Test("Decimal 2.0 hours → '2h 00m'")
    func decimalTwoExact() {
        #expect(DurationFormatting.hoursMinutes(decimalHours: 2.0) == "2h 00m")
    }
}
