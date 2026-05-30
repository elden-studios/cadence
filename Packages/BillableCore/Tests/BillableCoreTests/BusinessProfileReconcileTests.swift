import Testing
import Foundation
import SwiftData
@testable import BillableCore

@MainActor
@Suite("BusinessProfileStore.reconcile")
struct BusinessProfileReconcileTests {
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: BillableModelContainer.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @Test("no-op for zero or one profile (idempotent)")
    func noop() throws {
        let ctx = try makeContext()
        BusinessProfileStore.reconcile(in: ctx)
        let solo = BusinessProfile(name: "Solo")
        ctx.insert(solo); try ctx.save()
        BusinessProfileStore.reconcile(in: ctx)
        #expect((try ctx.fetchCount(FetchDescriptor<BusinessProfile>())) == 1)
    }

    @Test("both-non-empty conflict: newer user fields + max counter survive")
    func conflictKeepsNewerAndMax() throws {
        let ctx = try makeContext()
        let older = BusinessProfile(
            name: "Jane", createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        older.nextInvoiceNumber = 1
        older.entityType = .freelancer
        let newer = BusinessProfile(
            name: "Jane Doe Studio", createdAt: Date(timeIntervalSince1970: 200),
            updatedAt: Date(timeIntervalSince1970: 999)
        )
        newer.nextInvoiceNumber = 12
        newer.entityType = .organization
        ctx.insert(older); ctx.insert(newer); try ctx.save()

        BusinessProfileStore.reconcile(in: ctx)

        let survivors = try ctx.fetch(FetchDescriptor<BusinessProfile>())
        #expect(survivors.count == 1)
        let s = survivors[0]
        #expect(s.name == "Jane Doe Studio")
        #expect(s.entityType == .organization)
        #expect(s.nextInvoiceNumber == 12)
        #expect(s.createdAt == Date(timeIntervalSince1970: 100))
    }

    @Test("latches merge as earliest non-nil; never cleared")
    func latchesEarliestNonNil() throws {
        let ctx = try makeContext()
        let a = BusinessProfile(name: "A", createdAt: Date(timeIntervalSince1970: 100),
                                updatedAt: Date(timeIntervalSince1970: 100))
        a.onboardingCompletedAt = nil
        let b = BusinessProfile(name: "B", createdAt: Date(timeIntervalSince1970: 200),
                                updatedAt: Date(timeIntervalSince1970: 200))
        b.onboardingCompletedAt = Date(timeIntervalSince1970: 250)
        ctx.insert(a); ctx.insert(b); try ctx.save()

        BusinessProfileStore.reconcile(in: ctx)

        let s = try #require(BusinessProfileStore.canonical(in: ctx))
        #expect(s.onboardingCompletedAt == Date(timeIntervalSince1970: 250))
    }

    @Test("running reconcile twice yields the same single survivor (idempotent)")
    func idempotent() throws {
        let ctx = try makeContext()
        ctx.insert(BusinessProfile(name: "A", createdAt: Date(timeIntervalSince1970: 100)))
        ctx.insert(BusinessProfile(name: "B", createdAt: Date(timeIntervalSince1970: 200)))
        try ctx.save()
        BusinessProfileStore.reconcile(in: ctx)
        BusinessProfileStore.reconcile(in: ctx)
        #expect((try ctx.fetchCount(FetchDescriptor<BusinessProfile>())) == 1)
    }
}
