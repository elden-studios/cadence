import SwiftUI
import SwiftData
import BillableCore

/// Form for logging time after the fact (or editing the times on an existing
/// entry). On save, creates a `TimeEntry` with `isManual = true`.
struct ManualEntrySheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(AppErrorPresenter.self) private var errorPresenter

    @Query(filter: #Predicate<Client> { !$0.isArchived }, sort: \Client.name)
    private var clients: [Client]

    @State private var selectedProject: Project?
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var notes: String = ""

    /// Drives the "Recalculate this entry?" confirmation dialog.
    @State private var showingBreakWarning = false

    /// When non-nil, the sheet edits the given entry instead of creating a new one.
    let editing: TimeEntry?

    init(editing: TimeEntry? = nil, defaultProject: Project? = nil) {
        self.editing = editing
        if let editing {
            _selectedProject = State(initialValue: editing.project)
            _startDate = State(initialValue: editing.startedAt)
            _endDate = State(initialValue: editing.endedAt ?? Date.now)
            _notes = State(initialValue: editing.notes ?? "")
        } else {
            let now = Date.now
            _selectedProject = State(initialValue: defaultProject)
            _startDate = State(initialValue: now.addingTimeInterval(-3600))
            _endDate = State(initialValue: now)
        }
    }

    private var isEditing: Bool { editing != nil }
    /// True when the entry being edited is still running (no end time yet).
    /// Running entries are adjusted via RunningTimerCard/adjustStart, not this sheet.
    private var isEditingRunningEntry: Bool { editing != nil && editing?.endedAt == nil }
    private var rangeIsValid: Bool { endDate > startDate }
    private var canSave: Bool { selectedProject != nil && rangeIsValid && !isEditingRunningEntry }

    /// True when editing an existing entry whose times have changed AND it has
    /// banked break data that would be silently destroyed by flattening.
    private var wouldDestroyBreaks: Bool {
        guard let editing else { return false }
        guard editing.accumulatedSeconds > 0 else { return false }
        return editing.startedAt != startDate || editing.endedAt != endDate
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Project") {
                    projectPicker
                }

                Section("When") {
                    // Cap the upper bound to now: a manual entry cannot start in
                    // the future. End is bounded by the chosen start.
                    DatePicker("Start", selection: $startDate, in: ...Date.now)
                    DatePicker("End", selection: $endDate, in: startDate...max(startDate, Date.now))
                    LabeledContent("Duration", value: durationLabel)
                }

                Section("Notes") {
                    TextField("What did you work on?", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                }

                if isEditingRunningEntry {
                    Section {
                        EmptyView()
                    } footer: {
                        Text("This timer is still running — stop it first to edit this session's times.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit entry" : "Add entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save", action: save)
                        .bold()
                        .disabled(!canSave)
                }
            }
            .confirmationDialog(
                "Recalculate this entry?",
                isPresented: $showingBreakWarning,
                titleVisibility: .visible
            ) {
                Button("Recalculate & Save", role: .destructive) {
                    commitEdit(flattenBreaks: true)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Editing the times recalculates this entry from start to end and clears its recorded breaks.")
            }
        }
    }

    @ViewBuilder
    private var projectPicker: some View {
        Menu {
            ForEach(clients) { client in
                let projects = client.projects.filter { !$0.isArchived }
                if !projects.isEmpty {
                    Section(client.name) {
                        ForEach(projects) { project in
                            Button {
                                selectedProject = project
                            } label: {
                                HStack {
                                    Text(project.name)
                                    if selectedProject?.persistentModelID == project.persistentModelID {
                                        Spacer()
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            HStack {
                Text("Project")
                Spacer()
                if let project = selectedProject {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(project.client?.color.swiftUIColor ?? .blue)
                            .frame(width: 8, height: 8)
                        Text("\(project.client?.name ?? "—") · \(project.name)")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Choose")
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
    }

    private var durationLabel: String {
        guard rangeIsValid else { return "—" }
        return DurationFormatting.hoursMinutes(seconds: endDate.timeIntervalSince(startDate))
    }

    private func save() {
        guard rangeIsValid else { return }

        if editing != nil, wouldDestroyBreaks {
            // Warn before silently wiping banked break data.
            showingBreakWarning = true
        } else if let editing {
            // Times unchanged or no banked breaks — save without flattening.
            let timesChanged = editing.startedAt != startDate || editing.endedAt != endDate
            commitEdit(flattenBreaks: timesChanged && editing.accumulatedSeconds == 0)
        } else {
            commitNew()
        }
    }

    /// Persist a new completed entry via TimerActions (fires widget reload).
    private func commitNew() {
        guard let project = selectedProject, rangeIsValid else { return }
        let storedNotes = storedNotesValue()
        guard TimerActions.logCompleted(
            project: project, start: startDate, end: endDate,
            notes: storedNotes, in: modelContext
        ) != nil else {
            errorPresenter.present("Couldn't save the entry — please try again.")
            return
        }
        dismiss()
    }

    /// Persist edits to the existing entry via TimerActions (fires widget reload).
    /// `flattenBreaks` controls whether accumulated break seconds are zeroed out.
    private func commitEdit(flattenBreaks: Bool) {
        guard let editing, let project = selectedProject, rangeIsValid else { return }
        let storedNotes = storedNotesValue()
        guard TimerActions.saveEdit(
            entry: editing,
            project: project,
            start: startDate,
            end: endDate,
            notes: storedNotes,
            flattenBreaks: flattenBreaks,
            in: modelContext
        ) else {
            errorPresenter.present("Couldn't save the entry — please try again.")
            return
        }
        dismiss()
    }

    private func storedNotesValue() -> String? {
        let trimmed = notes.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
