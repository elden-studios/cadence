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

    @Test("RangeRule.previousBiweek resolves to the two prior weeks")
    func rangeRulePreviousBiweek() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2 // Monday-first
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let fireAt = cal.date(from: DateComponents(year: 2026, month: 6, day: 19, hour: 8))! // Friday
        let range = RangeRule.previousBiweek.resolve(from: fireAt, calendar: cal)
        // startOfFireWeek = Mon 2026-06-15; -14d = Mon 2026-06-01
        let expectedStart = cal.date(from: DateComponents(year: 2026, month: 6, day: 1))!
        let expectedEnd   = cal.date(from: DateComponents(year: 2026, month: 6, day: 15))!
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
        #expect(entry.invoiceID == draft.uuid)
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

    @Test("pendingMaterializations returns templates with nextFireDate in the past")
    @MainActor
    func pendingMaterializationsReturnsOverdue() throws {
        let container = try BillableModelContainer.inMemory()
        let context = container.mainContext

        let client = Client(name: "Acme", color: .blue)
        context.insert(client)

        let now = Date()
        let pastFire = now.addingTimeInterval(-3600 * 24 * 3) // 3 days ago
        let futureFire = now.addingTimeInterval(3600 * 24 * 5) // 5 days from now

        let pending = RecurrenceTemplate(
            client: client, cadence: .monthly(dayOfMonth: 1),
            grouping: .perEntry, nextFireDate: pastFire
        )
        let later = RecurrenceTemplate(
            client: client, cadence: .monthly(dayOfMonth: 15),
            grouping: .perEntry, nextFireDate: futureFire
        )
        context.insert(pending); context.insert(later)
        try context.save()

        let overdue = RecurrenceService.pendingMaterializations(now: now, context: context)
        #expect(overdue.count == 1)
        #expect(overdue.first?.id == pending.id)
    }

    @Test("pendingMaterializations excludes inactive and ended templates")
    @MainActor
    func pendingMaterializationsExcludesInactiveAndEnded() throws {
        let container = try BillableModelContainer.inMemory()
        let context = container.mainContext
        let client = Client(name: "Acme", color: .blue)
        context.insert(client)

        let now = Date()
        let past = now.addingTimeInterval(-3600 * 24 * 3)

        let inactive = RecurrenceTemplate(
            client: client, cadence: .monthly(dayOfMonth: 1),
            grouping: .perEntry, nextFireDate: past, isActive: false
        )
        let ended = RecurrenceTemplate(
            client: client, cadence: .monthly(dayOfMonth: 1),
            grouping: .perEntry, nextFireDate: past,
            endDate: now.addingTimeInterval(-3600 * 24 * 10)
        )
        context.insert(inactive); context.insert(ended)
        try context.save()

        let overdue = RecurrenceService.pendingMaterializations(now: now, context: context)
        #expect(overdue.isEmpty)
    }

    @Test("RecurrenceCadenceKind derives correctly from RecurrenceCadence")
    func cadenceKindMapping() {
        #expect(RecurrenceCadenceKind(.monthly(dayOfMonth: 15)) == .monthly)
        #expect(RecurrenceCadenceKind(.weekly(weekday: .friday)) == .weekly)
        #expect(RecurrenceCadenceKind(.biweekly(weekday: .monday)) == .biweekly)
    }

    @Test("pendingMaterializations sorts ascending by nextFireDate (oldest first)")
    @MainActor
    func pendingMaterializationsSorted() throws {
        let container = try BillableModelContainer.inMemory()
        let context = container.mainContext
        let client = Client(name: "Acme", color: .blue)
        context.insert(client)

        let now = Date()
        let earlier = now.addingTimeInterval(-3600 * 24 * 30) // 30 days ago
        let middle  = now.addingTimeInterval(-3600 * 24 * 10) // 10 days ago
        let recent  = now.addingTimeInterval(-3600 * 24 * 2)  // 2 days ago

        let t1 = RecurrenceTemplate(client: client, cadence: .monthly(dayOfMonth: 1), grouping: .perEntry, nextFireDate: middle)
        let t2 = RecurrenceTemplate(client: client, cadence: .monthly(dayOfMonth: 1), grouping: .perEntry, nextFireDate: earlier)
        let t3 = RecurrenceTemplate(client: client, cadence: .monthly(dayOfMonth: 1), grouping: .perEntry, nextFireDate: recent)
        context.insert(t1); context.insert(t2); context.insert(t3)
        try context.save()

        let overdue = RecurrenceService.pendingMaterializations(now: now, context: context)
        #expect(overdue.count == 3)
        #expect(overdue[0].nextFireDate == earlier)
        #expect(overdue[1].nextFireDate == middle)
        #expect(overdue[2].nextFireDate == recent)
    }

    @Test("ReminderConfig persists with default offsets and templates")
    @MainActor
    func reminderConfigPersists() throws {
        let container = try BillableModelContainer.inMemory()
        let context = container.mainContext

        let config = ReminderConfig.defaultConfig()
        context.insert(config)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<ReminderConfig>())
        #expect(fetched.count == 1)
        let c = try #require(fetched.first)
        #expect(c.enabledOffsets == [3, 7, 14])
        #expect(c.subjectTemplate.contains("{invoiceNumber}"))
        #expect(c.bodyTemplate.contains("{clientFirstName}"))
        #expect(c.masterEnabled == false)  // off until user enables explicitly
    }

    @Test("ReminderConfig default templates contain all expected merge fields")
    @MainActor
    func reminderConfigDefaultTemplatesMergeFields() {
        let config = ReminderConfig.defaultConfig()
        // Subject: at minimum invoiceNumber
        #expect(config.subjectTemplate.contains("{invoiceNumber}"))
        // Body: clientFirstName, invoiceNumber, amount, dueDate, senderName
        #expect(config.bodyTemplate.contains("{clientFirstName}"))
        #expect(config.bodyTemplate.contains("{invoiceNumber}"))
        #expect(config.bodyTemplate.contains("{amount}"))
        #expect(config.bodyTemplate.contains("{dueDate}"))
        #expect(config.bodyTemplate.contains("{senderName}"))
    }

    @Test("InvoiceReminderSchedule stores fireDates and tracks firedDates")
    @MainActor
    func reminderSchedulePersists() throws {
        let container = try BillableModelContainer.inMemory()
        let context = container.mainContext

        let dueAt = Date(timeIntervalSince1970: 1_900_000_000)
        let fires = [3, 7, 14].map { Calendar.current.date(byAdding: .day, value: $0, to: dueAt)! }
        let schedule = InvoiceReminderSchedule(fireDates: fires)
        context.insert(schedule)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<InvoiceReminderSchedule>())
        #expect(fetched.first?.fireDates == fires)
        #expect(fetched.first?.firedDates.isEmpty == true)
    }

    @Test("InvoiceReminderSchedule appends to firedDates without duplicates via mutation")
    @MainActor
    func reminderScheduleFiredDatesAppend() throws {
        let container = try BillableModelContainer.inMemory()
        let context = container.mainContext
        let schedule = InvoiceReminderSchedule(fireDates: [], firedDates: [])
        context.insert(schedule)
        try context.save()

        let fireA = Date(timeIntervalSince1970: 1_900_000_000)
        schedule.firedDates.append(fireA)
        try context.save()

        let fetched = try #require(context.fetch(FetchDescriptor<InvoiceReminderSchedule>()).first)
        #expect(fetched.firedDates == [fireA])
    }

    @Test("Client.reminderOffsets defaults to nil")
    @MainActor
    func clientReminderOffsetsDefaultsNil() throws {
        let container = try BillableModelContainer.inMemory()
        let context = container.mainContext
        let client = Client(name: "Acme", color: .blue)
        context.insert(client)
        try context.save()
        let fetched = try #require(context.fetch(FetchDescriptor<Client>()).first)
        #expect(fetched.reminderOffsets == nil)
    }

    @Test("Client.reminderOffsets can be set and persisted")
    @MainActor
    func clientReminderOffsetsSet() throws {
        let container = try BillableModelContainer.inMemory()
        let context = container.mainContext
        let client = Client(name: "Acme", color: .blue, reminderOffsets: [5, 10])
        context.insert(client)
        try context.save()
        let fetched = try #require(context.fetch(FetchDescriptor<Client>()).first)
        #expect(fetched.reminderOffsets == [5, 10])
    }

    @Test("Invoice.reminderSchedule starts nil and can be set")
    @MainActor
    func invoiceReminderScheduleField() throws {
        let container = try BillableModelContainer.inMemory()
        let context = container.mainContext

        let invoice = Invoice(
            number: "INV-0001",
            dueAt: Date(),
            clientNameSnapshot: "Acme",
            issuerNameSnapshot: "Me",
            issuerAddressSnapshot: "",
            issuerEmailSnapshot: "",
            paymentTermsSnapshot: "Net 14",
            taxLabelSnapshot: "Tax",
            taxRateSnapshot: 0,
            currencyCodeSnapshot: "USD"
        )
        context.insert(invoice)
        try context.save()

        let fetched = try #require(context.fetch(FetchDescriptor<Invoice>()).first)
        #expect(fetched.reminderSchedule == nil)

        let schedule = InvoiceReminderSchedule(fireDates: [Date()])
        schedule.invoice = invoice
        invoice.reminderSchedule = schedule
        context.insert(schedule)
        try context.save()

        let refetched = try #require(context.fetch(FetchDescriptor<Invoice>()).first)
        #expect(refetched.reminderSchedule?.fireDates.count == 1)
    }

    @Test("ReminderTemplateRenderer resolves all merge fields")
    @MainActor
    func renderResolvesAllFields() throws {
        let container = try BillableModelContainer.inMemory()
        let context = container.mainContext

        let client = Client(
            name: "Acme Corp",
            color: .blue,
            contactName: "Jane Doe"
        )
        context.insert(client)

        let profile = BusinessProfile(name: "Louay Bazerbashi", currencyCode: "USD")
        context.insert(profile)

        let due = Date(timeIntervalSince1970: 1_900_000_000)
        let invoice = Invoice(
            number: "INV-0042",
            dueAt: due,
            clientNameSnapshot: "Acme Corp",
            issuerNameSnapshot: "Louay Bazerbashi",
            issuerAddressSnapshot: "",
            issuerEmailSnapshot: "",
            paymentTermsSnapshot: "Net 14",
            taxLabelSnapshot: "Tax",
            taxRateSnapshot: 0,
            currencyCodeSnapshot: "USD",
            lineItems: [InvoiceLineItem(description: "Work", hours: 10, hourlyRate: 100, sourceTimeEntryRef: nil)],
            client: client
        )
        context.insert(invoice)
        try context.save()

        let template = "Hi {clientFirstName}, {invoiceNumber} for {amount} was due {dueDate}. — {senderName}"
        let now = due.addingTimeInterval(3 * 86400)
        let rendered = ReminderTemplateRenderer.render(
            template: template,
            invoice: invoice,
            senderName: "Louay Bazerbashi",
            now: now
        )

        #expect(rendered.contains("Hi Jane"))
        #expect(rendered.contains("INV-0042"))
        #expect(rendered.contains("1,000"))      // 10h * $100 = $1,000 — formatter detail varies by locale, just check digits
        #expect(rendered.contains("Louay Bazerbashi"))
        // {dueDate} resolves to a localized date; we just check it's substituted
        #expect(rendered.contains("{dueDate}") == false)
    }

    @Test("ReminderTemplateRenderer computes daysOverdue from now and dueAt")
    @MainActor
    func renderDaysOverdue() throws {
        let container = try BillableModelContainer.inMemory()
        let context = container.mainContext
        let client = Client(name: "Acme", color: .blue)
        let profile = BusinessProfile(name: "Me", currencyCode: "USD")
        context.insert(client); context.insert(profile)

        let due = Date(timeIntervalSince1970: 1_900_000_000)
        let invoice = Invoice(
            number: "INV-0007", dueAt: due,
            clientNameSnapshot: "Acme",
            issuerNameSnapshot: "Me", issuerAddressSnapshot: "", issuerEmailSnapshot: "",
            paymentTermsSnapshot: "", taxLabelSnapshot: "Tax", taxRateSnapshot: 0,
            currencyCodeSnapshot: "USD",
            client: client
        )
        context.insert(invoice)
        try context.save()

        let now = due.addingTimeInterval(7 * 86400)
        let rendered = ReminderTemplateRenderer.render(
            template: "{daysOverdue} days overdue",
            invoice: invoice, senderName: "Me", now: now
        )
        #expect(rendered == "7 days overdue")
    }

    @Test("ReminderTemplateRenderer falls back to clientName when no contactName")
    @MainActor
    func renderFirstNameFallback() throws {
        let container = try BillableModelContainer.inMemory()
        let context = container.mainContext
        let client = Client(name: "Solo Acme", color: .blue)  // No contactName
        let profile = BusinessProfile(name: "Me", currencyCode: "USD")
        context.insert(client); context.insert(profile)

        let invoice = Invoice(
            number: "INV-0001", dueAt: Date(),
            clientNameSnapshot: "Solo Acme",
            issuerNameSnapshot: "Me", issuerAddressSnapshot: "", issuerEmailSnapshot: "",
            paymentTermsSnapshot: "", taxLabelSnapshot: "Tax", taxRateSnapshot: 0,
            currencyCodeSnapshot: "USD",
            client: client
        )
        context.insert(invoice)
        try context.save()

        let rendered = ReminderTemplateRenderer.render(
            template: "Hi {clientFirstName}",
            invoice: invoice, senderName: "Me"
        )
        #expect(rendered == "Hi Solo")  // First word of clientName when contactName is nil
    }

    @Test("ReminderTemplateRenderer leaves unknown tokens untouched")
    @MainActor
    func renderUnknownTokenUntouched() throws {
        let container = try BillableModelContainer.inMemory()
        let context = container.mainContext
        let client = Client(name: "Acme", color: .blue)
        let profile = BusinessProfile(name: "Me", currencyCode: "USD")
        context.insert(client); context.insert(profile)

        let invoice = Invoice(
            number: "INV-0001", dueAt: Date(),
            clientNameSnapshot: "Acme",
            issuerNameSnapshot: "Me", issuerAddressSnapshot: "", issuerEmailSnapshot: "",
            paymentTermsSnapshot: "", taxLabelSnapshot: "Tax", taxRateSnapshot: 0,
            currencyCodeSnapshot: "USD",
            client: client
        )
        context.insert(invoice)
        try context.save()

        let rendered = ReminderTemplateRenderer.render(
            template: "Hello {unknownToken}",
            invoice: invoice, senderName: "Me"
        )
        #expect(rendered == "Hello {unknownToken}")  // unchanged
    }

    @Test("ReminderTemplateRenderer daysOverdue clamps to 0 when now is before dueAt")
    @MainActor
    func renderDaysOverdueClampNonNegative() throws {
        let container = try BillableModelContainer.inMemory()
        let context = container.mainContext
        let client = Client(name: "Acme", color: .blue)
        let profile = BusinessProfile(name: "Me", currencyCode: "USD")
        context.insert(client); context.insert(profile)

        let due = Date(timeIntervalSince1970: 1_900_000_000)
        let invoice = Invoice(
            number: "INV-0001", dueAt: due,
            clientNameSnapshot: "Acme",
            issuerNameSnapshot: "Me", issuerAddressSnapshot: "", issuerEmailSnapshot: "",
            paymentTermsSnapshot: "", taxLabelSnapshot: "Tax", taxRateSnapshot: 0,
            currencyCodeSnapshot: "USD",
            client: client
        )
        context.insert(invoice)
        try context.save()

        // Now is 5 days BEFORE due — daysOverdue must clamp to 0, not -5
        let now = due.addingTimeInterval(-5 * 86400)
        let rendered = ReminderTemplateRenderer.render(
            template: "{daysOverdue}",
            invoice: invoice, senderName: "Me", now: now
        )
        #expect(rendered == "0")
    }

    @Test("scheduleForInvoice resolves offsets and creates fire dates at 8am local")
    @MainActor
    func scheduleForInvoiceCreatesFires() async throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!

        let center = FakeNotificationCenter()
        center.authorized = true
        let container = try BillableModelContainer.inMemory()
        let context = container.mainContext

        let config = ReminderConfig.defaultConfig()
        config.masterEnabled = true
        context.insert(config)

        let client = Client(name: "Acme", color: .blue)
        let profile = BusinessProfile(name: "Me", currencyCode: "USD")
        context.insert(client); context.insert(profile)

        let due = cal.date(from: DateComponents(year: 2026, month: 6, day: 15))!
        let invoice = Invoice(
            number: "INV-0010", dueAt: due,
            clientNameSnapshot: "Acme",
            issuerNameSnapshot: "Me", issuerAddressSnapshot: "", issuerEmailSnapshot: "",
            paymentTermsSnapshot: "", taxLabelSnapshot: "Tax", taxRateSnapshot: 0,
            currencyCodeSnapshot: "USD",
            client: client
        )
        try invoice.markSent(at: due.addingTimeInterval(-86400)) // Sent yesterday
        context.insert(invoice)
        try context.save()

        let scheduler = Scheduler(center: center, modelContext: context)
        _ = try await scheduler.requestAuthorization()
        let reminderService = ReminderService(scheduler: scheduler, modelContext: context, calendar: cal)

        try await reminderService.scheduleForInvoice(invoice)

        let schedule = try #require(invoice.reminderSchedule)
        let expected3  = cal.date(from: DateComponents(year: 2026, month: 6, day: 18, hour: 8))!
        let expected7  = cal.date(from: DateComponents(year: 2026, month: 6, day: 22, hour: 8))!
        let expected14 = cal.date(from: DateComponents(year: 2026, month: 6, day: 29, hour: 8))!
        #expect(schedule.fireDates == [expected3, expected7, expected14])
        #expect(center.addedRequests.count == 3)
    }

    @Test("scheduleForInvoice no-ops when masterEnabled is false")
    @MainActor
    func scheduleForInvoiceMasterDisabled() async throws {
        let center = FakeNotificationCenter()
        center.authorized = true
        let container = try BillableModelContainer.inMemory()
        let context = container.mainContext

        let config = ReminderConfig.defaultConfig()
        config.masterEnabled = false
        context.insert(config)

        let client = Client(name: "Acme", color: .blue)
        let profile = BusinessProfile(name: "Me", currencyCode: "USD")
        context.insert(client); context.insert(profile)

        let invoice = Invoice(
            number: "INV-0011", dueAt: Date().addingTimeInterval(86400),
            clientNameSnapshot: "Acme",
            issuerNameSnapshot: "Me", issuerAddressSnapshot: "", issuerEmailSnapshot: "",
            paymentTermsSnapshot: "", taxLabelSnapshot: "Tax", taxRateSnapshot: 0,
            currencyCodeSnapshot: "USD",
            client: client
        )
        try invoice.markSent()
        context.insert(invoice)
        try context.save()

        let scheduler = Scheduler(center: center, modelContext: context)
        _ = try await scheduler.requestAuthorization()
        let service = ReminderService(scheduler: scheduler, modelContext: context)

        try await service.scheduleForInvoice(invoice)
        #expect(invoice.reminderSchedule == nil)
        #expect(center.addedRequests.isEmpty)
    }

    @Test("scheduleForInvoice respects per-client override")
    @MainActor
    func scheduleForInvoiceClientOverride() async throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let center = FakeNotificationCenter()
        center.authorized = true
        let container = try BillableModelContainer.inMemory()
        let context = container.mainContext

        let config = ReminderConfig.defaultConfig()
        config.masterEnabled = true
        config.enabledOffsets = [3, 7]
        context.insert(config)

        let client = Client(name: "Acme", color: .blue, reminderOffsets: [5])
        let profile = BusinessProfile(name: "Me", currencyCode: "USD")
        context.insert(client); context.insert(profile)

        let due = cal.date(from: DateComponents(year: 2026, month: 6, day: 15))!
        let invoice = Invoice(
            number: "INV-0012", dueAt: due,
            clientNameSnapshot: "Acme",
            issuerNameSnapshot: "Me", issuerAddressSnapshot: "", issuerEmailSnapshot: "",
            paymentTermsSnapshot: "", taxLabelSnapshot: "Tax", taxRateSnapshot: 0,
            currencyCodeSnapshot: "USD",
            client: client
        )
        try invoice.markSent()
        context.insert(invoice)
        try context.save()

        let scheduler = Scheduler(center: center, modelContext: context)
        _ = try await scheduler.requestAuthorization()
        let service = ReminderService(scheduler: scheduler, modelContext: context, calendar: cal)
        try await service.scheduleForInvoice(invoice)

        let schedule = try #require(invoice.reminderSchedule)
        #expect(schedule.fireDates.count == 1)
        let expected5 = cal.date(from: DateComponents(year: 2026, month: 6, day: 20, hour: 8))!
        #expect(schedule.fireDates.first == expected5)
    }

    @Test("scheduleForInvoice no-ops when no ReminderConfig exists")
    @MainActor
    func scheduleForInvoiceNoConfig() async throws {
        let center = FakeNotificationCenter()
        center.authorized = true
        let container = try BillableModelContainer.inMemory()
        let context = container.mainContext

        // NO ReminderConfig inserted

        let client = Client(name: "Acme", color: .blue)
        let profile = BusinessProfile(name: "Me", currencyCode: "USD")
        context.insert(client); context.insert(profile)

        let invoice = Invoice(
            number: "INV-0013", dueAt: Date().addingTimeInterval(86400),
            clientNameSnapshot: "Acme",
            issuerNameSnapshot: "Me", issuerAddressSnapshot: "", issuerEmailSnapshot: "",
            paymentTermsSnapshot: "", taxLabelSnapshot: "Tax", taxRateSnapshot: 0,
            currencyCodeSnapshot: "USD",
            client: client
        )
        try invoice.markSent()
        context.insert(invoice)
        try context.save()

        let scheduler = Scheduler(center: center, modelContext: context)
        _ = try await scheduler.requestAuthorization()
        let service = ReminderService(scheduler: scheduler, modelContext: context)
        try await service.scheduleForInvoice(invoice)

        #expect(invoice.reminderSchedule == nil)
        #expect(center.addedRequests.isEmpty)
    }

    // Helper that builds a fully-scheduled invoice fixture used by 4.6 tests.
    @MainActor
    func makeScheduledReminderFixture() async throws -> (ReminderService, Invoice, ModelContainer) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let center = FakeNotificationCenter()
        center.authorized = true
        let container = try BillableModelContainer.inMemory()
        let context = container.mainContext

        let config = ReminderConfig.defaultConfig()
        config.masterEnabled = true
        context.insert(config)

        let client = Client(name: "Acme", color: .blue)
        let profile = BusinessProfile(name: "Me", currencyCode: "USD")
        context.insert(client); context.insert(profile)

        let invoice = Invoice(
            number: "INV-0014",
            dueAt: cal.date(from: DateComponents(year: 2026, month: 6, day: 15))!,
            clientNameSnapshot: "Acme",
            issuerNameSnapshot: "Me", issuerAddressSnapshot: "", issuerEmailSnapshot: "",
            paymentTermsSnapshot: "", taxLabelSnapshot: "Tax", taxRateSnapshot: 0,
            currencyCodeSnapshot: "USD",
            client: client
        )
        try invoice.markSent()
        context.insert(invoice)
        try context.save()

        let scheduler = Scheduler(center: center, modelContext: context)
        _ = try await scheduler.requestAuthorization()
        let service = ReminderService(scheduler: scheduler, modelContext: context, calendar: cal)
        try await service.scheduleForInvoice(invoice)
        return (service, invoice, container)
    }

    @Test("cancelForInvoice removes all pending fires + deletes schedule")
    @MainActor
    func cancelForInvoiceClears() async throws {
        let (service, invoice, container) = try await makeScheduledReminderFixture()
        let scheduleID = try #require(invoice.reminderSchedule?.id)
        let priorCount = try container.mainContext.fetch(FetchDescriptor<ScheduledNotification>()).count
        #expect(priorCount > 0)

        try await service.cancelForInvoice(invoice)

        #expect(invoice.reminderSchedule == nil)
        let after = try container.mainContext.fetch(FetchDescriptor<ScheduledNotification>())
        #expect(after.isEmpty)
        // Schedule row also gone
        let scheduleRows = try container.mainContext.fetch(
            FetchDescriptor<InvoiceReminderSchedule>(predicate: #Predicate { $0.id == scheduleID })
        )
        #expect(scheduleRows.isEmpty)
    }

    @Test("cancelForInvoice is idempotent (no-op when no schedule exists)")
    @MainActor
    func cancelForInvoiceIdempotent() async throws {
        let container = try BillableModelContainer.inMemory()
        let context = container.mainContext
        let center = FakeNotificationCenter()
        center.authorized = true

        let client = Client(name: "Acme", color: .blue)
        let profile = BusinessProfile(name: "Me", currencyCode: "USD")
        context.insert(client); context.insert(profile)

        let invoice = Invoice(
            number: "INV-0015", dueAt: Date(),
            clientNameSnapshot: "Acme",
            issuerNameSnapshot: "Me", issuerAddressSnapshot: "", issuerEmailSnapshot: "",
            paymentTermsSnapshot: "", taxLabelSnapshot: "Tax", taxRateSnapshot: 0,
            currencyCodeSnapshot: "USD",
            client: client
        )
        context.insert(invoice)
        try context.save()

        let scheduler = Scheduler(center: center, modelContext: context)
        _ = try await scheduler.requestAuthorization()
        let service = ReminderService(scheduler: scheduler, modelContext: context)

        // No schedule exists — should be no-op, no throw
        try await service.cancelForInvoice(invoice)
        #expect(invoice.reminderSchedule == nil)
    }

    @Test("recordFired appends to firedDates so the step doesn't repeat")
    @MainActor
    func recordFiredAppends() async throws {
        let (service, invoice, container) = try await makeScheduledReminderFixture()
        _ = container  // keep the container alive — required because Scheduler captures its context
        let schedule = try #require(invoice.reminderSchedule)
        let firstFire = try #require(schedule.fireDates.first)

        service.recordFired(invoice: invoice, at: firstFire)
        #expect(invoice.reminderSchedule?.firedDates == [firstFire])

        // Second call is idempotent — no duplicate
        service.recordFired(invoice: invoice, at: firstFire)
        #expect(invoice.reminderSchedule?.firedDates.count == 1)
    }

    @Test("recordFired is a no-op when invoice has no schedule")
    @MainActor
    func recordFiredNoSchedule() async throws {
        let container = try BillableModelContainer.inMemory()
        let context = container.mainContext
        let center = FakeNotificationCenter()
        center.authorized = true
        let client = Client(name: "Acme", color: .blue)
        let profile = BusinessProfile(name: "Me", currencyCode: "USD")
        context.insert(client); context.insert(profile)
        let invoice = Invoice(
            number: "INV-0016", dueAt: Date(),
            clientNameSnapshot: "Acme",
            issuerNameSnapshot: "Me", issuerAddressSnapshot: "", issuerEmailSnapshot: "",
            paymentTermsSnapshot: "", taxLabelSnapshot: "Tax", taxRateSnapshot: 0,
            currencyCodeSnapshot: "USD",
            client: client
        )
        context.insert(invoice)
        try context.save()

        let scheduler = Scheduler(center: center, modelContext: context)
        let service = ReminderService(scheduler: scheduler, modelContext: context)

        // No throw, no crash
        service.recordFired(invoice: invoice, at: Date())
        #expect(invoice.reminderSchedule == nil)  // still nil
    }

    @Test("Invoice.markSent fires didMarkSentHook")
    @MainActor
    func markSentFiresHook() async throws {
        let container = try BillableModelContainer.inMemory()
        let context = container.mainContext
        let client = Client(name: "Acme", color: .blue)
        let profile = BusinessProfile(name: "Me", currencyCode: "USD")
        context.insert(client); context.insert(profile)
        let invoice = Invoice(
            number: "INV-0050", dueAt: Date(),
            clientNameSnapshot: "Acme",
            issuerNameSnapshot: "Me", issuerAddressSnapshot: "", issuerEmailSnapshot: "",
            paymentTermsSnapshot: "", taxLabelSnapshot: "Tax", taxRateSnapshot: 0,
            currencyCodeSnapshot: "USD",
            client: client
        )
        context.insert(invoice)
        try context.save()

        // Capture the invoice the hook receives. We extract uuid (Sendable) inside
        // the @MainActor hook closure before crossing into the actor, which avoids
        // sending a non-Sendable Invoice value across isolation boundaries.
        //
        // We save+restore the hook around the test so that parallel tests that also
        // call markSent() don't stomp on this test's `captured` actor.
        let previousSentHook = Invoice.didMarkSentHook
        let captured = HookCapture()
        Invoice.didMarkSentHook = { @MainActor inv in
            let id = inv.uuid
            await captured.capture(id: id)
        }
        defer { Invoice.didMarkSentHook = previousSentHook }

        try invoice.markSent()
        // Wait for the fire-and-forget Task to run. The Task is enqueued on the
        // main actor; we yield here so the scheduler can execute it. The explicit
        // wait-loop (up to 500ms) makes the test robust under parallel test load.
        let targetID = invoice.uuid
        var waited = 0
        while await !captured.invoiceIDs.contains(targetID), waited < 500 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 10
        }
        #expect(await captured.invoiceIDs.contains(invoice.uuid))
    }

    @Test("Invoice.markPaid fires didMarkPaidHook")
    @MainActor
    func markPaidFiresHook() async throws {
        let container = try BillableModelContainer.inMemory()
        let context = container.mainContext
        let client = Client(name: "Acme", color: .blue)
        let profile = BusinessProfile(name: "Me", currencyCode: "USD")
        context.insert(client); context.insert(profile)
        let invoice = Invoice(
            number: "INV-0051", dueAt: Date(),
            clientNameSnapshot: "Acme",
            issuerNameSnapshot: "Me", issuerAddressSnapshot: "", issuerEmailSnapshot: "",
            paymentTermsSnapshot: "", taxLabelSnapshot: "Tax", taxRateSnapshot: 0,
            currencyCodeSnapshot: "USD",
            client: client
        )
        context.insert(invoice)
        try context.save()
        try invoice.markSent()

        let previousPaidHook = Invoice.didMarkPaidHook
        let captured = HookCapture()
        Invoice.didMarkPaidHook = { @MainActor inv in
            let id = inv.uuid
            await captured.capture(id: id)
        }
        defer { Invoice.didMarkPaidHook = previousPaidHook }

        try invoice.markPaid()
        let targetIDPaid = invoice.uuid
        var waitedPaid = 0
        while await !captured.invoiceIDs.contains(targetIDPaid), waitedPaid < 500 {
            try await Task.sleep(for: .milliseconds(10))
            waitedPaid += 10
        }
        #expect(await captured.invoiceIDs.contains(invoice.uuid))
    }

    @Test("BadgeCount.compute counts pending recurrence materializations + pending reminder fires")
    @MainActor
    func badgeCountCombines() async throws {
        let container = try BillableModelContainer.inMemory()
        let context = container.mainContext

        let client = Client(name: "Acme", color: .blue)
        let profile = BusinessProfile(name: "Me", currencyCode: "USD")
        context.insert(client); context.insert(profile)

        // 1 pending recurrence: nextFireDate in the past, active, not ended
        let past = Date().addingTimeInterval(-3600)
        context.insert(RecurrenceTemplate(
            client: client, cadence: .monthly(dayOfMonth: 1),
            grouping: .perEntry, nextFireDate: past
        ))

        // 1 sent invoice with an unfired past reminder step
        let invoice = Invoice(
            number: "INV-0099",
            dueAt: Date().addingTimeInterval(-86400 * 4),
            clientNameSnapshot: "Acme",
            issuerNameSnapshot: "Me", issuerAddressSnapshot: "", issuerEmailSnapshot: "",
            paymentTermsSnapshot: "", taxLabelSnapshot: "Tax", taxRateSnapshot: 0,
            currencyCodeSnapshot: "USD",
            client: client
        )
        try invoice.markSent()
        let schedule = InvoiceReminderSchedule(
            invoice: invoice,
            fireDates: [Date().addingTimeInterval(-3600)],  // 1 fire in the past
            firedDates: []                                    // not acted on
        )
        invoice.reminderSchedule = schedule
        context.insert(invoice); context.insert(schedule)
        try context.save()

        let count = BadgeCount.compute(context: context, now: Date())
        #expect(count == 2)  // 1 recurrence + 1 reminder
    }

    @Test("BadgeCount.compute excludes paid invoices' reminder fires")
    @MainActor
    func badgeCountExcludesPaid() async throws {
        let container = try BillableModelContainer.inMemory()
        let context = container.mainContext

        let client = Client(name: "Acme", color: .blue)
        let profile = BusinessProfile(name: "Me", currencyCode: "USD")
        context.insert(client); context.insert(profile)

        let invoice = Invoice(
            number: "INV-0100",
            dueAt: Date().addingTimeInterval(-86400 * 4),
            clientNameSnapshot: "Acme",
            issuerNameSnapshot: "Me", issuerAddressSnapshot: "", issuerEmailSnapshot: "",
            paymentTermsSnapshot: "", taxLabelSnapshot: "Tax", taxRateSnapshot: 0,
            currencyCodeSnapshot: "USD",
            client: client
        )
        try invoice.markSent()
        try invoice.markPaid()  // Now status is .paid
        let schedule = InvoiceReminderSchedule(
            invoice: invoice,
            fireDates: [Date().addingTimeInterval(-3600)],
            firedDates: []
        )
        invoice.reminderSchedule = schedule
        context.insert(invoice); context.insert(schedule)
        try context.save()

        let count = BadgeCount.compute(context: context, now: Date())
        #expect(count == 0)  // Paid invoice's fires don't count
    }

    @Test("BadgeCount.compute excludes already-fired reminder steps")
    @MainActor
    func badgeCountExcludesAlreadyFired() async throws {
        let container = try BillableModelContainer.inMemory()
        let context = container.mainContext

        let client = Client(name: "Acme", color: .blue)
        let profile = BusinessProfile(name: "Me", currencyCode: "USD")
        context.insert(client); context.insert(profile)

        let pastFire = Date().addingTimeInterval(-3600)
        let invoice = Invoice(
            number: "INV-0101",
            dueAt: Date().addingTimeInterval(-86400 * 4),
            clientNameSnapshot: "Acme",
            issuerNameSnapshot: "Me", issuerAddressSnapshot: "", issuerEmailSnapshot: "",
            paymentTermsSnapshot: "", taxLabelSnapshot: "Tax", taxRateSnapshot: 0,
            currencyCodeSnapshot: "USD",
            client: client
        )
        try invoice.markSent()
        let schedule = InvoiceReminderSchedule(
            invoice: invoice,
            fireDates: [pastFire],
            firedDates: [pastFire]  // Already acted on
        )
        invoice.reminderSchedule = schedule
        context.insert(invoice); context.insert(schedule)
        try context.save()

        let count = BadgeCount.compute(context: context, now: Date())
        #expect(count == 0)
    }

}

// Small actor helper for capturing UUID(s) from a fire-and-forget hook Task.
// Stores a set so parallel tests that share the same static hook don't lose IDs
// via last-write-wins. Tests check containment, not equality.
// We receive only the UUID (Sendable) to avoid sending a non-Sendable Invoice
// value across isolation boundaries.
actor HookCapture {
    private(set) var invoiceIDs: Set<UUID> = []
    func capture(id: UUID) {
        invoiceIDs.insert(id)
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
