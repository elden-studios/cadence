import SwiftUI
import SwiftData
import BillableCore

struct InvoicesView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Invoice.issuedAt, order: .reverse)
    private var invoices: [Invoice]

    enum Filter: String, CaseIterable {
        case outstanding, paid, drafts, recurring
        var label: String {
            switch self {
            case .outstanding: "Unpaid"
            case .paid:        "Paid"
            case .drafts:      "Drafts"
            case .recurring:   "Recurring"
            }
        }
    }

    enum NavigationTarget: Hashable {
        case detail(invoiceID: UUID)
        case preview(invoiceID: UUID)
        case recurrenceEditor(templateID: UUID)
    }

    /// When set by `RootView` (e.g., after a reminder notification tap), the view
    /// pushes this destination onto its navigation stack and clears the binding.
    @Binding var pendingPushTarget: NavigationTarget?

    @State private var path: [NavigationTarget] = []
    @State private var filter: Filter = .outstanding
    @State private var showingGenerator = false
    private var subscriptions = SubscriptionManager.shared

    /// Convenience initialiser for call sites that don't supply an external push target
    /// (e.g., direct tab renders, previews).
    init(pendingPushTarget: Binding<NavigationTarget?> = .constant(nil)) {
        self._pendingPushTarget = pendingPushTarget
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if invoices.isEmpty {
                    emptyState
                } else {
                    listContent
                }
            }
            .navigationTitle("Invoices")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        startNewInvoice()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New invoice")
                }
            }
            .sheet(isPresented: $showingGenerator) {
                InvoiceGeneratorView()
            }
            .navigationDestination(for: NavigationTarget.self) { target in
                switch target {
                case .detail(let invoiceID):
                    InvoiceDetailDestinationLoader(invoiceID: invoiceID)
                case .preview(let invoiceID):
                    InvoicePreviewDestinationLoader(invoiceID: invoiceID)
                case .recurrenceEditor(let templateID):
                    RecurrenceEditorDestinationLoader(templateID: templateID)
                }
            }
            .onChange(of: pendingPushTarget) { _, newValue in
                guard let target = newValue else { return }
                path.append(target)
                pendingPushTarget = nil  // consume so the binding resets for the next tap
            }
        }
    }

    private func startNewInvoice() {
        showingGenerator = true
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No invoices yet", systemImage: "doc.text")
        } description: {
            Text("Track some time, then create an invoice from this tab.")
        } actions: {
            Button {
                startNewInvoice()
            } label: {
                Label("New invoice", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var listContent: some View {
        VStack(spacing: 0) {
            Picker("Filter", selection: $filter) {
                ForEach(Filter.allCases, id: \.self) { f in
                    Text(f.label).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)

            if filter == .recurring {
                RecurringRulesView()
            } else {
                List(filteredInvoices) { invoice in
                    NavigationLink {
                        InvoiceDetailView(invoice: invoice)
                    } label: {
                        InvoiceRow(invoice: invoice)
                    }
                }
            }
        }
    }

    private var filteredInvoices: [Invoice] {
        switch filter {
        case .outstanding:
            return invoices
                .filter { $0.status == .sent }
                .sorted { lhs, rhs in
                    if lhs.isOverdue() != rhs.isOverdue() { return lhs.isOverdue() }  // overdue first
                    return lhs.issuedAt > rhs.issuedAt                                 // then newest
                }
        case .paid:
            return invoices.filter { $0.status == .paid }
        case .drafts:
            return invoices.filter { $0.status == .draft }
        case .recurring:
            return []
        }
    }
}

private struct InvoiceDetailDestinationLoader: View {
    @Environment(\.modelContext) private var modelContext
    let invoiceID: UUID
    var body: some View {
        if let invoice = fetch() {
            InvoiceDetailView(invoice: invoice)
        } else {
            ContentUnavailableView("Invoice not found", systemImage: "questionmark.folder")
        }
    }
    private func fetch() -> Invoice? {
        var descriptor = FetchDescriptor<Invoice>(predicate: #Predicate { $0.uuid == invoiceID })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }
}

private struct InvoicePreviewDestinationLoader: View {
    @Environment(\.modelContext) private var modelContext
    let invoiceID: UUID
    var body: some View {
        if let invoice = fetch() {
            // InvoicePreviewView is only available during invoice generation;
            // for persisted invoices, show the detail view instead.
            InvoiceDetailView(invoice: invoice)
        } else {
            ContentUnavailableView("Invoice not found", systemImage: "questionmark.folder")
        }
    }
    private func fetch() -> Invoice? {
        var descriptor = FetchDescriptor<Invoice>(predicate: #Predicate { $0.uuid == invoiceID })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }
}

private struct RecurrenceEditorDestinationLoader: View {
    @Environment(\.modelContext) private var modelContext
    let templateID: UUID
    var body: some View {
        if let template = fetch() {
            RecurrenceEditorView(template: template)
        } else {
            ContentUnavailableView("Schedule not found", systemImage: "questionmark.folder")
        }
    }
    private func fetch() -> RecurrenceTemplate? {
        var descriptor = FetchDescriptor<RecurrenceTemplate>(predicate: #Predicate { $0.id == templateID })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }
}

private struct InvoiceRow: View {
    let invoice: Invoice

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(invoice.number).font(.subheadline.weight(.semibold))
                Spacer()
                StatusPill(status: invoice.status, isOverdue: invoice.isOverdue())
            }
            HStack {
                Text(invoice.clientNameSnapshot)
                    .font(.body)
                Spacer()
                Text(invoice.total.formatted(.currency(code: invoice.currencyCodeSnapshot)))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(dateLabel)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var dateLabel: String {
        if let paidAt = invoice.paidAt {
            return "Paid \(paidAt.formatted(date: .abbreviated, time: .omitted))"
        }
        if invoice.status == .sent {
            return "Due \(invoice.dueAt.formatted(date: .abbreviated, time: .omitted))"
        }
        return "Created \(invoice.issuedAt.formatted(date: .abbreviated, time: .omitted))"
    }
}

private struct StatusPill: View {
    let status: InvoiceStatus
    let isOverdue: Bool

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.18), in: .capsule)
            .foregroundStyle(color)
    }

    private var label: String {
        if isOverdue { return "Overdue" }
        switch status {
        case .draft: return "Draft"
        case .sent:  return "Sent"
        case .paid:  return "Paid"
        }
    }

    private var color: Color {
        if isOverdue { return .red }
        switch status {
        case .draft: return .gray
        case .sent:  return .blue
        case .paid:  return .green
        }
    }
}
