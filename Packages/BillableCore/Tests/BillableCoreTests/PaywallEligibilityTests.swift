import Testing
import Foundation
@testable import BillableCore

@Suite("Paywall trial eligibility")
@MainActor
struct PaywallEligibilityTests {

    @Test("Eligible is false when products haven't loaded")
    func eligibleFalseWithoutProducts() {
        let manager = SubscriptionManager()
        #expect(manager.eligibleForIntroOffer == false)
    }

    // MARK: - OR-logic truth table for computeIntroEligibility
    //
    // refreshProducts() computes `eligibleForIntroOffer` as `mEligible || yEligible`,
    // delegating to the pure helper below. We test the helper directly because
    // `Product` has no public initializer, so the StoreKit-level eligibility flags
    // can't be synthesized in a SwiftPM test target. The F/F case is covered by
    // `eligibleFalseWithoutProducts` above (default state, before any products load).

    @Test("Monthly eligible, yearly not → eligible")
    func monthlyOnlyEligible() {
        #expect(SubscriptionManager.computeIntroEligibility(monthly: true, yearly: false) == true)
    }

    @Test("Yearly eligible, monthly not → eligible")
    func yearlyOnlyEligible() {
        #expect(SubscriptionManager.computeIntroEligibility(monthly: false, yearly: true) == true)
    }

    @Test("Both eligible → eligible")
    func bothEligible() {
        #expect(SubscriptionManager.computeIntroEligibility(monthly: true, yearly: true) == true)
    }
}
