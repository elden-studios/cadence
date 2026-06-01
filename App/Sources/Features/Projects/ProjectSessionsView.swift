import SwiftUI
import SwiftData
import BillableCore

extension Sequence where Element == TimeEntry {
    /// Groups time entries by calendar month, preserving the input order (newest-first).
    /// Shared by `ProjectDetailView`'s 5-session preview and the full `ProjectSessionsView`.
    func groupedByMonth() -> [(String, [TimeEntry])] {
        let calendar = Calendar.current
        var order: [DateComponents] = []
        var buckets: [DateComponents: [TimeEntry]] = [:]
        for entry in self {
            let comps = calendar.dateComponents([.year, .month], from: entry.startedAt)
            if buckets[comps] == nil { order.append(comps); buckets[comps] = [] }
            buckets[comps]?.append(entry)
        }
        return order.map { comps in
            let label = (calendar.date(from: comps) ?? .now).formatted(.dateTime.month(.wide).year())
            return (label, buckets[comps] ?? [])
        }
    }
}

/// One session row — weekday/day · duration · (amount when billable). Shared between
/// the detail preview and the full sessions screen.
struct SessionRow: View {
    let entry: TimeEntry
    let asOf: Date
    let currencyCode: String
    let isBillable: Bool

    var body: some View {
        HStack {
            Text(entry.startedAt.formatted(.dateTime.weekday().day().hour().minute()))
            Spacer()
            Text(DurationFormatting.hoursMinutes(seconds: entry.duration(asOf: asOf)))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if isBillable {
                Text(entry.amount(asOf: asOf).formatted(.currency(code: currencyCode)))
                    .monospacedDigit()
                    .foregroundStyle(.green)
                    .frame(minWidth: 70, alignment: .trailing)
            }
        }
        .font(.subheadline)
        .padding(.vertical, 4)
    }

}

/// Pushed full-history list of a project's sessions, month-grouped, newest-first.
/// Reached from the detail screen's "See all N sessions ›" row. Renders `asOf: .now`
/// without per-second ticking — this is a history screen, and the running entry
/// (if any) is normally the top row on the detail screen the user came from.
struct ProjectSessionsView: View {
    @Bindable var project: Project
    /// Supplied by the parent (`ProjectDetailView` already resolves it) so this
    /// pushed history screen doesn't run its own redundant `@Query<BusinessProfile>`
    /// (Gemini PR #13 finding 4).
    let currencyCode: String

    @Environment(\.modelContext) private var modelContext
    @State private var editingEntry: TimeEntry?

    var body: some View {
        let grouped = project.entries.sorted { $0.startedAt > $1.startedAt }.groupedByMonth()
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if grouped.isEmpty {
                    Text("No time tracked yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(grouped, id: \.0) { month, entries in
                        Text(month)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(entries) { entry in
                            sessionRow(entry)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .scrollIndicators(.hidden)
        .navigationTitle("Sessions")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingEntry) { entry in
            ManualEntrySheet(editing: entry)
        }
    }

    @ViewBuilder
    private func sessionRow(_ entry: TimeEntry) -> some View {
        if entry.isRunning {
            TimelineView(TimerTickSchedule(running: true)) { ctx in
                SessionRow(entry: entry, asOf: ctx.date,
                           currencyCode: currencyCode, isBillable: project.isBillable)
            }
        } else {
            SessionRow(entry: entry, asOf: entry.endedAt ?? entry.startedAt,
                       currencyCode: currencyCode, isBillable: project.isBillable)
                .contentShape(Rectangle())
                .onTapGesture { editingEntry = entry }
                .contextMenu {
                    Button(role: .destructive) { delete(entry) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
        }
    }

    private func delete(_ entry: TimeEntry) {
        modelContext.delete(entry)
        modelContext.saveOrLog("delete session")
    }
}
