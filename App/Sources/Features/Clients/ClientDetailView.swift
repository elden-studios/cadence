import SwiftUI
import SwiftData
import BillableCore

struct ClientDetailView: View {
    @Bindable var client: Client

    @Environment(\.modelContext) private var modelContext
    @State private var showingEditClient = false
    @State private var showingNewProject = false
    @State private var deletionCandidate: Project?
    @State private var blockedDeleteName: String?

    private var activeProjects: [Project] {
        client.projects.filter { !$0.isArchived }.sorted { $0.name < $1.name }
    }

    private var archivedProjects: [Project] {
        client.projects.filter { $0.isArchived }.sorted { $0.name < $1.name }
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Circle()
                        .fill(client.color.swiftUIColor)
                        .frame(width: 18, height: 18)
                    VStack(alignment: .leading) {
                        Text(client.name).font(.headline)
                        if let contactName = client.contactName, !contactName.isEmpty {
                            Text(contactName)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let email = client.email, !email.isEmpty {
                    LabeledContent("Email", value: email)
                }
                if let address = client.address, !address.isEmpty {
                    VStack(alignment: .leading) {
                        Text("Address").font(.caption).foregroundStyle(.secondary)
                        Text(address)
                    }
                }
                Button("Edit client") { showingEditClient = true }
            }

            Section {
                if activeProjects.isEmpty {
                    Text("No projects yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(activeProjects) { project in
                        NavigationLink {
                            ProjectDetailView(project: project)
                        } label: {
                            ProjectRow(project: project)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                if project.hasInvoicedTime {
                                    blockedDeleteName = project.name
                                } else {
                                    deletionCandidate = project
                                }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }

                Button {
                    showingNewProject = true
                } label: {
                    Label("Add project", systemImage: "plus.circle")
                }
            } header: {
                Text("Projects")
            }

            if !archivedProjects.isEmpty {
                Section("Archived projects") {
                    ForEach(archivedProjects) { project in
                        NavigationLink {
                            ProjectDetailView(project: project)
                        } label: {
                            ProjectRow(project: project)
                                .foregroundStyle(.secondary)
                        }
                        .swipeActions(edge: .trailing) {
                            Button {
                                project.isArchived = false
                                project.completedAt = nil
                                project.updatedAt = .now
                                modelContext.saveOrLog("restore project")
                            } label: {
                                Label("Restore", systemImage: "tray.and.arrow.up")
                            }
                            .tint(.blue)
                        }
                    }
                }
            }
        }
        .navigationTitle(client.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingEditClient) {
            NavigationStack {
                ClientEditorView(client: client)
            }
        }
        .sheet(isPresented: $showingNewProject) {
            NavigationStack {
                ProjectEditorView(client: client, project: nil)
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
            Button("Delete project and time entries", role: .destructive) {
                if let project = deletionCandidate {
                    modelContext.delete(project)
                    modelContext.saveOrLog("delete project")
                }
                deletionCandidate = nil
            }
            Button("Cancel", role: .cancel) { deletionCandidate = nil }
        } message: {
            Text("This permanently removes the project and all of its time entries.")
        }
        .alert("Can't delete — billing records",
               isPresented: Binding(get: { blockedDeleteName != nil },
                                    set: { if !$0 { blockedDeleteName = nil } })) {
            Button("Cancel", role: .cancel) { blockedDeleteName = nil }
        } message: {
            Text("\(blockedDeleteName ?? "This project") has time on sent or paid invoices. Archive it instead to keep your billing records.")
        }
    }
}

private struct ProjectRow: View {
    let project: Project

    @Query(sort: \BusinessProfile.createdAt, order: .forward) private var profiles: [BusinessProfile]

    private var currencyCode: String {
        profiles.first?.currencyCode
            ?? Locale.current.currency?.identifier
            ?? "USD"
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(project.name)
                if !project.isBillable {
                    Text("Non-billable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if project.isBillable {
                Text(project.hourlyRate, format: .currency(code: currencyCode))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
