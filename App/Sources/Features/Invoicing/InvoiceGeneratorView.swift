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
    @Query private var profiles: [BusinessProfile]

    @State private var selectedClient: Client?
    @State private var selectedProject: Project?
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
    @State private var permissionDeniedAlert = false
    @State private var invoiceAllResult: Int?

    init(defaultClient: Client? = nil) {
        _selectedClient = State(initialValue: defaultClient)
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
        selectedClient != nil && selectedProject != nil && profile != nil && !lineItems.isEmpty
            && Self.canSendInvoice(profile: profile)
    }

    private var saveDisabled: Bool {
        selectedClient == nil || profile == nil || savingRecurrence
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Client") {
                    clientPicker
                }

                Section("Project") {
                    if selectedClient != nil {
                        if activeProjects.isEmpty {
                            Text("This client has no active projects.").foregroundStyle(.secondary)
                        } else {
                            Picker("Project", selection: $selectedProject) {
                                Text("Choose").tag(Project?.none)
                                ForEach(activeProjects) { p in Text(p.name).tag(Project?.some(p)) }
                            }
                            if !projectsWithEligible.isEmpty {
                                Button { invoiceAllProjects() } label: {
                                    Label("Invoice all projects (separate drafts)", systemImage: "doc.on.doc")
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

                Section("Line items") {
                    Picker("Grouping", selection: $grouping) {
                        ForEach(LineItemGrouping.allCases) { g in
                            Text(g.label).tag(g)
                        }
                    }
                    .pickerStyle(.segmented)

                    if let client = selectedClient {
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
            .onChange(of: selectedProject) { _, _ in refreshEligibleEntries() }
            .onChange(of: selectedClient) { _, _ in refreshProjectsAndActive() }
            .onChange(of: preset) { _, _ in
                refreshEligibleEntries()
                refreshProjectsAndActive()
            }
            // Debounce the custom-date pickers: spinning the wheel emits a burst
            // of changes, and each refresh hits SwiftData on the main thread.
            .task(id: customStart) {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                refreshEligibleEntries()
                refreshProjectsAndActive()
            }
            .task(id: customEnd) {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                refreshEligibleEntries()
                refreshProjectsAndActive()
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
                Text("Created \(invoiceAllResult ?? 0) draft invoice(s) — one per project with billable time. Open each from Invoices to add a scope and send.")
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
                        selectedProject = nil
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

    /// Recompute the selected project's eligible entries. Depends on
    /// `selectedProject` and the resolved range only.
    @MainActor
    private func refreshEligibleEntries() {
        eligibleEntries = selectedProject.map {
            InvoiceBuilder.eligibleEntries(for: $0, in: resolvedRange, context: modelContext)
        } ?? []
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
            if (try? InvoiceBuilder.createDraft(
                for: client, lineItems: items, project: project,
                scopeOfWork: nil, notes: notes.isEmpty ? nil : notes,
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
            // Roll back the insertion + surface to the user. We don't have a generic
            // error-toast system yet, so reuse the existing permission alert mechanism
            // with a localised message. (v1.1 polish.)
            modelContext.rollback()
            permissionDeniedAlert = false
            // Stash the error; for v1.1 we just log via OSLog and bail without dismissing.
            Logger(subsystem: "com.eldenstudios.billable", category: "InvoiceGenerator")
                .error("Failed to save recurrence template: \(error.localizedDescription, privacy: .public)")
            return
        }

        // Schedule the first iOS notification for this template.
        try? await RecurrenceScheduling.scheduleNext(for: template, scheduler: scheduler)

        dismiss()
    }
}

