import SwiftUI
import SwiftData
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
    @State private var preset: InvoicePeriodPreset = .lastMonth
    @State private var customStart: Date = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
    @State private var customEnd: Date = .now
    @State private var grouping: LineItemGrouping = .perEntry
    @State private var notes: String = ""
    @State private var showingPreview = false

    init(defaultClient: Client? = nil) {
        _selectedClient = State(initialValue: defaultClient)
    }

    private var profile: BusinessProfile? { profiles.first }

    private var resolvedRange: InvoiceDateRange {
        if preset == .custom {
            return InvoiceDateRange(start: Calendar.current.startOfDay(for: customStart),
                                    end: Calendar.current.startOfDay(for: customEnd).addingTimeInterval(86_400))
        }
        return preset.range() ?? InvoiceDateRange(start: customStart, end: customEnd)
    }

    private var eligibleEntries: [TimeEntry] {
        guard let client = selectedClient else { return [] }
        return InvoiceBuilder.eligibleEntries(for: client, in: resolvedRange, context: modelContext)
    }

    private var lineItems: [InvoiceLineItem] {
        InvoiceBuilder.buildLineItems(from: eligibleEntries, grouping: grouping)
    }

    private var canPreview: Bool {
        selectedClient != nil && profile != nil && !lineItems.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Client") {
                    clientPicker
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

                if profile == nil {
                    Section {
                        Label("Set up your business profile first.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("New invoice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Preview") { showingPreview = true }
                        .bold()
                        .disabled(!canPreview)
                }
            }
            .sheet(isPresented: $showingPreview) {
                if let client = selectedClient, let profile {
                    InvoicePreviewView(
                        client: client,
                        profile: profile,
                        lineItems: lineItems,
                        sourceEntries: eligibleEntries,
                        notes: notes.isEmpty ? nil : notes,
                        onDone: { dismiss() }
                    )
                }
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
}
