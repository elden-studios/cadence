import Testing
import Foundation
import SwiftData
@testable import BillableCore

@MainActor
@Suite("BusinessProfileStore.canonical")
struct BusinessProfileStoreTests {
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: BillableModelContainer.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @Test("returns nil when empty")
    func empty() throws {
        let ctx = try makeContext()
        #expect(BusinessProfileStore.canonical(in: ctx) == nil)
    }

    @Test("returns the oldest by createdAt")
    func oldestWins() throws {
        let ctx = try makeContext()
        let older = BusinessProfile(name: "Older", createdAt: Date(timeIntervalSince1970: 100))
        let newer = BusinessProfile(name: "Newer", createdAt: Date(timeIntervalSince1970: 200))
        ctx.insert(newer); ctx.insert(older)
        try ctx.save()
        #expect(BusinessProfileStore.canonical(in: ctx)?.name == "Older")
    }
}
