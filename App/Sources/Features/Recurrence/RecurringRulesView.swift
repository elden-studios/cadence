import SwiftUI
import SwiftData
import UserNotifications
import UIKit
import BillableCore

struct RecurringRulesView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \RecurrenceTemplate.nextFireDate) private var templates: [RecurrenceTemplate]

    @State private var notificationPermissionDenied: Bool = false

    var body: some View {
        Group {
            if notificationPermissionDenied {
                permissionBanner
            }
            if templates.isEmpty {
                ContentUnavailableView(
                    "No recurring schedules",
                    systemImage: "arrow.triangle.2.circlepath",
                    description: Text("To set up recurring billing, open the Invoices tab, tap the + button, then turn on 'Make this recurring'.")
                )
            } else {
                List {
                    ForEach(templates) { template in
                        NavigationLink(value: InvoicesView.NavigationTarget.recurrenceEditor(templateID: template.id)) {
                            row(template)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { delete(template) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            if !template.isEnded() {
                                Button { togglePause(template) } label: {
                                    Label(template.isActive ? "Pause" : "Resume",
                                          systemImage: template.isActive ? "pause" : "play")
                                }
                                .tint(.orange)
                            }
                        }
                    }
                }
            }
        }
        .task(id: scenePhase) {
            await refreshPermissionStatus()
        }
    }

    // MARK: - Permission Banner

    private var permissionBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "bell.slash.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Notifications are off")
                    .font(.subheadline.weight(.semibold))
                Text("Schedules won't fire until you re-enable notifications.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .background(Color.orange.opacity(0.12), in: .rect(cornerRadius: 12))
        .padding(.horizontal)
    }

    @MainActor
    private func refreshPermissionStatus() async {
        let scheduler = Scheduler(
            center: UNUserNotificationCenter.current(),
            modelContext: modelContext
        )
        let status = await scheduler.currentAuthorizationStatus()
        notificationPermissionDenied = (status == .denied)
    }

    // MARK: - Row

    @ViewBuilder
    private func row(_ template: RecurrenceTemplate) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(clientColor(template))
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(template.client?.name ?? "—")
                    .font(.headline)
                Text(cadenceSummary(template))
                    .font(.caption).foregroundStyle(.secondary)
                Text("Next: \(template.nextFireDate.formatted(.dateTime.month().day()))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            statusPill(template)
        }
    }

    private func clientColor(_ template: RecurrenceTemplate) -> Color {
        template.client?.color.swiftUIColor ?? Color.secondary
    }

    private func cadenceSummary(_ template: RecurrenceTemplate) -> String {
        switch template.cadenceValue {
        case .monthly(let d):   return "Monthly · \(d)"
        case .weekly(let w):    return "Weekly · \(w.rawValue.capitalized)"
        case .biweekly(let w):  return "Biweekly · \(w.rawValue.capitalized)"
        }
    }

    private func statusPill(_ template: RecurrenceTemplate) -> some View {
        let (label, color): (String, Color) = {
            if template.isEnded() {
                return ("Ended", .secondary)
            } else if template.isActive {
                return ("Active", .green)
            } else {
                return ("Paused", .orange)
            }
        }()
        return Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.18), in: .capsule)
            .foregroundStyle(color)
    }

    // MARK: - Actions

    private func delete(_ template: RecurrenceTemplate) {
        let scheduler = Scheduler(
            center: UNUserNotificationCenter.current(),
            modelContext: modelContext
        )
        RecurrenceScheduling.cancelAll(for: template, scheduler: scheduler, modelContext: modelContext)
        modelContext.delete(template)
        modelContext.saveOrLog("delete recurrence template")
    }

    private func togglePause(_ template: RecurrenceTemplate) {
        template.isActive.toggle()
        modelContext.saveOrLog("toggle recurrence pause")
        let scheduler = Scheduler(
            center: UNUserNotificationCenter.current(),
            modelContext: modelContext
        )
        if template.isActive {
            Task {
                try? await RecurrenceScheduling.scheduleNext(for: template, scheduler: scheduler)
            }
        } else {
            RecurrenceScheduling.cancelAll(for: template, scheduler: scheduler, modelContext: modelContext)
        }
    }
}
