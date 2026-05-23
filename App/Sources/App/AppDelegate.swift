import UIKit
import UserNotifications
import SwiftData
import BillableCore

/// Minimal AppDelegate. Sole job: be the `UNUserNotificationCenterDelegate`
/// and route taps into `NotificationRouter`.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    /// Set by `BillableApp.performStartupWiring()` so the delegate can use the
    /// same NotificationRouter instance that's injected into the SwiftUI environment.
    nonisolated(unsafe) static var sharedRouter: NotificationRouter?

    /// Set similarly so we can run `Scheduler.handleNotificationTap` against the
    /// real model context.
    nonisolated(unsafe) static var sharedSchedulerFactory: (@MainActor () -> Scheduler)?

    /// Set so the tap resolver can fetch InvoiceReminderSchedule rows directly
    /// when resolving `.reminder` destinations (refined in Task 5.4).
    nonisolated(unsafe) static var sharedModelContext: ModelContext?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    // Foreground delivery: still show the banner + sound (default is silent).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // Tap handler — routes the request identifier through Scheduler to a payload,
    // then sets `NotificationRouter.pendingDestination` so SwiftUI can navigate.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let requestID = response.notification.request.identifier
        // Capture the completion handler as nonisolated(unsafe) so the async
        // Task body (which is @MainActor-isolated) can call it without triggering
        // Swift 6 data-race warnings. The handler is safe to invoke from any
        // context — UNUserNotificationCenter guarantees it.
        nonisolated(unsafe) let handler = completionHandler
        Task { @MainActor in
            defer { handler() }
            guard let router = Self.sharedRouter,
                  let factory = Self.sharedSchedulerFactory else { return }
            let scheduler = factory()
            guard let payload = scheduler.handleNotificationTap(requestIdentifier: requestID) else {
                return
            }
            router.pendingDestination = Self.destination(for: payload)
        }
    }

    /// Map a `SchedulerPayload` to a `NotificationRouter.Destination`. For v1.1 we
    /// route both .recurrence and .reminder taps to the Recurring list — Task 5.4
    /// will refine .reminder to .invoiceDetail(invoiceID:) by looking up the
    /// owning invoice from `InvoiceReminderSchedule`.
    @MainActor
    private static func destination(for payload: SchedulerPayload) -> NotificationRouter.Destination {
        switch payload {
        case .recurrence: .recurringList
        case .reminder:   .recurringList
        }
    }
}
