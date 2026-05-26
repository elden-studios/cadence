import SwiftUI
import SwiftData
import UserNotifications
import BillableCore

struct ClientsView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(filter: #Predicate<Client> { !$0.isArchived }, sort: \Client.name)
    private var activeClients: [Client]

    @Query(filter: #Predicate<Client> { $0.isArchived }, sort: \Client.name)
    private var archivedClients: [Client]

    @State private var showingNew = false
    @State private var deletionCandidate: Client?

    var body: some View {
        NavigationStack {
            Group {
                if activeClients.isEmpty && archivedClients.isEmpty {
                    ContentUnavailableView {
                        Label("No clients yet", systemImage: "person.2")
                    } description: {
                        Text("Add your first client to start tracking time.")
                    } actions: {
                        Button {
                            startAddClient()
                        } label: {
                            Label("Add Client", systemImage: "plus.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    listContent
                }
            }
            .navigationTitle("Clients")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        startAddClient()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add client")
                }
            }
            .sheet(isPresented: $showingNew) {
                NavigationStack {
                    ClientEditorView(client: nil)
                }
            }
            .confirmationDialog(
                deletionCandidate.map { "Delete \($0.name)?" } ?? "Delete?",
                isPresented: Binding(
                    get: { deletionCandidate != nil },
                    set: { if !$0 { deletionCandidate = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete client and all data", role: .destructive) {
                    if let client = deletionCandidate {
                        deleteClient(client)
                    }
                    deletionCandidate = nil
                }
                Button("Cancel", role: .cancel) { deletionCandidate = nil }
            } message: {
                Text("This permanently deletes the client, their projects, and their time entries. Archive instead if you might come back.")
            }
        }
    }

    private func deleteClient(_ client: Client) {
        let scheduler = Scheduler(
            center: UNUserNotificationCenter.current(),
            modelContext: modelContext
        )
        // Cancel + delete RecurrenceTemplate rows owned by this client first.
        // Fetch all templates and filter in-memory: SwiftData's #Predicate does
        // not support cross-store relationship equality comparisons.
        let allTemplates = (try? modelContext.fetch(FetchDescriptor<RecurrenceTemplate>())) ?? []
        let clientPID = client.persistentModelID
        for template in allTemplates where template.client?.persistentModelID == clientPID {
            RecurrenceScheduling.cancelAll(for: template, scheduler: scheduler, modelContext: modelContext)
            modelContext.delete(template)
        }
        // Then delete the client (cascades to Project via existing @Relationship).
        modelContext.delete(client)
        modelContext.saveOrLog("delete client")
    }

    private func startAddClient() {
        showingNew = true
    }

    private var listContent: some View {
        List {
            Section {
                ForEach(activeClients) { client in
                    NavigationLink {
                        ClientDetailView(client: client)
                    } label: {
                        ClientRow(client: client)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            deletionCandidate = client
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            client.isArchived = true
                            client.updatedAt = .now
                            modelContext.saveOrLog("archive client")
                        } label: {
                            Label("Archive", systemImage: "archivebox")
                        }
                        .tint(.gray)
                    }
                }
            } header: {
                if !activeClients.isEmpty { Text("Active") }
            }

            if !archivedClients.isEmpty {
                Section("Archived") {
                    ForEach(archivedClients) { client in
                        ClientRow(client: client)
                            .foregroundStyle(.secondary)
                            .swipeActions(edge: .trailing) {
                                Button {
                                    client.isArchived = false
                                    client.updatedAt = .now
                                    modelContext.saveOrLog("restore client")
                                } label: {
                                    Label("Restore", systemImage: "tray.and.arrow.up")
                                }
                                .tint(.blue)
                            }
                    }
                }
            }
        }
    }
}

private struct ClientRow: View {
    let client: Client

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(client.color.swiftUIColor)
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(client.name)
                if let contactName = client.contactName, !contactName.isEmpty {
                    Text(contactName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text("\(client.activeProjects.count)")
                .foregroundStyle(.secondary)
                .font(.subheadline.monospacedDigit())
            Image(systemName: "folder")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}
