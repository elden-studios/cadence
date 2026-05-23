import SwiftUI
import SwiftData
import UserNotifications
import BillableCore

struct RecurringRulesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RecurrenceTemplate.nextFireDate) private var templates: [RecurrenceTemplate]

    var body: some View {
        Group {
            if templates.isEmpty {
                ContentUnavailableView(
                    "No recurring schedules",
                    systemImage: "arrow.triangle.2.circlepath",
                    description: Text("Set up monthly billing for a retainer client from the New Invoice screen.")
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
        scheduler.cancel(id: template.id)
        modelContext.delete(template)
        try? modelContext.save()
    }

    private func togglePause(_ template: RecurrenceTemplate) {
        template.isActive.toggle()
        try? modelContext.save()
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
