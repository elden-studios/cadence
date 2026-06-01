import SwiftUI
import SwiftData
import BillableCore

struct ProjectDetailView: View {
    @Bindable var project: Project

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \BusinessProfile.createdAt, order: .forward) private var profiles: [BusinessProfile]
    @Query(Self.runningDescriptor) private var runningEntries: [TimeEntry]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(TimerMotionStyle.storageKey) private var motionStyleRaw = TimerMotionStyle.spring.rawValue
    private var motionStyle: TimerMotionStyle { TimerMotionStyle(rawValue: motionStyleRaw) ?? .spring }

    @State private var showingEdit = false
    @State private var showingInvoiceGenerator = false
    @State private var showingCompleteConfirm = false
    @State private var showingSwitchSheet = false

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
        // Sort + group once per real change, not per TimelineView tick: the
        // order and month grouping are asOf-independent (only the per-row
        // duration/amount values tick), so we hoist them out of the per-second
        // content closure.
        let sortedEntries = project.entries.sorted { $0.startedAt > $1.startedAt }
        let groupedEntries = Array(sortedEntries.prefix(5)).groupedByMonth()
        let totalCount = sortedEntries.count
        return ScrollView {
            // ONE stable TimelineView — ticks every second only while a timer is
            // running (TimerTickSchedule), otherwise emits a single frame. Keeping
            // the timer area in a single, non-conditional TimelineView means the
            // Start ↔ Running swap animates in place rather than the whole subtree
            // being destroyed/recreated on start/stop (which previously killed the
            // transition).
            TimelineView(TimerTickSchedule(running: runningEntryForProject != nil)) { context in
                content(asOf: context.date, groupedEntries: groupedEntries, totalCount: totalCount)
            }
            .padding()
        }
        .scrollIndicators(.hidden)
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showingEdit = true } label: {
                        Label("Edit project", systemImage: "pencil")
                    }
                    if project.isArchived {
                        Button { restoreProject() } label: {
                            Label("Restore project", systemImage: "tray.and.arrow.up")
                        }
                    } else {
                        Button(role: .destructive) { showingCompleteConfirm = true } label: {
                            Label("Complete project", systemImage: "checkmark.circle")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Project options")
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
            Text("Marks the project complete and moves it to Archived. Logged time stays on past invoices and reports, and any uninvoiced time stays billable here.")
        }
    }

    @ViewBuilder
    private func content(asOf: Date, groupedEntries: [(String, [TimeEntry])], totalCount: Int) -> some View {
        let stats = ProjectStats.compute(for: project, asOf: asOf)
        VStack(alignment: .leading, spacing: 20) {
            hero(stats: stats)
            engagementLine(stats: stats)
            // Timer moved up — the most time-sensitive control is reachable
            // without scrolling past the uninvoiced tile or session history.
            timerArea(asOf: asOf)
            if project.isBillable && (!project.isArchived || stats.uninvoicedAmount > 0) {
                uninvoicedTile(stats: stats)
                Button {
                    showingInvoiceGenerator = true
                } label: {
                    Label("Create invoice", systemImage: "doc.text")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            recentSessions(asOf: asOf, groupedEntries: groupedEntries, totalCount: totalCount)
        }
    }

    // MARK: Hero

    private func hero(stats: ProjectStats) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(DurationFormatting.hoursMinutes(seconds: stats.lifetimeSeconds))
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
            LinearGradient(colors: [.timerAccent, .timerAccent.opacity(0.85)],
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
            } else if project.isArchived {
                Text("\(startLabel) · \(daysLabel) · Archived")
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
            Text("UNINVOICED · THIS PROJECT")
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
        Group {
            if let running = runningEntryForProject {
                RunningTimerCard(
                    entry: running, asOf: asOf, currencyCode: currencyCode,
                    onStop: { TimerActions.stop(in: modelContext) },
                    onSwitch: { showingSwitchSheet = true },
                    onTakeBreak: { TimerActions.takeBreak(in: modelContext) },
                    onResume: { TimerActions.resume(in: modelContext) }
                )
                .id(running.persistentModelID)
                .transition(motionStyle.transition(reduceMotion: reduceMotion))
            } else if !project.isArchived {
                startTimerButton
                    .transition(motionStyle.transition(reduceMotion: reduceMotion))
            }
        }
        // Auto-animate the Start ↔ Running swap with the selected motion. Keyed
        // on the running entry's identity so it fires on start (nil→id), stop
        // (id→nil) and switch (id→id′).
        .animation(motionStyle.animation(reduceMotion: reduceMotion),
                   value: runningEntryForProject?.persistentModelID)
    }

    private var startTimerButton: some View {
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
        .tint(.timerAccent)
    }

    // MARK: Recent sessions

    @ViewBuilder
    private func recentSessions(asOf: Date, groupedEntries: [(String, [TimeEntry])], totalCount: Int) -> some View {
        let shownCount = groupedEntries.reduce(0) { $0 + $1.1.count }
        LazyVStack(alignment: .leading, spacing: 10) {
            Text("Sessions").font(.headline)
            if shownCount == 0 {
                Text("No time tracked yet.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(groupedEntries, id: \.0) { month, entries in
                    Text(month)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(entries) { entry in
                        // Only the running row needs the ticking `asOf`; completed
                        // rows have a constant duration/amount, so pin them to a
                        // stable date to skip per-second re-evaluation under the
                        // TimelineView (Gemini PR #13 r3).
                        SessionRow(entry: entry,
                                   asOf: entry.isRunning ? asOf : (entry.endedAt ?? entry.startedAt),
                                   currencyCode: currencyCode, isBillable: project.isBillable)
                    }
                }
                if totalCount > shownCount {
                    NavigationLink {
                        ProjectSessionsView(project: project, currencyCode: currencyCode)
                    } label: {
                        HStack {
                            Text("See all \(totalCount) sessions")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .font(.subheadline)
                    }
                    .padding(.top, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Actions

    private func completeProject() {
        project.isArchived = true
        project.completedAt = .now
        project.updatedAt = .now
        modelContext.saveOrLog("complete project")
        // Stay on the (now-archived) detail when there's still uninvoiced billable
        // time to bill — the uninvoiced tile + Create-invoice remain visible (WS1).
        if ProjectStats.compute(for: project).uninvoicedAmount == 0 {
            dismiss()
        }
    }

    private func restoreProject() {
        project.isArchived = false
        project.completedAt = nil
        project.updatedAt = .now
        modelContext.saveOrLog("restore project")
    }

    // MARK: Helpers

}

/// Ticks every second only while a timer is running; otherwise emits a single
/// frame. Lets the project-detail timer area live in ONE stable `TimelineView`
/// across start/stop (see `body`) so the Start ↔ Running swap can animate.
private struct TimerTickSchedule: TimelineSchedule, Equatable {
    let running: Bool
    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnySequence<Date> {
        running
            ? AnySequence(PeriodicTimelineSchedule(from: startDate, by: 1).entries(from: startDate, mode: mode))
            : AnySequence([startDate])
    }
}
