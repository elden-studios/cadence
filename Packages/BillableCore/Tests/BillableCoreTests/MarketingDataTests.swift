import Foundation
import SwiftData
import Testing
@testable import BillableCore

/// Lock in invariants that App Store screenshot mode depends on. Without
/// these, A7's "Last invoice: N days ago" subtitle silently disappears from
/// the demo because the seeded paid invoice doesn't satisfy ClientsView's
/// `$0.sentAt != nil` @Query predicate.
@Suite("MarketingData seed")
@MainActor
struct MarketingDataTests {

    @Test("Seeded paid invoice has sentAt + paidAt populated (A7 subtitle prerequisite)")
    func seedPaidInvoiceHasTimestamps() throws {
        let container = try BillableModelContainer.inMemory()
        let context = ModelContext(container)
        MarketingData.seed(in: context)

        // Find the paid invoice (INV-0010).
        let invoices = try context.fetch(FetchDescriptor<Invoice>())
        let paidInvoices = invoices.filter { $0.status == .paid }
        #expect(paidInvoices.count >= 1, "Seed should produce at least one paid invoice")

        let paid = try #require(paidInvoices.first)
        // The A7 ClientsView @Query predicate is `$0.sentAt != nil`. If this
        // assertion fails, the 'Last invoice: N days ago' subtitle won't
        // render for any seeded client in screenshot mode.
        #expect(paid.sentAt != nil, "Paid seed invoice must have sentAt set (A7 query predicate)")
        #expect(paid.paidAt != nil, "Paid seed invoice should have paidAt set")
    }

    @Test("Seeded paid invoice's sentAt is in the past + before paidAt (chronology)")
    func seedPaidInvoiceTimestampsAreChronological() throws {
        let container = try BillableModelContainer.inMemory()
        let context = ModelContext(container)
        let referenceDate = Date(timeIntervalSinceReferenceDate: 760_000_000)
        MarketingData.seed(in: context, referenceDate: referenceDate)

        let invoices = try context.fetch(FetchDescriptor<Invoice>())
        let paid = try #require(invoices.first { $0.status == .paid })
        let sentAt = try #require(paid.sentAt)
        let paidAt = try #require(paid.paidAt)
        #expect(sentAt <= paidAt, "Paid invoice's sentAt should be at or before paidAt")
        #expect(sentAt <= referenceDate, "Paid invoice's sentAt should be at or before reference date")
        #expect(paidAt <= referenceDate, "Paid invoice's paidAt should be at or before reference date")
    }

    @Test("Seed produces at least one client whose paid invoice satisfies the A7 lastInvoice query")
    func seedSatisfiesClientsViewA7Query() throws {
        let container = try BillableModelContainer.inMemory()
        let context = ModelContext(container)
        MarketingData.seed(in: context)

        // Mirror ClientsView's @Query predicate.
        var descriptor = FetchDescriptor<Invoice>(predicate: #Predicate<Invoice> { $0.sentAt != nil })
        descriptor.sortBy = [SortDescriptor(\.sentAt, order: .reverse)]
        let visibleInvoices = try context.fetch(descriptor)
        #expect(!visibleInvoices.isEmpty, "ClientsView's @Query must surface at least one seeded invoice")

        // And that invoice should belong to a non-archived active client (so
        // the A7 subtitle actually renders in the active section).
        let invoice = try #require(visibleInvoices.first)
        let client = try #require(invoice.client)
        #expect(!client.isArchived, "Seeded paid invoice's client must be active for A7 subtitle to render")
    }
}
