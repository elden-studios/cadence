import SwiftUI
import SwiftData
import UserNotifications
import BillableCore

struct ClientsListContent: View {
    @Environment(\.modelContext) private var modelContext

    @Query(filter: #Predicate<Client> { !$0.isArchived }, sort: \Client.name)
    private var activeClients: [Client]

    @Query(filter: #Predicate<Client> { $0.isArchived }, sort: \Client.name)
    private var archivedClients: [Client]

    // Drafts are excluded at the SwiftData predicate level (instead of in the
    // map builder) so the @Query never materializes them — for power users
    // with hundreds of historical invoices that's a meaningful win in fetch
    // cost AND in the per-render iteration below.
    //
    // Sort by `\Invoice.sentAt` (not issuedAt) so the FIRST occurrence per
    // client is genuinely the most recent send. Issuance and send dates can
    // diverge by arbitrary amounts when a draft is created then finalized
    // later — sorting by issuedAt would let an older-issued-but-recently-sent
    // invoice be masked by a newer-issued-but-earlier-sent one.
    //
    // `relationshipKeyPathsForPrefetching = [\.client]` batch-loads the client
    // relationship with the invoice fetch, eliminating the N+1 fault that would
    // otherwise occur when `lastInvoiceByClientID` accesses `invoice.client`
    // per row.
    @Query(Self.sentInvoicesDescriptor)
    private var sentInvoices: [Invoice]

    private static var sentInvoicesDescriptor: FetchDescriptor<Invoice> {
        var descriptor = FetchDescriptor<Invoice>(
            predicate: #Predicate<Invoice> { $0.sentAt != nil },
            sortBy: [SortDescriptor(\.sentAt, order: .reverse)]
        )
        descriptor.relationshipKeyPathsForPrefetching = [\.client]
        return descriptor
    }

    @State private var showingNew = false
    @State private var deletionCandidate: Client?

    private var lastInvoiceByClientID: [PersistentIdentifier: Date] {
        var map: [PersistentIdentifier: Date] = [:]
        // Sort is `\Invoice.sentAt` DESC + predicate guarantees non-nil, so the
        // first occurrence per client IS the most recent send. Early-exit once
        // we've recorded a value for a client — O(unique clients) in practice.
        for invoice in sentInvoices {
            guard let clientID = invoice.client?.persistentModelID else { continue }
            guard map[clientID] == nil else { continue }
            // Predicate guarantees sentAt non-nil, but guard defensively
            // rather than force-unwrap.
            guard let sentAt = invoice.sentAt else { continue }
            map[clientID] = sentAt
        }
        return map
    }

    var body: some View {
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
        // Compute the map ONCE per render, not once per row. Accessing
        // `lastInvoiceByClientID` directly inside the ForEach below would
        // rebuild the entire dictionary (and re-fault every invoice.client
        // relationship) for every single active client — O(activeClients ×
        // sentInvoices) per render pass. Hoisting to a local `let` makes it
        // O(sentInvoices) per render. (SwiftData caches faulted Client objects
        // in the context, so repeat renders don't re-fault.)
        let lastInvoices = lastInvoiceByClientID
        return List {
            Section {
                ForEach(activeClients) { client in
                    NavigationLink {
                        ClientDetailView(client: client)
                    } label: {
                        ClientRow(
                            client: client,
                            lastInvoiceDate: lastInvoices[client.persistentModelID]
                        )
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
                        ClientRow(client: client, lastInvoiceDate: nil)
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
    let lastInvoiceDate: Date?

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
                if let lastInvoiceDate {
                    Text(DaysAgoFormatter.string(for: lastInvoiceDate, prefix: "Last invoice: "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
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
