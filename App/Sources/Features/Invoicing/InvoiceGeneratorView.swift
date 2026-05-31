import SwiftUI
import SwiftData
import OSLog
import UserNotifications
import BillableCore

/// Multi-step invoice generation: pick a client, choose a date range, choose
/// a line-item grouping, then `Preview` to inspect/finalize.
struct InvoiceGeneratorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(filter: #Predicate<Client> { !$0.isArchived }, sort: \Client.name)
    private var clients: [Client]
    @Query(sort: \BusinessProfile.createdAt, order: .forward) private var profiles: [BusinessProfile]

    // MARK: – Project scope (Item 1 — consolidated option)
    private enum ProjectScope: Hashable {
        case project(Project)
        case allConsolidated
    }

    @State private var selectedClient: Client?
    @State private var projectScope: ProjectScope?
    @State private var scopeOfWork: String = ""
    @State private var preset: InvoicePeriodPreset = .lastMonth
    @State private var customStart: Date = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
    @State private var customEnd: Date = .now
    @State private var grouping: LineItemGrouping = .perEntry
    @State private var notes: String = ""
    @State private var showingPreview = false

    // MARK: – Recurring
    @State private var makeRecurring: Bool = false
    @State private var recurrenceCadenceKind: RecurrenceCadenceKind = .monthly
    @State private var recurrenceDayOfMonth: Int = 1
    @State private var recurrenceWeekday: RecurrenceCadence.Weekday = .monday
    @State private var recurrenceEndDate: Date? = nil
    @State private var savingRecurrence = false
    @State private var saveErrorAlert = false          // Item 3
    @State private var permissionDeniedAlert = false
    @State private var invoiceAllResult: Int?

    init(defaultClient: Client? = nil, defaultProject: Project? = nil) {
        _selectedClient = State(initialValue: defaultClient)
        _projectScope = State(initialValue: defaultProject.map { .project($0) })
    }

    /// Convenience back-compat accessor — returns the single project for the
    /// `.project` case, nil for `.allConsolidated` and nil scope. (Item 1)
    private var selectedProject: Project? {
        if case .project(let p) = projectScope { return p }
        return nil
    }

    private var profile: BusinessProfile? { profiles.first }

    /// Whether Send / Preview is allowed. Delegates to the BillableCore helper so
    /// the logic is unit-testable without importing UIKit or SwiftUI.
    static func canSendInvoice(profile: BusinessProfile?) -> Bool {
        BusinessProfile.canSendInvoice(profile: profile)
    }

    private var resolvedRange: InvoiceDateRange {
        if preset == .custom {
            return InvoiceDateRange(start: Calendar.current.startOfDay(for: customStart),
                                    end: Calendar.current.startOfDay(for: customEnd).addingTimeInterval(86_400))
        }
        return preset.range() ?? InvoiceDateRange(start: customStart, end: customEnd)
    }

    @State private var eligibleEntries: [TimeEntry] = []
    @State private var projectsWithEligible: [Project] = []
    @State private var activeProjects: [Project] = []

    private var lineItems: [InvoiceLineItem] {
        InvoiceBuilder.buildLineItems(from: eligibleEntries, grouping: grouping)
    }

    /// Scope text with surrounding whitespace stripped; nil when blank so a
    /// whitespace-only entry never renders an empty Scope block on the invoice.
    private var trimmedScope: String? {
        let trimmed = scopeOfWork.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var canPreview: Bool {
        // Item 1: scope chosen (single or consolidated) counts; nil → can't preview
        selectedClient != nil && projectScope != nil && profile != nil && !lineItems.isEmpty
            && Self.canSendInvoice(profile: profile)
    }

    /// §7b conditional copy: name which half is missing, or both. `isProfileEnriched`
    /// requires a non-blank address AND `hasBankDetails`; mirror those two checks.
    private func enrichmentPromptMessage(for profile: BusinessProfile) -> String {
        let hasAddress = !profile.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasBank = profile.hasBankDetails
        switch (hasAddress, hasBank) {
        case (false, false):
            return "Add your address and payment details so this invoice looks complete."
        case (false, true):
            return "Add your address so this invoice looks complete."
        case (true, false):
            return "Add your payment details so this invoice looks complete."
        case (true, true):
            return ""   // unreachable: !isProfileEnriched implies at least one is missing
        }
    }

    /// Item 2: message used in both the non-recurring and recurring branches when
    /// `activeProjects` (billable set) is empty.
    private var nonBillableEmptyStateMessage: String {
        let allActive = selectedClient?.projects.filter { !$0.isArchived } ?? []
        if allActive.isEmpty {
            return "This client has no active projects."
        } else {
            return "This client's active projects are all non-billable — only billable time can be invoiced."
        }
    }

    private var saveDisabled: Bool {
        // Item 9: also require ≥1 billable project so we never schedule an empty-
        // invoice loop. activeProjects is already the billable-filtered set.
        selectedClient == nil || profile == nil || savingRecurrence || activeProjects.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Client") {
                    clientPicker
                }

                Section("Project") {
                    if selectedClient != nil {
                        if makeRecurring {
                            // Items 4/7: recurring mode is always client-wide; hide per-project
                            // picker and batch button, show a clarifying caption instead.
                            // Item 9: if there are no billable projects, explain it too.
                            if activeProjects.isEmpty {
                                Text(nonBillableEmptyStateMessage).foregroundStyle(.secondary)
                            } else {
                                Text("Recurring invoices cover all billable projects for this client, each period.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            // Items 1/2: show correct empty-state; otherwise show three-choice picker.
                            // M-1: reuse nonBillableEmptyStateMessage (single source of truth).
                            let hasAnyActiveProject = !(selectedClient?.projects.filter { !$0.isArchived }.isEmpty ?? true)
                            if !hasAnyActiveProject || activeProjects.isEmpty {
                                Text(nonBillableEmptyStateMessage).foregroundStyle(.secondary)
                            } else {
                                // Item 1: three-choice Picker (single project / consolidated / nil)
                                Picker("Project", selection: $projectScope) {
                                    Text("Choose").tag(ProjectScope?.none)
                                    ForEach(activeProjects) { p in
                                        Text(p.name).tag(ProjectScope?.some(.project(p)))
                                    }
                                    if projectsWithEligible.count > 1 {
                                        Text("All projects · one invoice")
                                            .tag(ProjectScope?.some(.allConsolidated))
                                    }
                                }
                                // Item 6/8: batch button — present but only when there are ≥2
                                // eligible projects; hidden when makeRecurring (already in else branch).
                                if projectsWithEligible.count > 1 {
                                    Button { invoiceAllProjects() } label: {
                                        Label("Invoice all projects (separate drafts)", systemImage: "doc.on.doc")
                                    }
                                }
                            }
                        }
                    } else {
                        Text("Pick a client first.").foregroundStyle(.secondary)
                    }
                }

                Section("Scope of work (optional)") {
                    TextField("e.g. Build the v1 analytics dashboard", text: $scopeOfWork, axis: .vertical)
                        .lineLimit(2...6)
                }

                // Item 4 (NEW-S6-2): Period is irrelevant when recurring — cadence
                // derives its own range. Hide entirely in recurring mode.
                if !makeRecurring {
                    Section("Period") {
                        Picker("Range", selection: $preset) {
                            ForEach(InvoicePeriodPreset.allCases) { p in
                                Text(p.label).tag(p)
                            }
                        }
                        if preset == .custom {
                            DatePicker("From", selection: $customStart, displayedComponents: .date)
                            DatePicker("To", selection: $customEnd, in: customStart..., displayedComponents: .date)
                        } else {
                            LabeledContent("Period", value: periodSummary)
                        }
                    }
                }

                Section("Line items") {
                    Picker("Grouping", selection: $grouping) {
                        ForEach(LineItemGrouping.allCases) { g in
                            Text(g.label).tag(g)
                        }
                    }
                    .pickerStyle(.segmented)

                    // Item 4 (NEW-S6-2): eligible-entry count/hours/subtotal are based
                    // on a specific period — hide them when recurring (period is implied).
                    if !makeRecurring, let client = selectedClient {
                        if eligibleEntries.isEmpty {
                            Label("No billable, completed time entries for \(client.name) in this range.",
                                  systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else {
                            LabeledContent("Eligible entries", value: "\(eligibleEntries.count)")
                            LabeledContent("Total hours", value: formatHours(eligibleEntries))
                            LabeledContent("Subtotal", value: formatSubtotal())
                        }
                    }
                }

                Section("Notes (optional)") {
                    TextField("Thank you, payment details, etc.", text: $notes, axis: .vertical)
                        .lineLimit(2...8)
                }

                // MARK: Recurring section
                Section {
                    Toggle(isOn: $makeRecurring) {
                        Label("Make this recurring", systemImage: "arrow.triangle.2.circlepath")
                    }
                    if makeRecurring {
                        Picker("Cadence", selection: $recurrenceCadenceKind) {
                            ForEach(RecurrenceCadenceKind.allCases) { kind in
                                Text(kind.label).tag(kind)
                            }
                        }
                        .pickerStyle(.segmented)

                        switch recurrenceCadenceKind {
                        case .monthly:
                            Picker("Day of month", selection: $recurrenceDayOfMonth) {
                                ForEach(1...31, id: \.self) { day in
                                    Text("\(day)").tag(day)
                                }
                            }
                        case .weekly, .biweekly:
                            Picker("Day of week", selection: $recurrenceWeekday) {
                                ForEach([RecurrenceCadence.Weekday.monday, .tuesday, .wednesday,
                                         .thursday, .friday, .saturday, .sunday], id: \.rawValue) { w in
                                    Text(w.rawValue.capitalized).tag(w)
                                }
                            }
                        }

                        DatePicker(
                            "Until (optional)",
                            selection: Binding(
                                get: { recurrenceEndDate ?? Date.distantFuture },
                                set: { recurrenceEndDate = ($0 == Date.distantFuture) ? nil : $0 }
                            ),
                            displayedComponents: [.date]
                        )
                    }
                } header: {
                    Text("Recurring")
                }

                if let profile, !profile.isProfileEnriched, Self.canSendInvoice(profile: profile) {
                    Section {
                        NavigationLink {
                            BusinessProfileEditorView()
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "doc.text.magnifyingglass")
                                    .foregroundStyle(.blue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Complete your invoice details")
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary)
                                    Text(enrichmentPromptMessage(for: profile))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .accessibilityIdentifier("invoiceGenerator.enrichmentPrompt")
                    }
                }

                if !Self.canSendInvoice(profile: profile) {
                    Section {
                        if profile == nil {
                            Label("Set up your business profile first.", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        } else {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                Text("Set your business name in Settings to send invoices.")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }
            .onAppear {
                refreshEligibleEntries()
                refreshProjectsAndActive()
            }
            .onChange(of: projectScope) { _, _ in refreshEligibleEntries() }
            .onChange(of: selectedClient) { _, _ in
                // Clear the project scope/recurring state on any client change so a
                // prior client's selections can't linger. (Items 1/5)
                projectScope = nil
                makeRecurring = false      // Item 5: stale recurring toggle must not carry across clients
                eligibleEntries = []
                refreshProjectsAndActive()
            }
            .onChange(of: preset) { _, _ in refreshForDateRange() }
            // Debounce the custom-date pickers: spinning the wheel emits a burst
            // of changes, and each refresh hits SwiftData on the main thread.
            .task(id: customStart) {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                refreshForDateRange()
            }
            .task(id: customEnd) {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                refreshForDateRange()
            }
            .navigationTitle("New invoice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if makeRecurring {
                        Button {
                            Task { await saveRecurrence() }
                        } label: {
                            if savingRecurrence {
                                ProgressView()
                            } else {
                                Text("Save schedule")
                            }
                        }
                        .bold()
                        .disabled(saveDisabled)
                    } else {
                        Button("Preview") { showingPreview = true }
                            .bold()
                            .disabled(!canPreview)
                    }
                }
            }
            .sheet(isPresented: $showingPreview) {
                if let client = selectedClient, let profile {
                    InvoicePreviewView(
                        client: client,
                        project: selectedProject,
                        profile: profile,
                        lineItems: lineItems,
                        sourceEntries: eligibleEntries,
                        scopeOfWork: trimmedScope,
                        notes: notes.isEmpty ? nil : notes,
                        onDone: { dismiss() }
                    )
                }
            }
            .alert("Drafts created", isPresented: Binding(get: { invoiceAllResult != nil }, set: { if !$0 { invoiceAllResult = nil } })) {
                Button("OK") { invoiceAllResult = nil; dismiss() }
            } message: {
                // Item 6: only prompt the user to add a scope if they didn't type one.
                if trimmedScope == nil {
                    Text("Created \(invoiceAllResult ?? 0) draft invoice(s) — one per project with billable time. Open each from Invoices to add a scope and send.")
                } else {
                    Text("Created \(invoiceAllResult ?? 0) draft invoice(s) — one per project with billable time.")
                }
            }
            // Item 3: surface recurrence-save failure to the user.
            .alert("Couldn't save the schedule", isPresented: $saveErrorAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Your data wasn't changed — please try again.")
            }
            .alert("Notifications are off", isPresented: $permissionDeniedAlert) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Cadence needs notifications to remind you when invoices are due. Open Settings to enable.")
            }
        }
    }

    @ViewBuilder
    private var clientPicker: some View {
        if clients.isEmpty {
            Text("Add a client first.")
                .foregroundStyle(.secondary)
        } else {
            Menu {
                ForEach(clients) { client in
                    Button {
                        selectedClient = client
                        projectScope = nil
                    } label: {
                        HStack {
                            Text(client.name)
                            if selectedClient?.persistentModelID == client.persistentModelID {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack {
                    Text("Client").foregroundStyle(.primary)
                    Spacer()
                    if let c = selectedClient {
                        HStack(spacing: 6) {
                            Circle().fill(c.color.swiftUIColor).frame(width: 10, height: 10)
                            Text(c.name).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Choose").foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
        }
    }

    private var periodSummary: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        let start = formatter.string(from: resolvedRange.start)
        // The "end" is exclusive; show the previous day as inclusive end.
        let inclusiveEnd = resolvedRange.end.addingTimeInterval(-1)
        let end = formatter.string(from: inclusiveEnd)
        return "\(start) – \(end)"
    }

    private func formatHours(_ entries: [TimeEntry]) -> String {
        let seconds = entries.reduce(into: TimeInterval(0)) { $0 += $1.duration() }
        let total = Int(seconds / 60)
        let h = total / 60
        let m = total % 60
        return "\(h)h \(String(format: "%02d", m))m"
    }

    private func formatSubtotal() -> String {
        let subtotal = lineItems.reduce(into: Decimal(0)) { $0 += $1.amount }
        let code = profile?.currencyCode ?? "USD"
        return subtotal.formatted(.currency(code: code))
    }

    // MARK: – Eligible-entry + project cache

    /// Recompute eligible entries based on the current `projectScope`.
    /// - `.project(p)` → that project's entries.
    /// - `.allConsolidated` → client-wide entries across all billable projects.
    /// - `nil` → empty (no selection yet). (Item 1)
    @MainActor
    private func refreshEligibleEntries() {
        guard let client = selectedClient else {
            eligibleEntries = []
            return
        }
        switch projectScope {
        case .project(let p):
            eligibleEntries = InvoiceBuilder.eligibleEntries(for: p, in: resolvedRange, context: modelContext)
        case .allConsolidated:
            // M-2: exclude entries from archived projects (mirrors activeProjects and invoiceAllProjects).
            eligibleEntries = InvoiceBuilder.eligibleEntries(for: client, in: resolvedRange, context: modelContext)
                .filter { !($0.project?.isArchived ?? true) }
        case nil:
            eligibleEntries = []
        }
    }

    /// Recompute the client's pickable projects and the subset with eligible
    /// entries. Depends on `selectedClient` and the resolved range only — kept
    /// separate so a client change doesn't redundantly re-fetch entries.
    @MainActor
    private func refreshProjectsAndActive() {
        activeProjects = selectedClient.map {
            $0.projects.filter { !$0.isArchived && $0.isBillable }.sorted { $0.name < $1.name }
        } ?? []
        projectsWithEligible = selectedClient.map {
            InvoiceBuilder.projectsWithEligibleEntries(for: $0, in: resolvedRange, context: modelContext)
        } ?? []
    }

    /// A date-range change moves both `eligibleEntries` and `projectsWithEligible`,
    /// and both derive from the same client fetch — so fetch once and group in
    /// memory rather than firing two queries. (`activeProjects` is range-independent
    /// and is left untouched.)
    ///
    /// Item 1: eligibleEntries is now scope-aware — consolidated scope keeps all
    /// client entries; single-project scope filters down; nil scope returns [].
    @MainActor
    private func refreshForDateRange() {
        guard let client = selectedClient else {
            eligibleEntries = []
            projectsWithEligible = []
            return
        }
        let clientEntries = InvoiceBuilder.eligibleEntries(for: client, in: resolvedRange, context: modelContext)
        let byProject = Dictionary(grouping: clientEntries) { $0.project }
        projectsWithEligible = byProject.keys
            .compactMap { $0 }
            .filter { !$0.isArchived }
            .sorted { $0.name < $1.name }
        switch projectScope {
        case .project(let p):
            eligibleEntries = byProject[p] ?? []
        case .allConsolidated:
            // M-2: exclude entries from archived projects (already filtered out of projectsWithEligible above).
            eligibleEntries = clientEntries.filter { !($0.project?.isArchived ?? true) }
        case nil:
            eligibleEntries = []
        }
    }

    // MARK: – Invoice all projects

    @MainActor
    private func invoiceAllProjects() {
        guard let client = selectedClient, let profile else { return }
        // Single fetch, then group in memory — avoids an N+1 per-project re-fetch.
        // `eligibleEntries(for: client)` already restricts to billable projects, so
        // we only need to drop archived ones (matching projectsWithEligibleEntries).
        let entries = InvoiceBuilder.eligibleEntries(for: client, in: resolvedRange, context: modelContext)
        let entriesByProject = Dictionary(grouping: entries) { $0.project }
        let projects = entriesByProject.keys
            .compactMap { $0 }
            .filter { !$0.isArchived }
            .sorted { $0.name < $1.name }
        var created = 0
        for project in projects {
            let items = InvoiceBuilder.buildLineItems(from: entriesByProject[project] ?? [], grouping: grouping)
            guard !items.isEmpty else { continue }
            // Item 6: carry the typed scope into every batch draft.
            if (try? InvoiceBuilder.createDraft(
                for: client, lineItems: items, project: project,
                scopeOfWork: trimmedScope, notes: notes.isEmpty ? nil : notes,
                profile: profile, context: modelContext
            )) != nil { created += 1 }
        }
        invoiceAllResult = created
    }

    // MARK: – Save recurrence

    @MainActor
    private func saveRecurrence() async {
        guard let client = selectedClient else { return }
        savingRecurrence = true
        defer { savingRecurrence = false }

        // Just-in-time permission ask
        let scheduler = Scheduler(
            center: UNUserNotificationCenter.current(),
            modelContext: modelContext
        )
        let status = await scheduler.currentAuthorizationStatus()
        switch status {
        case .notDetermined:
            let granted = (try? await scheduler.requestAuthorization()) ?? false
            if !granted {
                permissionDeniedAlert = true
                return
            }
        case .denied:
            permissionDeniedAlert = true
            return
        default:
            break
        }

        let cadence: RecurrenceCadence = switch recurrenceCadenceKind {
        case .monthly:  .monthly(dayOfMonth: recurrenceDayOfMonth)
        case .weekly:   .weekly(weekday: recurrenceWeekday)
        case .biweekly: .biweekly(weekday: recurrenceWeekday)
        }
        let nextFire = RecurrenceService.computeNextFireDate(
            cadence: cadence,
            after: Date()
        )
        let template = RecurrenceTemplate(
            client: client,
            cadence: cadence,
            grouping: grouping,
            notesTemplate: (notes.isEmpty ? nil : notes),
            nextFireDate: nextFire,
            endDate: recurrenceEndDate
        )
        modelContext.insert(template)
        do {
            try modelContext.save()
        } catch {
            // Item 3: roll back the insertion, log, and surface the failure to the user
            // via saveErrorAlert instead of silently returning.
            modelContext.rollback()
            Logger(subsystem: "com.eldenstudios.billable", category: "InvoiceGenerator")
                .error("Failed to save recurrence template: \(error.localizedDescription, privacy: .public)")
            saveErrorAlert = true
            return
        }

        // Schedule the first iOS notification for this template.
        try? await RecurrenceScheduling.scheduleNext(for: template, scheduler: scheduler)

        dismiss()
    }
}

