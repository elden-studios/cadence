import Foundation

/// Pure, testable display math for the paywall savings badge. Computes the
/// annual saving vs 12x monthly as dollars, "months free", and a percentage —
/// so the badge is never a stale hardcoded string.
public enum PricingDisplay {
    public struct AnnualSavings: Equatable {
        public let dollarsSaved: Decimal
        public let monthsFree: Int
        public let percent: Int
    }

    /// Returns nil when inputs are invalid or the yearly isn't actually cheaper.
    public static func annualSavings(monthlyPrice: Decimal, yearlyPrice: Decimal) -> AnnualSavings? {
        guard monthlyPrice > 0, yearlyPrice > 0 else { return nil }
        let twelveMonths = monthlyPrice * 12
        guard yearlyPrice < twelveMonths else { return nil }
        // Round the saving to a 2-place currency scale. `Decimal` is base-10, but a
        // price sourced from a `Double` literal (or StoreKit) carries binary residue
        // into the subtraction (e.g. 47.88… - 39.99… = 7.8900000…02048); rounding to
        // cents both displays correct money and yields an exact value (7.89).
        var rawDollars = twelveMonths - yearlyPrice
        var dollars = Decimal()
        NSDecimalRound(&dollars, &rawDollars, 2, .bankers)
        let months = Int((NSDecimalNumber(decimal: dollars / monthlyPrice)).doubleValue.rounded())
        let fraction = (NSDecimalNumber(decimal: yearlyPrice / twelveMonths)).doubleValue
        let percent = Int(((1 - fraction) * 100).rounded())
        return AnnualSavings(dollarsSaved: dollars, monthsFree: months, percent: percent)
    }

    /// Badge copy leading with the tangible framing, e.g. "SAVE $7.89 · about 2 months free".
    public static func savingsBadge(_ s: AnnualSavings, currencyCode: String) -> String {
        let dollars = s.dollarsSaved.formatted(.currency(code: currencyCode))
        return "SAVE \(dollars) · about \(s.monthsFree) months free"
    }
}
