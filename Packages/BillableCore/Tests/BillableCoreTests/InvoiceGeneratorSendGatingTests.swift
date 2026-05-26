import Foundation
import Testing
@testable import BillableCore

@Suite("Invoice send gating")
struct InvoiceGeneratorSendGatingTests {
    @Test("canSendInvoice returns false when business name is empty")
    func canSendInvoice_returnsFalse_whenBusinessNameIsEmpty() {
        let profile = BusinessProfile(name: "")
        #expect(BusinessProfile.canSendInvoice(profile: profile) == false,
                "Send should be blocked when business name is empty")
    }

    @Test("canSendInvoice returns true when business name is set")
    func canSendInvoice_returnsTrue_whenBusinessNameIsSet() {
        let profile = BusinessProfile(name: "Elden Studios")
        #expect(BusinessProfile.canSendInvoice(profile: profile) == true,
                "Send should be enabled when business name is set")
    }

    @Test("canSendInvoice returns false when profile is nil")
    func canSendInvoice_returnsFalse_whenProfileIsNil() {
        #expect(BusinessProfile.canSendInvoice(profile: nil) == false,
                "Send should be blocked when there's no business profile at all")
    }

    @Test("canSendInvoice returns false when business name is whitespace only")
    func canSendInvoice_returnsFalse_whenBusinessNameIsWhitespaceOnly() {
        let profile = BusinessProfile(name: "   ")
        #expect(BusinessProfile.canSendInvoice(profile: profile) == false,
                "Send should be blocked when business name is only whitespace")
    }
}
