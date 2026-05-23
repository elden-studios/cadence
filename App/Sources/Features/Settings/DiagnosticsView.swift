import SwiftUI
import SwiftData
import UserNotifications
import BillableCore

/// Internal QA screen for verifying the Scheduler subsystem state.
/// Gated by `--debug-scheduler` in `SettingsView`. Not shown in production builds
/// unless the launch flag is present.
struct DiagnosticsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ScheduledNotification.fireAt) private var rows: [ScheduledNotification]

    @State private var iosPending: [UNNotificationRequest] = []
    @State private var lastResync: Date?
    @State private var resyncInProgress: Bool = false

    var body: some View {
        List {
            Section {
                LabeledContent("SwiftData rows", value: "\(rows.count)")
                LabeledContent("iOS pending", value: "\(iosPending.count)")
                LabeledContent("Δ (rows − iOS)", value: "\(rows.count - iosPending.count)")
                if let lastResync {
                    LabeledContent("Last resync", value: lastResync.formatted(date: .abbreviated, time: .shortened))
                }
                Button {
                    Task { await runResync() }
                } label: {
                    HStack {
                        if resyncInProgress { ProgressView() }
                        Text("Run resyncOnLaunch")
                    }
                }
                .disabled(resyncInProgress)
            } header: { Text("Scheduler") }

            Section {
                if rows.isEmpty {
                    Text("No pending notifications").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.id.uuidString).font(.caption.monospaced())
                            HStack(spacing: 4) {
                                Text(row.payloadType)
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.tint.opacity(0.18), in: .capsule)
                                    .foregroundStyle(.tint)
                                Text(row.fireAt.formatted(.dateTime.month().day().hour().minute()))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: { Text("Pending (SwiftData)") }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
    }

    private func refresh() async {
        iosPending = await UNUserNotificationCenter.current().pendingNotificationRequests()
    }

    @MainActor
    private func runResync() async {
        resyncInProgress = true
        defer { resyncInProgress = false }
        let scheduler = Scheduler(
            center: UNUserNotificationCenter.current(),
            modelContext: modelContext
        )
        _ = await scheduler.resyncOnLaunch()
        lastResync = Date()
        await refresh()
    }
}
