import SwiftUI
import SwiftData
import BillableCore

struct ProjectDetailView: View {
    @Bindable var project: Project

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \BusinessProfile.createdAt, order: .forward) private var profiles: [BusinessProfile]
    @Query(Self.runningDescriptor) private var runningEntries: [TimeEntry]

    @State private var showingEdit = false
    @State private var showingInvoiceGenerator = false
    @State private var showingCompleteConfirm = false
    @State private var showingSwitchSheet = false
    @State private var sessionLimit = 50

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        let groupedEntries = groupedByMonth(Array(sortedEntries.prefix(sessionLimit)))
        let totalCount = sortedEntries.count
        return ScrollView {
            // One STABLE TimelineView so the timer area's hero-morph isn't
            // destroyed/recreated on start/stop (which would kill the animation).
            // It ticks every 1s only while running; otherwise it emits a single
            // entry and idles.
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
    private func content(asOf: Date, groupedEntries: [(String, [TimeEntry])], totalCount: Int) -> some View {
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
                    Label("Create invoice", systemImage: "doc.text")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            recentSessions(asOf: asOf, groupedEntries: groupedEntries, totalCount: totalCount)
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
        // Hero morph: the Start/Switch button "unfolds" into the running card
        // (and folds back on Stop). The card renders at its natural size — only
        // the surrounding frame height is animated (button height → card height)
        // and the overflow clipped — so the card's contents never squish. Reduce
        // Motion drops the height morph for a plain cross-fade.
        let isRunning = runningEntryForProject != nil
        ZStack(alignment: .top) {
            if let running = runningEntryForProject {
                RunningTimerCard(
                    entry: running, asOf: asOf, currencyCode: currencyCode,
                    onStop: { TimerActions.stop(in: modelContext) },
                    onSwitch: { showingSwitchSheet = true },
                    onTakeBreak: { TimerActions.takeBreak(in: modelContext) },
                    onResume: { TimerActions.resume(in: modelContext) }
                )
                .id(running.persistentModelID)
                .transition(reduceMotion ? .opacity
                                         : .timerExpand(collapsedHeight: 52, fullHeight: 300))
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
                .tint(.timerAccent)
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2)
                                : .spring(response: 0.5, dampingFraction: 0.86),
                   value: isRunning)
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
                        sessionRow(entry, asOf: asOf)
                    }
                }
                if totalCount > shownCount {
                    Button("See all \(totalCount) sessions") { sessionLimit = totalCount }
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

    private func hoursString(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int(seconds / 60)
        return "\(totalMinutes / 60)h \(String(format: "%02d", totalMinutes % 60))m"
    }

    private func groupedByMonth(_ entries: [TimeEntry]) -> [(String, [TimeEntry])] {
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
}

/// The Start-button → running-card "unfold" morph. The card lays out at its
/// natural size (so its contents never squish); we animate the *frame height*
/// from the button height up to the card's and clip the overflow with a rounded
/// rect whose corner radius eases button→card. Content below slides smoothly as
/// the height grows. Clipping (and the height constraint) are dropped at rest so
/// the card keeps its natural height + shadow.
private struct TimerExpandModifier: ViewModifier, @preconcurrency Animatable {
    var progress: CGFloat            // 0 = collapsed (button), 1 = expanded (card)
    let collapsedHeight: CGFloat
    let fullHeight: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View {
        let p = max(0, min(1, progress))
        let h = collapsedHeight + (fullHeight - collapsedHeight) * p
        let sized = content
            .fixedSize(horizontal: false, vertical: true)
            .frame(height: p < 1 ? max(h, 1) : nil, alignment: .top)
            .opacity(Double(min(1, p * 1.5)))
        if p < 1 {
            return AnyView(sized.clipShape(RoundedRectangle(cornerRadius: 14 + 8 * p, style: .continuous)))
        } else {
            return AnyView(sized)
        }
    }
}

private extension AnyTransition {
    static func timerExpand(collapsedHeight: CGFloat, fullHeight: CGFloat) -> AnyTransition {
        .modifier(
            active: TimerExpandModifier(progress: 0, collapsedHeight: collapsedHeight, fullHeight: fullHeight),
            identity: TimerExpandModifier(progress: 1, collapsedHeight: collapsedHeight, fullHeight: fullHeight)
        )
    }
}

/// Ticks every second while a timer is running (to advance the elapsed display),
/// idling to a single entry otherwise — so `ProjectDetailView`'s content stays a
/// stable view across start/stop and the timer hero-morph can animate.
private struct TimerTickSchedule: TimelineSchedule {
    let running: Bool
    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnySequence<Date> {
        if running {
            return AnySequence(PeriodicTimelineSchedule(from: startDate, by: 1).entries(from: startDate, mode: mode))
        } else {
            return AnySequence([startDate])
        }
    }
}
