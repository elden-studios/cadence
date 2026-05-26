import Testing
import Foundation
@testable import BillableCore

@Suite("BusinessProfile locale default currency")
struct BusinessProfileLocaleDefaultTests {
    @Test("default currency comes from Locale.current.currency.identifier")
    func defaultCurrencyCodeMatchesLocale() {
        let expected = Locale.current.currency?.identifier ?? "USD"
        let profile = BusinessProfile.defaultForCurrentLocale()
        #expect(profile.currencyCode == expected)
    }

    @Test("explicit currencyCode overrides locale default")
    func explicitCurrencyOverridesLocale() {
        let profile = BusinessProfile.defaultForCurrentLocale(currencyCode: "EUR")
        #expect(profile.currencyCode == "EUR")
    }
}
