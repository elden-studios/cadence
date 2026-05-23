import Foundation

/// Opaque payload routed by `Scheduler.handleNotificationTap`.
/// Kept here (and not in `Scheduler.swift`) so services can reference the
/// payload type without pulling in the full Scheduler implementation.
public enum SchedulerPayload: Equatable, Sendable {
    case recurrence(templateID: UUID)
    case reminder(scheduleID: UUID)

    /// String form stored in `ScheduledNotification.payloadType` +
    /// `ScheduledNotification.payloadID`.
    public func encoded() -> (type: String, id: UUID) {
        switch self {
        case .recurrence(let id): return ("recurrence", id)
        case .reminder(let id):   return ("reminder",   id)
        }
    }

    public static func decode(payloadType: String, payloadID: UUID) -> SchedulerPayload? {
        switch payloadType {
        case "recurrence": return .recurrence(templateID: payloadID)
        case "reminder":   return .reminder(scheduleID: payloadID)
        default:           return nil
        }
    }
}
