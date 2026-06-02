import Foundation

/// Pure, testable display copy for the paywall tier rows. Keeps locale-aware
/// money formatting out of the SwiftUI view so it can be unit-tested without a
/// running app or a live StoreKit session. No hardcoded currency — every figure
/// is formatted via the locale the call site derives from the StoreKit product
/// (`product.priceFormatStyle.locale`), so the app ships correctly in 175 countries.
public enum PaywallCopy {
    /// The Yearly-hero price sub-line, e.g. "Just $3.33/mo · 2 months free".
    ///
    /// - Returns nil when `yearlyPrice` is absent (products not loaded yet) so the
    ///   caller can hide the line rather than flash an incorrect figure.
    /// - Omits the "· N months free" clause when `monthlyPrice` is absent or the
    ///   yearly isn't actually cheaper than 12× monthly (mirrors `savingsPill`'s guard).
    public static func monthlyEquivalentLine(
        yearlyPrice: Decimal?,
        monthlyPrice: Decimal?,
        locale: Locale
    ) -> String? {
        guard let yearlyPrice, yearlyPrice > 0 else { return nil }
        let perMonth = yearlyPrice / 12
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = locale
        guard let perMonthString = formatter.string(from: perMonth as NSDecimalNumber) else {
            return nil
        }
        var line = "Just \(perMonthString)/mo"
        if let monthlyPrice,
           let savings = PricingDisplay.annualSavings(monthlyPrice: monthlyPrice, yearlyPrice: yearlyPrice) {
            line += " · \(savings.monthsFree) months free"
        }
        return line
    }
}
