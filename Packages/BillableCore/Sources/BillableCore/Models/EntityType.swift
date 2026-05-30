import Foundation

/// Whether the user invoices as an individual or under a business.
/// Drives presentation only (labels + default tax-section visibility), never capability.
/// Stored on `BusinessProfile` as a raw `String` (CloudKit-safe; see `Client.colorRaw`).
public enum EntityType: String, Codable, CaseIterable, Sendable {
    case freelancer
    case organization

    /// Presentation *policy* (not strings — those live in the app layer).
    public var showsTaxByDefault: Bool { self == .organization }
}
