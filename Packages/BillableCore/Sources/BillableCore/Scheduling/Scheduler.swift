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

    public struct ResyncResult: Equatable, Sendable {
        public let reregistered: Int
        public let pruned: Int

        public init(reregistered: Int, pruned: Int) {
            self.reregistered = reregistered
            self.pruned = pruned
        }
    }

    /// Called from `AppDelegate` / `App.scene(_:willConnectTo:options:)` on
    /// cold launch. Reconciles SwiftData rows against iOS pending requests.
    ///
    /// - Prunes rows whose `fireAt` is in the past — iOS has already delivered
    ///   them (or dropped them), and the owning service updates state on tap.
    /// - Re-registers any future rows that iOS no longer has pending (e.g.,
    ///   dropped across a reboot or force-quit).
    @discardableResult
    public func resyncOnLaunch(now: Date = .now) async -> ResyncResult {
        // 1. Prune past rows.
        let pastDescriptor = FetchDescriptor<ScheduledNotification>(
            predicate: #Predicate { $0.fireAt < now }
        )
        var pruned = 0
        if let pastRows = try? modelContext.fetch(pastDescriptor) {
            for row in pastRows { modelContext.delete(row) }
            pruned = pastRows.count
        }

        // 2. For future rows, check if iOS still has the request; re-register the
        //    missing ones. The placeholder title/body is intentional — services
        //    that care issue richer notifications via cancel(id:) + schedule(...)
        //    when they detect they need to refresh content.
        let pending = await center.getPendingNotificationRequests()
        let pendingIDs = Set(pending.map(\.identifier))
        let futureDescriptor = FetchDescriptor<ScheduledNotification>(
            predicate: #Predicate { $0.fireAt >= now }
        )
        var reregistered = 0
        if let futureRows = try? modelContext.fetch(futureDescriptor) {
            for row in futureRows where !pendingIDs.contains(row.id.uuidString) {
                let content = UNMutableNotificationContent()
                content.title = "Cadence"
                content.body  = "Tap to review."
                content.sound = .default
                let trigger = UNCalendarNotificationTrigger(
                    dateMatching: Calendar.current.dateComponents(
                        [.year, .month, .day, .hour, .minute],
                        from: row.fireAt
                    ),
                    repeats: false
                )
                let request = UNNotificationRequest(
                    identifier: row.id.uuidString,
                    content: content,
                    trigger: trigger
                )
                try? await center.add(request)
                reregistered += 1
            }
        }

        try? modelContext.save()
        log.info("resyncOnLaunch(): reregistered=\(reregistered, privacy: .public) pruned=\(pruned, privacy: .public)")
        return ResyncResult(reregistered: reregistered, pruned: pruned)
    }

    /// Called by `AppDelegate` when the user taps a delivered notification.
    /// Returns the decoded payload (or nil if unknown / row missing) so the
    /// caller can route to the appropriate destination via `NotificationRouter`.
    public func handleNotificationTap(requestIdentifier: String) -> SchedulerPayload? {
        guard let id = UUID(uuidString: requestIdentifier) else { return nil }
        let descriptor = FetchDescriptor<ScheduledNotification>(
            predicate: #Predicate { $0.id == id }
        )
        guard let row = try? modelContext.fetch(descriptor).first else { return nil }
        return SchedulerPayload.decode(payloadType: row.payloadType, payloadID: row.payloadID)
    }
}
