import SwiftUI
import SwiftData
import BillableCore

/// Add or edit a Client. When `client` is nil, creates a new one on save.
struct ClientEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let client: Client?

    @State private var name: String = ""
    @State private var color: ClientColor = .blue
    @State private var contactName: String = ""
    @State private var email: String = ""
    @State private var address: String = ""
    @State private var notes: String = ""

    @State private var hasLoaded = false

    var body: some View {
        Form {
            Section("Basics") {
                TextField("Client name", text: $name)
                    .textInputAutocapitalization(.words)
                colorPicker
            }

            Section("Contact (optional)") {
                TextField("Contact name", text: $contactName)
                    .textInputAutocapitalization(.words)
                TextField("Email", text: $email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .textContentType(.emailAddress)
                TextField("Address", text: $address, axis: .vertical)
                    .lineLimit(2...4)
            }

            Section("Notes") {
                TextField("Notes", text: $notes, axis: .vertical)
                    .lineLimit(3...8)
            }
        }
        .navigationTitle(client == nil ? "New client" : "Edit client")
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

    private var colorPicker: some View {
        LabeledContent("Color") {
            HStack(spacing: 8) {
                ForEach(ClientColor.allCases, id: \.self) { option in
                    Circle()
                        .fill(option.swiftUIColor)
                        .frame(width: 22, height: 22)
                        .overlay(
                            Circle()
                                .stroke(Color.primary, lineWidth: color == option ? 2 : 0)
                        )
                        .onTapGesture { color = option }
                        .accessibilityLabel(Text(option.displayName))
                        .accessibilityAddTraits(color == option ? .isSelected : [])
                }
            }
        }
    }

    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard let client else { return }
        name = client.name
        color = client.color
        contactName = client.contactName ?? ""
        email = client.email ?? ""
        address = client.address ?? ""
        notes = client.notes ?? ""
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        if let existing = client {
            existing.name = trimmedName
            existing.color = color
            existing.contactName = optional(contactName)
            existing.email = optional(email)
            existing.address = optional(address)
            existing.notes = optional(notes)
            existing.updatedAt = .now
        } else {
            let new = Client(
                name: trimmedName,
                color: color,
                contactName: optional(contactName),
                email: optional(email),
                address: optional(address),
                notes: optional(notes)
            )
            modelContext.insert(new)
        }
        try? modelContext.save()
        dismiss()
    }

    private func optional(_ s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
