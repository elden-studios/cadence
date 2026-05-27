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
                        currencyCode: currencyCode,
                        onStop: stopRunning,
                        onSwitch: { showingSwitchSheet = true },
                        onResume: resumeLastTimer
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
        !BusinessProfile.canSendInvoice(profile: profiles.first)
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
    }

    private var hasAnyProject: Bool {
        allClients.contains { !$0.activeProjects.isEmpty }
    }

    private func stopRunning() {
        _ = try? TimerService.stop(in: modelContext)
        Task { await TimerActivityController.shared.endActivity() }
        Task { try? await StopTimerIntent().donate() }
    }

    private func resumeLastTimer(project: Project) {
        do {
            let entry = try TimerService.start(project: project, in: modelContext)
            Task { await TimerActivityController.shared.startActivity(for: entry, currencyCode: currencyCode) }
            if let entity = ProjectEntity(from: project) {
                Task { try? await StartTimerIntent(project: entity).donate() }
            }
        } catch TimerService.TimerError.projectIsArchived {
            // The project was archived since the last stop. Silently fail —
            // the pill will disappear on next refresh once the state settles.
        } catch {
            // Other errors are no-ops. The pill remains; user can tap again.
        }
    }
}

// MARK: - Active timer card

private struct TodayActiveTimerSection: View {
    @Query(Self.runningDescriptor)
    private var runningEntries: [TimeEntry]

    @Query(Self.lastStoppedDescriptor)
    private var stoppedEntries: [TimeEntry]

    private static var runningDescriptor: FetchDescriptor<TimeEntry> {
        var descriptor = FetchDescriptor<TimeEntry>(
            predicate: #Predicate<TimeEntry> { $0.endedAt == nil }
        )
        descriptor.fetchLimit = 1
        return descriptor
    }

