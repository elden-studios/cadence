import Foundation

/// Pure, read-only resolver for Today's *single* guidance element. Mirrors
/// `BadgeCount`: it takes booleans the view already computes and returns the one
/// element to show — it NEVER reads SwiftData and NEVER mutates (so it is
/// exhaustively unit-testable). Precedence (spec §7), highest first:
///
///   1. name missing            → `.nameBanner`   (can't send invoices at all)
///   2. onboarded, setup unreached → `.getStarted`
///   3. set up, not enriched, not snoozed → `.enrichment`
///   4. otherwise               → `.none`
///
/// "One element at a time": the resolver returns exactly one case; the view
/// renders that case and nothing else. The first-setup latch is owned by
/// `BusinessProfileStore.stampFirstSetupIfReached` — NOT stamped here.
public enum TodayGuidance: Sendable {

    /// The single guidance element Today should render (or `.none`).
    public enum Element: Sendable, Equatable {
        case nameBanner
        case getStarted
        case enrichment
        case none
    }

    /// - Parameters:
    ///   - hasName: `BusinessProfile.canSendInvoice(profile:)` — a non-blank issuer name exists.
    ///   - hasActiveSetup: `firstSetupCompletedAt != nil` — a client + a client-linked active project have coexisted.
    ///   - isEnriched: `BusinessProfile.isProfileEnriched` — issuer name + address present (bank details optional).
    ///   - enrichmentSnoozed: session-only "Not now" was tapped (no persisted flag; spec §7b).
    public static func resolve(
        hasName: Bool,
        hasActiveSetup: Bool,
        isEnriched: Bool,
        enrichmentSnoozed: Bool
    ) -> Element {
        if !hasName { return .nameBanner }
        if !hasActiveSetup { return .getStarted }
        if !isEnriched && !enrichmentSnoozed { return .enrichment }
        return .none
    }
}
