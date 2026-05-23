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
            case .outstanding: "Outstanding"
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
        case pendingMaterializations
    }

    @State private var filter: Filter = .outstanding
    @State private var showingGenerator = false
    @State private var showingPaywall = false
    private var subscriptions = SubscriptionManager.shared

    var body: some View {
        NavigationStack {
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
            .sheet(isPresented: $showingPaywall) {
                PaywallView(trigger: .createInvoice)
            }
            .navigationDestination(for: NavigationTarget.self) { target in
                switch target {
                case .detail(let invoiceID):
                    InvoiceDetailDestinationLoader(invoiceID: invoiceID)
                case .preview(let invoiceID):
                    InvoicePreviewDestinationLoader(invoiceID: invoiceID)
                case .recurrenceEditor:
                    // Placeholder — Task 3.5 will replace with RecurrenceEditorView(template:)
                    Text("Recurrence editor (Task 3.5)")
                case .pendingMaterializations:
                    // Placeholder — Task 3.6 will replace with a list view.
                    Text("Pending materializations (Task 3.6)")
                }
            }
        }
    }

    private func startNewInvoice() {
        if subscriptions.isPro {
            showingGenerator = true
        } else {
            showingPaywall = true
        }
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
                ContentUnavailableView(
                    "No recurring schedules",
                    systemImage: "arrow.triangle.2.circlepath",
                    description: Text("Set up monthly billing for a retainer client from the New Invoice screen.")
                )
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
            return invoices.filter { $0.status == .sent }
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
        let descriptor = FetchDescriptor<Invoice>(predicate: #Predicate { $0.uuid == invoiceID })
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
        let descriptor = FetchDescriptor<Invoice>(predicate: #Predicate { $0.uuid == invoiceID })
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
