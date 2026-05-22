import SwiftUI
import WidgetKit
import SwiftData
import AppIntents
import BillableCore

/// Medium home-screen widget showing today's hours + uninvoiced $ + quick-start tiles.
struct TodaySummaryWidget: Widget {
    let kind = "TodaySummaryWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TodaySummaryProvider()) { entry in
            TodaySummaryWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Today")
        .description("Today's hours, uninvoiced amount, and one-tap project start.")
        .supportedFamilies([.systemMedium])
    }
}

// MARK: - Timeline provider

struct TodaySummaryProvider: TimelineProvider {
    typealias Entry = TodaySummaryEntry

    func placeholder(in context: Context) -> TodaySummaryEntry {
        TodaySummaryEntry.placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (TodaySummaryEntry) -> Void) {
        completion(fetchEntry(now: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodaySummaryEntry>) -> Void) {
        let entry = fetchEntry(now: .now)
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: .now) ?? .now.addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func fetchEntry(now: Date) -> TodaySummaryEntry {
        guard let container = try? BillableModelContainer.appGroup("group.com.eldenstudios.billable") else {
            return .placeholder
        }
        let context = ModelContext(container)
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: now)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? now

        let allDescriptor = FetchDescriptor<TimeEntry>()
        let all = (try? context.fetch(allDescriptor)) ?? []

        let todays = all.filter { entry in
            entry.startedAt < dayEnd && (entry.endedAt ?? now) > dayStart
        }
        let todaysSeconds = todays.reduce(into: TimeInterval(0)) { acc, e in
            let start = max(e.startedAt, dayStart)
            let end = min(e.endedAt ?? now, dayEnd)
            acc += max(0, end.timeIntervalSince(start))
        }
        let todaysAmount = todays.reduce(into: Decimal(0)) { acc, e in
            guard let project = e.project, project.isBillable else { return }
            let start = max(e.startedAt, dayStart)
            let end = min(e.endedAt ?? now, dayEnd)
            let hours = Decimal(max(0, end.timeIntervalSince(start)) / 3600)
            acc += hours * project.hourlyRate
        }
        let uninvoiced = all
            .filter { $0.invoiceID == nil }
            .reduce(into: Decimal(0)) { $0 += $1.amount(asOf: now) }

        let recents = recentProjects(from: all)

        let currencyCode = ((try? context.fetch(FetchDescriptor<BusinessProfile>())) ?? [])
            .first?.currencyCode ?? "USD"

        return TodaySummaryEntry(
            date: now,
            todaysHoursLabel: formatHours(todaysSeconds),
            todaysAmount: todaysAmount,
            uninvoicedAmount: uninvoiced,
            currencyCode: currencyCode,
            recents: recents
        )
    }

    private func recentProjects(from entries: [TimeEntry]) -> [RecentTile] {
        let cutoff = Date.now.addingTimeInterval(-30 * 24 * 3600)
        let recent = entries
            .filter { $0.startedAt > cutoff }
            .sorted(by: { $0.startedAt > $1.startedAt })
        var seen = Set<String>()
        var result: [RecentTile] = []
        for entry in recent {
            guard let project = entry.project, !project.isArchived else { continue }
            let id = project.persistentModelID.storeIdentifier ?? UUID().uuidString
            guard seen.insert(id).inserted else { continue }
            guard let client = project.client else { continue }
            result.append(RecentTile(
                projectEntity: ProjectEntity(
                    id: id,
                    name: project.name,
                    clientName: client.name,
                    clientColorRaw: client.colorRaw
                )
            ))
            if result.count == 3 { break }
        }
        return result
    }

    private func formatHours(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int(seconds / 60)
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        return "\(h)h \(String(format: "%02d", m))m"
    }
}

// MARK: - Entry

struct TodaySummaryEntry: TimelineEntry {
    let date: Date
    let todaysHoursLabel: String
    let todaysAmount: Decimal
    let uninvoicedAmount: Decimal
    let currencyCode: String
    let recents: [RecentTile]

    static let placeholder = TodaySummaryEntry(
        date: .now,
        todaysHoursLabel: "0h 00m",
        todaysAmount: 0,
        uninvoicedAmount: 0,
        currencyCode: "USD",
        recents: []
    )
}

struct RecentTile: Hashable {
    let projectEntity: ProjectEntity
}

// MARK: - View

struct TodaySummaryWidgetView: View {
    let entry: TodaySummaryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Today")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(entry.uninvoicedAmount, format: .currency(code: entry.currencyCode))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.primary)
            }

            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("HOURS")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(entry.todaysHoursLabel)
                        .font(.title3.weight(.bold).monospacedDigit())
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("EARNED")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(entry.todaysAmount, format: .currency(code: entry.currencyCode))
                        .font(.title3.weight(.bold).monospacedDigit())
                        .foregroundStyle(.green)
                }
                Spacer()
            }

            if entry.recents.isEmpty {
                Spacer()
                Text("Add a client to start tracking.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                HStack(spacing: 6) {
                    ForEach(entry.recents, id: \.projectEntity.id) { tile in
                        Button(intent: StartTimerIntent(project: tile.projectEntity)) {
                            VStack(alignment: .leading, spacing: 4) {
                                Circle()
                                    .fill(ClientColor(rawValue: tile.projectEntity.clientColorRaw)?.swiftUIColor ?? .blue)
                                    .frame(width: 7, height: 7)
                                Text(tile.projectEntity.name)
                                    .font(.caption2.weight(.semibold))
                                    .lineLimit(1)
                                Text(tile.projectEntity.clientName)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 5)
                            .background(.regularMaterial, in: .rect(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
