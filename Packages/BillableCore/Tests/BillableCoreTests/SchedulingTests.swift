import Foundation
import SwiftData
import Testing
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
}