    private static var lastStoppedDescriptor: FetchDescriptor<TimeEntry> {
        var descriptor = FetchDescriptor<TimeEntry>(
            predicate: #Predicate<TimeEntry> { $0.endedAt != nil },
            sortBy: [SortDescriptor(\.endedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return descriptor
    }

    let currencyCode: String
    let onStop: () -> Void
    let onSwitch: () -> Void
    let onResume: (Project) -> Void

    private var lastStopped: TimeEntry? { stoppedEntries.first }

    var body: some View {
        if let running = runningEntries.first {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                RunningTimerCard(entry: running, asOf: context.date, currencyCode: currencyCode, onStop: onStop, onSwitch: onSwitch)
            }
        } else {
            // No running timer — maybe show the Resume pill.
            TimelineView(.periodic(from: .now, by: 60)) { context in
                if TimeEntry.shouldShowResumePill(lastStopped: lastStopped, now: context.date),
                   let last = lastStopped,
                   let project = last.project {
                    ResumePill(project: project, onTap: { onResume(project) })
                } else {
                    EmptyView()
                }
            }
        }
    }
}

private struct ResumePill: View {
    let project: Project
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "play.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
                Circle()
                    .fill(project.client?.color.swiftUIColor ?? .gray)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Resume \(project.client?.name ?? "—") · \(project.name)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text("Continue tracking where you left off")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

private struct RunningTimerCard: View {
    @Bindable var entry: TimeEntry
    let asOf: Date
    let currencyCode: String
    let onStop: () -> Void
    let onSwitch: () -> Void

    @Environment(\.modelContext) private var modelContext

    @State private var showingAdjustDialog = false
    @State private var showingDatePickerSheet = false
    // Snapshot of entry.notes at last save. Used by the debounce .task to detect
    // a genuine pause-in-typing vs. an in-flight series of keystrokes — avoids
    // the previous per-keystroke saveOrLog storm (which spammed SwiftData and
    // CloudKit per character).
    @State private var lastSavedNotes: String? = nil

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

            // A4: inline note. Empty string ↔ nil so users can clear by deleting.
            TextField("What are you working on?", text: notesBinding, axis: .vertical)
                .lineLimit(1...2)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .textFieldStyle(.plain)

            HStack(alignment: .firstTextBaseline) {
                Button {
                    showingAdjustDialog = true
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(elapsedString)
                            .font(.system(size: 40, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
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
        // Debounced persistence for the inline note field. The setter mutates
        // entry.notes in memory only; this .task fires once per quiescent
        // 400ms window (Task.sleep is cancelled and re-fired when `entry.notes`
        // changes again), bumps updatedAt, and saves. Mirrors the descriptionBinding
        // debounce pattern in InvoicePreviewView. Force-quit window shrinks from
        // "until next autosave" to ~400ms — acceptable, and keeps the per-keystroke
        // SwiftData/CloudKit write storm collapsed into one save per pause.
        .task(id: entry.notes) {
            // Skip the initial fire-on-appear: lastSavedNotes is nil at first
            // appear AND matches entry.notes when entry.notes is also nil.
            // The condition below picks up only real user edits.
            guard entry.notes != lastSavedNotes else { return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            // Re-check post-sleep — entry.notes may have been reverted between
            // the keystroke and the timeout (e.g., user typed then erased back
            // to the original value).
            guard entry.notes != lastSavedNotes else { return }
            entry.updatedAt = .now
            modelContext.saveOrLog("update running entry notes")
            lastSavedNotes = entry.notes
        }
        .onAppear {
            // Seed the saved-state baseline so the .task above can detect the
            // first real edit. Without this, the first keystroke wouldn't fire
            // (lastSavedNotes == nil == entry.notes for a brand-new entry).
            lastSavedNotes = entry.notes
        }
        .confirmationDialog(
            "Adjust start time",
            isPresented: $showingAdjustDialog,
            titleVisibility: .visible
        ) {
            Button("Back 5 minutes") { shiftStart(byMinutes: 5) }
            Button("Back 10 minutes") { shiftStart(byMinutes: 10) }
            Button("Back 15 minutes") { shiftStart(byMinutes: 15) }
            Button("Adjust to…") {
                showingDatePickerSheet = true
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showingDatePickerSheet) {
            AdjustStartTimePickerSheet(
                currentStart: entry.startedAt,
                onSave: { newStart in
                    applyAdjustedStart(newStart)
                    showingDatePickerSheet = false
                },
                onCancel: { showingDatePickerSheet = false }
            )
        }
    }

    private func shiftStart(byMinutes minutes: Int) {
        let newStart = entry.startedAt.addingTimeInterval(TimeInterval(-minutes * 60))
        applyAdjustedStart(newStart)
    }

    private func applyAdjustedStart(_ newStart: Date) {
        // Defensive guard: never write a future start. The DatePicker sheet
        // already restricts to .now-or-earlier; the 5/10/15-min offsets always
        // go backward. This guard is for unforeseen call paths.
        guard newStart < .now else { return }
        do {
            try TimerService.adjustStart(entry: entry, to: newStart, in: modelContext)
        } catch {
            // Silent fail; UI simply won't update. Phase 1 noted error toasts
            // as future work.
        }
    }

    private var notesBinding: Binding<String> {
        Binding(
            get: { entry.notes ?? "" },
            set: { newValue in
                // Normalize: empty string ↔ nil so deleting fully resets.
                let normalized = newValue.isEmpty ? nil : newValue
                // No-op guard: SwiftUI's TextField can invoke the setter with
                // the same value on focus / re-render churn.
                guard entry.notes != normalized else { return }
                // In-memory mutation only — the debounce .task(id: entry.notes)
                // below picks this up and persists once typing pauses. Avoids
                // the per-keystroke SwiftData / CloudKit write storm the first
                // implementation introduced (matches the descriptionBinding
                // pattern in InvoicePreviewView which already debounces).
                entry.notes = normalized
            }
        )
    }

    private var elapsedString: String {
        let seconds = Int(entry.duration(asOf: asOf))
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    private var amountString: String {
        entry.amount(asOf: asOf).formatted(.currency(code: currencyCode))
    }
}

private struct AdjustStartTimePickerSheet: View {
    let currentStart: Date
    let onSave: (Date) -> Void
    let onCancel: () -> Void
    @State private var selection: Date

    init(currentStart: Date, onSave: @escaping (Date) -> Void, onCancel: @escaping () -> Void) {
        self.currentStart = currentStart
        self.onSave = onSave
        self.onCancel = onCancel
        _selection = State(initialValue: currentStart)
    }

    var body: some View {
        // Single `now` per body render — the DatePicker's range bound and the
        // Save predicate read THIS value, not Date.now twice independently.
        // Eliminates the millisecond-scale flicker that prompted the first fix
        // attempt (which pinned to .now at init and introduced minute-scale
        // staleness when the sheet stayed open). Body re-renders pick up a
        // fresh now on every user interaction, so the upper bound advances
        // naturally with the wall clock.
        let now = Date.now
        return NavigationStack {
            Form {
                DatePicker(
                    "Start time",
                    selection: $selection,
                    in: ...now,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.graphical)
            }
            .navigationTitle("Adjust start")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { onSave(selection) }
                        .bold()
                        .disabled(selection >= now)
                }
            }
        }
        .presentationDetents([.medium, .large])
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
