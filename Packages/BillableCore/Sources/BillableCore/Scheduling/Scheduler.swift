import Foundation
import SwiftData
import UserNotifications
import OSLog

/// Test seam over `UNUserNotificationCenter` — narrow to what `Scheduler` uses.
public protocol NotificationCenterProtocol: Sendable {
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func authorizationStatus() async -> UNAuthorizationStatus
    func add(_ request: UNNotificationRequest) async throws
    func getPendingNotificationRequests() async -> [UNNotificationRequest]
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
}

/// The real `UNUserNotificationCenter` adopts the protocol via this extension.
///
/// - `requestAuthorization(options:)` — already async throws on `UNUserNotificationCenter`
/// - `add(_:)` — already async throws on `UNUserNotificationCenter`
/// - `removePendingNotificationRequests(withIdentifiers:)` — sync on `UNUserNotificationCenter`
/// - `authorizationStatus()` and `getPendingNotificationRequests()` need async wrappers.
extension UNUserNotificationCenter: NotificationCenterProtocol {
    public func authorizationStatus() async -> UNAuthorizationStatus {
        await notificationSettings().authorizationStatus
    }

    public func getPendingNotificationRequests() async -> [UNNotificationRequest] {
        // UNNotificationRequest is an ObjC class not annotated Sendable; the
        // nonisolated(unsafe) lets us shuttle the array across the concurrency
        // boundary without a data race — the completion handler is called once
        // and the continuation resumes immediately after.
        nonisolated(unsafe) var captured: [UNNotificationRequest] = []
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            getPendingNotificationRequests { requests in
                captured = requests
                continuation.resume()
            }
        }
        return captured
    }
}

/// Domain-knowledge-free local-notification scheduler.
///
/// Wraps `UNUserNotificationCenter` requests and persists each pending
/// notification's `(id, fireAt, payload)` to SwiftData for cold-launch
/// reconciliation (iOS drops scheduled notifications across force-quits,
/// reboots, and the 64-pending overflow).
///
/// Knows nothing about invoices, reminders, or recurrences — those concepts
/// live in `RecurrenceService` and `ReminderService`, which use this primitive
/// via `SchedulerPayload` for opaque tap routing.
@MainActor
public final class Scheduler {
    public enum ScheduleResult: Equatable, Sendable {
        case scheduled
        case noPermission
        case capExceeded
    }

    private let center: any NotificationCenterProtocol
    private let modelContext: ModelContext
    private let log = Logger(subsystem: "com.eldenstudios.billable", category: "Scheduler")

    /// Soft cap to stay under iOS's 64-pending hard cap with headroom.
    public static let softCap = 60

    public init(center: any NotificationCenterProtocol, modelContext: ModelContext) {
        self.center = center
        self.modelContext = modelContext
    }

    public func requestAuthorization() async throws -> Bool {
        let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        log.info("Authorization request: granted=\(granted, privacy: .public)")
        return granted
    }

    public func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        await center.authorizationStatus()
    }
}
