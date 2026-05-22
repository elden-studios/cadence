import Foundation
import SwiftUI

/// A constrained palette of accent colors a user can assign to a client.
/// Using a closed enum (rather than free-form Color) keeps invoice PDFs
/// and widget renderings deterministic and CloudKit-friendly.
public enum ClientColor: String, CaseIterable, Codable, Sendable {
    case slate
    case red
    case orange
    case amber
    case green
    case teal
    case blue
    case indigo
    case purple
    case pink

    public var displayName: String {
        switch self {
        case .slate:   "Slate"
        case .red:     "Red"
        case .orange:  "Orange"
        case .amber:   "Amber"
        case .green:   "Green"
        case .teal:    "Teal"
        case .blue:    "Blue"
        case .indigo:  "Indigo"
        case .purple:  "Purple"
        case .pink:    "Pink"
        }
    }

    /// sRGB hex string (no alpha), used in invoice PDFs and exports.
    public var hex: String {
        switch self {
        case .slate:   "#64748B"
        case .red:     "#EF4444"
        case .orange:  "#F97316"
        case .amber:   "#F59E0B"
        case .green:   "#10B981"
        case .teal:    "#14B8A6"
        case .blue:    "#3B82F6"
        case .indigo:  "#6366F1"
        case .purple:  "#A855F7"
        case .pink:    "#EC4899"
        }
    }

    public var swiftUIColor: Color {
        switch self {
        case .slate:   Color(red: 0.392, green: 0.455, blue: 0.545)
        case .red:     Color(red: 0.937, green: 0.267, blue: 0.267)
        case .orange:  Color(red: 0.976, green: 0.451, blue: 0.086)
        case .amber:   Color(red: 0.961, green: 0.620, blue: 0.043)
        case .green:   Color(red: 0.063, green: 0.725, blue: 0.506)
        case .teal:    Color(red: 0.078, green: 0.722, blue: 0.651)
        case .blue:    Color(red: 0.231, green: 0.510, blue: 0.965)
        case .indigo:  Color(red: 0.388, green: 0.400, blue: 0.945)
        case .purple:  Color(red: 0.659, green: 0.333, blue: 0.969)
        case .pink:    Color(red: 0.925, green: 0.282, blue: 0.600)
        }
    }
}
