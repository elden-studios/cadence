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
    let lineItems: [InvoiceLineItem]
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
        self.lineItems = lineItems
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
        return InvoiceTemplateData(
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
            try? modelContext.save()
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
