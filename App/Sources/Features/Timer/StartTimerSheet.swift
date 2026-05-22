import SwiftUI
import SwiftData
import BillableCore

/// Sheet presenting all active Client → Project options to start (or switch
/// into) a timer. Recents row stays at the top so the common case is one tap.
struct StartTimerSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(filter: #Predicate<Client> { !$0.isArchived }, sort: \Client.name)
    private var clients: [Client]

    @State private var search: String = ""

    /// When true, the caller already has a running timer and tapping a project
    /// should perform a `switchTo` instead of a `start`.
    let isSwitching: Bool
    /// Optional callback after a successful start/switch — for the host to
    /// dismiss any other sheets or react.
    var onStarted: (TimeEntry) -> Void = { _ in }

    var body: some View {
        NavigationStack {
            List {
                if !recentProjects.isEmpty && search.isEmpty {
                    Section("Recent") {
                        ForEach(recentProjects) { project in
                            projectRow(project)
                        }
                    }
                }
                ForEach(filteredClients) { client in
                    Section(client.name) {
                        ForEach(activeProjects(of: client)) { project in
                            projectRow(project)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(isSwitching ? "Switch to" : "Start timer")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Search projects")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func projectRow(_ project: Project) -> some View {
        Button {
            startOrSwitch(to: project)
        } label: {
            HStack {
                Circle()
                    .fill(project.client?.color.swiftUIColor ?? .blue)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading) {
                    Text(project.name)
                        .foregroundStyle(.primary)
                    if let client = project.client {
                        Text(client.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if project.isBillable {
                    Text(project.hourlyRate, format: .currency(code: "USD"))
                        .foregroundStyle(.secondary)
                        .font(.subheadline.monospacedDigit())
                } else {
                    Text("Non-billable")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
        }
    }

    private var filteredClients: [Client] {
        guard !search.isEmpty else { return clients }
        return clients.filter { client in
            client.name.localizedCaseInsensitiveContains(search)
                || activeProjects(of: client).contains {
                    $0.name.localizedCaseInsensitiveContains(search)
                }
        }
    }

    private func activeProjects(of client: Client) -> [Project] {
        client.projects.filter { !$0.isArchived }.sorted { $0.name < $1.name }
    }

    private var recentProjects: [Project] {
        // Look at the last ~30 days of entries; rank projects by most recent use.
        let cutoff = Date.now.addingTimeInterval(-30 * 24 * 3600)
        let descriptor = FetchDescriptor<TimeEntry>(
            predicate: #Predicate { entry in
                entry.startedAt > cutoff
            },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        let entries = (try? modelContext.fetch(descriptor)) ?? []
        var seen = Set<PersistentIdentifier>()
        var ordered: [Project] = []
        for entry in entries {
            guard let project = entry.project, !project.isArchived else { continue }
            if seen.insert(project.persistentModelID).inserted {
                ordered.append(project)
                if ordered.count == 3 { break }
            }
        }
        return ordered
    }

    private func startOrSwitch(to project: Project) {
        do {
            let entry: TimeEntry
            if isSwitching {
                entry = try TimerService.switchTo(project: project, in: modelContext)
            } else {
                entry = try TimerService.start(project: project, in: modelContext)
            }
            Task { await TimerActivityController.shared.startActivity(for: entry) }
            if let entity = ProjectEntity(from: project) {
                if isSwitching {
                    Task { try? await SwitchTimerIntent(project: entity).donate() }
                } else {
                    Task { try? await StartTimerIntent(project: entity).donate() }
                }
            }
            onStarted(entry)
            dismiss()
        } catch TimerService.TimerError.alreadyTrackingSameProject {
            // Same project — just dismiss; the existing entry keeps going.
            dismiss()
        } catch {
            // For now, swallow other errors silently. Step 5 hooks in real surfacing.
            dismiss()
        }
    }
}
