import SwiftUI
import SwiftData
import BillableCore

struct WorkView: View {
    private enum Mode: String, CaseIterable { case projects = "Projects", clients = "Clients" }

    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [BusinessProfile]
    @Query(Self.projectsDescriptor) private var activeProjects: [Project]

    private static var projectsDescriptor: FetchDescriptor<Project> {
        var descriptor = FetchDescriptor<Project>(
            predicate: #Predicate<Project> { !$0.isArchived },
            sortBy: [SortDescriptor(\.name)]
        )
        // Prefetch entries too: each row computes ProjectStats from project.entries,
        // so without this the grouped list triggers an N+1 fetch storm.
        descriptor.relationshipKeyPathsForPrefetching = [\.client, \.entries]
        return descriptor
    }
    @Query(Self.runningDescriptor) private var runningEntries: [TimeEntry]

    @State private var mode: Mode = .projects
    @State private var search = ""
    @State private var showingNewClient = false
    @State private var showingNewProject = false

    private static var runningDescriptor: FetchDescriptor<TimeEntry> {
        var d = FetchDescriptor<TimeEntry>(predicate: #Predicate { $0.endedAt == nil })
        d.fetchLimit = 1
        return d
    }

    private var currencyCode: String {
        profiles.first?.currencyCode ?? Locale.current.currency?.identifier ?? "USD"
    }

    var body: some View {
        NavigationStack {
            Group {
                if mode == .projects {
                    projectsList
                } else {
                    ClientsListContent()
                }
            }
            .navigationTitle("Work")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("View", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if mode == .projects {
                        Menu {
                            Button {
                                showingNewProject = true
                            } label: {
                                Label("New project", systemImage: "folder.badge.plus")
                            }
                            Button {
                                showingNewClient = true
                            } label: {
                                Label("New client", systemImage: "person.badge.plus")
                            }
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
            .sheet(isPresented: $showingNewClient) {
                NavigationStack { ClientEditorView(client: nil) }
            }
            .sheet(isPresented: $showingNewProject) {
                NewProjectSheet()
            }
        }
    }

    private var filteredProjects: [Project] {
        guard !search.isEmpty else { return activeProjects }
        return activeProjects.filter {
            $0.name.localizedCaseInsensitiveContains(search)
            || ($0.client?.name.localizedCaseInsensitiveContains(search) ?? false)
        }
    }

    private var grouped: [(clientName: String, color: Color?, projects: [Project])] {
        let byClient = Dictionary(grouping: filteredProjects) { $0.client?.name ?? "No client" }
        return byClient.keys.sorted().map { name in
            let projects = byClient[name] ?? []
            return (name, projects.first?.client?.color.swiftUIColor, projects)
        }
    }

    @ViewBuilder
    private var projectsList: some View {
        if activeProjects.isEmpty {
            ContentUnavailableView {
                Label("No projects yet", systemImage: "folder")
            } description: {
                Text("Add a client and a project to start tracking.")
            }
        } else if filteredProjects.isEmpty {
            ContentUnavailableView("No results", systemImage: "magnifyingglass",
                description: Text("No projects or clients match \"\(search)\"."))
        } else {
            List {
                ForEach(grouped, id: \.clientName) { group in
                    Section {
                        ForEach(group.projects) { project in
                            ProjectBrowserRow(
                                project: project,
                                currencyCode: currencyCode,
                                isRunning: runningEntries.first?.project?.persistentModelID == project.persistentModelID,
                                anotherRunning: runningEntries.first != nil
                                    && runningEntries.first?.project?.persistentModelID != project.persistentModelID,
                                onPlay: {
                                    if let running = runningEntries.first,
                                       running.project?.persistentModelID != project.persistentModelID {
                                        TimerActions.switchTo(project: project, currencyCode: currencyCode, in: modelContext)
                                    } else {
                                        TimerActions.start(project: project, currencyCode: currencyCode, in: modelContext)
                                    }
                                }
                            )
                        }
                    } header: {
                        HStack(spacing: 8) {
                            if let color = group.color {
                                Circle().fill(color).frame(width: 8, height: 8)
                            }
                            Text(group.clientName)
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Search projects or clients")
        }
    }
}

private struct NewProjectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Client> { !$0.isArchived }, sort: \Client.name)
    private var clients: [Client]
    @State private var selectedClient: Client?

    var body: some View {
        NavigationStack {
            Group {
                if clients.isEmpty {
                    ContentUnavailableView(
                        "No clients yet",
                        systemImage: "person.2",
                        description: Text("Add a client first, then create a project for them.")
                    )
                } else {
                    List(clients) { client in
                        Button {
                            selectedClient = client
                        } label: {
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(client.color.swiftUIColor)
                                    .frame(width: 10, height: 10)
                                Text(client.name).foregroundStyle(.primary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("New project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .navigationDestination(item: $selectedClient) { client in
                ProjectEditorView(client: client, project: nil, onSaved: { dismiss() })
            }
        }
    }
}

private struct ProjectBrowserRow: View {
    let project: Project
    let currencyCode: String
    let isRunning: Bool
    let anotherRunning: Bool
    let onPlay: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            NavigationLink {
                ProjectDetailView(project: project)
            } label: {
                HStack(spacing: 12) {
                    Circle()
                        .fill(project.client?.color.swiftUIColor ?? .blue)
                        .frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.name)
                        Text(statsLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Button(action: onPlay) {
                Image(systemName: isRunning ? "waveform" : "play.fill")
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(
                        (isRunning ? Color.green : .timerAccent),
                        in: .circle
                    )
            }
            .buttonStyle(.plain)
            .disabled(isRunning)
            .accessibilityLabel(isRunning ? "Running" : (anotherRunning ? "Switch to this project" : "Start timer"))
        }
    }

    private var statsLine: String {
        let stats = ProjectStats.compute(for: project)
        let hours = Int(stats.lifetimeSeconds / 3600)
        let mins = (Int(stats.lifetimeSeconds) % 3600) / 60
        let time = "\(hours)h \(String(format: "%02d", mins))m"
        guard project.isBillable else { return time }
        return "\(time) · \(stats.lifetimeValue.formatted(.currency(code: currencyCode)))"
    }
}
