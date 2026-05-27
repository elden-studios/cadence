import SwiftUI
import SwiftData
import PDFKit
import StoreKit
import UserNotifications
import MessageUI
import BillableCore

struct InvoiceDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.requestReview) private var requestReview

    @Bindable var invoice: Invoice

    @State private var showingShare = false
    @State private var showingDeleteConfirm = false
    @State private var pendingMailSubject: String = ""
    @State private var pendingMailBody: String = ""
    @State private var pendingMailRecipients: [String] = []
    @State private var pendingMailFireDate: Date?
    @State private var showingMailComposer = false
    @State private var mailComposerSubject = ""
    @State private var mailComposerBody = ""

    private var subscriptions: SubscriptionManager { SubscriptionManager.shared }

    private static let hasPromptedReviewKey = "billable.hasPromptedReview"

    // MARK: - Pending reminder step

    /// The first reminder fire date that has happened (<= now) but is NOT
    /// yet in `firedDates` — i.e., the step the user needs to act on. Returns
    /// nil if the invoice has no schedule, is not sent, or has no unfired past fires.
    private var pendingReminderStep: (offsetDays: Int, fireDate: Date)? {
        guard let schedule = invoice.reminderSchedule else { return nil }
        guard invoice.status == .sent else { return nil }
        let now = Date()
        for fire in schedule.fireDates where fire <= now {
            if !schedule.firedDates.contains(fire) {
                let days = Calendar.current.dateComponents([.day], from: invoice.dueAt, to: now).day ?? 0
                return (max(days, 0), fire)
            }
        }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                reminderBanner
                statusBanner
                pdfPreview
                actionButtons
                metadata
            }
            .padding()
        }
        .background(Color(.secondarySystemBackground))
        .navigationTitle(invoice.number)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showingShare = true
                    } label: {
                        Label("Share PDF", systemImage: "square.and.arrow.up")
                    }
                    if invoice.status != .draft {
                        Button {
                            presentEmailInvoice()
                        } label: {
                            Label("Email invoice", systemImage: "envelope")
                        }
                    }
                    if invoice.status == .sent {
                        Button {
                            sendReminder()
                        } label: {
                            Label("Send reminder email", systemImage: "envelope")
                        }
                    }
                    if invoice.status == .draft {
                        Button(role: .destructive) {
                            showingDeleteConfirm = true
                        } label: {
                            Label("Delete draft", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showingShare) {
            if let url = ensurePDFOnDisk() {
                ShareSheet(items: [url])
                    .ignoresSafeArea()
            }
        }
        .sheet(isPresented: $showingMailComposer) {
            MailComposerView(
                recipients: invoice.clientEmailSnapshot.map { [$0] } ?? [],
                subject: mailComposerSubject,
                body: mailComposerBody,
                attachmentData: ensurePDFData(),
                attachmentMimeType: "application/pdf",
                attachmentFilename: "\(invoice.number).pdf",
                onDismiss: { _ in /* no-op; iOS provides its own feedback */ }
            )
        }
        .confirmationDialog(
            "Delete draft \(invoice.number)?",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                modelContext.delete(invoice)
                modelContext.saveOrLog("delete invoice draft")
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Reminder banner

    @ViewBuilder
    private var reminderBanner: some View {
        if let step = pendingReminderStep {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(step.offsetDays) days overdue")
                        .font(.subheadline.weight(.semibold))
                    Text("Send a reminder to \(invoice.client?.name ?? invoice.clientNameSnapshot)?")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Send reminder") { composeReminder(for: step.fireDate) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(12)
            .background(Color.orange.opacity(0.12), in: .rect(cornerRadius: 12))
            .padding(.horizontal)
        }
    }

    // MARK: - Status banner

    @ViewBuilder
    private var statusBanner: some View {
        let pillBg: Color = {
            if invoice.isOverdue() { return .red }
            switch invoice.status {
            case .draft: return .gray
            case .sent:  return .blue
            case .paid:  return .green
            }
        }()
        let label: String = {
            if invoice.isOverdue() { return "OVERDUE" }
            switch invoice.status {
            case .draft: return "DRAFT"
            case .sent:  return "SENT"
            case .paid:  return "PAID"
            }
        }()
        HStack(spacing: 10) {
            Text(label)
                .font(.caption.weight(.bold))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(pillBg.opacity(0.18), in: .capsule)
                .foregroundStyle(pillBg)

            Text(invoice.total, format: .currency(code: invoice.currencyCodeSnapshot))
                .font(.title3.weight(.semibold))

            Spacer()

            if let paidAt = invoice.paidAt {
                Text("Paid \(paidAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if invoice.status == .sent {
                Text("Due \(invoice.dueAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(invoice.isOverdue() ? .red : .secondary)
            }
        }
    }

    // MARK: - PDF preview

    /// Template data for the live-render fallback (used when pdfDataCached is nil).
    private var liveTemplateData: InvoiceTemplateData {
        var data = InvoiceTemplateData.from(invoice)
        data.watermark = subscriptions.canRemoveWatermark ? nil : "Sent with Cadence"
        return data
    }

    private var pdfPreview: some View {
        Group {
            if let data = invoice.pdfDataCached, let doc = PDFDocument(data: data) {
                PDFKitView(document: doc)
                    .frame(height: 480)
                    .background(.white, in: .rect(cornerRadius: 8))
                    .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 4)
            } else {
                // Fallback to a live SwiftUI render if the cache is empty (older invoices).
                let templateData = liveTemplateData
                let scale = 0.6
                InvoiceTemplate(data: templateData, accent: invoice.clientColor.swiftUIColor)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(
                        width: InvoiceTemplate.pageWidth * scale,
                        height: InvoiceTemplate.pageHeight * scale,
                        alignment: .topLeading
                    )
                    .frame(maxWidth: .infinity, alignment: .center)
                    .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 4)
            }
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionButtons: some View {
        VStack(spacing: 10) {
            if invoice.status == .sent {
                Button {
                    markPaid()
                } label: {
                    Label("Mark as paid", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
            Button {
                showingShare = true
            } label: {
                Label("Share PDF", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)

            if invoice.status != .draft {
                Button {
                    presentEmailInvoice()
                } label: {
                    Label("Email invoice", systemImage: "envelope")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Metadata

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("Client", invoice.clientNameSnapshot)
            row("Issued", invoice.issuedAt.formatted(date: .abbreviated, time: .omitted))
            row("Due",    invoice.dueAt.formatted(date: .abbreviated, time: .omitted))
            row("Terms",  invoice.paymentTermsSnapshot)
            if let sentAt = invoice.sentAt {
                row("Sent", sentAt.formatted(date: .abbreviated, time: .shortened))
            }
        }
        .padding()
        .background(.thinMaterial, in: .rect(cornerRadius: 12))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.subheadline)
        }
    }

    // MARK: - Behavior

    private func markPaid() {
        try? invoice.markPaid()
        modelContext.saveOrLog("mark invoice paid")
        promptReviewIfFirstTime()
    }

    private func promptReviewIfFirstTime() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.hasPromptedReviewKey) else { return }
        defaults.set(true, forKey: Self.hasPromptedReviewKey)
        // The environment-driven `requestReview` is rate-limited by the system
        // and won't show in test environments, but we still gate on first-paid
        // to maximize the chance the system shows it during real use.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            requestReview()
        }
    }

    private func presentEmailInvoice() {
        var profileDescriptor = FetchDescriptor<BusinessProfile>()
        profileDescriptor.fetchLimit = 1
        let profile = (try? modelContext.fetch(profileDescriptor))?.first
        let senderName = profile?.name ?? ""

        let subjectTemplate = profile?.invoiceEmailSubjectTemplate ?? BusinessProfile.defaultInvoiceEmailSubject
        let bodyTemplate = profile?.invoiceEmailBodyTemplate ?? BusinessProfile.defaultInvoiceEmailBody

        let renderedSubject = ReminderTemplateRenderer.render(
            template: subjectTemplate,
            invoice: invoice,
            senderName: senderName
        )
        let renderedBody = ReminderTemplateRenderer.render(
            template: bodyTemplate,
            invoice: invoice,
            senderName: senderName
        )

        if MFMailComposeViewController.canSendMail() {
            mailComposerSubject = renderedSubject
            mailComposerBody = renderedBody
            showingMailComposer = true
        } else {
            // Graceful fallback: open user's default mail handler via mailto.
            // PDF attachment is lost in this path — better than a silent no-op.
            guard let email = invoice.clientEmailSnapshot,
                  !email.isEmpty,
                  let url = mailtoURL(to: email, subject: renderedSubject, body: renderedBody) else { return }
            UIApplication.shared.open(url)
        }
    }

    private func ensurePDFData() -> Data {
        // Mirror ensurePDFOnDisk()'s watermark + staleness logic — otherwise a
        // free-tier user who triggers the email path before any cache exists
        // would email a no-watermark PDF (paywall bypass).
        let shouldHaveWatermark = !subscriptions.canRemoveWatermark
        if let cached = invoice.pdfDataCached,
           !Self.cacheIsStale(cached, shouldHaveWatermark: shouldHaveWatermark) {
            return cached
        }
        var templateData = InvoiceTemplateData.from(invoice)
        templateData.watermark = subscriptions.canRemoveWatermark ? nil : "Sent with Cadence"
        let data = InvoicePDFRenderer.renderPDFData(
            for: templateData,
            accent: invoice.clientColor.swiftUIColor
        )
        invoice.pdfDataCached = data
        modelContext.saveOrLog("cache invoice pdf (email)")
        return data
    }

    private func sendReminder() {
        var configDescriptor = FetchDescriptor<ReminderConfig>()
        configDescriptor.fetchLimit = 1
        let config = (try? modelContext.fetch(configDescriptor))?.first
        var profileDescriptor = FetchDescriptor<BusinessProfile>()
        profileDescriptor.fetchLimit = 1
        let profile = (try? modelContext.fetch(profileDescriptor))?.first
        let senderName = profile?.name ?? ""

        let subjectTemplate = config?.subjectTemplate ?? ReminderConfig.defaultSubjectTemplate
        let bodyTemplate = config?.bodyTemplate ?? ReminderConfig.defaultBodyTemplate

        let subject = ReminderTemplateRenderer.render(
            template: subjectTemplate,
            invoice: invoice,
            senderName: senderName
        )
        let body = ReminderTemplateRenderer.render(
            template: bodyTemplate,
            invoice: invoice,
            senderName: senderName
        )

        guard let email = invoice.clientEmailSnapshot, !email.isEmpty,
              let url = mailtoURL(to: email, subject: subject, body: body) else { return }
        UIApplication.shared.open(url)
    }

    private func composeReminder(for fireDate: Date) {
        var configDescriptor = FetchDescriptor<ReminderConfig>()
        configDescriptor.fetchLimit = 1
        let configs = (try? modelContext.fetch(configDescriptor)) ?? []
        let config = configs.first
        var profileDescriptor = FetchDescriptor<BusinessProfile>()
        profileDescriptor.fetchLimit = 1
        let profiles = (try? modelContext.fetch(profileDescriptor)) ?? []
        let profile = profiles.first
        let senderName = profile?.name ?? ""

        let subjectTemplate = config?.subjectTemplate ?? ReminderConfig.defaultSubjectTemplate
        let bodyTemplate = config?.bodyTemplate ?? ReminderConfig.defaultBodyTemplate

        pendingMailSubject = ReminderTemplateRenderer.render(
            template: subjectTemplate,
            invoice: invoice,
            senderName: senderName,
            now: Date()
        )
        pendingMailBody = ReminderTemplateRenderer.render(
            template: bodyTemplate,
            invoice: invoice,
            senderName: senderName,
            now: Date()
        )
        pendingMailRecipients = [invoice.clientEmailSnapshot].compactMap { $0 }
        pendingMailFireDate = fireDate

        // Record fired BEFORE presenting so the step doesn't repeat even if the
        // user cancels — once we've offered to send, the step is considered acted on.
        let scheduler = Scheduler(
            center: UNUserNotificationCenter.current(),
            modelContext: modelContext
        )
        let service = ReminderService(scheduler: scheduler, modelContext: modelContext)
        service.recordFired(invoice: invoice, at: fireDate)

        let recipient = pendingMailRecipients.first ?? ""
        guard let url = mailtoURL(to: recipient, subject: pendingMailSubject, body: pendingMailBody) else { return }
        UIApplication.shared.open(url)
    }

    private func mailtoURL(to: String, subject: String, body: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = to
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body),
        ]
        return components.url
    }

    private func ensurePDFOnDisk() -> URL? {
        let bytes: Data
        let shouldHaveWatermark = !subscriptions.canRemoveWatermark
        if let cached = invoice.pdfDataCached,
           !Self.cacheIsStale(cached, shouldHaveWatermark: shouldHaveWatermark) {
            bytes = cached
        } else {
            var templateData = InvoiceTemplateData.from(invoice)
            templateData.watermark = subscriptions.canRemoveWatermark ? nil : "Sent with Cadence"
            bytes = InvoicePDFRenderer.renderPDFData(
                for: templateData,
                accent: invoice.clientColor.swiftUIColor
            )
            invoice.pdfDataCached = bytes
            modelContext.saveOrLog("cache invoice pdf")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(invoice.number).pdf")
        try? bytes.write(to: url, options: .atomic)
        return url
    }

    /// Returns `true` when the cached PDF bytes' watermark state no longer matches
    /// the current entitlement, meaning the cache must be discarded and re-rendered.
    private static func cacheIsStale(_ data: Data, shouldHaveWatermark: Bool) -> Bool {
        guard let text = PDFDocument(data: data)?.string else { return false }
        let hasWatermark = text.contains("Sent with Cadence")
        return hasWatermark != shouldHaveWatermark
    }
}

/// PDFKit view bridge for displaying a rendered PDF inside SwiftUI.
private struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePage
        view.backgroundColor = .white
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        uiView.document = document
    }
}
