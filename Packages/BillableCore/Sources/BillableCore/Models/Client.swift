import Foundation
import SwiftData

@Model
public final class Client {
    public var name: String
    public var colorRaw: String   // stores ClientColor.rawValue (Codable enum in CloudKit can be fragile; raw string is safe)

    public var contactName: String?
    public var email: String?
    public var address: String?
    public var notes: String?

    public var isArchived: Bool
    public var createdAt: Date
    public var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \Project.client)
    public var projects: [Project] = []

    public init(
        name: String,
        color: ClientColor = .blue,
        contactName: String? = nil,
        email: String? = nil,
        address: String? = nil,
        notes: String? = nil,
        isArchived: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.name = name
        self.colorRaw = color.rawValue
        self.contactName = contactName
        self.email = email
        self.address = address
        self.notes = notes
        self.isArchived = isArchived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var color: ClientColor {
        get { ClientColor(rawValue: colorRaw) ?? .blue }
        set { colorRaw = newValue.rawValue }
    }

    /// All non-archived projects. UI filter helper.
    public var activeProjects: [Project] {
        projects.filter { !$0.isArchived }
    }
}
