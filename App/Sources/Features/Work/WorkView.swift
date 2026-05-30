import SwiftUI
import SwiftData
import BillableCore

struct WorkView: View {
    private enum Mode: String, CaseIterable { case projects = "Projects", clients = "Clients" }

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \BusinessProfile.createdAt, order: .forward) private var profiles: [BusinessProfile]
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
        // `runningProjectID` reads .project; prefetch it to avoid a lazy fault.
        d.relationshipKeyPathsForPrefetching = [\.project]
        return d
    }

    private var currencyCode: String {
        profiles.first?.currencyCode ?? Locale.current.currency?.identifier ?? "USD"
    }

    /// The running project's ID (if any), read via one named accessor so the
    /// project rows don't each re-traverse the running entry's relationship.
    private var runningProjectID: PersistentIdentifier? {
        runningEntries.first?.project?.persistentModelID
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
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return activeProjects }
        return activeProjects.filter {
            $0.name.localizedCaseInsensitiveContains(query)
            || ($0.client?.name.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var grouped: [ProjectGroup] {
        // Group by client identity (not name) so two clients sharing a name
        // don't collide into one section. Projects within a group keep the
        // @Query's name order (Dictionary(grouping:) preserves insertion order).
        let byClient = Dictionary(grouping: filteredProjects) { $0.client?.persistentModelID }
        return byClient.map { id, projects in
            let client = projects.first?.client
            return ProjectGroup(
                id: id,
                clientName: client?.name ?? "No client",
                color: client?.color.swiftUIColor,
                projects: projects
            )
        }
        .sorted { lhs, rhs in
            // Real clients first (locale-aware); the "No client" bucket (nil id) last.
            switch (lhs.id, rhs.id) {
            case (nil, nil): return false
            case (nil, _): return false
            case (_, nil): return true
            default: return lhs.clientName.localizedStandardCompare(rhs.clientName) == .orderedAscending
            }
        }
    }

    private var projectsList: some View {
        // Compute the grouping once per render (it also drives `filteredProjects`)
        // rather than recomputing for both the empty check and the list.
        // `.searchable` is applied here (a stable container), not on the List,
        // so the search bar persists when the no-results empty state replaces it.
        projectsListContent(groups: grouped)
            .searchable(text: $search, prompt: "Search projects or clients")
    }

    @ViewBuilder
    private func projectsListContent(groups: [ProjectGroup]) -> some View {
        if activeProjects.isEmpty {
            ContentUnavailableView {
                Label("No projects yet", systemImage: "folder")
            } description: {
                Text("Add a client and a project to start tracking.")
            }
        } else if groups.isEmpty {
            ContentUnavailableView("No results", systemImage: "magnifyingglass",
                description: Text("No projects or clients match \"\(search)\"."))
        } else {
            List {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.projects) { project in
                            ProjectBrowserRow(
                                project: project,
                                currencyCode: currencyCode,
                                isRunning: runningProjectID == project.persistentModelID,
                                anotherRunning: runningProjectID != nil
                                    && runningProjectID != project.persistentModelID,
                                onPlay: {
                                    if let runningProjectID,
                                       runningProjectID != project.persistentModelID {
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
        }
    }
}

private struct NewProjectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Client> { !$0.isArchived }, sort: \Client.name)
    private var clients: [Client]
    // Store the ID, not the model, in @State (more robust than holding a
    // SwiftData object across view updates); resolve from `clients` on push.
    @State private var selectedClientID: PersistentIdentifier?

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
                            selectedClientID = client.persistentModelID
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
            .navigationDestination(item: $selectedClientID) { id in
                if let client = clients.first(where: { $0.persistentModelID == id }) {
                    ProjectEditorView(client: client, project: nil, onSaved: { dismiss() })
                }
            }
        }
    }
}

/// One client's projects in the Work browser. `Identifiable` by the client's
/// persistent ID (nil for the "No client" bucket) so two clients sharing a
/// display name remain distinct sections.
private struct ProjectGroup: Identifiable {
    let id: PersistentIdentifier?
    let clientName: String
    let color: Color?
    let projects: [Project]
}

private struct ProjectBrowserRow: View {
    let project: Project
    let currencyCode: String
    let isRunning: Bool
    let anotherRunning: Bool
    let onPlay: () -> Void

    var body: some View {
        // Only the running row ticks: wrap just it in a TimelineView so its
        // hours/earnings update live without churning the whole list per second.
        Group {
            if isRunning {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    rowContent(asOf: context.date)
                }
            } else {
                rowContent(asOf: .now)
            }
        }
        // NavigationLink lives in the background (hidden) so the whole row
        // navigates without a mid-row chevron, and the play Button stays an
        // independent tap target instead of fighting the link's gesture.
        .background(
            NavigationLink(destination: ProjectDetailView(project: project)) {
                EmptyView()
            }
            .opacity(0)
        )
    }

    @ViewBuilder
    private func rowContent(asOf: Date) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                Circle()
                    .fill(project.client?.color.swiftUIColor ?? .blue)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                    Text(statsLine(asOf: asOf))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(action: onPlay) {
                Image(systemName: isRunning ? "waveform" : "play.fill")
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(
                        (isRunning ? .green : .timerAccent),
                        in: .circle
                    )
            }
            .buttonStyle(.plain)
            .disabled(isRunning)
            .accessibilityLabel(isRunning ? "Running" : (anotherRunning ? "Switch to this project" : "Start timer"))
        }
    }

    private func statsLine(asOf: Date) -> String {
        let stats = ProjectStats.compute(for: project, asOf: asOf)
        let hours = Int(stats.lifetimeSeconds / 3600)
        let mins = (Int(stats.lifetimeSeconds) % 3600) / 60
        let time = "\(hours)h \(String(format: "%02d", mins))m"
        guard project.isBillable else { return time }
        return "\(time) · \(stats.lifetimeValue.formatted(.currency(code: currencyCode)))"
    }
}
