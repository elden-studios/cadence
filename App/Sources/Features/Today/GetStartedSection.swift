import SwiftUI
import SwiftData
import BillableCore

/// First-run guidance block on Today (spec §7a). Shows while the user has
/// onboarded but a real client+project haven't yet coexisted
/// (`firstSetupCompletedAt == nil`). One PRIMARY action ("Start a timer now")
/// plus a SECONDARY 2-step checklist. The block disappears on its own once
/// `BusinessProfileStore.stampFirstSetupIfReached` latches first-setup — this
/// view never writes that latch.
///
/// `clients` is passed in from TodayView's existing `allClients` @Query so we
/// don't open a second client query. The "is there an active project?" probe is
/// a BOUNDED count query (never an unbounded `allProjects`).
struct GetStartedSection: View {
    @Environment(\.modelContext) private var modelContext

    /// Reused from TodayView's `allClients` — do not add a second @Query here.
    let clients: [Client]
    let currencyCode: String

    /// Bounded probe: at most one running entry. Drives the header reframe +
    /// the 0-rate "Set your rate" affordance.
    @Query(Self.runningDescriptor) private var runningEntries: [TimeEntry]

    /// Bounded probe: does at least one non-archived client-linked project exist?
    /// `fetchLimit 1` → SwiftData stops after the first match; this is NOT an
    /// unbounded project list.
    @Query(Self.anyLinkedProjectDescriptor) private var linkedProjectProbe: [Project]

    @State private var showingAddClient = false
    @State private var showingNewProject = false
    @State private var startingQuickTimer = false
    @State private var rateTargetProject: Project?

