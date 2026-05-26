import Testing
import StoreKit
@testable import BillableCore

/// Unit tests for the `SubscriptionManager.LoadState` enum added in v1.1.2.
///
/// `SubscriptionManager` is `@MainActor` and talks to StoreKit, so the pure
/// enum tests don't need live StoreKit. The three integration-style tests at the
/// bottom inject mock fetchers via `_fetchProducts` / `_timeoutSeconds`.
///
/// Because `SubscriptionManager.shared` is the global singleton, each
/// integration test resets those hooks in a `defer` block to avoid state leakage.
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

    // MARK: - Integration tests (mock fetcher injection)

    /// Exercises the `products.isEmpty → .failed` branch (line ~98 of
    /// SubscriptionManager.swift). The `.storekit` config produces non-empty
    /// results in normal operation; this guards the fallback for when StoreKit
    /// returns [] in production (e.g. misconfigured product IDs).
    @Test @MainActor
    func test_emptyProductsArray_setsLoadStateToFailed() async {
        let manager = SubscriptionManager.shared
        let originalFetcher = manager._fetchProducts
        let originalTimeout = manager._timeoutSeconds
        let originalObserver = manager._onLoadStateChange
        defer {
            manager._fetchProducts = originalFetcher
            manager._timeoutSeconds = originalTimeout
            manager._onLoadStateChange = originalObserver
            manager._resetLoadStateForTesting()
        }

        // Inject a fetcher that returns an empty array immediately.
        manager._fetchProducts = { _ in [] }
        manager._timeoutSeconds = 5

        await manager.refreshProducts()

        if case .failed(let msg) = manager.loadState {
            #expect(!msg.isEmpty)
        } else {
            Issue.record("Expected loadState to be .failed when products array is empty, got \(manager.loadState)")
        }
    }

    /// After a load failure, calling `reloadProducts()` must transition back
    /// through `.loading` before reaching the final state. A user tapping Retry
    /// should see the spinner re-appear.
    @Test @MainActor
    func test_reloadProducts_transitionsFromFailedThroughLoading() async {
        let manager = SubscriptionManager.shared
        let originalFetcher = manager._fetchProducts
        let originalTimeout = manager._timeoutSeconds
        let originalObserver = manager._onLoadStateChange
        defer {
            manager._fetchProducts = originalFetcher
            manager._timeoutSeconds = originalTimeout
            manager._onLoadStateChange = originalObserver
            manager._resetLoadStateForTesting()
        }

        // First: drive manager to .failed with a throwing fetcher.
        manager._fetchProducts = { _ in throw URLError(.notConnectedToInternet) }
        manager._timeoutSeconds = 1
        await manager.refreshProducts()
        guard case .failed = manager.loadState else {
            Issue.record("Pre-condition failed: expected .failed state")
            return
        }

        // Now: use `_onLoadStateChange` to record every state transition.
        // refreshProducts sets loadState = .loading as its first action, so
        // the observer will fire with .loading before the fetcher is called.
        var observedStates: [SubscriptionManager.LoadState] = []
        manager._onLoadStateChange = { state in
            observedStates.append(state)
        }
        manager._fetchProducts = { _ in [] }   // empty → ends in .failed
        manager._timeoutSeconds = 5

        await manager.reloadProducts()

        #expect(observedStates.contains(.loading),
                "loadState must pass through .loading during reloadProducts(); got \(observedStates)")
        // Final state should also be .failed (empty products).
        if case .failed = manager.loadState {
            // expected
        } else {
            Issue.record("Expected final loadState to be .failed, got \(manager.loadState)")
        }
    }

    /// Injects a fetcher that sleeps longer than the configured timeout.
    /// Asserts that `loadState` becomes `.failed` within a reasonable wall-clock
    /// budget. Uses a short `_timeoutSeconds = 0.5` to keep the test fast.
    @Test @MainActor
    func test_slowFetch_timesOutWithFailedState() async throws {
        let manager = SubscriptionManager.shared
        let originalFetcher = manager._fetchProducts
        let originalTimeout = manager._timeoutSeconds
        let originalObserver = manager._onLoadStateChange
        defer {
            manager._fetchProducts = originalFetcher
            manager._timeoutSeconds = originalTimeout
            manager._onLoadStateChange = originalObserver
            manager._resetLoadStateForTesting()
        }

        // Injected fetcher sleeps longer than the timeout so the timer wins.
        manager._fetchProducts = { _ in
            try await Task.sleep(for: .seconds(10))
            return []
        }
        manager._timeoutSeconds = 0.5   // 500 ms timeout — fast for tests

        let start = ContinuousClock.now
        await manager.refreshProducts()
        let elapsed = ContinuousClock.now - start

        // Should have resolved within ~2 seconds (0.5 s timeout + generous grace).
        #expect(elapsed < .seconds(2), "refreshProducts took too long: \(elapsed)")

        if case .failed = manager.loadState {
            // expected — timeout causes CancellationError → .failed branch
        } else {
            Issue.record("Expected loadState .failed after timeout, got \(manager.loadState)")
        }
    }
}
