import XCTest
@testable import BillableCore

final class BusinessProfileCompletenessTests: XCTestCase {
    func test_emptyProfile_missesNameAddressBankLogo() {
        let p = BusinessProfile(name: "")
        XCTAssertEqual(Set(p.missingProfileFields), [.name, .address, .bankDetails, .logo])
    }
    func test_nameAndAddressOnly_stillMissesBankAndLogo() {
        let p = BusinessProfile(name: "Acme")
        p.address = "1 Main St"
        XCTAssertEqual(Set(p.missingProfileFields), [.bankDetails, .logo])
    }
    func test_fullyComplete_missesNothing() {
        let p = BusinessProfile(name: "Acme")
        p.address = "1 Main St"
        p.bankIBAN = "DE00 0000"      // any one bank field → hasBankDetails true
        p.logoData = Data([0x1])
        XCTAssertTrue(p.missingProfileFields.isEmpty)
    }
    func test_taxIsNeitherRequiredNorCounted() {
        // Tax rate + tax ID set, but bank missing → only bank is reported.
        // Proves tax never appears in missingProfileFields (not required, not counted).
        let p = BusinessProfile(name: "Acme", taxRate: 0.08)
        p.address = "1 Main St"
        p.taxIDNumber = "GB123456789"
        p.logoData = Data([0x1])
        XCTAssertEqual(p.missingProfileFields, [.bankDetails])
    }
    func test_whitespaceOnlyName_treatedAsMissing() {
        let p = BusinessProfile(name: "   ")
        p.address = "1 Main St"
        p.bankIBAN = "DE00"
        p.logoData = Data([0x1])
        XCTAssertEqual(p.missingProfileFields, [.name])
    }
    func test_isProfileEnriched_unchanged_nameAddressOnly() {
        let p = BusinessProfile(name: "Acme")
        p.address = "1 Main St"
        XCTAssertTrue(p.isProfileEnriched)
    }
}
