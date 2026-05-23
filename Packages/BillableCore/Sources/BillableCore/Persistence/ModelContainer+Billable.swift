import Foundation
import SwiftData

/// Factory functions for the Billable SwiftData stack.
///
/// Three flavors:
/// - `inMemory()` — ephemeral, used by tests and SwiftUI previews
/// - `local()` — on-disk only, no CloudKit (useful in TestFlight builds with iCloud disabled)
/// - `cloudKit()` — on-disk + private CloudKit mirror (production default)
///
/// The container is built from two configurations so that local-only bookkeeping
/// models (e.g., `ScheduledNotification`) never sync to iCloud while user data
/// (clients, invoices, time entries) does.
public enum BillableModelContainer {
    /// Single source of truth for mirrored model types.
    private static let mirroredTypes: [any PersistentModel.Type] = [
        BusinessProfile.self,
        Client.self,
        Project.self,
        TimeEntry.self,
        Invoice.self,
        RecurrenceTemplate.self,
        ReminderConfig.self,
    ]

    /// Single source of truth for local-only model types.
    private static let localOnlyTypes: [any PersistentModel.Type] = [
        ScheduledNotification.self,
    ]

    /// Mirrored models (sync to CloudKit private DB when enabled).
    public static let mirroredSchema = Schema(mirroredTypes)

    /// Local-only models (never sync to CloudKit).
    public static let localOnlySchema = Schema(localOnlyTypes)

    /// Convenience for SwiftData previews and tests that want a single schema.
    /// Derived from the type lists so adding a model only requires one edit.
    public static let schema = Schema(mirroredTypes + localOnlyTypes)

    public static func inMemory() throws -> ModelContainer {
        let mirrored = ModelConfiguration(
            "mirrored",
            schema: mirroredSchema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let local = ModelConfiguration(
            "local",
            schema: localOnlySchema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema,
            configurations: mirrored, local
        )
    }

    public static func local(url: URL? = nil) throws -> ModelContainer {
        let mirroredURL = url ?? defaultStoreURL()
        let localURL = localStoreURL(siblingTo: mirroredURL)
        let mirrored = ModelConfiguration(
            "mirrored",
            schema: mirroredSchema,
            url: mirroredURL,
            cloudKitDatabase: .none
        )
        let local = ModelConfiguration(
            "local",
            schema: localOnlySchema,
            url: localURL,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema,
            configurations: mirrored, local
        )
    }

    /// Build a container backed by a store inside an App Group container so
    /// both the main app and the widget extension can read/write it.
    /// When `cloudKitContainerID` is supplied, the mirrored store is mirrored
    /// to that CloudKit private database. Falls back to local-only on
    /// entitlement failures so dev runs without a provisioning profile stay
    /// unblocked. The local-only store (e.g., ScheduledNotification) is
    /// always device-local.
    public static func appGroup(
        _ groupID: String,
        cloudKitContainerID: String? = nil
    ) throws -> ModelContainer {
        guard let groupURL = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            return try local()
        }
        let mirroredStoreURL = groupURL.appendingPathComponent("Billable.store")
        let localConfigURL = groupURL.appendingPathComponent("Billable-local.store")

        let mirroredConfig: ModelConfiguration
        if let cloudKitContainerID {
            mirroredConfig = ModelConfiguration(
                "mirrored",
                schema: mirroredSchema,
                url: mirroredStoreURL,
                cloudKitDatabase: .private(cloudKitContainerID)
            )
        } else {
            mirroredConfig = ModelConfiguration(
                "mirrored",
                schema: mirroredSchema,
                url: mirroredStoreURL,
                cloudKitDatabase: .none
            )
        }

        let localConfig = ModelConfiguration(
            "local",
            schema: localOnlySchema,
            url: localConfigURL,
            cloudKitDatabase: .none
        )

        do {
            return try ModelContainer(
                for: schema,
                configurations: mirroredConfig, localConfig
            )
        } catch {
            // CloudKit setup commonly fails when there's no provisioning team
            // (simulator dev, CI). Drop the mirrored config to local-only so
            // the app still launches; the user will see no sync but won't lose data.
            let fallback = ModelConfiguration(
                "mirrored-fallback",
                schema: mirroredSchema,
                url: mirroredStoreURL,
                cloudKitDatabase: .none
            )
            return try ModelContainer(
                for: schema,
                configurations: fallback, localConfig
            )
        }
    }

    /// The CloudKit container ID used by the production app. Kept here so the
    /// main app target and the widget extension stay in sync.
    public static let defaultCloudKitContainerID = "iCloud.com.eldenstudios.billable"

    public static func cloudKit(containerIdentifier: String) throws -> ModelContainer {
        let mirrored = ModelConfiguration(
            "mirrored",
            schema: mirroredSchema,
            cloudKitDatabase: .private(containerIdentifier)
        )
        let local = ModelConfiguration(
            "local",
            schema: localOnlySchema,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema,
            configurations: mirrored, local
        )
    }

    private static func defaultStoreURL() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("Billable.store")
    }

    private static func localStoreURL(siblingTo mirroredURL: URL) -> URL {
        mirroredURL
            .deletingLastPathComponent()
            .appendingPathComponent("Billable-local.store")
    }
}
