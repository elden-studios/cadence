import Foundation
import Testing
@testable import BillableCore

@Suite("BusinessProfile tax ID")
struct BusinessProfileTaxIDTests {

    @Test("Default BusinessProfile() has empty taxIDLabel and taxIDNumber")
    func defaultsAreEmpty() {
        let profile = BusinessProfile()
        #expect(profile.taxIDLabel == "")
        #expect(profile.taxIDNumber == "")
    }

    @Test("Default BusinessProfile.hasTaxID is false")
    func defaultHasTaxIDFalse() {
        let profile = BusinessProfile()
        #expect(profile.hasTaxID == false)
    }

    @Test("Setting taxIDNumber flips hasTaxID to true")
    func numberFlipsHelper() {
        let profile = BusinessProfile(taxIDNumber: "GB123456789")
        #expect(profile.hasTaxID == true)
    }

    @Test("Setting only taxIDLabel does not flip hasTaxID — label without number is meaningless")
    func labelAloneIsFalse() {
        let profile = BusinessProfile(taxIDLabel: "VAT")
        #expect(profile.hasTaxID == false)
    }

    @Test("Whitespace-only taxIDNumber does not flip hasTaxID")
    func whitespaceOnlyIsFalse() {
        let profile = BusinessProfile(taxIDNumber: "   ")
        #expect(profile.hasTaxID == false)
    }

    @Test("Both fields set: hasTaxID true, both values preserved")
    func bothSet() {
        let profile = BusinessProfile(taxIDLabel: "VAT", taxIDNumber: "GB123456789")
        #expect(profile.hasTaxID == true)
        #expect(profile.taxIDLabel == "VAT")
        #expect(profile.taxIDNumber == "GB123456789")
    }
}
