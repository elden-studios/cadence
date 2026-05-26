import SwiftUI
import SwiftData
import UIKit
import UserNotifications
import BillableCore

struct PaymentRemindersView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var configs: [ReminderConfig]
    @Query private var profiles: [BusinessProfile]

    private var currencyCode: String {
        profiles.first?.currencyCode ?? "USD"
    }

    // Computed accessor — ensures a singleton exists by creating one
    // lazily if needed. Subsequent reads return the same instance.
    private var config: ReminderConfig {
        if let existing = configs.first { return existing }
        let new = ReminderConfig.defaultConfig()
        modelContext.insert(new)
        modelContext.saveOrLog("create reminder config")
        return new
    }

    // Local UI state mirrored from `config` so the form binds cleanly.
    @State private var enabledSet: Set<Int> = []
    @State private var subject: String = ""
    @State private var bodyText: String = ""
    @State private var masterEnabled: Bool = false
    @State private var permissionDenied: Bool = false
    @State private var saveError: String?

    /// The fixed offset chip set. v1.1 offers 3/7/14/30; user toggles
    /// which subset is enabled.
    private let allOffsets: [Int] = [3, 7, 14, 30]

    var body: some View {
        Form {
            masterSection
            offsetsSection
            templatesSection
            if let saveError {
                Section {
                    Text(saveError).foregroundStyle(.red)
                }
            }
            previewSection
        }
        .navigationTitle("Payment reminders")
        .onAppear { syncFromConfig() }
    }

    // MARK: - Sections

    private var masterSection: some View {
        Section {
            Toggle("Send reminders for overdue invoices", isOn: $masterEnabled)
                .onChange(of: masterEnabled) { _, newValue in
                    if newValue { Task { await requestPermissionIfNeeded() } }
                    config.masterEnabled = newValue
                    persist()
                }
            if permissionDenied {
                Label("Notifications are off — reminders won't fire.",
                      systemImage: "bell.slash")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
        } header: { Text("Reminders") }
    }

    private var offsetsSection: some View {
        Section {
            ForEach(allOffsets, id: \.self) { offset in
                Toggle("After \(offset) days overdue", isOn: Binding(
                    get: { enabledSet.contains(offset) },
                    set: { isOn in
                        if isOn { enabledSet.insert(offset) } else { enabledSet.remove(offset) }
                        config.enabledOffsets = enabledSet.sorted()
                        persist()
                    }
                ))
                .disabled(!masterEnabled)
            }
        } header: { Text("When to send") }
    }

    private var templatesSection: some View {
        Section {
            TextField("Subject", text: $subject)
                .onChange(of: subject) { _, v in
                    config.subjectTemplate = v
                    persist()
                }
                .disabled(!masterEnabled)
            TextEditor(text: $bodyText)
                .frame(minHeight: 160)
                .onChange(of: bodyText) { _, v in
                    config.bodyTemplate = v
                    persist()
                }
                .disabled(!masterEnabled)
            Text("Merge fields: {clientName} {clientFirstName} {invoiceNumber} {amount} {dueDate} {daysOverdue} {senderName}")
                .font(.caption2).foregroundStyle(.tertiary)
        } header: { Text("Email template") }
    }

    // MARK: - Preview

    /// Synthetic Invoice + Client used for the preview render. Not inserted into
    /// any ModelContext — just a value snapshot for ReminderTemplateRenderer.
    private static func makePreviewInvoice(currencyCode: String) -> Invoice {
        let sampleClient = Client(
            name: "Acme Corp",
            color: .blue,
            contactName: "Pat Doe",
            email: "pat@acme.example"
        )
        let dueAt = Date().addingTimeInterval(-86400 * 3)  // 3 days ago
        let invoice = Invoice(
            number: "INV-0042",
            dueAt: dueAt,
            clientNameSnapshot: "Acme Corp",
            issuerNameSnapshot: "Studio Lina",
            issuerAddressSnapshot: "",
            issuerEmailSnapshot: "hello@studio-lina.example",
            paymentTermsSnapshot: "Net 14",
            taxLabelSnapshot: "Tax",
            taxRateSnapshot: 0,
            currencyCodeSnapshot: currencyCode,
            lineItems: [
                InvoiceLineItem(description: "Sample work", hours: 12, hourlyRate: 100, sourceTimeEntryRef: nil)
            ],
            client: sampleClient
        )
        return invoice
    }

    private var previewSection: some View {
        let invoice = Self.makePreviewInvoice(currencyCode: currencyCode)
        let renderedSubject = ReminderTemplateRenderer.render(
            template: subject,
            invoice: invoice,
            senderName: "Studio Lina",
            now: Date()
        )
        let renderedBody = ReminderTemplateRenderer.render(
            template: bodyText,
            invoice: invoice,
            senderName: "Studio Lina",
            now: Date()
        )
        return Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Subject")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(renderedSubject)
                    .font(.body)
                Divider()
                Text("Body")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(renderedBody)
                    .font(.body)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 4)
        } header: {
            Text("Preview (sample invoice)")
        } footer: {
            Text("Rendered against a sample invoice (INV-0042, $1,200, 3 days overdue). Edits to the template above update this preview live.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - State sync

    private func syncFromConfig() {
        let c = config
        enabledSet = Set(c.enabledOffsets)
        subject = c.subjectTemplate
        bodyText = c.bodyTemplate
        masterEnabled = c.masterEnabled
        Task { await checkPermission() }
    }

    private func persist() {
        do {
            try modelContext.save()
            saveError = nil
        } catch {
            saveError = "Couldn't save: \(error.localizedDescription)"
        }
    }

    // MARK: - Permission flow

    @MainActor
    private func requestPermissionIfNeeded() async {
        let scheduler = Scheduler(
            center: UNUserNotificationCenter.current(),
            modelContext: modelContext
        )
        let status = await scheduler.currentAuthorizationStatus()
        switch status {
        case .notDetermined:
            let granted = (try? await scheduler.requestAuthorization()) ?? false
            if !granted {
                masterEnabled = false
                config.masterEnabled = false
                permissionDenied = true
                persist()
            } else {
                permissionDenied = false
            }
        case .denied:
            masterEnabled = false
            config.masterEnabled = false
            permissionDenied = true
            persist()
        default:
            permissionDenied = false
        }
    }

    @MainActor
    private func checkPermission() async {
        let scheduler = Scheduler(
            center: UNUserNotificationCenter.current(),
            modelContext: modelContext
        )
        let status = await scheduler.currentAuthorizationStatus()
        permissionDenied = (status == .denied)
    }
}
