import SwiftUI
import SwiftData
import BillableCore

/// Groups time entries by calendar month, preserving the input order (newest-first).
/// Shared by `ProjectDetailView`'s 5-session preview and the full `ProjectSessionsView`.
func groupedSessionsByMonth(_ entries: [TimeEntry]) -> [(String, [TimeEntry])] {
    let calendar = Calendar.current
    var order: [DateComponents] = []
    var buckets: [DateComponents: [TimeEntry]] = [:]
    for entry in entries {
        let comps = calendar.dateComponents([.year, .month], from: entry.startedAt)
        if buckets[comps] == nil { order.append(comps); buckets[comps] = [] }
        buckets[comps]?.append(entry)
    }
    return order.map { comps in
        let label = (calendar.date(from: comps) ?? .now).formatted(.dateTime.month(.wide).year())
        return (label, buckets[comps] ?? [])
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
            Text(entry.startedAt.formatted(.dateTime.weekday().day()))
            Spacer()
            Text(hoursLabel(entry.duration(asOf: asOf)))
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

    private func hoursLabel(_ seconds: TimeInterval) -> String {
        let m = Int(seconds / 60)
        return "\(m / 60)h \(String(format: "%02d", m % 60))m"
    }
}

/// Pushed full-history list of a project's sessions, month-grouped, newest-first.
/// Reached from the detail screen's "See all N sessions ›" row. Renders `asOf: .now`
/// without per-second ticking — this is a history screen, and the running entry
/// (if any) is normally the top row on the detail screen the user came from.
struct ProjectSessionsView: View {
    @Bindable var project: Project
    @Query(sort: \BusinessProfile.createdAt, order: .forward) private var profiles: [BusinessProfile]

    private var currencyCode: String {
        profiles.first?.currencyCode ?? Locale.current.currency?.identifier ?? "USD"
    }

    var body: some View {
        let grouped = groupedSessionsByMonth(project.entries.sorted { $0.startedAt > $1.startedAt })
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
                            SessionRow(entry: entry, asOf: .now,
                                       currencyCode: currencyCode, isBillable: project.isBillable)
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
    }
}
