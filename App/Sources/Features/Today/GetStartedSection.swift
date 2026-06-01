import SwiftUI
import SwiftData
import BillableCore

/// First-run guidance block on Today (spec §7a). Shows while the user has
/// onboarded but a real client+project haven't yet coexisted
/// (`firstSetupCompletedAt == nil`). Setup-first: the two-step checklist
/// (Add a client → Create a project) is the lead action. The block disappears
/// on its own once `BusinessProfileStore.stampFirstSetupIfReached` latches
/// first-setup — this view never writes that latch.
///
/// `clients` is passed in from TodayView's existing `allClients` @Query so we
/// don't open a second client query. The "is there an active project?" probe is
/// a BOUNDED count query (never an unbounded `allProjects`).
struct GetStartedSection: View {
    /// Reused from TodayView's `allClients` — do not add a second @Query here.
    let clients: [Client]

    /// Bounded probe: does at least one non-archived client-linked project exist?
    /// `fetchLimit 1` → SwiftData stops after the first match; this is NOT an
    /// unbounded project list.
    @Query(Self.anyLinkedProjectDescriptor) private var linkedProjectProbe: [Project]

    @State private var showingAddClient = false
    @State private var showingNewProject = false

    private static var anyLinkedProjectDescriptor: FetchDescriptor<Project> {
        var d = FetchDescriptor<Project>(predicate: #Predicate { !$0.isArchived && $0.client != nil })
        d.fetchLimit = 1
        return d
    }

    private var hasClient: Bool { !clients.isEmpty }
    private var hasLinkedProject: Bool { !linkedProjectProbe.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            VStack(spacing: 0) {
                checklistRow(title: "Add your first client",
                             isDone: hasClient, isEnabled: true, hint: nil) {
                    showingAddClient = true
                }
                Divider().padding(.leading, 44)
                checklistRow(title: "Create a project",
                             isDone: hasLinkedProject, isEnabled: hasClient,
                             hint: hasClient ? nil : "Add a client first") {
                    showingNewProject = true
                }
            }
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 14))
        }
        .padding(16)
        .background(.thinMaterial, in: .rect(cornerRadius: 18))
        .sheet(isPresented: $showingAddClient) { NavigationStack { ClientEditorView(client: nil) } }
        .sheet(isPresented: $showingNewProject) { GetStartedNewProjectSheet() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Set up to get paid").font(.headline)
            Text("Add a client and a project so the time you track can become an invoice.")
                .font(.subheadline).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Secondary checklist row

    private func checklistRow(
        title: String,
        isDone: Bool,
        isEnabled: Bool,
        hint: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isDone ? .green : (isEnabled ? .accentColor : .secondary))
                    .frame(width: 32)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.body)
                    .foregroundStyle(isEnabled ? .primary : .secondary)
                    .strikethrough(isDone, color: .secondary)
                Spacer()
                if !isDone && isEnabled {
                    Image(systemName: "chevron.right")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 12)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isDone)
        .accessibilityValue(isDone ? "Completed" : "Incomplete")
        .accessibilityHint(hint ?? "")
    }
}

/// New-project sheet for the get-started checklist: pick a client, then push the
/// existing `ProjectEditorView`. Mirrors `WorkView`'s `NewProjectSheet` (a
/// `private` type there, so this is the Today-local sibling per spec §7a "the
/// existing add-project sheet via the New-Project flow"). Only non-archived
/// clients are offered, matching the rest of the app.
private struct GetStartedNewProjectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Client> { !$0.isArchived }, sort: \Client.name)
    private var clients: [Client]
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
