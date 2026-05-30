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
}
