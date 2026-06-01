import SwiftUI
import SwiftData
import StoreKit
import BillableCore

struct SettingsView: View {
    @Query(sort: \BusinessProfile.createdAt, order: .forward) private var profiles: [BusinessProfile]
    @State private var showingPaywall = false
    @State private var showingManageSubscriptions = false
    @State private var restoreNotice: String?
    @State private var isRestoring = false
    private var subscriptions = SubscriptionManager.shared
    #if DEBUG
    @AppStorage(TimerMotionStyle.storageKey) private var timerMotionRaw = TimerMotionStyle.spring.rawValue
    #endif

    var body: some View {
        NavigationStack {
            Form {
                Section("Preferences") {
                    NavigationLink {
                        CurrencyPickerView()
                    } label: {
                        LabeledContent("Currency") {
                            Text(profiles.first?.currencyCode
                                 ?? Locale.current.currency?.identifier
                                 ?? "USD")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Business profile") {
                    NavigationLink {
                        BusinessProfileEditorView()
                    } label: {
                        if let profile = profiles.first {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(profile.name.isEmpty ? "Unnamed business" : profile.name)
                                Text("\(profile.currencyCode) · Next \(profile.previewNextInvoiceNumber)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                let missing = profile.missingProfileFields
                                if missing.isEmpty {
                                    Label("Complete", systemImage: "checkmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.green)
                                } else {
                                    // Its own view (not a "· "-glued fragment) so VoiceOver
                                    // reads a discrete status, not a run-on line.
                                    Text("Add \(missing.map(\.label).formatted(.list(type: .and, width: .short)))")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Set up your business")
                                Text("Add your name, address, and tax info to start invoicing.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Subscription") {
                    if subscriptions.isPro {
                        HStack {
                            Label("Cadence Pro", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                            Spacer()
                            Text("Active")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(.green.opacity(0.18), in: .capsule)
                                .foregroundStyle(.green)
                        }
                        Button {
                            showingManageSubscriptions = true
                        } label: {
                            Label("Manage subscription", systemImage: "creditcard")
                        }
                    } else {
                        Button {
                            showingPaywall = true
                        } label: {
                            Label("Upgrade to Pro", systemImage: "sparkles")
                        }
                        Button {
                            isRestoring = true
                            Task {
                                defer { isRestoring = false }
                                let restored = await subscriptions.restore()
                                if !restored { restoreNotice = "No active purchases were found for your Apple ID." }
                            }
                        } label: {
                            Label("Restore purchases", systemImage: "arrow.clockwise")
                                .foregroundStyle(.tint)
                        }
                        .disabled(isRestoring)
                        .overlay(alignment: .trailing) {
                            if isRestoring { ProgressView().padding(.trailing, 4) }
                        }
                    }
                }

                Section {
                    NavigationLink {
                        PaymentRemindersView()
                    } label: {
                        Label("Payment reminders", systemImage: "bell.badge")
                    }
                } header: { Text("Reminders") }

                #if DEBUG
                Section {
                    Picker(selection: $timerMotionRaw) {
                        ForEach(TimerMotionStyle.allCases) { style in
                            Text(style.label).tag(style.rawValue)
                        }
                    } label: {
                        Label("Start-timer motion", systemImage: "wand.and.stars")
                    }
                    if let style = TimerMotionStyle(rawValue: timerMotionRaw) {
                        Text(style.blurb)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Timer motion")
                } footer: {
                    Text("Flip the Start ↔ Running animation, then open a project and tap Start to compare. DEBUG builds only.")
                }
                #endif

                if CommandLine.arguments.contains("--debug-scheduler") {
                    Section {
                        NavigationLink {
                            DiagnosticsView()
                        } label: {
                            Label("Diagnostics", systemImage: "stethoscope")
                        }
                        #if DEBUG
                        NavigationLink {
                            ActivationMetricsView()
                        } label: {
                            Label("Activation metrics", systemImage: "chart.bar.xaxis")
                        }
                        #endif
                    } header: { Text("Debug") }
                }

                Section("About") {
                    LabeledContent("Version", value: appVersionString)
                    HStack {
                        Text("Developer")
                        Spacer()
                        Text("Elden Studios Company")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    Link(destination: URL(string: "mailto:bazerbashi@elden-studios.com")!) {
                        HStack {
                            Text("Contact")
                            Spacer()
                            Text("bazerbashi@elden-studios.com")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Image(systemName: "envelope")
                                .foregroundStyle(.tint)
                                .font(.caption)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showingPaywall) {
                PaywallView(trigger: .settings)
            }
            .manageSubscriptionsSheet(isPresented: $showingManageSubscriptions)
            .alert("Restore purchases", isPresented: Binding(
                get: { restoreNotice != nil }, set: { if !$0 { restoreNotice = nil } }
            )) {
                Button("OK", role: .cancel) { restoreNotice = nil }
            } message: {
                Text(restoreNotice ?? "")
            }
        }
    }

    private var appVersionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0.0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }
}
