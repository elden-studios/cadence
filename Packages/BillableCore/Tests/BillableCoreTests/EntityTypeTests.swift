import Testing
@testable import BillableCore

@Suite("EntityType")
struct EntityTypeTests {
    @Test("raw values round-trip")
    func rawRoundTrip() {
        #expect(EntityType(rawValue: "freelancer") == .freelancer)
        #expect(EntityType(rawValue: "organization") == .organization)
        #expect(EntityType(rawValue: "bogus") == nil)
        #expect(EntityType.freelancer.rawValue == "freelancer")
    }

    @Test("exactly two cases")
    func allCases() {
        #expect(EntityType.allCases == [.freelancer, .organization])
    }

    @Test("tax-by-default policy")
    func taxPolicy() {
        #expect(EntityType.freelancer.showsTaxByDefault == false)
        #expect(EntityType.organization.showsTaxByDefault == true)
    }
}
