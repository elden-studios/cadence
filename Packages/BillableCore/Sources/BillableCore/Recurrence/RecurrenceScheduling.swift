import Foundation
import SwiftData
import OSLog

/// Bridges `RecurrenceTemplate` lifecycle events to `Scheduler.schedule`/`cancel`.
/// Lives separately from `RecurrenceService` (which owns the materialization
/// logic) so the schedule-side wiring is testable in isolation.
@MainActor
public enum RecurrenceScheduling {
    private static let log = Logger(subsystem: "com.eldenstudios.billable", category: "RecurrenceScheduling")

    /// Build the notification title for a recurrence fire.
    /// Format: "{clientName}'s {monthYear} invoice is ready to send"
    /// Falls back gracefully when client is nil.
    public static func notificationTitle(
        for template: RecurrenceTemplate,
        calendar: Calendar = .current
    ) -> String {
        let clientName = template.client?.name ?? "Client"
        // Use the rangeRule to label the period — for monthly, the period
        // ENDING the day before nextFireDate (so a Jun 1 fire is about May).
        let range = template.rangeRuleValue.resolve(
            from: template.nextFireDate, calendar: calendar
        )
        let monthFormatter = DateFormatter()
        monthFormatter.calendar = calendar
        monthFormatter.dateFormat = "LLLL"
        let month = monthFormatter.string(from: range.start)
        return "\(clientName)'s \(month) invoice is ready to send"
    }

    public static let notificationBody = "Tap to review and send."

    /// Schedule the next iOS notification for this template (at template.nextFireDate).
    /// Called when a template is created, resumed (isActive flips true), or
    /// materialized (next cycle scheduled).
    /// No-op when template.isActive == false or template has ended.
    public static func scheduleNext(
        for template: RecurrenceTemplate,
        scheduler: Scheduler,
        calendar: Calendar = .current
    ) async throws {
        guard template.isActive, !template.isEnded() else {
            log.info("scheduleNext(): inactive or ended, skipping")
            return
        }
        let title = notificationTitle(for: template, calendar: calendar)
        _ = try await scheduler.schedule(
            payload: .recurrence(templateID: template.id),
            fireAt: template.nextFireDate,
            title: title,
            body: notificationBody
        )
        log.info("scheduleNext(): templateID=\(template.id.uuidString, privacy: .public) fireAt=\(template.nextFireDate, privacy: .public)")
    }

    /// Cancel ALL pending iOS notifications for this template (typically just one — the next pending fire).
    /// Called when template is paused, deleted, or about to be re-scheduled with a new nextFireDate.
    public static func cancelAll(
        for template: RecurrenceTemplate,
        scheduler: Scheduler,
        modelContext: ModelContext
    ) {
        let templateID = template.id
        let descriptor = FetchDescriptor<ScheduledNotification>(
            predicate: #Predicate { row in
                row.payloadType == "recurrence" && row.payloadID == templateID
            }
        )
        guard let rows = try? modelContext.fetch(descriptor) else { return }
        for row in rows {
            scheduler.cancel(id: row.id)
        }
        log.info("cancelAll(): templateID=\(template.id.uuidString, privacy: .public) cleared=\(rows.count, privacy: .public)")
    }
}
