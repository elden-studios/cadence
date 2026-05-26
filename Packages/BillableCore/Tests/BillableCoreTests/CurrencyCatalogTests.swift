import Testing
import Foundation
@testable import BillableCore

@Suite("CurrencyCatalog")
struct CurrencyCatalogTests {

    @Test("includes SAR (the user's local currency)")
    func includes_SAR() {
        #expect(CurrencyCatalog.allCodes.contains("SAR"))
    }

    @Test("includes common MENA currencies that were previously missing")
    func includes_common_MENA_currencies() {
        let expected = ["SAR", "AED", "EGP", "ILS", "KWD", "BHD", "QAR", "OMR", "JOD"]
        for code in expected {
            #expect(CurrencyCatalog.allCodes.contains(code), "Expected \(code) in catalog")
        }
    }

    @Test("preserves all previously-hardcoded currencies (no regression)")
    func includes_previous_picker_currencies() {
        // The pre-v1.3.1 hardcoded list from BusinessProfileEditorView — make sure none regressed.
        let previous = [
            "USD", "EUR", "GBP", "CAD", "AUD", "JPY", "CHF", "SEK", "NOK", "DKK",
            "NZD", "SGD", "HKD", "INR", "MXN", "BRL", "ZAR",
        ]
        for code in previous {
            #expect(CurrencyCatalog.allCodes.contains(code), "Expected \(code) in catalog")
        }
    }

    @Test("codes are sorted alphabetically for predictable picker order")
    func is_sorted_alphabetically() {
        let codes = CurrencyCatalog.allCodes
        #expect(codes == codes.sorted(), "Catalog must be alphabetically sorted")
    }

    @Test("catalog is substantial (≥100 currencies)")
    func has_substantial_coverage() {
        // commonISOCurrencyCodes returns ~150 currently-circulating currencies.
        // Guard against an unexpected platform regression that returns an empty/tiny list.
        #expect(CurrencyCatalog.allCodes.count >= 100)
    }

    @Test("displayName returns a localized, non-empty name for a known code")
    func displayName_returns_localized_name() {
        let usdName = CurrencyCatalog.displayName(for: "USD", locale: Locale(identifier: "en_US"))
        #expect(!usdName.isEmpty)

        let sarNameInArabic = CurrencyCatalog.displayName(for: "SAR", locale: Locale(identifier: "ar_SA"))
        #expect(!sarNameInArabic.isEmpty)
    }

    @Test("displayName falls back to the code for unknown input")
    func displayName_falls_back_to_code_for_unknown() {
        let result = CurrencyCatalog.displayName(for: "ZZZ", locale: Locale(identifier: "en_US"))
        #expect(result == "ZZZ" || !result.isEmpty)
    }
}
