import Foundation
import SwiftData

/// Deterministic access to the singleton `BusinessProfile`. SwiftData `@Query` sites can't
/// call this (they're macros) — they must add `sort: \.createdAt`; this is for non-view code
/// and for reconciliation. "Oldest by createdAt" is the canonical survivor; ties are broken by
/// a stable id string so every device agrees.
@MainActor
public enum BusinessProfileStore {
    /// All profiles, oldest-first, with a stable tie-break for equal `createdAt`.
    public static func allSorted(in context: ModelContext) -> [BusinessProfile] {
        let all = (try? context.fetch(FetchDescriptor<BusinessProfile>())) ?? []
        return all.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return String(describing: lhs.persistentModelID) < String(describing: rhs.persistentModelID)
        }
    }

    /// The canonical (oldest) profile, or nil if none exist.
    public static func canonical(in context: ModelContext) -> BusinessProfile? {
        allSorted(in: context).first
    }

    /// Converge duplicate singletons (multi-device CloudKit). Survivor = oldest `createdAt`
    /// (stable tie-break); user fields taken from the latest-`updatedAt` record; `nextInvoiceNumber`
    /// = max() (never regress → no invoice-number collisions); one-way latches = earliest non-nil
    /// (fill, never clear). Idempotent. `BusinessProfile` has no inbound relationship, so deleting
    /// extras orphans nothing. Call from launch + scenePhase==.active (see Plan 2).
    public static func reconcile(in context: ModelContext) {
        let all = allSorted(in: context)
        guard all.count > 1 else { return }

        let survivor = all[0]
        let source = all.max { $0.updatedAt < $1.updatedAt } ?? survivor

        if source !== survivor { copyUserFields(from: source, to: survivor) }

        survivor.nextInvoiceNumber = all.map(\.nextInvoiceNumber).max() ?? survivor.nextInvoiceNumber
        survivor.onboardingCompletedAt = earliest(all.compactMap(\.onboardingCompletedAt))
        survivor.firstSetupCompletedAt = earliest(all.compactMap(\.firstSetupCompletedAt))

        for extra in all where extra !== survivor { context.delete(extra) }
        survivor.updatedAt = .now
        context.saveOrLog("reconcile business profiles")
    }

    /// The SINGLE writer of `firstSetupCompletedAt`. Idempotent + one-way: stamps the canonical
    /// profile the first time a Client AND a client-linked, non-archived Project coexist. A
    /// clientless "General" project does NOT count — the quick-start path that created one has
    /// been removed, but the exclusion is retained for any legacy/upgraded installs that already
    /// have a clientless project. Call from the same launch + scenePhase seam as `reconcile`.
    public static func stampFirstSetupIfReached(in context: ModelContext) {
        guard let profile = canonical(in: context), profile.firstSetupCompletedAt == nil else { return }
        guard ((try? context.fetchCount(FetchDescriptor<Client>())) ?? 0) > 0 else { return }
        var linked = FetchDescriptor<Project>(predicate: #Predicate { !$0.isArchived && $0.client != nil })
        linked.fetchLimit = 1
        guard ((try? context.fetchCount(linked)) ?? 0) > 0 else { return }
        profile.firstSetupCompletedAt = .now
        context.saveOrLog("stamp first setup")
    }

    private static func earliest(_ dates: [Date]) -> Date? { dates.min() }

    /// Copies every user-entered field. NOTE: keep in sync with `BusinessProfile`'s stored
    /// user fields — `BusinessProfileMergeCompletenessTests` (later task) fails if a property is
    /// added without a line here.
    private static func copyUserFields(from src: BusinessProfile, to dst: BusinessProfile) {
        dst.name = src.name
        dst.entityTypeRaw = src.entityTypeRaw
        dst.address = src.address
        dst.email = src.email
        dst.phone = src.phone
        dst.logoData = src.logoData
        dst.paymentTerms = src.paymentTerms
        dst.defaultDueAfterDays = src.defaultDueAfterDays
        dst.invoiceNumberPrefix = src.invoiceNumberPrefix
        dst.taxLabel = src.taxLabel
        dst.taxRate = src.taxRate
        dst.currencyCode = src.currencyCode
        dst.bankBeneficiaryName = src.bankBeneficiaryName
        dst.bankName = src.bankName
        dst.bankLocation = src.bankLocation
        dst.bankIBAN = src.bankIBAN
        dst.bankSWIFT = src.bankSWIFT
        dst.taxIDLabel = src.taxIDLabel
        dst.taxIDNumber = src.taxIDNumber
        dst.invoiceEmailSubjectTemplate = src.invoiceEmailSubjectTemplate
        dst.invoiceEmailBodyTemplate = src.invoiceEmailBodyTemplate
    }
}
