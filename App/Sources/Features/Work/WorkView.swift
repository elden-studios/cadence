import SwiftUI
import SwiftData
import BillableCore

struct WorkView: View {
    private enum Mode: String, CaseIterable { case projects = "Projects", clients = "Clients" }

    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [BusinessProfile]
    @Query(filter: #Predicate<Project> { !$0.isArchived }, sort: \Project.name)
    private var activeProjects: [Project]
    @Query(Self.runningDescriptor) private var runningEntries: [TimeEntry]

    @State private var mode: Mode = .projects
    @State private var search = ""

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

    private var grouped: [(client: String, projects: [Project])] {
        let byClient = Dictionary(grouping: filteredProjects) { $0.client?.name ?? "No client" }
        return byClient.keys.sorted().map { ($0, byClient[$0]!.sorted { $0.name < $1.name }) }
    }

    @ViewBuilder
    private var projectsList: some View {
        if activeProjects.isEmpty {
            ContentUnavailableView {
                Label("No projects yet", systemImage: "folder")
            } description: {
                Text("Add a client and a project to start tracking.")
            }
        } else {
            List {
                ForEach(grouped, id: \.client) { group in
                    Section(group.client) {
                        ForEach(group.projects) { project in
                            ProjectBrowserRow(
                                project: project,
                                currencyCode: currencyCode,
                                isRunning: runningEntries.first?.project?.persistentModelID == project.persistentModelID,
                                anotherRunning: runningEntries.first != nil
                                    && runningEntries.first?.project?.persistentModelID != project.persistentModelID,
                                onPlay: {
                                    if runningEntries.first != nil
                                        && runningEntries.first?.project?.persistentModelID != project.persistentModelID {
                                        TimerActions.switchTo(project: project, currencyCode: currencyCode, in: modelContext)
                                    } else {
                                        TimerActions.start(project: project, currencyCode: currencyCode, in: modelContext)
                                    }
                                }
                            )
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Search projects or clients")
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
                        (isRunning ? Color.green : Color(red: 0.98, green: 0.49, blue: 0.13)),
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
