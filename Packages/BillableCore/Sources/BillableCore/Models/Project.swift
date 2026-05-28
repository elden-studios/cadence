import Foundation
import SwiftData

@Model
public final class Project {
    public var name: String
    public var hourlyRate: Decimal
    public var isBillable: Bool
    public var isArchived: Bool
    public var notes: String?
    public var createdAt: Date
    public var updatedAt: Date

    /// When the user tapped "Complete project"; `nil` while the project is active.
    /// Cleared on restore. Display-only — `isArchived` remains the source of truth
    /// for whether a project is active.
    public var completedAt: Date?

    public var client: Client?

    @Relationship(deleteRule: .cascade, inverse: \TimeEntry.project)
    public var entries: [TimeEntry] = []

    public init(
        name: String,
        hourlyRate: Decimal,
        isBillable: Bool = true,
        isArchived: Bool = false,
        notes: String? = nil,
        client: Client? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        completedAt: Date? = nil
    ) {
        self.name = name
        self.hourlyRate = hourlyRate
        self.isBillable = isBillable
        self.isArchived = isArchived
        self.notes = notes
        self.client = client
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
    }
}
