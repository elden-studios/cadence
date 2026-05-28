import Foundation
import Testing
@testable import BillableCore

@Suite("Invoice project + scope fields")
struct InvoiceProjectFieldsTests {
    private func make(project: String? = nil, scope: String? = nil) -> Invoice {
        Invoice(
            number: "INV-1", dueAt: Date(timeIntervalSince1970: 1_700_000_000),
            clientNameSnapshot: "Acme",
            issuerNameSnapshot: "Me", issuerAddressSnapshot: "", issuerEmailSnapshot: "",
            paymentTermsSnapshot: "Net 14", taxLabelSnapshot: "Tax", taxRateSnapshot: 0,
            currencyCodeSnapshot: "USD",
            projectNameSnapshot: project, scopeOfWork: scope
        )
    }

    @Test("Project + scope default to nil (client-combined / legacy invoices)")
    func defaultsNil() {
        let inv = make()
        #expect(inv.project == nil)
        #expect(inv.projectNameSnapshot == nil)
        #expect(inv.scopeOfWork == nil)
    }

    @Test("Project name + scope round-trip when set")
    func storesValues() {
        let inv = make(project: "Dashboard MVP", scope: "Build v1 dashboard")
        #expect(inv.projectNameSnapshot == "Dashboard MVP")
        #expect(inv.scopeOfWork == "Build v1 dashboard")
    }
}
