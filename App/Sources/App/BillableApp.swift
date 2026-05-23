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
                    if (try? appGroup.mainContext.fetch(FetchDescriptor<Client>()))?.isEmpty != false {
                        SampleData.seedDemo(in: appGroup.mainContext)
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
        AppDelegate.sharedRouter = notificationRouter
        AppDelegate.sharedModelContext = container.mainContext
        AppDelegate.sharedSchedulerFactory = { [container] in
            Scheduler(
                center: UNUserNotificationCenter.current(),
                modelContext: container.mainContext
            )
        }
        // Invoice state-machine hooks (ReminderService) installed in Task 5.4.
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
}
