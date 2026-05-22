import SwiftUI
import SwiftData
import BillableCore

/// Tab-bar shell. Today is the home; Clients/Invoices/Reports/Settings are siblings.
struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var showingReportsPaywall = false
    @State private var needsOnboarding: Bool = false
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
            needsOnboarding = OnboardingFlags.shouldShow(in: modelContext)
        }
    }

    @ViewBuilder
    private var mainShell: some View {
        if CommandLine.arguments.contains("--show-timeline") {
            NavigationStack { TimelineScreen() }
        } else {
            TabView {
                TodayView()
                    .tabItem { Label("Today", systemImage: "timer") }

                ClientsView()
                    .tabItem { Label("Clients", systemImage: "person.2") }

                InvoicesView()
                    .tabItem { Label("Invoices", systemImage: "doc.text") }

                reportsTab
                    .tabItem { Label("Reports", systemImage: "chart.bar") }

                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
            }
            .sheet(isPresented: $showingReportsPaywall) {
                PaywallView(trigger: .reports)
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
