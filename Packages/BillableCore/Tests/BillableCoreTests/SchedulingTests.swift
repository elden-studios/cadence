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
