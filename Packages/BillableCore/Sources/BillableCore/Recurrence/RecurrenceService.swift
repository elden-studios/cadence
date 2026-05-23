import Foundation
import SwiftData
import OSLog

@MainActor
public enum RecurrenceService {
    private static let log = Logger(subsystem: "com.eldenstudios.billable", category: "RecurrenceService")

    /// 8:00am local, the fixed v1.1 fire-of-day slot.
    public static let fireHour = 8

    /// Compute the next fire date STRICTLY AFTER `from`. Always returns a date
    /// greater than `from`. Handles monthly day-of-month clamping for short months
    /// and weekly/biweekly walk to the next target weekday.
    public static func computeNextFireDate(
        cadence: RecurrenceCadence,
        after from: Date,
        calendar: Calendar = .current
    ) -> Date {
        switch cadence {
        case .monthly(let day):
            return nextMonthlyDate(dayOfMonth: day, after: from, calendar: calendar)
        case .weekly(let weekday):
            return nextWeekdayDate(weekday: weekday, after: from, calendar: calendar, weeksOffset: 1)
        case .biweekly(let weekday):
            return nextWeekdayDate(weekday: weekday, after: from, calendar: calendar, weeksOffset: 2)
        }
    }

    // MARK: - Internal

    private static func nextMonthlyDate(dayOfMonth: Int, after from: Date, calendar: Calendar) -> Date {
        // Try the current month, then the next, then the one after — in case the
        // target day in the current month is in the past relative to `from`.
        for monthsAhead in 0...2 {
            let advanced = calendar.date(byAdding: .month, value: monthsAhead, to: from)!
            let components = calendar.dateComponents([.year, .month], from: advanced)
            let candidateComponents = DateComponents(
                year: components.year, month: components.month,
                day: clampedDayOfMonth(dayOfMonth, in: advanced, calendar: calendar),
                hour: fireHour, minute: 0, second: 0
            )
            if let candidate = calendar.date(from: candidateComponents), candidate > from {
                return candidate
            }
        }
        // Defensive fallback — should be unreachable for sane inputs.
        return calendar.date(byAdding: .month, value: 1, to: from)!
    }

    private static func clampedDayOfMonth(_ day: Int, in date: Date, calendar: Calendar) -> Int {
        let range = calendar.range(of: .day, in: .month, for: date) ?? 1..<29
        return min(day, range.upperBound - 1)
    }

    private static func nextWeekdayDate(
        weekday: RecurrenceCadence.Weekday,
        after from: Date,
        calendar: Calendar,
        weeksOffset: Int  // 1 = weekly, 2 = biweekly
    ) -> Date {
        var components = DateComponents()
        components.weekday = weekday.calendarComponent
        components.hour = fireHour
        components.minute = 0
        // Find next target weekday strictly after `from`.
        let firstNext = calendar.nextDate(
            after: from, matching: components, matchingPolicy: .nextTime
        )!
        // For biweekly: nudge +7d. This makes both call sites correct:
        // - Creation (Wed Jun 3 → first Fri = Jun 5 → +7 = Jun 12) gives the user
        //   a one-week grace before the first invoice.
        // - Materialization (Fri Jun 5 8am tap → next Fri = Jun 12 → +7 = Jun 19)
        //   correctly produces every-14-days cadence with no drift.
        guard weeksOffset > 1 else { return firstNext }
        return calendar.date(byAdding: .day, value: 7, to: firstNext)!
    }

    // MARK: - materializeDraft

    public enum MaterializationError: Error, Equatable {
        case noBusinessProfile
        case noClient
        case ended
    }

    /// Resolve the prior period, build line items from eligible entries, and
    /// insert a Draft `Invoice`. Updates `lastFiredAt` and `nextFireDate` on
    /// the template. Returns the inserted Invoice.
    ///
    /// Zero-entry case is allowed — produces an empty draft so the user sees
    /// "nothing to bill this period" rather than silently swallowing the fire.
    @discardableResult
    public static func materializeDraft(
        template: RecurrenceTemplate,
        now: Date = .now,
        calendar: Calendar = .current,
        context: ModelContext
    ) throws -> Invoice {
        guard !template.isEnded(now: now) else {
            throw MaterializationError.ended
        }
        guard let client = template.client else {
            throw MaterializationError.noClient
        }
        let profiles = try context.fetch(FetchDescriptor<BusinessProfile>())
        guard let profile = profiles.first else {
            throw MaterializationError.noBusinessProfile
        }

        let range = template.rangeRuleValue.resolve(from: now, calendar: calendar)

        let entries = InvoiceBuilder.eligibleEntries(
            for: client, in: range, context: context
        )
        let lineItems = InvoiceBuilder.buildLineItems(
            from: entries, grouping: template.groupingValue
        )

        let resolvedNotes = renderNotes(
            template.notesTemplate,
            client: client,
            forDate: range.start,
            calendar: calendar
        )

        // For zero-entry materialization we still want an Invoice row to show
        // up in Drafts. `InvoiceBuilder.createDraft` throws on empty line items,
        // so we synthesize a placeholder line at zero hours.
        let effectiveLineItems = lineItems.isEmpty
            ? [InvoiceLineItem(
                description: "No tracked time for this period",
                hours: 0,
                hourlyRate: 0,
                sourceTimeEntryRef: nil
              )]
            : lineItems

        let invoice = try InvoiceBuilder.createDraft(
            for: client,
            lineItems: effectiveLineItems,
            notes: resolvedNotes,
            issuedAt: now,
            profile: profile,
            context: context
        )

        // Stamp source entries as invoiced (only for the entries that were
        // actually billed — skip the synthesized placeholder case).
        if !lineItems.isEmpty {
            for entry in entries { entry.invoiceID = invoice.uuid }
        }

        // Advance template state.
        template.lastFiredAt = now
        template.nextFireDate = computeNextFireDate(
            cadence: template.cadenceValue, after: now, calendar: calendar
        )
        try context.save()

        log.info("materializeDraft(): templateID=\(template.id.uuidString, privacy: .public) lineItems=\(lineItems.count, privacy: .public)")
        return invoice
    }

    /// Render notes template with `{month}` `{year}` `{clientName}` merge fields.
    /// `forDate` is the start of the billed range — we name the period by its
    /// start month/year (May 2026 even though the invoice fires June 1).
    public static func renderNotes(
        _ template: String?,
        client: Client,
        forDate: Date,
        calendar: Calendar
    ) -> String? {
        guard let template, !template.isEmpty else { return nil }
        let monthFormatter = DateFormatter()
        monthFormatter.calendar = calendar
        monthFormatter.dateFormat = "LLLL"
        let yearFormatter = DateFormatter()
        yearFormatter.calendar = calendar
        yearFormatter.dateFormat = "yyyy"

        return template
            .replacingOccurrences(of: "{month}", with: monthFormatter.string(from: forDate))
            .replacingOccurrences(of: "{year}", with: yearFormatter.string(from: forDate))
            .replacingOccurrences(of: "{clientName}", with: client.name)
    }
}
