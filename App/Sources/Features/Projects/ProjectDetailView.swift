import SwiftUI
import SwiftData
import BillableCore

struct ProjectDetailView: View {
    @Bindable var project: Project

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query private var profiles: [BusinessProfile]
    @Query(Self.runningDescriptor) private var runningEntries: [TimeEntry]

    @State private var showingEdit = false
    @State private var showingInvoiceGenerator = false
    @State private var showingCompleteConfirm = false
    @State private var showingSwitchSheet = false
    @State private var sessionLimit = 50

    private static var runningDescriptor: FetchDescriptor<TimeEntry> {
        var d = FetchDescriptor<TimeEntry>(predicate: #Predicate { $0.endedAt == nil })
        d.fetchLimit = 1
        return d
    }

    private var currencyCode: String {
        profiles.first?.currencyCode ?? Locale.current.currency?.identifier ?? "USD"
    }

    /// The running entry, but only if it belongs to THIS project.
    private var runningEntryForProject: TimeEntry? {
        guard let running = runningEntries.first,
              running.project?.persistentModelID == project.persistentModelID else { return nil }
        return running
    }

    private var anotherProjectRunning: Bool {
        guard let running = runningEntries.first else { return false }
        return running.project?.persistentModelID != project.persistentModelID
    }

    var body: some View {
        ScrollView {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                content(asOf: context.date)
            }
            .padding()
        }
        .scrollIndicators(.hidden)
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { showingEdit = true }
            }
        }
        .sheet(isPresented: $showingEdit) {
            NavigationStack {
                ProjectEditorView(client: project.client ?? Client(name: ""), project: project)
            }
        }
        .sheet(isPresented: $showingInvoiceGenerator) {
            InvoiceGeneratorView(defaultClient: project.client, defaultProject: project)
        }
        .sheet(isPresented: $showingSwitchSheet) {
            StartTimerSheet(isSwitching: true)
        }
        .confirmationDialog(
            "Are you sure you're done with this project?",
            isPresented: $showingCompleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Complete project", role: .destructive) { completeProject() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Marks the project complete and moves it to Archived. Logged time stays on past invoices and reports.")
        }
    }

    @ViewBuilder
    private func content(asOf: Date) -> some View {
        let stats = ProjectStats.compute(for: project, asOf: asOf)
        VStack(alignment: .leading, spacing: 20) {
            hero(stats: stats)
            engagementLine(stats: stats)
            if project.isBillable && !project.isArchived {
                uninvoicedTile(stats: stats)
            }
            timerArea(asOf: asOf)
            if project.isBillable && !project.isArchived {
                Button {
                    showingInvoiceGenerator = true
                } label: {
                    Label(invoiceLabel(stats: stats), systemImage: "doc.text")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            recentSessions(asOf: asOf)
            lifecycleButton()
        }
    }

    // MARK: Hero

    private func hero(stats: ProjectStats) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(hoursString(stats.lifetimeSeconds))
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .monospacedDigit()
            HStack(spacing: 8) {
                Text("\(stats.sessionCount) session\(stats.sessionCount == 1 ? "" : "s")")
                if project.isBillable {
                    Text("·")
                    Text("\(stats.lifetimeValue.formatted(.currency(code: currencyCode))) at \(project.hourlyRate.formatted(.currency(code: currencyCode)))/h")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.9))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            LinearGradient(colors: [timerAccent, timerAccent.opacity(0.85)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: .rect(cornerRadius: 18)
        )
        .foregroundStyle(.white)
    }

    // MARK: Engagement line

    @ViewBuilder
    private func engagementLine(stats: ProjectStats) -> some View {
        let start = stats.firstTrackedDay ?? project.createdAt
        let startLabel = (stats.firstTrackedDay == nil ? "Created " : "Started ")
            + start.formatted(.dateTime.month().day())
        let daysLabel = "\(stats.activeDayCount) day\(stats.activeDayCount == 1 ? "" : "s") worked"
        HStack(spacing: 6) {
            Image(systemName: "calendar")
            if project.isArchived, let completed = project.completedAt {
                Text("\(start.formatted(.dateTime.month().day())) – \(completed.formatted(.dateTime.month().day())) · \(daysLabel)")
            } else {
                Text("\(startLabel) · \(daysLabel)")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: Uninvoiced tile

    private func uninvoicedTile(stats: ProjectStats) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("UNINVOICED")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(stats.uninvoicedAmount.formatted(.currency(code: currencyCode)))
                .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
            Text("Tracked time on this project you haven't invoiced yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: .rect(cornerRadius: 14))
    }

    // MARK: Timer area

    @ViewBuilder
    private func timerArea(asOf: Date) -> some View {
        if let running = runningEntryForProject {
            RunningTimerCard(
                entry: running, asOf: asOf, currencyCode: currencyCode,
                onStop: { TimerActions.stop(in: modelContext) },
                onSwitch: { showingSwitchSheet = true },
                onTakeBreak: { TimerActions.takeBreak(in: modelContext) },
                onResume: { TimerActions.resume(in: modelContext) }
            )
            .id(running.persistentModelID)
        } else if !project.isArchived {
            Button {
                if anotherProjectRunning {
                    TimerActions.switchTo(project: project, currencyCode: currencyCode, in: modelContext)
                } else {
                    TimerActions.start(project: project, currencyCode: currencyCode, in: modelContext)
                }
            } label: {
                Label(anotherProjectRunning ? "Switch to this project" : "Start timer",
                      systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(timerAccent)
        }
    }

    // MARK: Recent sessions

    @ViewBuilder
    private func recentSessions(asOf: Date) -> some View {
        let sorted = project.entries.sorted { $0.startedAt > $1.startedAt }
        let shown = Array(sorted.prefix(sessionLimit))
        VStack(alignment: .leading, spacing: 10) {
            Text("Sessions").font(.headline)
            if shown.isEmpty {
                Text("No time tracked yet.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(groupedByMonth(shown), id: \.0) { month, entries in
                    Text(month)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(entries) { entry in
                        sessionRow(entry, asOf: asOf)
                    }
                }
                if sorted.count > shown.count {
                    Button("See all \(sorted.count) sessions") { sessionLimit = sorted.count }
                        .font(.subheadline)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sessionRow(_ entry: TimeEntry, asOf: Date) -> some View {
        HStack {
            Text(entry.startedAt.formatted(.dateTime.weekday().day()))
            Spacer()
            Text(hoursString(entry.duration(asOf: asOf)))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if project.isBillable {
                Text(entry.amount(asOf: asOf).formatted(.currency(code: currencyCode)))
                    .monospacedDigit()
                    .foregroundStyle(.green)
                    .frame(minWidth: 70, alignment: .trailing)
            }
        }
        .font(.subheadline)
        .padding(.vertical, 4)
    }

    // MARK: Lifecycle button

    @ViewBuilder
    private func lifecycleButton() -> some View {
        if project.isArchived {
            Button { restoreProject() } label: {
                Label("Restore project", systemImage: "tray.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        } else {
            Button(role: .destructive) { showingCompleteConfirm = true } label: {
                Label("Complete project", systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: Actions

    private func completeProject() {
        project.isArchived = true
        project.completedAt = .now
        project.updatedAt = .now
        modelContext.saveOrLog("complete project")
        dismiss()
    }

    private func restoreProject() {
        project.isArchived = false
        project.completedAt = nil
        project.updatedAt = .now
        modelContext.saveOrLog("restore project")
    }

    // MARK: Helpers

    private func invoiceLabel(stats: ProjectStats) -> String {
        stats.uninvoicedAmount > 0
            ? "Create invoice · \(stats.uninvoicedAmount.formatted(.currency(code: currencyCode)))"
            : "Create invoice"
    }

    private func hoursString(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int(seconds / 60)
        return "\(totalMinutes / 60)h \(String(format: "%02d", totalMinutes % 60))m"
    }

    private func groupedByMonth(_ entries: [TimeEntry]) -> [(String, [TimeEntry])] {
        var order: [String] = []
        var buckets: [String: [TimeEntry]] = [:]
        for entry in entries {
            let key = entry.startedAt.formatted(.dateTime.month(.wide).year())
            if buckets[key] == nil { order.append(key); buckets[key] = [] }
            buckets[key]?.append(entry)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }
}
