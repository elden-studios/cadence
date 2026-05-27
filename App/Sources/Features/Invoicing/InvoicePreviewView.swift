import SwiftUI
import SwiftData
import BillableCore

/// Final preview before sending. Renders the same `InvoiceTemplate` that will
/// be exported as a PDF. Lets the user adjust notes one last time, then
/// "Finalize & share" creates the persisted invoice, transitions it to Sent,
/// renders the PDF, and triggers the iOS share sheet.
struct InvoicePreviewView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let client: Client
    let profile: BusinessProfile
    @State private var lineItems: [InvoiceLineItem]
    @State private var pendingDescriptionEdits: [UUID: String] = [:]
    let sourceEntries: [TimeEntry]
    @State private var notes: String?
    let onDone: () -> Void

    @State private var pdfData: Data?
    @State private var showingShare = false
    @State private var finalized: Invoice?
    @State private var showingRemoveWatermarkPaywall = false

    private var subscriptions: SubscriptionManager { SubscriptionManager.shared }

    init(
        client: Client,
        profile: BusinessProfile,
        lineItems: [InvoiceLineItem],
        sourceEntries: [TimeEntry],
        notes: String?,
        onDone: @escaping () -> Void
    ) {
        self.client = client
        self.profile = profile
        _lineItems = State(initialValue: lineItems)
        self.sourceEntries = sourceEntries
        _notes = State(initialValue: notes)
        self.onDone = onDone
    }

    private var templateData: InvoiceTemplateData {
        let now = Date.now
        let dueAt = Calendar.current.date(byAdding: .day, value: profile.defaultDueAfterDays, to: now) ?? now

        let subtotal = lineItems.reduce(into: Decimal(0)) { $0 += $1.amount }
        let taxAmount = subtotal * profile.taxRate
        let total = subtotal + taxAmount

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        var data = InvoiceTemplateData(
            issuerName: profile.name,
            issuerAddress: profile.address,
            issuerEmail: profile.email,
            issuerLogo: profile.logoData,
            clientName: client.name,
            clientAddress: client.address,
            clientEmail: client.email,
            invoiceNumber: finalized?.number ?? profile.previewNextInvoiceNumber,
            issuedDateLabel: formatter.string(from: now),
            dueDateLabel: formatter.string(from: dueAt),
            paymentTerms: profile.paymentTerms,
            lineItems: lineItems,
            notes: notes,
            subtotal: subtotal,
            taxLabel: profile.taxLabel,
            taxRate: profile.taxRate,
            taxAmount: taxAmount,
            total: total,
            currencyCode: profile.currencyCode,
            watermark: subscriptions.canRemoveWatermark ? nil : "Sent with Cadence"
        )
        data.bankBeneficiaryName = profile.bankBeneficiaryName
        data.bankName = profile.bankName
        data.bankLocation = profile.bankLocation
        data.bankIBAN = profile.bankIBAN
        data.bankSWIFT = profile.bankSWIFT
        data.taxIDLabel = profile.taxIDLabel
        data.taxIDNumber = profile.taxIDNumber
        return data
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !subscriptions.canRemoveWatermark {
                        Button {
                            showingRemoveWatermarkPaywall = true
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("This invoice has a watermark.")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text("Remove watermark with Pro →")
                                        .font(.caption)
                                        .foregroundStyle(.tint)
                                }
                                Spacer()
                            }
                            .padding(12)
                            .background(.orange.opacity(0.12), in: .rect(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal)
                    }
                    lineItemsEditor
                    pdfPreviewCard
                    notesEditor
                }
                .padding()
            }
            .background(Color(.secondarySystemBackground))
            .navigationTitle("Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Back") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        finalizeAndShare()
                    } label: {
                        Label("Finalize & share", systemImage: "paperplane.fill")
                    }
                    .bold()
                    .disabled(hasInvalidDescriptions)
                }
            }
            .sheet(isPresented: $showingShare) {
                if let pdfData,
                   let url = writeToTemp(pdfData, suggestedName: templateData.invoiceNumber) {
                    ShareSheet(items: [url])
                        .ignoresSafeArea()
                        .onDisappear {
                            dismiss()
                            onDone()
                        }
                }
            }
            .sheet(isPresented: $showingRemoveWatermarkPaywall) {
                PaywallView(trigger: .removeWatermark)
            }
        }
    }

    // MARK: - Preview card

    private var pdfPreviewCard: some View {
        GeometryReader { proxy in
            let scale = min(1, proxy.size.width / InvoiceTemplate.pageWidth)
            ZStack(alignment: .topLeading) {
                InvoiceTemplate(data: templateData, accent: client.color.swiftUIColor)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(
                        width: InvoiceTemplate.pageWidth * scale,
                        height: InvoiceTemplate.pageHeight * scale,
                        alignment: .topLeading
                    )
            }
            .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 4)
        }
        .aspectRatio(InvoiceTemplate.pageWidth / InvoiceTemplate.pageHeight, contentMode: .fit)
    }

    // MARK: - Line items editor (A8)

    private var lineItemsEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LINE ITEMS")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(lineItems.enumerated()), id: \.element.id) { index, item in
                lineItemRow(index: index, item: item)
            }
        }
        // 200ms debounce: flushes pending edits into the lineItems @State so the
        // PDF preview only re-renders when the user pauses typing. Validation
        // (red border, disabled Finalize) stays real-time because both read
        // from pendingDescriptionEdits ?? lineItems via currentDescription(at:).
        .task(id: pendingDescriptionEdits) {
            guard !pendingDescriptionEdits.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            flushPendingDescriptionEdits()
        }
    }

    @ViewBuilder
    private func lineItemRow(index: Int, item: InvoiceLineItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Description", text: descriptionBinding(at: index), axis: .vertical)
                .lineLimit(1...3)
                .textInputAutocapitalization(.sentences)
            HStack(spacing: 8) {
                Text(formatLineItemHours(item.hours)).foregroundStyle(.secondary)
                Text("·").foregroundStyle(.tertiary)
                Text(formatLineItemMoney(item.hourlyRate)).foregroundStyle(.secondary)
                Spacer()
                Text(formatLineItemMoney(item.amount)).fontWeight(.medium)
            }
            .font(.caption)
        }
        .padding(10)
        .background(.background, in: .rect(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isDescriptionEmpty(at: index)
                        ? AnyShapeStyle(Color.red.opacity(0.6))
                        : AnyShapeStyle(.quaternary),
                    lineWidth: 1
                )
        )
    }

    private func descriptionBinding(at index: Int) -> Binding<String> {
        Binding(
            get: {
                pendingDescriptionEdits[lineItems[index].id] ?? lineItems[index].description
            },
            set: { newValue in
                pendingDescriptionEdits[lineItems[index].id] = newValue
            }
        )
    }

    private func currentDescription(at index: Int) -> String {
        pendingDescriptionEdits[lineItems[index].id] ?? lineItems[index].description
    }

    private func isDescriptionEmpty(at index: Int) -> Bool {
        currentDescription(at: index).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasInvalidDescriptions: Bool {
        lineItems.indices.contains { isDescriptionEmpty(at: $0) }
    }

    private func flushPendingDescriptionEdits() {
        guard !pendingDescriptionEdits.isEmpty else { return }
        var updated = lineItems
        for (id, text) in pendingDescriptionEdits {
            if let i = updated.firstIndex(where: { $0.id == id }) {
                updated[i].description = text
            }
        }
        lineItems = updated
        pendingDescriptionEdits = [:]
    }

    private func formatLineItemHours(_ value: Decimal) -> String {
        let s = value.formatted(.number.precision(.fractionLength(0...2)))
        return s + "h"
    }

    private func formatLineItemMoney(_ value: Decimal) -> String {
        value.formatted(.currency(code: profile.currencyCode))
    }

    private var notesEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NOTES")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("Add a note to your client", text: Binding(
                get: { notes ?? "" },
                set: { notes = $0.isEmpty ? nil : $0 }
            ), axis: .vertical)
            .lineLimit(2...6)
            .padding(10)
            .background(.background, in: .rect(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(.quaternary, lineWidth: 1)
            )
        }
    }

    // MARK: - Actions

    private func finalizeAndShare() {
        // Drain any pending in-flight edits before snapshotting. Closes a race
        // where a user taps Finalize within the 200ms debounce window — without
        // this drain, the pre-edit description would be persisted instead of
        // the user's last keystrokes.
        flushPendingDescriptionEdits()
        do {
            let draft = try InvoiceBuilder.createDraft(
                for: client,
                lineItems: lineItems,
                notes: notes,
                profile: profile,
                context: modelContext
            )
            try InvoiceBuilder.finalizeAndSend(
                draft,
                sourceEntries: sourceEntries,
                profile: profile,
                context: modelContext
            )
            let data = InvoicePDFRenderer.renderPDFData(
                for: InvoiceTemplateData.from(draft),
                accent: draft.clientColor.swiftUIColor
            )
            draft.pdfDataCached = data
            modelContext.saveOrLog("cache invoice pdf")
            finalized = draft
            pdfData = data
            showingShare = true
        } catch {
            // Step 5 will add error toasts; for now just dismiss silently on failure.
        }
    }

    private func writeToTemp(_ data: Data, suggestedName: String) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(suggestedName).pdf")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

/// UIKit share sheet bridge.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
