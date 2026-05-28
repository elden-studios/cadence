import SwiftUI
import SwiftData
import WidgetKit
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
                        onTakeBreak: { TimerActions.takeBreak(in: modelContext) },
                        onResume: { TimerActions.resume(in: modelContext) },
                        onStart: { showingStartSheet = true }
                    )
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

    private var currencyCode: String {
        profiles.first?.currencyCode ?? "USD"
    }

    private var showEmptyBusinessBanner: Bool {
        !BusinessProfile.canSendInvoice(profile: profiles.first)
    }

    private func stopRunning() {
        TimerActions.stop(in: modelContext)
    }

}

// MARK: - Active timer card

private struct TodayActiveTimerSection: View {
    @Query(Self.runningDescriptor)
    private var runningEntries: [TimeEntry]

    private static var runningDescriptor: FetchDescriptor<TimeEntry> {
        var descriptor = FetchDescriptor<TimeEntry>(
            predicate: #Predicate<TimeEntry> { $0.endedAt == nil }
        )
        descriptor.fetchLimit = 1
        return descriptor
    }

    let currencyCode: String
    let onStop: () -> Void
    let onSwitch: () -> Void
    let onTakeBreak: () -> Void
    let onResume: () -> Void
    let onStart: () -> Void

    var body: some View {
        Group {
            if let running = runningEntries.first {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    RunningTimerCard(
                        entry: running, asOf: context.date, currencyCode: currencyCode,
                        onStop: onStop, onSwitch: onSwitch, onTakeBreak: onTakeBreak, onResume: onResume
                    )
                    // Tag identity by the running entry's persistent ID so that
                    // an atomic Switch (TimerService.switchTo stops the old
                    // entry and inserts a new one in one save) produces a
                    // FRESH view with fresh @State. Without this, the
                    // @State `lastSavedNotes` (debounce baseline) would
                    // persist from the OLD entry across into the NEW entry's
                    // lifetime and trigger a spurious save on the new entry's
                    // first .task fire (its notes are nil but the baseline
                    // remembers the old entry's saved value).
                    .id(running.persistentModelID)
                }
            } else {
                IdleTimerCard(onStart: onStart)
            }
        }
        .animation(.snappy(duration: 0.28), value: runningEntries.first?.persistentModelID)
        .animation(.snappy(duration: 0.28), value: runningEntries.first?.activeSegmentStartedAt)
    }
}


// MARK: - Timer card styling (frontend-design polish)

/// Warm accent used for the Working/Start primary action, matching the brand mark.
private let timerAccent = Color(red: 0.98, green: 0.49, blue: 0.13)

/// Status pill with a leading state dot (WORKING / ON BREAK).
private struct TimerStatusBadge: View {
    let text: String
    let color: Color
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.caption2.weight(.bold)).tracking(0.6)
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(color.opacity(0.14), in: .capsule)
        .foregroundStyle(color)
    }
}

/// Elevated card surface. Tints + outlines amber while On Break for state legibility.
private struct TimerCardSurface: View {
    var onBreak: Bool = false
    var body: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color(.secondarySystemBackground))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(onBreak ? Color.orange.opacity(0.06) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(onBreak ? Color.orange.opacity(0.22) : Color.primary.opacity(0.06),
                                  lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.07), radius: 14, y: 5)
    }
}

/// Filled, gradient primary action with a soft tinted shadow and press spring.
private struct TimerPrimaryButtonStyle: ButtonStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                LinearGradient(colors: [tint, tint.opacity(0.85)], startPoint: .top, endPoint: .bottom),
                in: .rect(cornerRadius: 14)
            )
            .shadow(color: tint.opacity(0.35), radius: 8, y: 4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

/// Subtle filled secondary action (Switch / Done for now).
private struct TimerSecondaryButtonStyle: ButtonStyle {
    var tint: Color = .primary
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 12))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

private struct IdleTimerCard: View {
    let onStart: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Text("00:00:00")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.quaternary)
            Text("No timer running").font(.subheadline).foregroundStyle(.secondary)
            Button(action: onStart) {
                Label("Start timer", systemImage: "play.fill")
            }
            .buttonStyle(TimerPrimaryButtonStyle(tint: timerAccent))
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(22)
        .background(TimerCardSurface())
    }
}

