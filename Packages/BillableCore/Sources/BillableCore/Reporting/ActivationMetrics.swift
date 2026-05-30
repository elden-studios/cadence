import Foundation
import SwiftData

/// On-device-only Tier-1 activation readout (spec §14). PRIVACY-PURE: every value is
/// re-derived from authoritative SwiftData on demand — nothing is persisted and nothing
/// is transmitted (no analytics, no `privacy.md` change). Surfaced only behind a `#if DEBUG`
/// diagnostics row gated by `--debug-scheduler` (see `ActivationMetricsView`).
///
/// Mirrors the shipping `BadgeCount` shape: a `@MainActor` enum with a single static
/// `compute(in:)` that reads the store and returns a value type.
@MainActor
public enum ActivationMetrics {

    /// Which first-run path produced the user's earliest timed entry — the headline
    /// "did the hybrid bet pay off" signal (spec §14).
    public enum FirstTimerKind: String, Sendable {
        case none        // no TimeEntry yet
        case quickStart  // earliest entry's project has no client ("General")
        case checklist   // earliest entry's project is client-linked
    }

    /// Immutable snapshot. `TimeInterval?` deltas are seconds from `onboardingCompletedAt`
    /// to the earliest relevant `createdAt`; nil when either endpoint is missing.
    public struct Snapshot: Sendable, Equatable {
        public var freelancerCount: Int
        public var organizationCount: Int
        public var activationReached: Bool
        public var timeToFirstTimer: TimeInterval?
        public var timeToFirstProject: TimeInterval?
        public var timeToFirstInvoice: TimeInterval?
        public var firstTimerKind: FirstTimerKind
    }

    public static func compute(in context: ModelContext) -> Snapshot {
        let profiles = (try? context.fetch(FetchDescriptor<BusinessProfile>())) ?? []
        let freelancers = profiles.filter { $0.entityType == .freelancer }.count
        let organizations = profiles.filter { $0.entityType == .organization }.count

        // Canonical onboarding instant = earliest non-nil stamp across profiles.
        let onboardedAt = profiles.compactMap(\.onboardingCompletedAt).min()

        let entries = (try? context.fetch(FetchDescriptor<TimeEntry>())) ?? []
        let earliestEntry = entries.min { $0.createdAt < $1.createdAt }

        // Earliest ACTIVE project (matches the §7 "non-archived project" activation notion).
        let activeProjects = (try? context.fetch(
            FetchDescriptor<Project>(predicate: #Predicate { !$0.isArchived })
        )) ?? []
        let earliestProjectAt = activeProjects.map(\.createdAt).min()

        let invoices = (try? context.fetch(FetchDescriptor<Invoice>())) ?? []
        let earliestInvoiceAt = invoices.map(\.createdAt).min()

        func delta(_ end: Date?) -> TimeInterval? {
            guard let start = onboardedAt, let end else { return nil }
            return end.timeIntervalSince(start)
        }

        let kind: FirstTimerKind
        if let earliestEntry {
            kind = earliestEntry.project?.client == nil ? .quickStart : .checklist
        } else {
            kind = .none
        }

        return Snapshot(
            freelancerCount: freelancers,
            organizationCount: organizations,
            activationReached: earliestEntry != nil,
            timeToFirstTimer: delta(earliestEntry?.createdAt),
            timeToFirstProject: delta(earliestProjectAt),
            timeToFirstInvoice: delta(earliestInvoiceAt),
            firstTimerKind: kind
        )
    }
}
