import SwiftUI
import SwiftData
import UserNotifications
import BillableCore

/// Tab-bar shell. Today is the home; Clients/Invoices/Reports/Settings are siblings.
struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(NotificationRouter.self) private var router
    @State private var showingReportsPaywall = false
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
            // UI-test hook: force-show the onboarding screen so tagline tests
            // can assert on it regardless of existing simulator state.
            if CommandLine.arguments.contains("--ui-test-show-onboarding") {
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

                ClientsView()
                    .tabItem { Label("Clients", systemImage: "person.2") }
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
            .safeAreaInset(edge: .bottom, spacing: 0) {
                FloatingTimerBar()
            }
            .sheet(isPresented: $showingReportsPaywall) {
                PaywallView(trigger: .reports)
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
            ReportsLockedView { showingReportsPaywall = true }
        }
    }
}

/// Shown to free users when they tap the Reports tab — the visual sells the
/// upgrade rather than just blocking the tab.
private struct ReportsLockedView: View {
    let onUpgrade: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Spacer()
                Image(systemName: "lock.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                Text("Reports are part of Pro")
                    .font(.title2.weight(.semibold))
                Text("Hours by client, billable vs. non-billable, 8-week earnings trend, plus CSV export for your accountant.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button(action: onUpgrade) {
                    Label("Upgrade to Pro", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 32)
                Spacer()
            }
            .navigationTitle("Reports")
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
