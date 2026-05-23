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
