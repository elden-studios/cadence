import Testing
@testable import BillableCore

/// Unit tests for the `SubscriptionManager.LoadState` enum added in v1.1.2.
///
/// `SubscriptionManager` is `@MainActor` and talks to StoreKit, so we test
/// only the pure value-type behaviour of `LoadState` here — no live StoreKit
/// calls required.
struct SubscriptionManagerLoadStateTests {

    // MARK: - LoadState Equatable

    @Test func idleStateIsEquatable() {
        let a = SubscriptionManager.LoadState.idle
        let b = SubscriptionManager.LoadState.idle
        #expect(a == b)
    }

    @Test func loadingStateIsEquatable() {
        let a = SubscriptionManager.LoadState.loading
        let b = SubscriptionManager.LoadState.loading
        #expect(a == b)
    }

    @Test func readyStateIsEquatable() {
        let a = SubscriptionManager.LoadState.ready
        let b = SubscriptionManager.LoadState.ready
        #expect(a == b)
    }

    @Test func failedStateWithSameMessageIsEquatable() {
        let a = SubscriptionManager.LoadState.failed("Network error")
        let b = SubscriptionManager.LoadState.failed("Network error")
        #expect(a == b)
    }

    @Test func failedStateWithDifferentMessagesIsNotEqual() {
        let a = SubscriptionManager.LoadState.failed("Network error")
        let b = SubscriptionManager.LoadState.failed("Timeout")
        #expect(a != b)
    }

    @Test func differentStatesAreNotEqual() {
        #expect(SubscriptionManager.LoadState.idle != .loading)
        #expect(SubscriptionManager.LoadState.loading != .ready)
        #expect(SubscriptionManager.LoadState.ready != .failed("x"))
        #expect(SubscriptionManager.LoadState.idle != .failed("x"))
    }

    // MARK: - Failed state carries non-empty message

    @Test func failedStateMessageIsNonEmpty() {
        let message = "Pricing unavailable. Pull to retry."
        let state = SubscriptionManager.LoadState.failed(message)
        if case .failed(let msg) = state {
            #expect(!msg.isEmpty)
            #expect(msg == message)
        } else {
            Issue.record("Expected .failed state")
        }
    }

    @Test func failedStateIsDistinctFromReady() {
        let failed = SubscriptionManager.LoadState.failed("error")
        #expect(failed != .ready)
    }
}
