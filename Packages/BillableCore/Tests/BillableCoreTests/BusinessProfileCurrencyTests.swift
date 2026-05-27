import Foundation
import Testing
import SwiftData
@testable import BillableCore

@Suite("BusinessProfile currency persistence (drives CurrencyPickerView)")
@MainActor
struct BusinessProfileCurrencyTests {

    @Test("currency defaults to current locale's identifier when constructed via defaultForCurrentLocale()")
    func defaultForCurrentLocale_usesLocale() {
        let profile = BusinessProfile.defaultForCurrentLocale()
        let expected = Locale.current.currency?.identifier ?? "USD"
        #expect(profile.currencyCode == expected)
    }

    @Test("explicit override wins over Locale.current")
    func defaultForCurrentLocale_overrideWins() {
        let profile = BusinessProfile.defaultForCurrentLocale(currencyCode: "JPY")
        #expect(profile.currencyCode == "JPY")
    }

    @Test("assigning currencyCode updates the value (no validation, no normalization)")
    func currencyCode_isAssignable() {
        let profile = BusinessProfile.defaultForCurrentLocale()
        profile.currencyCode = "EUR"
        #expect(profile.currencyCode == "EUR")
    }
}
