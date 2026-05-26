import Foundation
import Testing
import SwiftData
@testable import BillableCore

@Suite("ModelContext.saveOrLog helper")
@MainActor
struct ModelContextSaveOrLogTests {
    @Test("saveOrLog persists inserted models (happy path)")
    func saveOrLogPersistsInserts() throws {
        let container = try BillableModelContainer.inMemory()
        let context = ModelContext(container)

        let client = Client(name: "SaveOrLog")
        context.insert(client)

        // Drop-in for `try? context.save()` — should persist without throwing.
        context.saveOrLog("test save")

        let fetched = try context.fetch(FetchDescriptor<Client>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.name == "SaveOrLog")
    }

    @Test("saveOrLog is non-throwing and callable with no args (signature contract)")
    func saveOrLogSignatureContract() throws {
        let container = try BillableModelContainer.inMemory()
        let context = ModelContext(container)

        // Both call forms compile without try and return Void.
        // This locks the drop-in ergonomics so future refactors don't
        // accidentally make the helper throw.
        context.saveOrLog()
        context.saveOrLog("with context string")

        // No assertion needed — the test passes if it compiles + runs.
        // Reading the count back proves nothing crashed on an empty save.
        let count = try context.fetchCount(FetchDescriptor<Client>())
        #expect(count == 0)
    }
}
