import SwiftUI
import WidgetKit
import SwiftData
import BillableCore

/// Small home/lock-screen widget showing the running timer's project + elapsed.
/// Idle state shows a "Tap to start" prompt that deep-links into the app.
struct CurrentTimerWidget: Widget {
    let kind = "CurrentTimerWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CurrentTimerProvider()) { entry in
            CurrentTimerWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Current timer")
        .description("Glanceable status of your active timer.")
        .supportedFamilies([
            .systemSmall,
            .accessoryRectangular,
            .accessoryCircular,
            .accessoryInline,
        ])
    }
}

// MARK: - Timeline provider

struct CurrentTimerProvider: TimelineProvider {
    typealias Entry = CurrentTimerEntry

    func placeholder(in context: Context) -> CurrentTimerEntry {
        CurrentTimerEntry.placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (CurrentTimerEntry) -> Void) {
        completion(fetchEntry(now: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CurrentTimerEntry>) -> Void) {
        let entry = fetchEntry(now: .now)
        // Refresh in ~15 min: enough to catch state changes when the user
        // forgets to launch the app, without burning the widget refresh budget.
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: .now) ?? .now.addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func fetchEntry(now: Date) -> CurrentTimerEntry {
        guard let container = try? BillableModelContainer.appGroup("group.com.eldenstudios.billable") else {
            return .placeholder
        }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<TimeEntry>(
            predicate: #Predicate { $0.endedAt == nil }
        )
        guard let entries = try? context.fetch(descriptor), let running = entries.first else {
            return CurrentTimerEntry(date: now, state: .idle)
        }
        let project = running.project
        let client = project?.client
        return CurrentTimerEntry(
            date: now,
            state: .running(
                clientName: client?.name ?? "",
                projectName: project?.name ?? "—",
                colorRaw: client?.colorRaw ?? ClientColor.blue.rawValue,
                startedAt: running.startedAt
            )
        )
    }
}

// MARK: - Entry

struct CurrentTimerEntry: TimelineEntry {
    enum State {
        case running(clientName: String, projectName: String, colorRaw: String, startedAt: Date)
        case idle
    }

    let date: Date
    let state: State

    static let placeholder = CurrentTimerEntry(date: .now, state: .idle)
}

// MARK: - View

struct CurrentTimerWidgetView: View {
    let entry: CurrentTimerEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryInline:
            inlineView
        case .accessoryCircular:
            circularView
        case .accessoryRectangular:
            rectangularView
        default:
            smallView
        }
    }

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch entry.state {
            case .running(let clientName, let projectName, let colorRaw, let startedAt):
                let color = ClientColor(rawValue: colorRaw)?.swiftUIColor ?? .blue
                HStack(spacing: 4) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    Text(clientName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(projectName)
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Text(timerInterval: startedAt...Date.now.addingTimeInterval(60 * 60 * 24),
                     pauseTime: nil, countsDown: false)
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(color)
            case .idle:
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                Text("Tap to start")
                    .font(.subheadline.weight(.semibold))
                Text("a timer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var rectangularView: some View {
        HStack {
            switch entry.state {
            case .running(let clientName, let projectName, _, let startedAt):
                VStack(alignment: .leading, spacing: 2) {
                    Text(clientName).font(.caption2.weight(.semibold)).lineLimit(1)
                    Text(projectName).font(.headline).lineLimit(1)
                }
                Spacer()
                Text(timerInterval: startedAt...Date.now.addingTimeInterval(60 * 60 * 24),
                     pauseTime: nil, countsDown: false)
                    .font(.title3.weight(.semibold).monospacedDigit())
            case .idle:
                Image(systemName: "timer")
                Text("No timer running")
                    .font(.subheadline.weight(.medium))
                Spacer()
            }
        }
    }

    private var circularView: some View {
        ZStack {
            switch entry.state {
            case .running(_, _, _, let startedAt):
                VStack(spacing: 2) {
                    Image(systemName: "timer")
                        .font(.caption2)
                    Text(timerInterval: startedAt...Date.now.addingTimeInterval(60 * 60 * 24),
                         pauseTime: nil, countsDown: false)
                        .font(.caption2.monospacedDigit())
                }
            case .idle:
                Image(systemName: "timer")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var inlineView: some View {
        switch entry.state {
        case .running(_, let projectName, _, let startedAt):
            return Text("⏱ \(projectName) · ") +
                Text(timerInterval: startedAt...Date.now.addingTimeInterval(60 * 60 * 24),
                     pauseTime: nil, countsDown: false)
        case .idle:
            return Text("⏱ No timer running")
        }
    }
}
