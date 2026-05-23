import Foundation
import SwiftData
import Testing
import UserNotifications
@testable import BillableCore

@Suite("Scheduling")
struct SchedulingTests {

    @Test("ScheduledNotification persists with all fields")
    @MainActor
    func scheduledNotificationPersists() throws {
        let container = try BillableModelContainer.inMemory()
        let context = container.mainContext
        let id = UUID()
        let fireAt = Date(timeIntervalSince1970: 1_900_000_000)
        let payloadID = UUID()

        let note = ScheduledNotification(
            id: id,
            fireAt: fireAt,
            payloadType: "recurrence",
            payloadID: payloadID
        )
        context.insert(note)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<ScheduledNotification>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.id == id)
        #expect(fetched.first?.fireAt == fireAt)
        #expect(fetched.first?.payloadType == "recurrence")
        #expect(fetched.first?.payloadID == payloadID)
    }

    @Test("SchedulerPayload encodes and decodes via String round-trip")
    func payloadRoundTrip() throws {
        let recurrencePayloadID = UUID()
        let recurrence = SchedulerPayload.recurrence(templateID: recurrencePayloadID)
        let recEncoded = recurrence.encoded()
        let recDecoded = try #require(SchedulerPayload.decode(
            payloadType: recEncoded.type,
            payloadID: recEncoded.id
        ))
        #expect(recDecoded == .recurrence(templateID: recurrencePayloadID))

        let reminderScheduleID = UUID()
        let reminder = SchedulerPayload.reminder(scheduleID: reminderScheduleID)
        let remEncoded = reminder.encoded()
        let remDecoded = try #require(SchedulerPayload.decode(
            payloadType: remEncoded.type,
            payloadID: remEncoded.id
        ))
        #expect(remDecoded == .reminder(scheduleID: reminderScheduleID))

        // Unknown discriminator → nil
        #expect(SchedulerPayload.decode(payloadType: "garbage", payloadID: UUID()) == nil)
    }

    @Test("Scheduler.requestAuthorization returns true when center grants permission")
    @MainActor
    func authorizationGrantsAndCaches() async throws {
        let center = FakeNotificationCenter()
        let container = try BillableModelContainer.inMemory()
        let scheduler = Scheduler(
            center: center,
            modelContext: container.mainContext
        )

        let granted = try await scheduler.requestAuthorization()
        #expect(granted == true)
        #expect(center.authorized == true)
    }

    @Test("Scheduler.requestAuthorization returns false when user declines (simulated)")
    @MainActor
    func authorizationDeclined() async throws {
        final class DeclineCenter: NotificationCenterProtocol, @unchecked Sendable {
            func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool { false }
            func authorizationStatus() async -> UNAuthorizationStatus { .denied }
            func add(_ request: UNNotificationRequest) async throws {}
            func getPendingNotificationRequests() async -> [UNNotificationRequest] { [] }
            func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {}
        }
        let center = DeclineCenter()
        let container = try BillableModelContainer.inMemory()
        let scheduler = Scheduler(
            center: center,
            modelContext: container.mainContext
        )

        let granted = try await scheduler.requestAuthorization()
        #expect(granted == false)
    }

    @Test("Scheduler.schedule registers iOS request + persists ScheduledNotification")
    @MainActor
    func scheduleRegistersBoth() async throws {
        let center = FakeNotificationCenter()
        center.authorized = true
        let container = try BillableModelContainer.inMemory()
        let scheduler = Scheduler(center: center, modelContext: container.mainContext)
        _ = try await scheduler.requestAuthorization()

        let payloadID = UUID()
        let fireAt = Date().addingTimeInterval(3600)
        let result = try await scheduler.schedule(
            payload: .recurrence(templateID: payloadID),
            fireAt: fireAt,
            title: "Test",
            body: "Body"
        )

        #expect(result == .scheduled)
        #expect(center.addedRequests.count == 1)
        let fetched = try container.mainContext.fetch(FetchDescriptor<ScheduledNotification>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.payloadType == "recurrence")
        #expect(fetched.first?.payloadID == payloadID)
        #expect(fetched.first?.fireAt == fireAt)
    }

    @Test("Scheduler.schedule returns .noPermission when unauthorized")
    @MainActor
    func scheduleNoPermission() async throws {
        let center = FakeNotificationCenter()
        // Note: authorized stays false
        let container = try BillableModelContainer.inMemory()
        let scheduler = Scheduler(center: center, modelContext: container.mainContext)

        let result = try await scheduler.schedule(
            payload: .reminder(scheduleID: UUID()),
            fireAt: Date().addingTimeInterval(3600),
            title: "T",
            body: "B"
        )

        #expect(result == .noPermission)
        #expect(center.addedRequests.isEmpty)
        let fetched = try container.mainContext.fetch(FetchDescriptor<ScheduledNotification>())
        #expect(fetched.isEmpty)
    }

    @Test("Scheduler.schedule returns .capExceeded when pending count is at soft cap, persists row anyway")
    @MainActor
    func scheduleCapExceededPersistsRow() async throws {
        let center = FakeNotificationCenter()
        center.authorized = true
        // Pre-fill pending to the soft cap so the next schedule() must refuse iOS-side.
        for i in 0..<Scheduler.softCap {
            center.pendingRequests.append(UNNotificationRequest(
                identifier: "dummy-\(i)",
                content: UNMutableNotificationContent(),
                trigger: nil
            ))
        }
        let container = try BillableModelContainer.inMemory()
        let scheduler = Scheduler(center: center, modelContext: container.mainContext)
        _ = try await scheduler.requestAuthorization()

        let result = try await scheduler.schedule(
            payload: .reminder(scheduleID: UUID()),
            fireAt: Date().addingTimeInterval(3600),
            title: "T", body: "B"
        )
        #expect(result == .capExceeded)
        #expect(center.addedRequests.isEmpty)
        let rows = try container.mainContext.fetch(FetchDescriptor<ScheduledNotification>())
        #expect(rows.count == 1)
    }

    @Test("Scheduler.cancel removes iOS request + SwiftData row")
    @MainActor
    func cancelRemovesBoth() async throws {
        let center = FakeNotificationCenter()
        center.authorized = true
        let container = try BillableModelContainer.inMemory()
        let scheduler = Scheduler(center: center, modelContext: container.mainContext)
        _ = try await scheduler.requestAuthorization()

        let payloadID = UUID()
        _ = try await scheduler.schedule(
            payload: .reminder(scheduleID: payloadID),
            fireAt: Date().addingTimeInterval(3600),
            title: "T",
            body: "B"
        )
        let id = try #require(
            container.mainContext.fetch(FetchDescriptor<ScheduledNotification>()).first?.id
        )

        scheduler.cancel(id: id)

        #expect(center.removedIdentifiers.contains(id.uuidString))
        let remaining = try container.mainContext.fetch(FetchDescriptor<ScheduledNotification>())
        #expect(remaining.isEmpty)
    }

    @Test("Scheduler.resyncOnLaunch re-registers SwiftData rows missing iOS-side")
    @MainActor
    func resyncReRegistersMissing() async throws {
        let center = FakeNotificationCenter()
        center.authorized = true
        let container = try BillableModelContainer.inMemory()
        let scheduler = Scheduler(center: center, modelContext: container.mainContext)
        _ = try await scheduler.requestAuthorization()

        // Insert two rows directly, simulating a state where iOS has lost the requests.
        let id1 = UUID(), id2 = UUID()
        let future = Date().addingTimeInterval(3600)
        container.mainContext.insert(ScheduledNotification(
            id: id1, fireAt: future, payloadType: "recurrence", payloadID: UUID()
        ))
        container.mainContext.insert(ScheduledNotification(
            id: id2, fireAt: future, payloadType: "reminder", payloadID: UUID()
        ))
        try container.mainContext.save()
        // iOS-side starts empty (center.pendingRequests already empty)

        let result = await scheduler.resyncOnLaunch(now: Date())

        #expect(result.reregistered == 2)
        #expect(center.addedRequests.count == 2)
        let identifiers = Set(center.addedRequests.map(\.identifier))
        #expect(identifiers.contains(id1.uuidString))
        #expect(identifiers.contains(id2.uuidString))
    }

    @Test("Scheduler.resyncOnLaunch prunes already-fired (past) rows")
    @MainActor
    func resyncPrunesPast() async throws {
        let center = FakeNotificationCenter()
        center.authorized = true
        let container = try BillableModelContainer.inMemory()
        let scheduler = Scheduler(center: center, modelContext: container.mainContext)
        _ = try await scheduler.requestAuthorization()

        let past = Date().addingTimeInterval(-3600)
        container.mainContext.insert(ScheduledNotification(
            fireAt: past, payloadType: "recurrence", payloadID: UUID()
        ))
        try container.mainContext.save()

        let result = await scheduler.resyncOnLaunch(now: Date())

        let remaining = try container.mainContext.fetch(FetchDescriptor<ScheduledNotification>())
        #expect(remaining.isEmpty)
        #expect(result.pruned == 1)
        #expect(result.reregistered == 0)
    }

    @Test("Scheduler.handleNotificationTap decodes payload by id")
    @MainActor
    func tapDecodesPayload() async throws {
        let center = FakeNotificationCenter()
        center.authorized = true
        let container = try BillableModelContainer.inMemory()
        let scheduler = Scheduler(center: center, modelContext: container.mainContext)
        _ = try await scheduler.requestAuthorization()

        let payloadID = UUID()
        _ = try await scheduler.schedule(
            payload: .reminder(scheduleID: payloadID),
            fireAt: Date().addingTimeInterval(60),
            title: "T", body: "B"
        )
        let id = try #require(
            container.mainContext.fetch(FetchDescriptor<ScheduledNotification>()).first?.id
        )

        let payload = scheduler.handleNotificationTap(requestIdentifier: id.uuidString)
        #expect(payload == .reminder(scheduleID: payloadID))
    }

    @Test("Scheduler.handleNotificationTap returns nil for invalid UUID string")
    @MainActor
    func tapInvalidUUID() throws {
        let center = FakeNotificationCenter()
        let container = try BillableModelContainer.inMemory()
        let scheduler = Scheduler(center: center, modelContext: container.mainContext)

        let payload = scheduler.handleNotificationTap(requestIdentifier: "not-a-uuid")
        #expect(payload == nil)
    }

    @Test("RecurrenceCadence round-trips via raw String")
    func cadenceRoundTrip() throws {
        let monthly = RecurrenceCadence.monthly(dayOfMonth: 1)
        let weekly  = RecurrenceCadence.weekly(weekday: .monday)
        let biweekly = RecurrenceCadence.biweekly(weekday: .friday)

        #expect(RecurrenceCadence.from(raw: monthly.rawValue) == monthly)
        #expect(RecurrenceCadence.from(raw: weekly.rawValue) == weekly)
        #expect(RecurrenceCadence.from(raw: biweekly.rawValue) == biweekly)
        #expect(RecurrenceCadence.from(raw: "garbage") == nil)
    }

    @Test("RecurrenceCadence.from rejects malformed inputs")
    func cadenceParserRejectsInvalid() {
        // Out-of-range day-of-month
        #expect(RecurrenceCadence.from(raw: "monthlyDay:0") == nil)
        #expect(RecurrenceCadence.from(raw: "monthlyDay:32") == nil)
        #expect(RecurrenceCadence.from(raw: "monthlyDay:-1") == nil)
        // Invalid weekday code
        #expect(RecurrenceCadence.from(raw: "weekly:xyz") == nil)
        #expect(RecurrenceCadence.from(raw: "biweekly:") == nil)
        // Missing colon / empty
        #expect(RecurrenceCadence.from(raw: "monthlyDay") == nil)
        #expect(RecurrenceCadence.from(raw: "") == nil)
        // Non-integer day
        #expect(RecurrenceCadence.from(raw: "monthlyDay:fifteen") == nil)
    }

    @Test("RangeRule.previousMonth resolves from a fire date")
    func rangeRulePreviousMonth() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!

        let fireAt = cal.date(from: DateComponents(year: 2026, month: 6, day: 1, hour: 8))!
        let range = RangeRule.previousMonth.resolve(from: fireAt, calendar: cal)

        let expectedStart = cal.date(from: DateComponents(year: 2026, month: 5, day: 1))!
        let expectedEnd   = cal.date(from: DateComponents(year: 2026, month: 6, day: 1))!
        #expect(range.start == expectedStart)
        #expect(range.end == expectedEnd)
    }

    @Test("RangeRule.previousWeek resolves to Mon-Sun before the fire date")
    func rangeRulePreviousWeek() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2 // Monday-first
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!

        let fireAt = cal.date(from: DateComponents(year: 2026, month: 6, day: 8))! // Monday
        let range = RangeRule.previousWeek.resolve(from: fireAt, calendar: cal)

        let expectedStart = cal.date(from: DateComponents(year: 2026, month: 6, day: 1))! // prior Mon
        let expectedEnd   = fireAt
        #expect(range.start == expectedStart)
        #expect(range.end == expectedEnd)
    }

    @Test("RangeRule.implied maps cadence to range rule")
    func rangeRuleImplied() {
        #expect(RangeRule.implied(from: .monthly(dayOfMonth: 1)) == .previousMonth)
        #expect(RangeRule.implied(from: .weekly(weekday: .monday)) == .previousWeek)
        #expect(RangeRule.implied(from: .biweekly(weekday: .friday)) == .previousBiweek)
    }

    @Test("RecurrenceTemplate persists with cadence + client + nextFireDate")
    @MainActor
    func recurrenceTemplatePersists() throws {
        let container = try BillableModelContainer.inMemory()
        let context = container.mainContext

        let client = Client(name: "Acme", color: .blue)
        context.insert(client)

        let cadence = RecurrenceCadence.monthly(dayOfMonth: 1)
        let next = Date(timeIntervalSince1970: 1_900_000_000)
        let template = RecurrenceTemplate(
            client: client,
            cadence: cadence,
            grouping: .perEntry,
            notesTemplate: "Services for {clientName} — {month} {year}",
            nextFireDate: next
        )
        context.insert(template)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<RecurrenceTemplate>())
        #expect(fetched.count == 1)
        let t = try #require(fetched.first)
        #expect(t.client?.name == "Acme")
        #expect(t.cadenceValue == cadence)
        #expect(t.rangeRuleValue == .previousMonth)
        #expect(t.groupingValue == .perEntry)
        #expect(t.notesTemplate == "Services for {clientName} — {month} {year}")
        #expect(t.nextFireDate == next)
        #expect(t.isActive == true)
        #expect(t.lastFiredAt == nil)
        #expect(t.endDate == nil)
    }

    @Test("RecurrenceTemplate.isEnded returns true once endDate has passed")
    @MainActor
    func recurrenceTemplateIsEnded() throws {
        let container = try BillableModelContainer.inMemory()
        let context = container.mainContext
        let client = Client(name: "Acme", color: .blue)
        context.insert(client)

        let past = Date().addingTimeInterval(-3600)
        let future = Date().addingTimeInterval(3600)

        let endedTemplate = RecurrenceTemplate(
            client: client,
            cadence: .monthly(dayOfMonth: 1),
            grouping: .perEntry,
            nextFireDate: Date(),
            endDate: past
        )
        let liveTemplate = RecurrenceTemplate(
            client: client,
            cadence: .monthly(dayOfMonth: 1),
            grouping: .perEntry,
            nextFireDate: Date(),
            endDate: future
        )
        let openTemplate = RecurrenceTemplate(
            client: client,
            cadence: .monthly(dayOfMonth: 1),
            grouping: .perEntry,
            nextFireDate: Date()
        )
        context.insert(endedTemplate); context.insert(liveTemplate); context.insert(openTemplate)
        try context.save()

        #expect(endedTemplate.isEnded() == true)
        #expect(liveTemplate.isEnded() == false)
        #expect(openTemplate.isEnded() == false)
    }

    @Test("RecurrenceTemplate explicit rangeRule overrides implied value")
    @MainActor
    func recurrenceTemplateExplicitRangeRule() throws {
        let container = try BillableModelContainer.inMemory()
        let context = container.mainContext
        let client = Client(name: "Acme", color: .blue)
        context.insert(client)

        // monthly cadence would normally imply .previousMonth; override with .previousWeek
        let template = RecurrenceTemplate(
            client: client,
            cadence: .monthly(dayOfMonth: 1),
            rangeRule: .previousWeek,
            grouping: .perEntry,
            nextFireDate: Date()
        )
        context.insert(template)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<RecurrenceTemplate>())
        let t = try #require(fetched.first)
        #expect(t.rangeRuleValue == .previousWeek)
    }

    @Test("computeNextFireDate: monthly day=1 → first of next month at 8am local")
    @MainActor
    func nextFireMonthlyDayOne() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!

        let from = cal.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 10))!
        let next = RecurrenceService.computeNextFireDate(
            cadence: .monthly(dayOfMonth: 1),
            after: from,
            calendar: cal
        )
        let expected = cal.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 8))!
        #expect(next == expected)
    }

    @Test("computeNextFireDate: monthly day=31 → clamps to last day of short month")
    @MainActor
    func nextFireMonthlyDay31Feb() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!

        let from = cal.date(from: DateComponents(year: 2026, month: 1, day: 31, hour: 12))!
        let next = RecurrenceService.computeNextFireDate(
            cadence: .monthly(dayOfMonth: 31),
            after: from,
            calendar: cal
        )
        let expected = cal.date(from: DateComponents(year: 2026, month: 2, day: 28, hour: 8))!
        #expect(next == expected)
    }

    @Test("computeNextFireDate: weekly Mon → next Monday at 8am")
    @MainActor
    func nextFireWeeklyMonday() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!

        // 2026-06-03 is a Wednesday
        let from = cal.date(from: DateComponents(year: 2026, month: 6, day: 3, hour: 12))!
        let next = RecurrenceService.computeNextFireDate(
            cadence: .weekly(weekday: .monday),
            after: from,
            calendar: cal
        )
        // Next Monday is 2026-06-08
        let expected = cal.date(from: DateComponents(year: 2026, month: 6, day: 8, hour: 8))!
        #expect(next == expected)
    }

    @Test("computeNextFireDate: biweekly Fri → 2 Fridays from now at 8am")
    @MainActor
    func nextFireBiweeklyFriday() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!

        // 2026-06-03 is a Wednesday. Next Friday is 2026-06-05; biweekly nudges +7d
        // so the first fire is the second Friday = 2026-06-12 (one-week grace UX).
        let from = cal.date(from: DateComponents(year: 2026, month: 6, day: 3, hour: 12))!
        let next = RecurrenceService.computeNextFireDate(
            cadence: .biweekly(weekday: .friday),
            after: from,
            calendar: cal
        )
        let expected = cal.date(from: DateComponents(year: 2026, month: 6, day: 12, hour: 8))!
        #expect(next == expected)
    }

    @Test("computeNextFireDate: biweekly Fri after a fire → 14 days later")
    @MainActor
    func nextFireBiweeklyAfterMaterialize() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!

        // Simulate: we just fired on Fri Jun 5 at 8am. Next fire should be Fri Jun 19.
        let prevFire = cal.date(from: DateComponents(year: 2026, month: 6, day: 5, hour: 8))!
        let next = RecurrenceService.computeNextFireDate(
            cadence: .biweekly(weekday: .friday),
            after: prevFire,
            calendar: cal
        )
        let expected = cal.date(from: DateComponents(year: 2026, month: 6, day: 19, hour: 8))!
        #expect(next == expected)
    }

    @Test("computeNextFireDate: biweekly Fri after delayed tap → still every 14 days")
    @MainActor
    func nextFireBiweeklyDelayedMaterialize() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!

        // User taps the notification at Fri Jun 5 10:30am (2.5h after 8am fire).
        let tapTime = cal.date(from: DateComponents(year: 2026, month: 6, day: 5, hour: 10, minute: 30))!
        let next = RecurrenceService.computeNextFireDate(
            cadence: .biweekly(weekday: .friday),
            after: tapTime,
            calendar: cal
        )
        let expected = cal.date(from: DateComponents(year: 2026, month: 6, day: 19, hour: 8))!
        #expect(next == expected)
    }

    @Test("materializeDraft creates a Draft Invoice from prior-month entries and advances lastFiredAt")
    @MainActor
    func materializeDraftHappyPath() async throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!

        let container = try BillableModelContainer.inMemory()
        let context = container.mainContext

        let profile = BusinessProfile(name: "Me", currencyCode: "USD")
        let client = Client(name: "Acme", color: .blue)
        let project = Project(name: "Web", hourlyRate: 100, isBillable: true, client: client)
        let entry = TimeEntry(
            startedAt: cal.date(from: DateComponents(year: 2026, month: 5, day: 15, hour: 10))!,
            endedAt: cal.date(from: DateComponents(year: 2026, month: 5, day: 15, hour: 12))!,
            project: project
        )
        context.insert(profile); context.insert(client); context.insert(project); context.insert(entry)

        let fireAt = cal.date(from: DateComponents(year: 2026, month: 6, day: 1, hour: 8))!
        let template = RecurrenceTemplate(
            client: client,
            cadence: .monthly(dayOfMonth: 1),
            grouping: .perEntry,
            notesTemplate: "Services — {month} {year}",
            nextFireDate: fireAt
        )
        context.insert(template)
        try context.save()

        let draft = try RecurrenceService.materializeDraft(
            template: template,
            now: fireAt,
            calendar: cal,
            context: context
        )

        #expect(draft.status == .draft)
        #expect(draft.clientNameSnapshot == "Acme")
        #expect(draft.lineItems.count == 1)
        #expect(draft.notes == "Services — May 2026")
        #expect(template.lastFiredAt == fireAt)
        let expectedNext = cal.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 8))!
        #expect(template.nextFireDate == expectedNext)
    }

    @Test("materializeDraft creates zero-amount draft when no eligible entries")
    @MainActor
    func materializeDraftZeroEntries() async throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let container = try BillableModelContainer.inMemory()
        let context = container.mainContext

        let profile = BusinessProfile(name: "Me", currencyCode: "USD")
        let client = Client(name: "Acme", color: .blue)
        context.insert(profile); context.insert(client)

        let fireAt = cal.date(from: DateComponents(year: 2026, month: 6, day: 1, hour: 8))!
        let template = RecurrenceTemplate(
            client: client,
            cadence: .monthly(dayOfMonth: 1),
            grouping: .perEntry,
            nextFireDate: fireAt
        )
        context.insert(template)
        try context.save()

        let draft = try RecurrenceService.materializeDraft(
            template: template, now: fireAt, calendar: cal, context: context
        )

        #expect(draft.status == .draft)
        #expect(draft.subtotal == 0)
        #expect(draft.lineItems.count == 1)
        #expect(draft.lineItems.first?.description == "No tracked time for this period")
    }

    @Test("materializeDraft throws .ended when template's endDate has passed")
    @MainActor
    func materializeDraftEndedTemplate() async throws {
        let container = try BillableModelContainer.inMemory()
        let context = container.mainContext
        let profile = BusinessProfile(name: "Me", currencyCode: "USD")
        let client = Client(name: "Acme", color: .blue)
        context.insert(profile); context.insert(client)

        let template = RecurrenceTemplate(
            client: client,
            cadence: .monthly(dayOfMonth: 1),
            grouping: .perEntry,
            nextFireDate: Date(),
            endDate: Date().addingTimeInterval(-3600)
        )
        context.insert(template)
        try context.save()

        do {
            _ = try RecurrenceService.materializeDraft(
                template: template, now: Date(), context: context
            )
            Issue.record("Expected .ended to throw")
        } catch RecurrenceService.MaterializationError.ended {
            // expected
        }
    }

}

// MARK: - Test helpers

final class FakeNotificationCenter: NotificationCenterProtocol, @unchecked Sendable {
    var authorized = false
    var pendingRequests: [UNNotificationRequest] = []
    var addedRequests: [UNNotificationRequest] = []
    var removedIdentifiers: [String] = []

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        authorized = true
        return true
    }
    func authorizationStatus() async -> UNAuthorizationStatus {
        authorized ? .authorized : .notDetermined
    }
    func add(_ request: UNNotificationRequest) async throws {
        addedRequests.append(request)
        pendingRequests.append(request)
    }
    func getPendingNotificationRequests() async -> [UNNotificationRequest] {
        pendingRequests
    }
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        removedIdentifiers.append(contentsOf: identifiers)
        pendingRequests.removeAll { identifiers.contains($0.identifier) }
    }
}
