import SwiftUI
import SwiftData
import BillableCore

/// Form for logging time after the fact (or editing the times on an existing
/// entry). On save, creates a `TimeEntry` with `isManual = true`.
struct ManualEntrySheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(filter: #Predicate<Client> { !$0.isArchived }, sort: \Client.name)
    private var clients: [Client]

    @State private var selectedProject: Project?
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var notes: String = ""

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
    private var rangeIsValid: Bool { endDate > startDate }
    private var canSave: Bool { selectedProject != nil && rangeIsValid }

    var body: some View {
        NavigationStack {
            Form {
                Section("Project") {
                    projectPicker
                }

                Section("When") {
                    DatePicker("Start", selection: $startDate)
                    DatePicker("End", selection: $endDate, in: startDate...)
                    LabeledContent("Duration", value: durationLabel)
                }

                Section("Notes") {
                    TextField("What did you work on?", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
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
        let seconds = Int(endDate.timeIntervalSince(startDate))
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        return "\(h)h \(String(format: "%02d", m))m"
    }

    private func save() {
        guard let project = selectedProject, rangeIsValid else { return }
        let trimmedNotes = notes.trimmingCharacters(in: .whitespaces)
        let storedNotes: String? = trimmedNotes.isEmpty ? nil : trimmedNotes

        if let editing {
            editing.project = project
            editing.startedAt = startDate
            editing.endedAt = endDate
            // Flatten any banked break data so duration() equals the new
            // wall-clock span (startedAt…endedAt). Per-break timestamps are
            // not stored, so the edited span is the only reliable truth.
            editing.accumulatedSeconds = 0
            editing.activeSegmentStartedAt = nil
            editing.notes = storedNotes
            editing.isManual = true
            editing.updatedAt = .now
            modelContext.saveOrLog("edit manual entry")
        } else {
            _ = try? TimerService.logCompletedEntry(
                project: project,
                start: startDate,
                end: endDate,
                notes: storedNotes,
                in: modelContext
            )
        }
        dismiss()
    }
}
