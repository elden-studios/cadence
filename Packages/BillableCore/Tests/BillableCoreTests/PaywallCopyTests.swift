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
        // "about N months free" matches PricingDisplay.savingsBadge wording so both
        // the sub-line and the savings pill read consistently on the same paywall screen.
        #expect(line == "Just $3.33/mo · about 2 months free")
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

@Suite("PaywallCopy CTA title")
struct PaywallCopyCTATests {
    @Test("lifetime selection names the price and never offers a trial")
    func lifetime() {
        #expect(PaywallCopy.ctaTitle(for: .lifetime, lifetimePrice: "$99.99",
                                     eligibleForIntroOffer: true) == "Buy Lifetime — $99.99")
        // Eligibility is irrelevant for a one-time buy.
        #expect(PaywallCopy.ctaTitle(for: .lifetime, lifetimePrice: "£94.99",
                                     eligibleForIntroOffer: false) == "Buy Lifetime — £94.99")
    }

    @Test("intro-eligible subscription offers the free trial")
    func subTrial() {
        #expect(PaywallCopy.ctaTitle(for: .yearly, lifetimePrice: nil,
                                     eligibleForIntroOffer: true) == "Start 7-day free trial")
        #expect(PaywallCopy.ctaTitle(for: .monthly, lifetimePrice: nil,
                                     eligibleForIntroOffer: true) == "Start 7-day free trial")
    }

    @Test("ineligible subscription shows Subscribe")
    func subNoTrial() {
        #expect(PaywallCopy.ctaTitle(for: .yearly, lifetimePrice: nil,
                                     eligibleForIntroOffer: false) == "Subscribe")
    }

    @Test("nil lifetime price yields 'Buy Lifetime' without a trailing dash-space")
    func lifetimeNilPrice() {
        // When the Lifetime product hasn't loaded yet, the CTA must NOT produce
        // "Buy Lifetime — " (a visible trailing dash-space). It degrades gracefully
        // to "Buy Lifetime" so the button text is always coherent.
        let cta = PaywallCopy.ctaTitle(for: .lifetime, lifetimePrice: nil,
                                        eligibleForIntroOffer: true)
        #expect(cta == "Buy Lifetime")
        #expect(!cta.hasSuffix("— "), "CTA must not end with a bare dash-space")
    }
}
