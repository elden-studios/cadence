import SwiftUI
import SwiftData
import AppIntents
import UserNotifications
import BillableCore

@main
struct BillableApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @MainActor private let notificationRouter = NotificationRouter()
    private let container: ModelContainer

    init() {
        do {
            // Dev / preview convenience: --seed-demo launches with sample data in memory.
            // Production launches go through `.local()` and (eventually) `.cloudKit()`.
            if CommandLine.arguments.contains("--seed-demo") {
                // For --seed-demo we use App Group so widgets see the data too.
                // CloudKit deliberately not enabled for demo runs — keeps the
                // demo data isolated from real iCloud accounts.
                let appGroup = try BillableModelContainer.appGroup("group.com.eldenstudios.billable")
                Self.runOnMainActor {
                    var clientCheck = FetchDescriptor<Client>()
                    clientCheck.fetchLimit = 1
                    if (try? appGroup.mainContext.fetch(clientCheck))?.isEmpty != false {
                        SampleData.seedDemo(in: appGroup.mainContext)
                    }
                }
                self.container = appGroup
            } else if CommandLine.arguments.contains("--seed-marketing") {
                // --seed-marketing: curated USD demo data for App Store screenshots.
                // App Group container (no CloudKit) — never touches user iCloud.
                //
                // UI-test support: `--reset-store` wipes the App Group store
                // files before construction so the seeder (gated on
                // clientCount == 0) actually runs on every launch. Without
                // this, simulators retain prior seed state across runs and
                // tests see stale data. The deletion is scoped to the
                // Billable.store + Billable-local.store files in the group.
                if CommandLine.arguments.contains("--reset-store") {
                    Self.resetAppGroupStore("group.com.eldenstudios.billable")
                }
                let appGroup = try BillableModelContainer.appGroup("group.com.eldenstudios.billable")
                Self.runOnMainActor {
                    var clientCheck = FetchDescriptor<Client>()
                    clientCheck.fetchLimit = 1
                    if (try? appGroup.mainContext.fetch(clientCheck))?.isEmpty != false {
                        MarketingData.seed(in: appGroup.mainContext)
                    }
                }
                self.container = appGroup
            } else {
                // Production: try CloudKit + App Group; gracefully degrades to
                // App-Group-only when CloudKit entitlements aren't active.
                self.container = try BillableModelContainer.appGroup(
                    "group.com.eldenstudios.billable",
                    cloudKitContainerID: BillableModelContainer.defaultCloudKitContainerID
                )
            }
            // App Intents (Siri, Shortcuts, widgets) read from this shared container.
            IntentContainer.shared.setContainer(self.container)
            // Subscriptions: load products + listen for transactions for the rest of the session.
            Self.runOnMainActor { SubscriptionManager.shared.start() }
        } catch {
            // SwiftData container failures here mean the schema can't load —
            // crashing loud is the right response; users would otherwise get
            // a black-box "couldn't open" experience.
            fatalError("Failed to initialize ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(notificationRouter)
                .task { await reconcileLiveActivity() }
                .task { performStartupWiring() }
        }
        .modelContainer(container)
    }

    @MainActor
    private func performStartupWiring() {
        // Repair any stale (cross-day) or legacy active timer session before the UI reads it.
        try? TimerService.reconcileActiveSessionOnLaunch(in: container.mainContext)
        AppDelegate.sharedRouter = notificationRouter
        AppDelegate.sharedModelContext = container.mainContext
        AppDelegate.sharedSchedulerFactory = { [container] in
            Scheduler(
                center: UNUserNotificationCenter.current(),
                modelContext: container.mainContext
            )
        }
        // Invoice state-machine hooks → ReminderService (Task 5.4).
        Invoice.didMarkSentHook = { @MainActor [container = container] invoice in
            let scheduler = Scheduler(
                center: UNUserNotificationCenter.current(),
                modelContext: container.mainContext
            )
            let service = ReminderService(scheduler: scheduler, modelContext: container.mainContext)
            try? await service.scheduleForInvoice(invoice)
        }
        Invoice.didMarkPaidHook = { @MainActor [container = container] invoice in
            let scheduler = Scheduler(
                center: UNUserNotificationCenter.current(),
                modelContext: container.mainContext
            )
            let service = ReminderService(scheduler: scheduler, modelContext: container.mainContext)
            try? await service.cancelForInvoice(invoice)
        }
        // UI test entry point: bypass the AppDelegate and seed a route directly.
        if CommandLine.arguments.contains("--ui-test-route-recurring") {
            notificationRouter.pendingDestination = .recurringList
        }
    }

    @MainActor
    private func reconcileLiveActivity() async {
        await TimerActivityController.shared.reconcileOnLaunch(in: container.mainContext)
    }

    private static func runOnMainActor(_ work: @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { work() }
        } else {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated { work() }
            }
        }
    }

    /// Delete the App Group SwiftData store files so the next container init
    /// starts from an empty schema. UI-test support only — gated on the
    /// `--reset-store` launch flag in init().
    private static func resetAppGroupStore(_ groupID: String) {
        guard let groupURL = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            return
        }
        // SwiftData writes each .store as a directory of files (.sqlite,
        // .sqlite-wal, .sqlite-shm). Walk the group and remove anything
        // whose name matches one of our stores.
        let storeBases = ["Billable.store", "Billable-local.store"]
        let fm = FileManager.default
        do {
            let contents = try fm.contentsOfDirectory(atPath: groupURL.path)
            for name in contents where storeBases.contains(where: { name.hasPrefix($0) }) {
                try? fm.removeItem(at: groupURL.appendingPathComponent(name))
            }
        } catch {
            // Non-fatal: the next launch will simply read whatever's there.
        }
    }
}
