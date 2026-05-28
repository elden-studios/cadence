import SwiftUI
import SwiftData
import BillableCore

// MARK: - Timer card styling (frontend-design polish)

/// Warm accent used for the Working/Start primary action, matching the brand mark.
let timerAccent = Color(red: 0.98, green: 0.49, blue: 0.13)

/// Status pill with a leading state dot (WORKING / ON BREAK).
struct TimerStatusBadge: View {
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
struct TimerCardSurface: View {
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
struct TimerPrimaryButtonStyle: ButtonStyle {
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
struct TimerSecondaryButtonStyle: ButtonStyle {
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

struct RunningTimerCard: View {
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

struct AdjustStartTimePickerSheet: View {
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
