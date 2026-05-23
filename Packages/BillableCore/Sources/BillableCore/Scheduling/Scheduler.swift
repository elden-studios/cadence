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

    /// Register a local notification + persist its bookkeeping row.
    /// Returns `.noPermission` if the user hasn't authorized; in that case
    /// no iOS request is registered and no SwiftData row is created.
    /// Returns `.capExceeded` when iOS pending count is at or above the
    /// soft cap; a SwiftData row IS still created so `resyncOnLaunch` can
    /// register it later when capacity frees up.
    @discardableResult
    public func schedule(
        payload: SchedulerPayload,
        fireAt: Date,
        title: String,
        body: String
    ) async throws -> ScheduleResult {
        guard await center.authorizationStatus() == .authorized else {
            log.info("schedule(): no permission; skipping")
            return .noPermission
        }

        let pending = await center.getPendingNotificationRequests().count
        // type = payload discriminator string; payloadID = entity UUID (templateID or scheduleID),
        // NOT the new ScheduledNotification.id that SwiftData will generate.
        let (type, payloadID) = payload.encoded()

        guard pending < Self.softCap else {
            log.notice("schedule(): soft cap reached (\(pending, privacy: .public))")
            // Persist the row so resync can register it later when capacity frees up.
            let note = ScheduledNotification(
                fireAt: fireAt, payloadType: type, payloadID: payloadID
            )
            modelContext.insert(note)
            try modelContext.save()
            return .capExceeded
        }

        let note = ScheduledNotification(
            fireAt: fireAt, payloadType: type, payloadID: payloadID
        )
        modelContext.insert(note)
        try modelContext.save()

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        // Minute granularity is intentional — all callers (8am daily) fire at :00 seconds.
        // Add .second here if sub-minute precision ever becomes necessary.
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: fireAt
            ),
            repeats: false
        )
        let request = UNNotificationRequest(
            identifier: note.id.uuidString,
            content: content,
            trigger: trigger
        )
        try await center.add(request)
        log.info("schedule(): id=\(note.id.uuidString, privacy: .public) fireAt=\(fireAt, privacy: .public)")
        return .scheduled
    }

    /// Cancel a previously-registered notification by id. Removes both the
    /// iOS pending request and the SwiftData bookkeeping row. Idempotent —
    /// calling on a nonexistent id is a no-op (no throw, no side effect).
    ///
    /// `id` is the `ScheduledNotification.id` (the iOS request identifier),
    /// not `payloadID` (the entity FK stored in the payload).
    ///
    /// Save errors during row deletion are intentionally silenced via `try?`
    /// — cancel is non-throwing and idempotent by contract.
    public func cancel(id: UUID) {
        center.removePendingNotificationRequests(withIdentifiers: [id.uuidString])
        let descriptor = FetchDescriptor<ScheduledNotification>(
            predicate: #Predicate { $0.id == id }
        )
        if let rows = try? modelContext.fetch(descriptor) {
            for row in rows { modelContext.delete(row) }
            try? modelContext.save()
        }
        log.info("cancel(): id=\(id.uuidString, privacy: .public)")
    }
}
