import SwiftUI
import SwiftData
import BillableCore

/// Add or edit a Project. `project` is nil for new projects; `client` is the
/// owning client (used as default selection for new projects; optional for edits).
struct ProjectEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let client: Client?
    let project: Project?
    /// Called after a successful save, before this editor dismisses. Lets a host
    /// that *pushed* the editor (e.g. the New Project picker sheet) dismiss the
    /// whole flow rather than just popping back to itself. Defaults to nil so
    /// existing sheet-presented callers are unaffected.
    var onSaved: (() -> Void)? = nil

    @Query(filter: #Predicate<Client> { !$0.isArchived }, sort: \Client.name) private var clients: [Client]
    @State private var selectedClient: Client?

    @State private var name: String = ""
    @State private var hourlyRateInput: Double = 0
    @State private var isBillable: Bool = true
    @State private var notes: String = ""

    @State private var hasLoaded = false

    var body: some View {
        Form {
            Section("Project") {
                TextField("Project name", text: $name)
                    .textInputAutocapitalization(.words)
                Menu {
                    ForEach(clients) { c in
                        Button { selectedClient = c } label: {
                            if selectedClient?.persistentModelID == c.persistentModelID {
                                Label(c.name, systemImage: "checkmark")
                            } else {
                                Text(c.name)
                            }
                        }
                    }
                } label: {
                    LabeledContent("Client") {
                        Text(selectedClient?.name ?? "Select client")
                            .foregroundStyle(selectedClient == nil ? .secondary : .primary)
                    }
                }
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
                    }
                    if hourlyRateInput.isZero {
                        Label(
                            "A 0 rate tracks time but earns nothing. Set a rate to track earnings.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }
            }

            Section("Notes") {
                TextField("Notes", text: $notes, axis: .vertical)
                    .lineLimit(2...8)
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
    }

    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        selectedClient = project?.client ?? client
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
            existing.client = selectedClient
            existing.updatedAt = .now
        } else {
            let new = Project(
                name: trimmedName,
                hourlyRate: rate,
                isBillable: isBillable,
                notes: storedNotes,
                client: selectedClient
            )
            modelContext.insert(new)
        }
        modelContext.saveOrLog("save project")
        // `onSaved` (when provided) already dismisses the presenting sheet, so
        // only fall back to a local dismiss() when there's no onSaved — calling
        // both double-fires dismissal and can glitch the navigation animation.
        if let onSaved {
            onSaved()
        } else {
            dismiss()
        }
    }
}
