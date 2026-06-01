import Testing
import Foundation
import SwiftData
@testable import BillableCore

@MainActor
@Suite("BusinessProfile additive migration")
struct BusinessProfileMigrationTests {
    /// Proves lightweight migration: a real on-disk store created with the CURRENT schema,
    /// closed, then reopened, materializes the new defaulted fields. (An in-memory store can't
    /// exercise store reopen, so this MUST be on disk.)
    @Test("defaulted fields survive a store close/reopen")
    func reopenAppliesDefaults() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("billable-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Billable.store")

        // Write a profile, then fully release the container.
        do {
            let c = try ModelContainer(for: BillableModelContainer.schema,
                                       configurations: ModelConfiguration(url: url))
            let ctx = ModelContext(c)
            ctx.insert(BusinessProfile(name: "Persisted"))
            try ctx.save()
        }

        // Reopen and assert the new defaulted fields materialized.
        let c2 = try ModelContainer(for: BillableModelContainer.schema,
                                    configurations: ModelConfiguration(url: url))
        let ctx2 = ModelContext(c2)
        let p = try #require(try ctx2.fetch(FetchDescriptor<BusinessProfile>()).first)
        #expect(p.name == "Persisted")
        #expect(p.entityType == .freelancer)
        #expect(p.onboardingCompletedAt == nil)
        #expect(p.isProfileEnriched == false)
    }
}
