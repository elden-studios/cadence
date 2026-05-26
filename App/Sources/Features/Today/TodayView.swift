import SwiftUI
import SwiftData
import BillableCore

struct TodayView: View {
    @Environment(\.modelContext) private var modelContext

    @Query private var allClients: [Client]
    @Query private var profiles: [BusinessProfile]

    @State private var showingStartSheet = false
    @State private var showingSwitchSheet = false
    @State private var showingManualEntry = false
    @State private var editingEntry: TimeEntry?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    headerSection
                    CatchUpBanner()
                        .padding(.horizontal)
                        .padding(.top, 4)
                    if showEmptyBusinessBanner {
                        NavigationLink(destination: BusinessProfileEditorView()) {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text("Add your business name to send invoices")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(12)
                            .background(.orange.opacity(0.12), in: .rect(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal)
                    }
                    TodayActiveTimerSection(
                        onStop: stopRunning,
                        onSwitch: { showingSwitchSheet = true }
                    )
                    if !hasRunningTimer {
                        startActions
                    }
                    TodaySummarySection(currencyCode: currencyCode)
                }
                .padding()
            }
            .scrollIndicators(.hidden)
            .navigationDestination(for: PendingMaterializationsLink.self) { _ in
                PendingMaterializationsView()
            }
            .navigationTitle("Today")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        TimelineScreen(day: .now)
                    } label: {
                        Image(systemName: "calendar.day.timeline.left")
                    }
                    .accessibilityLabel("Open timeline")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingManualEntry = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add past entry")
                }
                if allClients.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Seed demo") {
                            SampleData.seedDemo(in: modelContext)
                        }
                    }
                }
            }
            .sheet(isPresented: $showingStartSheet) {
                StartTimerSheet(isSwitching: false)
            }
            .sheet(isPresented: $showingSwitchSheet) {
                StartTimerSheet(isSwitching: true)
            }
            .sheet(isPresented: $showingManualEntry) {
                ManualEntrySheet()
            }
            .sheet(item: $editingEntry) { entry in
                ManualEntrySheet(editing: entry)
            }
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Date.now.formatted(.dateTime.weekday(.wide)))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(Date.now.formatted(.dateTime.month().day()))
                .font(.largeTitle.weight(.bold))
        }
    }

    private var hasRunningTimer: Bool {
        TimerService.currentRunningEntry(in: modelContext) != nil
    }

    private var currencyCode: String {
        profiles.first?.currencyCode ?? "USD"
    }

    private var showEmptyBusinessBanner: Bool {
        let trimmed = (profiles.first?.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
    }

    @ViewBuilder
    private var startActions: some View {
        Button {
            showingStartSheet = true
        } label: {
            Label("Start timer", systemImage: "play.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!hasAnyProject)

        QuickStartRow { project in
            do {
                let entry = try TimerService.start(project: project, in: modelContext)
                Task { await TimerActivityController.shared.startActivity(for: entry) }
                if let entity = ProjectEntity(from: project) {
                    Task { try? await StartTimerIntent(project: entity).donate() }
                }
            } catch {
                // TODO(step5): surface error via toast
            }
        }
    }

    private var hasAnyProject: Bool {
        allClients.contains { !$0.activeProjects.isEmpty }
    }

    private func stopRunning() {
        _ = try? TimerService.stop(in: modelContext)
        Task { await TimerActivityController.shared.endActivity() }
        Task { try? await StopTimerIntent().donate() }
    }
}

// MARK: - Active timer card

private struct TodayActiveTimerSection: View {
    @Query(filter: #Predicate<TimeEntry> { $0.endedAt == nil })
    private var runningEntries: [TimeEntry]

    let onStop: () -> Void
    let onSwitch: () -> Void

    var body: some View {
        if let running = runningEntries.first {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                RunningTimerCard(entry: running, asOf: context.date, onStop: onStop, onSwitch: onSwitch)
            }
        } else {
            EmptyView()
        }
    }
}

private struct RunningTimerCard: View {
    let entry: TimeEntry
    let asOf: Date
    let onStop: () -> Void
    let onSwitch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(entry.project?.client?.color.swiftUIColor ?? .blue)
                    .frame(width: 12, height: 12)
                Text(entry.project?.client?.name ?? "—")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("Running")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.green.opacity(0.18), in: .capsule)
                    .foregroundStyle(.green)
            }
            Text(entry.project?.name ?? "Project")
                .font(.title2.weight(.semibold))

            HStack(alignment: .firstTextBaseline) {
                Text(elapsedString)
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Spacer()
                Text(amountString)
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button(role: .destructive, action: onStop) {
                    Label("Stop", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)

                Button(action: onSwitch) {
                    Label("Switch", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(.thinMaterial, in: .rect(cornerRadius: 16))
    }

    private var elapsedString: String {
        let seconds = Int(entry.duration(asOf: asOf))
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    private var amountString: String {
        entry.amount(asOf: asOf).formatted(.currency(code: "USD"))
    }
}

// MARK: - Quick-start row

private struct QuickStartRow: View {
    @Environment(\.modelContext) private var modelContext

    let onTap: (Project) -> Void

    private var recents: [Project] {
        let cutoff = Date.now.addingTimeInterval(-30 * 24 * 3600)
        let descriptor = FetchDescriptor<TimeEntry>(
            predicate: #Predicate { $0.startedAt > cutoff },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        let entries = (try? modelContext.fetch(descriptor)) ?? []
        var seen = Set<PersistentIdentifier>()
        var ordered: [Project] = []
        for entry in entries {
            guard let project = entry.project, !project.isArchived else { continue }
            if seen.insert(project.persistentModelID).inserted {
                ordered.append(project)
                if ordered.count == 3 { break }
            }
        }
        return ordered
    }

    var body: some View {
        if !recents.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("RECENT")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    ForEach(recents) { project in
                        Button {
                            onTap(project)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Circle()
                                    .fill(project.client?.color.swiftUIColor ?? .blue)
                                    .frame(width: 10, height: 10)
                                Text(project.name)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                    .foregroundStyle(.primary)
                                Text(project.client?.name ?? "—")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(.thinMaterial, in: .rect(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

// MARK: - Summary numbers

private struct TodaySummarySection: View {
    @Query private var allEntries: [TimeEntry]
    let currencyCode: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(asOf: context.date)
        }
    }

    @ViewBuilder
    private func content(asOf referenceDate: Date) -> some View {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: referenceDate)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? referenceDate

        let todays = allEntries.filter { entry in
            entry.startedAt < dayEnd && (entry.endedAt ?? referenceDate) > dayStart
        }
        let todaysSeconds = todays.reduce(into: TimeInterval(0)) { acc, e in
            let start = max(e.startedAt, dayStart)
            let end = min(e.endedAt ?? referenceDate, dayEnd)
            acc += max(0, end.timeIntervalSince(start))
        }
        let todaysAmount = todays.reduce(into: Decimal(0)) { acc, e in
            guard let project = e.project, project.isBillable else { return }
            let start = max(e.startedAt, dayStart)
            let end = min(e.endedAt ?? referenceDate, dayEnd)
            let hours = Decimal(max(0, end.timeIntervalSince(start)) / 3600)
            acc += hours * project.hourlyRate
        }
        let uninvoiced = allEntries
            .filter { $0.invoiceID == nil }
            .reduce(into: Decimal(0)) { $0 += $1.amount(asOf: referenceDate) }

        VStack(alignment: .leading, spacing: 14) {
            Text("Today")
                .font(.title3.weight(.semibold))
            HStack(spacing: 12) {
                SummaryTile(label: "Hours", value: formatHours(todaysSeconds), color: .blue)
                SummaryTile(
                    label: "Earnings",
                    value: todaysAmount.formatted(.currency(code: currencyCode)),
                    color: .green
                )
            }
            UninvoicedTile(amount: uninvoiced, currency: currencyCode)
        }
    }

    private func formatHours(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int(seconds / 60)
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        return "\(h)h \(String(format: "%02d", m))m"
    }
}

private struct SummaryTile: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.bold).monospacedDigit())
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: .rect(cornerRadius: 14))
    }
}

private struct UninvoicedTile: View {
    let amount: Decimal
    let currency: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("UNINVOICED")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(amount.formatted(.currency(code: currency)))
                .font(.system(size: 36, weight: .bold, design: .rounded).monospacedDigit())
            Text("Hours you've tracked but haven't invoiced yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: .rect(cornerRadius: 14))
    }
}
