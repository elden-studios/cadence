import Foundation
import Testing
@testable import BillableCore

@Suite("PaywallCopy monthly-equivalent sub-line")
struct PaywallCopyMonthlyEquivalentTests {
    // A fixed en_US locale so the assertion is deterministic regardless of host.
    private let enUS = Locale(identifier: "en_US")

    @Test("yearly hero sub-line leads with per-month price and months-free")
    func subLine() throws {
        let line = try #require(PaywallCopy.monthlyEquivalentLine(
            yearlyPrice: 39.99, monthlyPrice: 3.99, locale: enUS))
        #expect(line == "Just $3.33/mo · 2 months free")
    }

    @Test("nil monthly price falls back to per-month only, no months-free clause")
    func noMonthly() throws {
        let line = try #require(PaywallCopy.monthlyEquivalentLine(
            yearlyPrice: 39.99, monthlyPrice: nil, locale: enUS))
        #expect(line == "Just $3.33/mo")
    }

    @Test("nil yearly price yields nil (products not loaded → hide the line)")
    func noYearly() {
        #expect(PaywallCopy.monthlyEquivalentLine(
            yearlyPrice: nil, monthlyPrice: 3.99, locale: enUS) == nil)
    }
}
