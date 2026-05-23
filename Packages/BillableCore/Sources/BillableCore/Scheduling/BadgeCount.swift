import Foundation
import SwiftData

/// Computes the app's notification badge value: the count of unresolved
/// actionable items across the Recurrence and Reminder subsystems.
///
/// Two contributions:
/// 1. Pending recurrence materializations — templates whose nextFireDate is
///    in the past but haven't been materialized yet
/// 2. Pending overdue reminder steps — fire dates that have passed but
///    aren't yet in `firedDates`, scoped to invoices still in `.sent` status
///
/// Recomputed from authoritative SwiftData state on every `scenePhase == .active`
/// (not incremented/decremented), so multi-device sync + missed notifications
/// don't drift the badge.
@MainActor
public enum BadgeCount {
    public static func compute(context: ModelContext, now: Date = .now) -> Int {
        // 1. Pending recurrences (reuse RecurrenceService logic)
        let pendingRecurrences = RecurrenceService.pendingMaterializations(
            now: now,
            context: context
        ).count

        // 2. Pending reminder fires: for each InvoiceReminderSchedule on a
        //    .sent invoice, count fires <= now that aren't in firedDates.
        let schedules = (try? context.fetch(FetchDescriptor<InvoiceReminderSchedule>())) ?? []
        let pendingReminders = schedules.reduce(into: 0) { acc, schedule in
            guard let invoice = schedule.invoice, invoice.status == .sent else { return }
            for fire in schedule.fireDates where fire <= now && !schedule.firedDates.contains(fire) {
                acc += 1
            }
        }

        return pendingRecurrences + pendingReminders
    }
}
