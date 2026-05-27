import Foundation
import SwiftData
import OSLog

/// Manages the per-invoice reminder lifecycle: scheduling fires when an
/// invoice transitions to `.sent`, recording when the user acts on a fire,
/// and canceling all remaining fires when the invoice transitions to `.paid`.
///
/// Unlike `RecurrenceService` (a namespace `enum` with static methods),
/// `ReminderService` is a `final class` because it holds references to
/// `Scheduler` and `ModelContext` for its lifetime.
@MainActor
public final class ReminderService {
    private let scheduler: Scheduler
    private let modelContext: ModelContext
    private let calendar: Calendar
    private let log = Logger(subsystem: "com.eldenstudios.billable", category: "ReminderService")

    public init(
        scheduler: Scheduler,
        modelContext: ModelContext,
        calendar: Calendar = .current
    ) {
        self.scheduler = scheduler
        self.modelContext = modelContext
        self.calendar = calendar
    }

    /// Compute fire dates from the resolved offsets, persist them, and register
    /// each with the Scheduler. No-op when:
    /// - `ReminderConfig.masterEnabled == false`
    /// - No `ReminderConfig` exists in the store
    /// - Effective offsets array is empty
    ///
    /// Called from `Invoice.markSent(at:)`'s `didMarkSentHook` (Task 5.4 wires
    /// this hook in `BillableApp.performStartupWiring()`).
    public func scheduleForInvoice(_ invoice: Invoice) async throws {
        var configDescriptor = FetchDescriptor<ReminderConfig>()
        configDescriptor.fetchLimit = 1
        let configs = try modelContext.fetch(configDescriptor)
        guard let config = configs.first, config.masterEnabled else {
            log.info("scheduleForInvoice(): master disabled or no config — no-op")
            return
        }

        // Per-client override > global default.
        let offsets: [Int] = invoice.client?.reminderOffsets ?? config.enabledOffsets
        guard !offsets.isEmpty else {
            log.info("scheduleForInvoice(): no offsets — no-op")
            return
        }

        // Compute fire dates at 8am local on each offset day from dueAt.
        let fireDates = offsets.compactMap { offset -> Date? in
            guard let plus = calendar.date(byAdding: .day, value: offset, to: invoice.dueAt) else {
                return nil
            }
            var comps = calendar.dateComponents([.year, .month, .day], from: plus)
            comps.hour = 8
            comps.minute = 0
            return calendar.date(from: comps)
        }
        .sorted()

        let schedule = InvoiceReminderSchedule(fireDates: fireDates, firedDates: [])
        schedule.invoice = invoice
        invoice.reminderSchedule = schedule
        modelContext.insert(schedule)
        try modelContext.save()

        // Build notification copy + register each fire with Scheduler.
        let clientName = invoice.client?.name ?? invoice.clientNameSnapshot
        let amountFormatter = NumberFormatter()
        amountFormatter.numberStyle = .currency
        amountFormatter.currencyCode = invoice.currencyCodeSnapshot
        let amount = amountFormatter.string(from: invoice.total as NSDecimalNumber) ?? ""

        for (i, fireAt) in fireDates.enumerated() {
            let offsetDays = offsets[i]
            let title = Self.notificationTitle(
                offsetDays: offsetDays,
                clientName: clientName,
                amount: amount,
                invoiceNumber: invoice.number
            )
            let body = Self.notificationBody(
                offsetDays: offsetDays,
                invoiceNumber: invoice.number
            )
            _ = try await scheduler.schedule(
                payload: .reminder(scheduleID: schedule.id),
                fireAt: fireAt,
                title: title,
                body: body
            )
        }

        log.info("scheduleForInvoice(): invoiceID=\(invoice.uuid.uuidString, privacy: .public) fires=\(fireDates.count, privacy: .public)")
    }

    // MARK: - Cancel

    /// Cancel all remaining iOS-side reminder fires for the invoice and delete
    /// the `InvoiceReminderSchedule` row. Idempotent — calling on an invoice
    /// without a schedule is a no-op (no throw, no side effect).
    ///
    /// Called from `Invoice.markPaid(at:)`'s `didMarkPaidHook` (Task 5.4 wires
    /// this hook in `BillableApp.performStartupWiring()`).
    public func cancelForInvoice(_ invoice: Invoice) async throws {
        guard let schedule = invoice.reminderSchedule else { return }
        let scheduleID = schedule.id

        // Find every ScheduledNotification row whose payload is this schedule
        // and cancel each via the Scheduler (which also removes the iOS-side
        // pending request).
        let descriptor = FetchDescriptor<ScheduledNotification>(
            predicate: #Predicate { row in
                row.payloadType == "reminder" && row.payloadID == scheduleID
            }
        )
        if let rows = try? modelContext.fetch(descriptor) {
            for row in rows {
                scheduler.cancel(id: row.id)
            }
        }

        invoice.reminderSchedule = nil
        modelContext.delete(schedule)
        try modelContext.save()
        log.info("cancelForInvoice(): invoiceID=\(invoice.uuid.uuidString, privacy: .public)")
    }

    // MARK: - Record fired

    /// Mark a single fire step as acted-on so it doesn't surface again in the
    /// in-app reminder banner. Idempotent — calling twice with the same
    /// `fireDate` is a no-op. No-op when invoice has no schedule.
    public func recordFired(invoice: Invoice, at fireDate: Date) {
        guard let schedule = invoice.reminderSchedule else { return }
        if !schedule.firedDates.contains(fireDate) {
            schedule.firedDates.append(fireDate)
            modelContext.saveOrLog("reminder recordFired")
        }
    }

    // MARK: - Notification copy

    /// Notification title text, escalating tone by offset bucket.
    /// See plan §6 "Notification copy" for the localization-ready table.
    static func notificationTitle(
        offsetDays: Int,
        clientName: String,
        amount: String,
        invoiceNumber: String
    ) -> String {
        switch offsetDays {
        case ...3:   return "\(clientName) owes you \(amount)"
        case 4...7:  return "Still waiting on \(clientName): \(amount)"
        case 8...14: return "\(invoiceNumber) is 2 weeks overdue"
        default:     return "\(invoiceNumber) is a month overdue"
        }
    }

    /// Notification body text, paired with the title above.
    static func notificationBody(
        offsetDays: Int,
        invoiceNumber: String
    ) -> String {
        switch offsetDays {
        case ...3:   return "\(invoiceNumber) is \(offsetDays) days overdue. Send a reminder?"
        case 4...7:  return "\(invoiceNumber) is now a week overdue."
        case 8...14: return "Time for a stronger nudge?"
        default:     return "Consider escalating or adding a late fee."
        }
    }
}
