import Foundation
import AppIntents
import SwiftData

/// AppEntity wrapper around `Project` so Shortcuts / Siri / Widgets can offer
/// project pickers and pass project references between intents.
///
/// Identifier is the SwiftData persistent identifier's `storeIdentifier`
/// string — opaque but stable across SwiftData restarts for the same store.
public struct ProjectEntity: AppEntity, Identifiable, Hashable, Sendable {
    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Project"
    public static let defaultQuery = ProjectEntityQuery()

    public var id: String
    public var name: String
    public var clientName: String
    public var clientColorRaw: String

    public init(id: String, name: String, clientName: String, clientColorRaw: String) {
        self.id = id
        self.name = name
        self.clientName = clientName
        self.clientColorRaw = clientColorRaw
    }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(clientName)"
        )
    }

    /// Build a ProjectEntity from a SwiftData `Project`.
    @MainActor
    public init?(from project: Project) {
        guard let client = project.client else { return nil }
        self.id = project.persistentModelID.storeIdentifier ?? UUID().uuidString
        self.name = project.name
        self.clientName = client.name
        self.clientColorRaw = client.colorRaw
    }
}

public struct ProjectEntityQuery: EntityQuery, EntityStringQuery {
    public init() {}

    @MainActor
    public func entities(for identifiers: [ProjectEntity.ID]) async throws -> [ProjectEntity] {
        try await projects().filter { identifiers.contains($0.id) }
    }

    @MainActor
    public func suggestedEntities() async throws -> [ProjectEntity] {
        try await projects()
    }

    @MainActor
    public func entities(matching string: String) async throws -> [ProjectEntity] {
        let all = try await projects()
        return all.filter { entity in
            entity.name.localizedCaseInsensitiveContains(string)
                || entity.clientName.localizedCaseInsensitiveContains(string)
        }
    }

    @MainActor
    private func projects() async throws -> [ProjectEntity] {
        guard let container = IntentContainer.shared.container else { return [] }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Project>(
            predicate: #Predicate { !$0.isArchived },
            sortBy: [SortDescriptor(\.name)]
        )
        let projects = try context.fetch(descriptor)
        return projects.compactMap { ProjectEntity(from: $0) }
    }
}
