import Foundation
import Observation

/// Bridge between the AppDelegate's notification-tap callback and the SwiftUI
/// navigation tree. Set by `Scheduler.handleNotificationTap`-derived flows in
/// the AppDelegate; observed by `RootView`, which clears `pendingDestination`
/// after navigating.
///
/// Why this lives in `BillableCore` rather than the app target: services
/// (RecurrenceService / ReminderService) and the AppDelegate both need to
/// reference the `Destination` enum, and keeping it in the package avoids
/// pulling the app target into the testable surface.
@MainActor
@Observable
public final class NotificationRouter {
    public enum Destination: Hashable, Sendable {
        /// Recurrence fired → route to the invoice preview for the new draft.
        case invoicePreview(invoiceID: UUID)
        /// Overdue reminder tapped → route to the invoice detail.
        case invoiceDetail(invoiceID: UUID)
        /// Tap from a catch-up banner / generic recurrence tap → route to the
        /// Recurring list segment of the Invoices tab.
        case recurringList
    }

    public var pendingDestination: Destination?

    public init(pendingDestination: Destination? = nil) {
        self.pendingDestination = pendingDestination
    }
}