    private static var runningDescriptor: FetchDescriptor<TimeEntry> {
        var d = FetchDescriptor<TimeEntry>(predicate: #Predicate { $0.endedAt == nil })
        d.fetchLimit = 1
        d.relationshipKeyPathsForPrefetching = [\.project]
        return d
    }

    private static var anyLinkedProjectDescriptor: FetchDescriptor<Project> {
        var d = FetchDescriptor<Project>(predicate: #Predicate { !$0.isArchived && $0.client != nil })
        d.fetchLimit = 1
        return d
    }

    private var hasClient: Bool { !clients.isEmpty }
    private var hasLinkedProject: Bool { !linkedProjectProbe.isEmpty }
    private var runningEntry: TimeEntry? { runningEntries.first }
    private var isTimerRunning: Bool { runningEntry != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            quickStartButton                       // PRIMARY (filled) — Task 3
            if let runningEntry, runningEntry.project?.hourlyRate == 0 {
                setRateRow(for: runningEntry)       // 0-rate affordance — Task 5
            }
            VStack(spacing: 0) {
                checklistRow(
                    title: "Add a client",
                    isDone: hasClient,
                    isEnabled: true,
                    hint: nil
                ) { showingAddClient = true }
                Divider().padding(.leading, 44)
                checklistRow(
                    title: "Create a project",
                    isDone: hasLinkedProject,
                    isEnabled: hasClient,
                    hint: hasClient ? nil : "Add a client first"
                ) { showingNewProject = true }
            }
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 14))
        }
        .padding(16)
        .background(.thinMaterial, in: .rect(cornerRadius: 18))
        .sheet(isPresented: $showingAddClient) {
            NavigationStack { ClientEditorView(client: nil) }
        }
        .sheet(isPresented: $showingNewProject) {
            GetStartedNewProjectSheet()
        }
        .sheet(item: $rateTargetProject) { project in
            if let client = project.client {
                // Client-linked rate-0 project → the full project editor.
                NavigationStack { ProjectEditorView(client: client, project: project) }
            } else {
                // Clientless "General" has no client to satisfy ProjectEditorView(client:);
                // edit just its rate.
                GeneralRateSheet(project: project)
            }
        }
    }

    // MARK: Header (reframes once a timer is running — spec §7a acknowledgement)

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(isTimerRunning ? "Timer running" : "Get started")
                .font(.headline)
            Text(isTimerRunning
                 ? "Add a client to invoice this time."
                 : "Track time now, or set up a client and project to invoice.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Quick-start PRIMARY (filled)

    private var quickStartButton: some View {
        Button {
            startQuickTimer()
        } label: {
            HStack(spacing: 8) {
                if startingQuickTimer {
                    ProgressView().tint(.white)
                    Text("Starting…")
                } else {
                    Image(systemName: "play.fill")
                    Text("Start a timer now")
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(startingQuickTimer || isTimerRunning)
        .accessibilityIdentifier("getStarted.quickStart")
        .accessibilityHint(isTimerRunning ? "A timer is already running" : "Starts tracking on a General project")
    }

    /// Fetch-or-create the ONE canonical clientless "General" project, then start
    /// a timer on it. The General project deliberately does NOT satisfy
    /// first-setup (it's clientless), so the checklist stays visible.
    ///
    /// Dedupe note (punch-list): `startingQuickTimer` is reset synchronously, so
    /// it only drives the transient "Starting…" affordance — it does NOT block a
    /// same-frame double-tap on its own. The REAL idempotency comes from two
    /// places: (a) `fetchOrCreateGeneralProject()` reuses the single existing
    /// clientless "General" (a `fetchLimit 1` probe) instead of inserting a
    /// second, and (b) `TimerService.start` no-ops when the same project is
    /// already running. Together these guarantee a double-tap yields exactly ONE
    /// General + ONE running timer (asserted by GetStartedChecklistUITests).
    private func startQuickTimer() {
        guard !startingQuickTimer, !isTimerRunning else { return }
        startingQuickTimer = true
        let project = fetchOrCreateGeneralProject()
        TimerActions.start(project: project, currencyCode: currencyCode, in: modelContext)
        // Clear the in-flight flag on the NEXT main-actor turn (not synchronously):
        // the running @Query flips `isTimerRunning` on the next runloop, so deferring
        // the clear keeps the button disabled across a same-frame double-tap, making
        // the flag a real debounce. (Hard dedupe is still the fetch-or-create +
        // TimerService same-project no-op above; this just makes the disabled state real.)
        Task { @MainActor in startingQuickTimer = false }
    }

    /// Probe for an existing non-archived clientless "General" (fetchLimit 1 —
    /// reuse, never duplicate); create one only if absent.
    private func fetchOrCreateGeneralProject() -> Project {
        var probe = FetchDescriptor<Project>(
            predicate: #Predicate { $0.name == "General" && $0.client == nil && !$0.isArchived }
        )
        probe.fetchLimit = 1
        if let existing = try? modelContext.fetch(probe).first {
            return existing
        }
        let general = Project(name: "General", hourlyRate: 0, isBillable: true, client: nil)
        modelContext.insert(general)
        modelContext.saveOrLog("create General quick-start project")
        return general
    }

    // MARK: 0-rate affordance

    @ViewBuilder private func setRateRow(for entry: TimeEntry) -> some View {
        if let project = entry.project {
            Button {
                rateTargetProject = project
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "dollarsign.circle")
                        .foregroundStyle(.orange)
                    Text("Set your rate")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text("— this project earns nothing at \(Decimal(0).formatted(.currency(code: currencyCode).precision(.fractionLength(0))))/hr")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
                .padding(12)
                .frame(minHeight: 44)
                .background(.orange.opacity(0.10), in: .rect(cornerRadius: 12))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("getStarted.setRate")
        }
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

/// One-field rate editor for the clientless "General" quick-start project, which
/// can't use `ProjectEditorView` (that requires a client). Edits `hourlyRate`
/// in place. "General" is explicitly a scratchpad; this is the on-ramp to a rate.
private struct GeneralRateSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let project: Project
    @State private var rateInput: Double = 0
    @State private var hasLoaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Hourly rate") {
                    HStack {
                        Text("Rate")
                        Spacer()
                        TextField("0", value: $rateInput, format: .number.precision(.fractionLength(0...2)))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 140)
                    }
                    if rateInput.isZero {
                        Label(
                            "A 0 rate tracks time but earns nothing. Set a rate to track earnings.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Set rate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        project.hourlyRate = Decimal(rateInput)
                        project.updatedAt = .now
                        modelContext.saveOrLog("set General rate")
                        dismiss()
                    }
                    .bold()
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                guard !hasLoaded else { return }
                hasLoaded = true
                rateInput = (project.hourlyRate as NSDecimalNumber).doubleValue
            }
        }
    }
}
