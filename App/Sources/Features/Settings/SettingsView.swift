import SwiftUI
import SwiftData
import StoreKit
import BillableCore

struct SettingsView: View {
    @Query private var profiles: [BusinessProfile]
    @State private var showingPaywall = false
    @State private var showingManageSubscriptions = false
    private var subscriptions = SubscriptionManager.shared

    var body: some View {
        NavigationStack {
            Form {
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
                            HStack {
                                Label("Upgrade to Pro", systemImage: "sparkles")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button {
                        Task { _ = await subscriptions.restore() }
                    } label: {
                        Label("Restore purchases", systemImage: "arrow.clockwise")
                            .foregroundStyle(.tint)
                    }
                }

                Section {
                    NavigationLink {
                        PaymentRemindersView()
                    } label: {
                        Label("Payment reminders", systemImage: "bell.badge")
                    }
                } header: { Text("Reminders") }

                Section("About") {
                    LabeledContent("Version", value: appVersionString)
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showingPaywall) {
                PaywallView(trigger: .settings)
            }
            .manageSubscriptionsSheet(isPresented: $showingManageSubscriptions)
        }
    }

    private var appVersionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0.0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }
}