private struct RunningTimerCard: View {
    @Bindable var entry: TimeEntry
    let asOf: Date
    let currencyCode: String
    let onStop: () -> Void          // "Done for now"
    let onSwitch: () -> Void
    let onTakeBreak: () -> Void
    let onResume: () -> Void

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
                if entry.isOnBreak {
                    TimerStatusBadge(text: "ON BREAK", color: .orange)
                } else {
                    TimerStatusBadge(text: "WORKING", color: .green)
                }
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
                if entry.isWorking && entry.accumulatedSeconds == 0 {
                    Button {
                        showingAdjustDialog = true
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(elapsedString)
                                .font(.system(size: 40, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.primary)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.subheadline)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(elapsedString)
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(entry.isOnBreak ? .secondary : .primary)
                }
                Spacer()
                Text(amountString)
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if entry.isOnBreak {
                Button(action: onResume) {
                    Label("Resume", systemImage: "play.fill")
                }
                .buttonStyle(TimerPrimaryButtonStyle(tint: .green))
            } else {
                Button(action: onTakeBreak) {
                    Label("Take a Break", systemImage: "cup.and.saucer.fill")
                }
                .buttonStyle(TimerPrimaryButtonStyle(tint: timerAccent))
            }
            HStack(spacing: 10) {
                Button(action: onSwitch) {
                    Label("Switch", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(TimerSecondaryButtonStyle(tint: .blue))
                Button(action: onStop) {
                    Text("Done for now")
                }
                .buttonStyle(TimerSecondaryButtonStyle())
            }
        }
        .padding(18)
        .background(TimerCardSurface(onBreak: entry.isOnBreak))
        // Debounced persistence for the inline note field. The setter mutates
        // entry.notes in memory only; this .task fires once per quiescent
        // 400ms window (Task.sleep is cancelled and re-fired when `entry.notes`
        // changes again), bumps updatedAt, and saves. Mirrors the
        // descriptionBinding debounce pattern in InvoicePreviewView.
        //
        // The .onAppear and .onDisappear modifiers below close the lifecycle
        // around this debounce:
        //   - onAppear seeds the baseline before the user can type.
        //   - onDisappear flushes any pending edit that the debounce hadn't
        //     fired yet, so tab-switching (which destroys the view and
        //     cancels the .task) doesn't strand a typed-but-not-saved note.
        // The .id(entry.persistentModelID) on the call site ensures Switch
        // creates a fresh view with fresh @State (no baseline carry-over
        // across entries).
        //
        // Real-world data-loss window: if the user types AND force-quits
        // within 400ms (debounce hasn't fired) AND before iOS suspends the
        // app (where SwiftData autosave runs at .background phase) — note
        // lost. Acceptable for v1.6.
        .task(id: entry.notes) {
            // Skip the initial fire-on-appear: lastSavedNotes is nil at first
            // appear AND matches entry.notes when entry.notes is also nil.
            // The post-sleep guard is the actual race-killer if .onAppear
            // hasn't yet seeded — by the time the sleep returns, .onAppear
            // has definitely run and lastSavedNotes is current.
            guard entry.notes != lastSavedNotes else { return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            // Re-check post-sleep — handles two cases: (1) user reverted to
            // the original value within 400ms; (2) .onAppear seed-vs-.task
            // race where lastSavedNotes is now current.
            guard entry.notes != lastSavedNotes else { return }
            flushNotesSave()
        }
        .onAppear {
            // Seed the saved-state baseline. Per Apple docs `.task` runs
            // before .onAppear, but the .task body's post-sleep guard catches
            // the race window (400ms is plenty of time for .onAppear to fire).
            lastSavedNotes = entry.notes
        }
        .onDisappear {
            // Flush any pending edit the debounce didn't get to. Without
            // this, a user who types and immediately tab-switches loses
            // the in-memory mutation when the .task is cancelled by view
            // teardown — SwiftData's autosave runs at background phase, not
            // on view destruction. After this flush, lastSavedNotes is
            // updated so the next reappear's .onAppear seeds correctly.
            guard entry.notes != lastSavedNotes else { return }
            flushNotesSave()
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

    /// Persists the current entry.notes value and updates the debounce
    /// baseline. Called from both the debounce .task (after 400ms quiescence)
    /// and .onDisappear (to flush pending edits on view teardown).
    private func flushNotesSave() {
        entry.updatedAt = .now
        modelContext.saveOrLog("update running entry notes")
        lastSavedNotes = entry.notes
    }

    private func shiftStart(byMinutes minutes: Int) {
        let newStart = entry.startedAt.addingTimeInterval(TimeInterval(-minutes * 60))
        applyAdjustedStart(newStart)
    }

    private func applyAdjustedStart(_ newStart: Date) {
        // Defensive guard: never write a strictly-future start. `<=` mirrors
        // TimerService.adjustStart — "now" (0 elapsed) is valid; only the future
        // is rejected. The DatePicker sheet already restricts to .now-or-earlier;
        // the 5/10/15-min offsets always go backward. This guard is for
        // unforeseen call paths.
        guard newStart <= .now else { return }
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
                        // `>` not `>=`: disable only for a strictly-future
                        // selection. Selecting exactly "now" is valid (0 elapsed)
                        // and matches the `<=` guards in applyAdjustedStart /
                        // TimerService.adjustStart.
                        .disabled(selection > now)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Summary numbers

private struct TodaySummarySection: View {
    @Query(Self.entriesDescriptor) private var allEntries: [TimeEntry]
    let currencyCode: String

    private static var entriesDescriptor: FetchDescriptor<TimeEntry> {
        var d = FetchDescriptor<TimeEntry>()
        d.relationshipKeyPathsForPrefetching = [\.project]
        return d
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(asOf: context.date)
        }
    }

    @ViewBuilder
    private func content(asOf referenceDate: Date) -> some View {
        let cal = Calendar.current
        let todays = allEntries.filter { entry in
            cal.isDate(entry.startedAt, inSameDayAs: referenceDate)
        }
        let todaysSeconds = todays.reduce(into: TimeInterval(0)) { acc, e in
            acc += e.duration(asOf: referenceDate)   // worked time, breaks excluded
        }
        let todaysAmount = todays.reduce(into: Decimal(0)) { acc, e in
            acc += e.amount(asOf: referenceDate)      // uses duration() internally
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
