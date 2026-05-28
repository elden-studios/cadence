import SwiftUI
import SwiftData
import BillableCore

/// Add or edit a Project. `project` is nil for new projects; `client` is the
/// owning client (required for new projects).
struct ProjectEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let client: Client
    let project: Project?

    @State private var name: String = ""
    @State private var hourlyRateInput: Double = 0
    @State private var isBillable: Bool = true
    @State private var notes: String = ""

    @State private var hasLoaded = false
    @State private var showingCompleteConfirm = false

    var body: some View {
        Form {
            Section("Project") {
                TextField("Project name", text: $name)
                    .textInputAutocapitalization(.words)
            }

            Section("Rate") {
                Toggle("Billable", isOn: $isBillable)
                if isBillable {
                    HStack {
                        Text("Hourly rate")
                        Spacer()
                        TextField("0", value: $hourlyRateInput, format: .number.precision(.fractionLength(0...2)))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 140)
                        Text(client.projects.first?.hourlyRate != nil ? "" : "")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Notes") {
                TextField("Notes", text: $notes, axis: .vertical)
                    .lineLimit(2...8)
            }

            if let project, !project.isArchived {
                Section {
                    Button("Complete project") { showingCompleteConfirm = true }
                        .frame(maxWidth: .infinity)
                } footer: {
                    Text("Marks the project complete and moves it to Archived. Logged time stays on past invoices and reports.")
                }
            }
        }
        .navigationTitle(project == nil ? "New project" : "Edit project")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { save() }
                    .bold()
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { dismiss() }
            }
        }
        .onAppear { loadIfNeeded() }
        .confirmationDialog(
            "Are you sure you're done with this project?",
            isPresented: $showingCompleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Complete project", role: .destructive) {
                project?.isArchived = true
                project?.updatedAt = .now
                try? modelContext.save()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard let project else { return }
        name = project.name
        hourlyRateInput = (project.hourlyRate as NSDecimalNumber).doubleValue
        isBillable = project.isBillable
        notes = project.notes ?? ""
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        let rate = isBillable ? Decimal(hourlyRateInput) : 0
        let trimmedNotes = notes.trimmingCharacters(in: .whitespaces)
        let storedNotes: String? = trimmedNotes.isEmpty ? nil : trimmedNotes

        if let existing = project {
            existing.name = trimmedName
            existing.hourlyRate = rate
            existing.isBillable = isBillable
            existing.notes = storedNotes
            existing.updatedAt = .now
        } else {
            let new = Project(
                name: trimmedName,
                hourlyRate: rate,
                isBillable: isBillable,
                notes: storedNotes,
                client: client
            )
            modelContext.insert(new)
        }
        modelContext.saveOrLog("save project")
        dismiss()
    }
}
