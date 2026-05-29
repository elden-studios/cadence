import Foundation
import Testing
import SwiftData
@testable import BillableCore

@Suite("Project.completedAt")
@MainActor
struct ProjectCompletedAtTests {
    @Test("new project has nil completedAt")
    func defaultsNil() throws {
        let project = Project(name: "Site", hourlyRate: 100)
        #expect(project.completedAt == nil)
    }

    @Test("completedAt round-trips through the store")
    func persists() throws {
        let container = try BillableModelContainer.inMemory()
        let context = ModelContext(container)
        let project = Project(name: "Site", hourlyRate: 100)
        let stamp = Date(timeIntervalSince1970: 1_779_793_200)
        project.completedAt = stamp
        context.insert(project)
        try context.save()

        let fetched = try #require(try context.fetch(FetchDescriptor<Project>()).first)
        #expect(fetched.completedAt == stamp)
    }
}
