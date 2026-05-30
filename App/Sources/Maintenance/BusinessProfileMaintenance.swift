import Foundation
import SwiftData
import BillableCore

/// App-side call-site wrapper for the Plan-1 `BusinessProfileStore` repairs.
///
/// Spec §8 requires the duplicate-delete to fire ONLY when the duplicate count is
/// stable across two consecutive observations — never mid-CloudKit-sync, when the
/// count could still be converging and a delete might race an inbound record. The
/// shipped `BusinessProfileStore.reconcile` deletes unconditionally, so this wrapper
/// owns the "stable across two checks" decision: it remembers the last observed
/// profile count and only calls `reconcile` when the current count is > 1 AND equals
/// the previous observation. `stampFirstSetupIfReached` is always safe to run
/// (idempotent + one-way), so it runs every pass.
///
/// `@MainActor` and stateless except for one in-memory observation counter, mirroring
/// `TimerService.reconcileActiveSessionOnLaunch`'s wiring. Call from
/// `BillableApp.performStartupWiring()` and `RootView`'s `scenePhase == .active` seam.
@MainActor
enum BusinessProfileMaintenance {
    /// Last observed BusinessProfile count. nil = never observed (first launch).
    /// Process-lifetime memory (not persisted): two foreground passes within a
    /// session are exactly the "two consecutive checks" the guard needs, and a
    /// fresh launch SHOULD re-observe before deleting.
    private static var lastObservedCount: Int?

    /// One maintenance pass. Always stamps first-setup; reconciles duplicates only
    /// when their count is stable across this and the previous pass.
    static func run(in context: ModelContext) {
        // First-setup latch: idempotent + one-way, always safe.
        BusinessProfileStore.stampFirstSetupIfReached(in: context)

        let count = (try? context.fetchCount(FetchDescriptor<BusinessProfile>())) ?? 0
        defer { lastObservedCount = count }

        // Need duplicates AND a prior observation that agrees: stable across two checks.
        guard count > 1, lastObservedCount == count else { return }

        BusinessProfileStore.reconcile(in: context)
    }

    #if DEBUG
    /// Test/preview hook so a fresh-launch observation starts clean.
    static func resetObservationForTesting() { lastObservedCount = nil }
    #endif
}
