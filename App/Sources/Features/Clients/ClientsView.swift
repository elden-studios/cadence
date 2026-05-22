import SwiftUI
import SwiftData
import BillableCore

struct ClientsView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(filter: #Predicate<Client> { !$0.isArchived }, sort: \Client.name)
    private var activeClients: [Client]

    @Query(filter: #Predicate<Client> { $0.isArchived }, sort: \Client.name)
    private var archivedClients: [Client]

    @State private var showingNew = false
    @State private var showingPaywall = false
    @State private var deletionCandidate: Client?
    private var subscriptions = SubscriptionManager.shared

    private static let freeClientCap = 2

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
            .sheet(isPresented: $showingPaywall) {
                PaywallView(trigger: .extraClient)
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
                        modelContext.delete(client)
                        try? modelContext.save()
                    }
                    deletionCandidate = nil
                }
                Button("Cancel", role: .cancel) { deletionCandidate = nil }
            } message: {
                Text("This permanently deletes the client, their projects, and their time entries. Archive instead if you might come back.")
            }
        }
    }

    private func startAddClient() {
        if subscriptions.isPro || activeClients.count < Self.freeClientCap {
            showingNew = true
        } else {
            showingPaywall = true
        }
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
                            try? modelContext.save()
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
                                    try? modelContext.save()
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
