import Foundation
import Testing
import SwiftData
@testable import BillableCore

@Suite("ModelContainer wiring")
@MainActor
struct ModelContainerTests {
    @Test("In-memory container can be created with the full schema")
    func canBuildInMemoryContainer() throws {
        let container = try BillableModelContainer.inMemory()
        let context = ModelContext(container)
        let client = Client(name: "Test")
        context.insert(client)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Client>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.name == "Test")
    }

    @Test("Cascading delete: removing a Client removes its Projects and TimeEntries")
    func cascadingDelete() throws {
        let container = try BillableModelContainer.inMemory()
        let context = ModelContext(container)

        let client = Client(name: "Cascade")
        let project = Project(name: "P", hourlyRate: 100, client: client)
        let entry = TimeEntry(
            startedAt: .now,
            endedAt: Date.now.addingTimeInterval(3600),
            project: project
        )
        context.insert(client)
        context.insert(project)
        context.insert(entry)
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<Project>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<TimeEntry>()) == 1)

        context.delete(client)
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<Client>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Project>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<TimeEntry>()) == 0)
    }

    @Test("SampleData seeds load without error")
    func sampleDataLoads() throws {
        let container = try BillableModelContainer.inMemory()
        let context = ModelContext(container)
        SampleData.seedDemo(in: context)

        let clients = try context.fetch(FetchDescriptor<Client>())
        let projects = try context.fetch(FetchDescriptor<Project>())
        let entries = try context.fetch(FetchDescriptor<TimeEntry>())
        let profiles = try context.fetch(FetchDescriptor<BusinessProfile>())

        #expect(profiles.count == 1)
        #expect(clients.count == 2)
        #expect(projects.count == 4)
        #expect(entries.count >= 2)
    }
}
