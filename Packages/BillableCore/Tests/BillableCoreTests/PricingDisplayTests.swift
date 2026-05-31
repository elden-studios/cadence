import Foundation
import Testing
@testable import BillableCore

@Suite("PricingDisplay savings")
struct PricingDisplayTests {
    @Test("annual vs 12x monthly yields dollar + months-free framing")
    func savings() throws {
        let s = try #require(PricingDisplay.annualSavings(monthlyPrice: 3.99, yearlyPrice: 39.99))
        #expect(s.dollarsSaved == Decimal(string: "7.89"))
        #expect(s.monthsFree == 2)
        #expect(s.percent == 16)
    }

    @Test("guards bad input")
    func guards() {
        #expect(PricingDisplay.annualSavings(monthlyPrice: 0, yearlyPrice: 39.99) == nil)
        #expect(PricingDisplay.annualSavings(monthlyPrice: 3.99, yearlyPrice: 60) == nil)
    }
}
