import BillableCore
import UIKit  // for UITextContentType

/// App-layer presentation strings for `EntityType`. The enum itself carries only
/// *policy* (`showsTaxByDefault`); the human-facing labels live here so the
/// onboarding identity screen and the Business Profile editor render IDENTICAL
/// copy from one source (DRY). English literals by product decision — Cadence
/// ships English-only and localization is out of scope (spec §11). Copy is still
/// written translation-shaped (single noun phrase, no glued fragments) as
/// zero-cost future insurance.
extension EntityType {
    /// Visible label for the issuer's name field, e.g. the ALL-CAPS field label
    /// in onboarding and the `TextField` title in the editor.
    var issuerNameLabel: String {
        switch self {
        case .freelancer:   return "Your name"
        case .organization: return "Business name"
        }
    }

    /// Prompt/placeholder for the issuer name field (matches `issuerNameLabel`'s register).
    var issuerNamePrompt: String {
        switch self {
        case .freelancer:   return "Jane Doe"
        case .organization: return "Acme Corp"
        }
    }

    /// Default tax-ID label shown beside the registration-number field.
    /// US-natural defaults; the editor's free-text field lets the user override.
    var taxIDLabel: String {
        switch self {
        case .freelancer:   return "Tax ID"
        case .organization: return "Business tax ID (EIN)"
        }
    }

    /// `UITextContentType` hint so the keyboard/AutoFill offers the right value
    /// (a person's name vs. an organization name).
    var nameContentType: UITextContentType {
        switch self {
        case .freelancer:   return .name
        case .organization: return .organizationName
        }
    }

    /// One-line, how-you-bill framing for the selectable entity cards (spec §5).
    var cardTitle: String {
        switch self {
        case .freelancer:   return "Freelancer"
        case .organization: return "Organization"
        }
    }

    var cardSubtitle: String {
        switch self {
        case .freelancer:   return "Just me — I bill for my own time."
        case .organization: return "A team — we bill under one company name."
        }
    }

    var cardSystemImage: String {
        switch self {
        case .freelancer:   return "person.fill"
        case .organization: return "building.2.fill"
        }
    }
}
