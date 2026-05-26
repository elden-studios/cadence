import Foundation

/// Catalog of ISO 4217 currency codes available for selection in the app.
///
/// Backed by `Locale.commonISOCurrencyCodes` so the list stays in sync with the
/// currencies Apple's locale system can format (~150 currencies in current circulation,
/// including SAR, AED, EGP, ILS, CNY, KRW, TRY, RUB, ARS, etc.).
public enum CurrencyCatalog {

    /// All common ISO 4217 currency codes, sorted alphabetically for predictable Picker order.
    public static let allCodes: [String] = Locale.commonISOCurrencyCodes.sorted()

    /// Returns the localized display name for a currency code in the given locale,
    /// or the code itself if no localized name is available.
    ///
    /// - Parameters:
    ///   - code: ISO 4217 currency code (e.g. "USD", "SAR").
    ///   - locale: Locale to localize the display name in. Defaults to `.current`.
    public static func displayName(for code: String, locale: Locale = .current) -> String {
        locale.localizedString(forCurrencyCode: code) ?? code
    }
}
