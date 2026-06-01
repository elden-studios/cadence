import Testing
import Foundation
@testable import BillableCore

@Suite("BusinessProfile entity-type & enrichment")
struct BusinessProfileEntityTests {
    @Test("entityType defaults to freelancer (freelancer-first product)")
    func defaultEntityType() {
        let p = BusinessProfile(name: "Acme")
        #expect(p.entityType == .freelancer)
        #expect(p.entityTypeRaw == "freelancer")
    }

    @Test("entityType accessor mutates the raw string")
    func accessorSetsRaw() {
        let p = BusinessProfile(name: "Jane")
        p.entityType = .freelancer
        #expect(p.entityTypeRaw == "freelancer")
        p.entityTypeRaw = "bogus"
        #expect(p.entityType == .organization) // unknown raw coalesces to .organization
    }

    @Test("latches default nil and are settable")
    func latches() {
        let p = BusinessProfile(name: "X")
        #expect(p.onboardingCompletedAt == nil)
        #expect(p.firstSetupCompletedAt == nil)
        let t = Date(timeIntervalSince1970: 1000)
        p.onboardingCompletedAt = t
        #expect(p.onboardingCompletedAt == t)
    }

    @Test("isProfileEnriched requires a non-blank name and address (bank details optional)")
    func enriched() {
        let p = BusinessProfile(name: "X")
        #expect(p.isProfileEnriched == false)   // name present, no address
        p.address = "1 Main St"
        #expect(p.isProfileEnriched == true)    // name + address — bank NOT required
        p.bankIBAN = "GB00 0000"
        #expect(p.isProfileEnriched == true)    // still true with a bank
        p.address = "   "
        #expect(p.isProfileEnriched == false)   // blank/whitespace address → not enriched
        p.address = "1 Main St"
        p.name = "   "
        #expect(p.isProfileEnriched == false)   // blank/whitespace name → not enriched
    }
}
