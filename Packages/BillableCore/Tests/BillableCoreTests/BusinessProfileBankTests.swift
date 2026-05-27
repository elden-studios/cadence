import Foundation
import Testing
@testable import BillableCore

@Suite("BusinessProfile bank details")
struct BusinessProfileBankTests {

    @Test("default profile has all five bank fields empty")
    func defaults_areEmpty() {
        let profile = BusinessProfile()
        #expect(profile.bankBeneficiaryName == "")
        #expect(profile.bankName == "")
        #expect(profile.bankLocation == "")
        #expect(profile.bankIBAN == "")
        #expect(profile.bankSWIFT == "")
    }

    @Test("default profile reports hasBankDetails == false")
    func defaults_hasBankDetails_false() {
        #expect(BusinessProfile().hasBankDetails == false)
    }

    @Test("Beneficiary alone flips hasBankDetails to true")
    func beneficiary_flipsTrue() {
        let p = BusinessProfile()
        p.bankBeneficiaryName = "Studio Lina LLC"
        #expect(p.hasBankDetails == true)
    }

    @Test("Bank name alone flips hasBankDetails to true")
    func bankName_flipsTrue() {
        let p = BusinessProfile()
        p.bankName = "Riyad Bank"
        #expect(p.hasBankDetails == true)
    }

    @Test("IBAN alone flips hasBankDetails to true")
    func iban_flipsTrue() {
        let p = BusinessProfile()
        p.bankIBAN = "SA03 8000 0000 6080 1016 7519"
        #expect(p.hasBankDetails == true)
    }

    @Test("SWIFT alone flips hasBankDetails to true")
    func swift_flipsTrue() {
        let p = BusinessProfile()
        p.bankSWIFT = "RIBLSARI"
        #expect(p.hasBankDetails == true)
    }

    @Test("Location alone does NOT flip hasBankDetails (location is not payment info)")
    func location_doesNotFlipTrue() {
        let p = BusinessProfile()
        p.bankLocation = "Riyadh, Saudi Arabia"
        #expect(p.hasBankDetails == false)
    }
}
