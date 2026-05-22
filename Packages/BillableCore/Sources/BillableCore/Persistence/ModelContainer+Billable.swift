import Foundation
import SwiftData

/// Factory functions for the Billable SwiftData stack.
///
/// Three flavors:
/// - `inMemory()` — ephemeral, used by tests and SwiftUI previews
/// - `local()` — on-disk only, no CloudKit (useful in TestFlight builds with iCloud disabled)
/// - `cloudKit()` — on-disk + private CloudKit mirror (production default)
public enum BillableModelContainer {
    /// All `@Model` types the container must know about.
    public static let schema = Schema([
        BusinessProfile.self,
        Client.self,
        Project.self,
        TimeEntry.self,
        Invoice.self,
    ])

    public static func inMemory() throws -> ModelContainer {
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: config)
    }

    public static func local(url: URL? = nil) throws -> ModelContainer {
        let config = ModelConfiguration(
            schema: schema,
            url: url ?? defaultStoreURL(),
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: config)
    }

    /// Build a container backed by a store inside an App Group container so
    /// both the main app and the widget extension can read/write it.
    /// When `cloudKitContainerID` is supplied, the store is mirrored to that
    /// CloudKit private database. Falls back to local-only on entitlement
    /// failures so dev runs without a provisioning profile stay unblocked.
    public static func appGroup(
        _ groupID: String,
        cloudKitContainerID: String? = nil
    ) throws -> ModelContainer {
        guard let groupURL = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            return try local()
        }
        let storeURL = groupURL.appendingPathComponent("Billable.store")

        if let cloudKitContainerID {
            let config = ModelConfiguration(
                schema: schema,
                url: storeURL,
                cloudKitDatabase: .private(cloudKitContainerID)
            )
            do {
                return try ModelContainer(for: schema, configurations: config)
            } catch {
                // CloudKit setup commonly fails when there's no provisioning
                // team configured (simulator dev, CI). Drop to local-only so
                // the app still launches; the user will see no sync but won't
                // lose data.
                return try local(url: storeURL)
            }
        }
        return try local(url: storeURL)
    }

    /// The CloudKit container ID used by the production app. Kept here so the
    /// main app target and the widget extension stay in sync.
    public static let defaultCloudKitContainerID = "iCloud.com.eldenstudios.billable"

    public static func cloudKit(containerIdentifier: String) throws -> ModelContainer {
        let config = ModelConfiguration(
            schema: schema,
            cloudKitDatabase: .private(containerIdentifier)
        )
        return try ModelContainer(for: schema, configurations: config)
    }

    private static func defaultStoreURL() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("Billable.store")
    }
}
