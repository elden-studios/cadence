import SwiftUI
import SwiftData
import UserNotifications
import BillableCore

/// Tab-bar shell. Today is the home; Clients/Invoices/Reports/Settings are siblings.
struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(NotificationRouter.self) private var router
    @State private var needsOnboarding: Bool = false
    @State private var selectedTab: Int = 0
    @State private var invoicesPendingTarget: InvoicesView.NavigationTarget?
    private var subscriptions = SubscriptionManager.shared

    var body: some View {
        Group {
            if needsOnboarding {
                OnboardingView { needsOnboarding = false }
            } else {
                mainShell
            }
        }
        .onAppear {
            // UI-test hooks (checked first, unconditionally, for deterministic
            // gating regardless of seed/launch-arg order):
            //  --ui-test-skip-onboarding force-HIDES onboarding so seeded tests
            //    (e.g. --seed-marketing) land straight in the app even though the
            //    seed run never stamps onboardingCompletedAt.
            //  --ui-test-show-onboarding force-SHOWS it so tagline/onboarding tests
            //    can assert on it regardless of existing simulator state.
            if CommandLine.arguments.contains("--ui-test-skip-onboarding") {
                needsOnboarding = false
            } else if CommandLine.arguments.contains("--ui-test-show-onboarding") {
                needsOnboarding = true
            } else {
                needsOnboarding = OnboardingFlags.shouldShow(in: modelContext)
            }
        }
    }

    @ViewBuilder
    private var mainShell: some View {
        if CommandLine.arguments.contains("--show-timeline") {
            NavigationStack { TimelineScreen() }
        } else {
            TabView(selection: $selectedTab) {
                TodayView()
                    .tabItem { Label("Today", systemImage: "timer") }
                    .tag(0)

                WorkView()
                    .tabItem { Label("Work", systemImage: "square.stack.3d.up") }
                    .tag(1)

                InvoicesView(pendingPushTarget: $invoicesPendingTarget)
                    .tabItem { Label("Invoices", systemImage: "doc.text") }
                    .tag(2)

                reportsTab
                    .tabItem { Label("Reports", systemImage: "chart.bar") }
                    .tag(3)

                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                    .tag(4)
            }
            .onChange(of: router.pendingDestination) { _, newValue in
                guard let destination = newValue else { return }
                switch destination {
                case .invoiceDetail(let invoiceID):
                    selectedTab = 2
                    invoicesPendingTarget = .detail(invoiceID: invoiceID)
                case .invoicePreview(let invoiceID):
                    // InvoicePreviewView cannot be reconstructed from a persisted invoice;
                    // fall back to detail view (matches InvoicePreviewDestinationLoader behaviour).
                    selectedTab = 2
                    invoicesPendingTarget = .detail(invoiceID: invoiceID)
                case .recurringList:
                    // Switch to Invoices tab; no NavigationTarget to push —
                    // the catch-up banner on TodayView owns the recurring-list UX.
                    selectedTab = 2
                }
                router.pendingDestination = nil
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else { return }
                // Profile upkeep + onboarding re-eval on the SAME foreground seam as
                // badge/notification resync. Re-evaluating shouldShow here means a
                // completion synced from another device dismisses onboarding without a
                // relaunch. The --ui-test-show-onboarding force-show is preserved so
                // tagline/onboarding UI tests stay deterministic.
                BusinessProfileMaintenance.run(in: modelContext)
                // Skip the re-eval entirely under either UI-test gating flag so a
                // foreground pass can't override the forced state set in onAppear.
                if !CommandLine.arguments.contains("--ui-test-show-onboarding"),
                   !CommandLine.arguments.contains("--ui-test-skip-onboarding") {
                    needsOnboarding = OnboardingFlags.shouldShow(in: modelContext)
                }
                Task {
                    let scheduler = Scheduler(
                        center: UNUserNotificationCenter.current(),
                        modelContext: modelContext
                    )
                    _ = await scheduler.resyncOnLaunch()
                    let count = BadgeCount.compute(context: modelContext)
                    try? await UNUserNotificationCenter.current().setBadgeCount(count)
                }
            }
        }
    }

    @ViewBuilder
    private var reportsTab: some View {
        if subscriptions.isPro {
            ReportsView()
        } else {
            // Render the contextual paywall directly in the locked tab — no cold
            // lock screen, no bounce to a sheet. The purchase completes in place;
            // SubscriptionManager.shared is @Observable, so on success `isPro`
            // flips and this branch swaps to the real ReportsView automatically.
            PaywallView(trigger: .reports)
        }
    }
}

#Preview {
    RootView()
        .modelContainer(previewContainer)
        .environment(NotificationRouter())
}

@MainActor
private var previewContainer: ModelContainer = {
    do {
        let container = try BillableModelContainer.inMemory()
        SampleData.seedDemo(in: container.mainContext)
        return container
    } catch {
        fatalError("Preview container failed: \(error)")
    }
}()
