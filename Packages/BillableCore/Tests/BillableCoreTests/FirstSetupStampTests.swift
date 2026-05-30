import Testing
import Foundation
import SwiftData
@testable import BillableCore

@MainActor
@Suite("stampFirstSetupIfReached")
struct FirstSetupStampTests {
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: BillableModelContainer.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @Test("does not stamp when no client-linked project exists")
    func noStampWithoutLinkedProject() throws {
        let ctx = try makeContext()
        let p = BusinessProfile(name: "X"); ctx.insert(p)
        ctx.insert(Project(name: "General", hourlyRate: 0, isBillable: true, client: nil))
        try ctx.save()
        BusinessProfileStore.stampFirstSetupIfReached(in: ctx)
        #expect(BusinessProfileStore.canonical(in: ctx)?.firstSetupCompletedAt == nil)
    }

    @Test("stamps when a client + client-linked non-archived project coexist")
    func stampsWhenReached() throws {
        let ctx = try makeContext()
        let p = BusinessProfile(name: "X"); ctx.insert(p)
        let client = Client(name: "Acme", color: .blue)
        ctx.insert(client)
        ctx.insert(Project(name: "Site", hourlyRate: 100, isBillable: true, client: client))
        try ctx.save()
        BusinessProfileStore.stampFirstSetupIfReached(in: ctx)
        #expect(BusinessProfileStore.canonical(in: ctx)?.firstSetupCompletedAt != nil)
    }

    @Test("is a one-way no-op once set")
    func oneWay() throws {
        let ctx = try makeContext()
        let p = BusinessProfile(name: "X")
        p.firstSetupCompletedAt = Date(timeIntervalSince1970: 500)
        ctx.insert(p)
        let client = Client(name: "Acme", color: .blue); ctx.insert(client)
        ctx.insert(Project(name: "Site", hourlyRate: 100, isBillable: true, client: client))
        try ctx.save()
        BusinessProfileStore.stampFirstSetupIfReached(in: ctx)
        #expect(BusinessProfileStore.canonical(in: ctx)?.firstSetupCompletedAt == Date(timeIntervalSince1970: 500))
    }
}
