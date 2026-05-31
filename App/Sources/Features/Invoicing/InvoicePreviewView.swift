import SwiftUI
import SwiftData
import MessageUI
import BillableCore

/// Final preview before sending. Renders the same `InvoiceTemplate` that will
/// be exported as a PDF. Lets the user adjust notes one last time, then
/// "Finalize & share" creates the persisted invoice, transitions it to Sent,
/// renders the PDF, and triggers the iOS share sheet.
struct InvoicePreviewView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let client: Client
    let project: Project?
    let scopeOfWork: String?
    let profile: BusinessProfile
    @State private var lineItems: [InvoiceLineItem]
    @State private var pendingDescriptionEdits: [UUID: String] = [:]
    let sourceEntries: [TimeEntry]
    @State private var notes: String?
    let onDone: () -> Void

    @State private var pdfData: Data?
    @State private var showingShare = false
    @State private var finalized: Invoice?
    @State private var draft: Invoice?          // created on first finalize tap; finalized only on delivery success
    @State private var isFinalizing = false     // synchronous re-entrancy guard
    @State private var finalizeError = false    // local error surface (Phase 4 unifies)
    @State private var showingRemoveWatermarkPaywall = false
    @State private var showingMailComposer = false
    @State private var mailComposerSubject = ""
    @State private var mailComposerBody = ""
    // Captured at finalize time so the sheet content builder doesn't need to
    // dereference draft.pdfDataCached (which the defensive `?? Data()` fallback
    // hid — could ship a 0-byte attachment on a SwiftData fault).
    @State private var mailComposerAttachment: Data?
    @State private var mailComposerRecipients: [String] = []
    @State private var showingNoClientEmailAlert = false

    private var subscriptions: SubscriptionManager { SubscriptionManager.shared }

    init(
        client: Client,
        project: Project? = nil,
        profile: BusinessProfile,
        lineItems: [InvoiceLineItem],
        sourceEntries: [TimeEntry],
        scopeOfWork: String? = nil,
        notes: String?,
        onDone: @escaping () -> Void
    ) {
        self.client = client
        self.project = project
        self.scopeOfWork = scopeOfWork
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
        data.projectName = project?.name
        data.scopeOfWork = scopeOfWork
        data.projectColorRaw = project?.client?.colorRaw
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
                        finalizeAndEmail()
                    } label: {
                        Label("Finalize & email", systemImage: "envelope.fill")
                    }
                    .bold()
                    // `finalized != nil` is the actual debouncer for double-taps —
                    // the in-function `guard finalized == nil` is belt-and-suspenders.
                    // The pair closes the race window between guard check and
                    // `finalized = draft` assignment (multi-touch / accessibility /
                    // multiple gesture recognizers can otherwise fire two calls in
                    // the same run-loop frame).
                    .disabled(hasInvalidDescriptions || finalized != nil)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            finalizeAndShare()
                        } label: {
                            Label("Finalize & share", systemImage: "square.and.arrow.up")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    // Same defense as the primary button — and same UX
                    // consistency: only the outer ToolbarItem disables (not the
                    // inner Button) so the ellipsis isn't a tappable affordance
                    // that opens a menu of disabled items.
                    .disabled(hasInvalidDescriptions || finalized != nil)
                }
            }
            .sheet(isPresented: $showingShare, onDismiss: {
                // CRITICAL: dismiss the preview when the share sheet closes,
                // regardless of what was inside. Previously this lived as
                // `.onDisappear` on the inner ShareSheet — but that's inside
                // the `if let pdfData, let url = writeToTemp(...)` conditional.
                // If writeToTemp returned nil (disk full, sandbox issue),
                // the sheet rendered empty, user swiped to dismiss, but
                // .onDisappear never registered → user stranded on the
                // preview with a finalized invoice underneath, no way out.
                // The `onDismiss:` parameter of .sheet(isPresented:onDismiss:content:)
                // fires reliably regardless of content state.
                dismiss()
                onDone()
            }) {
                if let pdfData,
                   let url = writeToTemp(pdfData, suggestedName: templateData.invoiceNumber) {
                    ShareSheet(items: [url], onComplete: { completed in
                        if completed, let theDraft = draft { commitFinalize(theDraft) }
                    })
                    .ignoresSafeArea()
                }
                // If writeToTemp returned nil, content is empty. The user
                // sees a blank sheet briefly, swipes down, and the onDismiss
                // above runs — they land at the parent cleanly. Not ideal
                // UX but deterministic and recoverable.
            }
            .sheet(isPresented: $showingMailComposer) {
                // Only present when we have something real to attach. Replaces
                // the previous `?? Data()` fallback which would silently send a
                // 0-byte PDF if the cache read returned nil.
                if let theDraft = draft, let attachment = mailComposerAttachment {
                    MailComposerView(
                        recipients: mailComposerRecipients,
                        subject: mailComposerSubject,
                        body: mailComposerBody,
                        attachmentData: attachment,
                        attachmentMimeType: "application/pdf",
                        attachmentFilename: "\(theDraft.number).pdf",
                        onDismiss: { result in
                            showingMailComposer = false
                            mailComposerAttachment = nil
                            mailComposerRecipients = []
                            // Finalize + leave the preview ONLY on a real send. On
                            // .cancelled / .failed / .saved (saved = an unsent draft
                            // email sitting in Mail), stay on the preview with the
                            // reusable draft intact so the user can retry — nothing is
                            // marked Sent and the user isn't ejected from the preview.
                            if result == .sent {
                                if let theDraft = draft { commitFinalize(theDraft) }
                                dismiss()
                                onDone()
                            }
                        }
                    )
                }
            }
            .alert("Add a client email first",
                   isPresented: $showingNoClientEmailAlert,
                   actions: { Button("OK", role: .cancel) {} },
                   message: {
                Text("This client doesn't have an email on file. Add one in the client's details to send invoices by email.")
            })
            .alert("Couldn't finalize the invoice", isPresented: $finalizeError, actions: {
                Button("OK", role: .cancel) {}
            }, message: { Text("Something went wrong creating or sending this invoice. Your tracked time was not changed — try again.") })
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

    /// Create the draft once (preview number, NOT consumed) and render its PDF.
    /// Returns nil on render failure. Reused across retries so no second draft.
    private func ensureDraftAndPDF() -> (draft: Invoice, pdf: Data)? {
        flushPendingDescriptionEdits()
        let theDraft: Invoice
        if let existing = draft {
            theDraft = existing
        } else {
            do {
                theDraft = try InvoiceBuilder.createDraft(
                    for: client, lineItems: lineItems, project: project,
                    scopeOfWork: scopeOfWork, notes: notes, profile: profile, context: modelContext
                )
                draft = theDraft
            } catch { return nil }
        }
        let data = InvoicePDFRenderer.renderPDFData(
            for: .from(theDraft, watermarked: !subscriptions.canRemoveWatermark),
            accent: theDraft.clientColor.swiftUIColor
        )
        guard !data.isEmpty else { return nil }
        theDraft.pdfDataCached = data
        modelContext.saveOrLog("cache invoice pdf (preview)")
        return (theDraft, data)
    }

    /// Finalize the draft (consume number, Draft->Sent, stamp entries) — called
    /// ONLY after delivery is confirmed.
    private func commitFinalize(_ theDraft: Invoice) {
        guard finalized == nil else { return }
        do {
            try InvoiceBuilder.finalizeAndSend(theDraft, sourceEntries: sourceEntries, profile: profile, context: modelContext)
            finalized = theDraft
        } catch {
            finalizeError = true
        }
    }

    private func finalizeAndEmail() {
        guard !isFinalizing, finalized == nil else { return }
        guard let recipient = client.email, !recipient.isEmpty else {
            showingNoClientEmailAlert = true
            return
        }
        isFinalizing = true
        defer { isFinalizing = false }
        guard let (theDraft, data) = ensureDraftAndPDF() else { finalizeError = true; return }
        pdfData = data

        let senderName = profile.name
        let subject = ReminderTemplateRenderer.render(template: profile.effectiveInvoiceEmailSubjectTemplate, invoice: theDraft, senderName: senderName)
        let body = ReminderTemplateRenderer.render(template: profile.effectiveInvoiceEmailBodyTemplate, invoice: theDraft, senderName: senderName)

        if MFMailComposeViewController.canSendMail() {
            mailComposerRecipients = [recipient]
            mailComposerSubject = subject
            mailComposerBody = body
            mailComposerAttachment = data
            showingMailComposer = true   // finalize happens in onDismiss when result == .sent
        } else if let url = mailtoURLFromComponents(to: recipient, subject: subject, body: body) {
            UIApplication.shared.open(url)
            commitFinalize(theDraft)
            dismiss(); onDone()
        } else {
            showingShare = true          // last-resort: finalize on share completion
        }
    }

    private func mailtoURLFromComponents(to: String, subject: String, body: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = to
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body)
        ]
        return components.url
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
        guard !isFinalizing, finalized == nil else { return }
        isFinalizing = true
        defer { isFinalizing = false }
        guard let (_, data) = ensureDraftAndPDF() else { finalizeError = true; return }
        pdfData = data
        showingShare = true              // finalize happens in ShareSheet completion
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
    var onComplete: ((Bool) -> Void)? = nil
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.completionWithItemsHandler = { _, completed, _, _ in onComplete?(completed) }
        return vc
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
