import Testing
import Foundation
@testable import BillableCore

@Suite("SubscriptionManager entitlement")
@MainActor
struct SubscriptionManagerEntitlementTests {

    @Test("Default entitlement is .free")
    func defaultEntitlementIsFree() {
        let manager = SubscriptionManager()
        #expect(manager.entitlement == .free)
    }

    @Test(".free entitlement implies !canRemoveWatermark and !canAccessReports")
    func freeBlocksWatermarkAndReports() {
        let manager = SubscriptionManager()
        manager._setEntitlementForTesting(.free)
        #expect(manager.canRemoveWatermark == false)
        #expect(manager.canAccessReports == false)
    }

    @Test(".pro entitlement implies canRemoveWatermark and canAccessReports")
    func proAllowsWatermarkAndReports() {
        let manager = SubscriptionManager()
        manager._setEntitlementForTesting(.pro)
        #expect(manager.canRemoveWatermark == true)
        #expect(manager.canAccessReports == true)
    }

    @Test(".trial entitlement implies canRemoveWatermark and canAccessReports")
    func trialAllowsWatermarkAndReports() {
        let manager = SubscriptionManager()
        manager._setEntitlementForTesting(.trial(daysRemaining: 5))
        #expect(manager.canRemoveWatermark == true)
        #expect(manager.canAccessReports == true)
    }

    @Test("isPro is true for .pro and .trial, false for .free (back-compat)")
    func isProDerivesFromEntitlement() {
        let manager = SubscriptionManager()

        manager._setEntitlementForTesting(.free)
        #expect(manager.isPro == false)

        manager._setEntitlementForTesting(.trial(daysRemaining: 3))
        #expect(manager.isPro == true)

        manager._setEntitlementForTesting(.pro)
        #expect(manager.isPro == true)
    }

    @Test(".trial daysRemaining is accessible")
    func trialDaysRemainingAccessible() {
        let manager = SubscriptionManager()
        manager._setEntitlementForTesting(.trial(daysRemaining: 7))
        guard case .trial(let days) = manager.entitlement else {
            Issue.record("Expected .trial")
            return
        }
        #expect(days == 7)
    }
}
