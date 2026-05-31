import Foundation

/// Errors raised by Invoice state-machine transitions.
public enum InvoiceTransitionError: Error, Equatable {
    /// The transition requested is not legal from the current status.
    case illegalTransition(from: InvoiceStatus, to: InvoiceStatus)
}

extension Invoice {
    /// Set by the app target at startup so `markSent` can schedule reminders
    /// without `BillableCore` directly depending on `ReminderService`. Wired
    /// in `BillableApp.performStartupWiring()` (Task 5.4).
    ///
    /// `nonisolated(unsafe)` is intentional: these are set exactly once at app
    /// startup — before any invoice transition can run — so the write-before-read
    /// ordering is guaranteed in practice even though Swift can't prove it.
    nonisolated(unsafe) public static var didMarkSentHook: (@MainActor (Invoice) async -> Void)?
    nonisolated(unsafe) public static var didMarkPaidHook: (@MainActor (Invoice) async -> Void)?

    /// Move a Draft invoice to Sent. Records `sentAt` and bumps `updatedAt`.
    /// Once `sent`, the invoice's line items are conceptually frozen.
    public func markSent(at date: Date = .now) throws {
        guard status == .draft else {
            throw InvoiceTransitionError.illegalTransition(from: status, to: .sent)
        }
        status = .sent
        sentAt = date
        updatedAt = date
        if let hook = Self.didMarkSentHook {
            // `nonisolated(unsafe)` bridges `self` (a non-Sendable @Model) into
            // the @MainActor Task. Safe in practice: all Invoice mutations happen
            // on the main context, so there's no concurrent access after this call.
            nonisolated(unsafe) let invoice = self
            Task { @MainActor in await hook(invoice) }
        }
    }

    /// Move a Sent invoice to Paid. Records `paidAt` and bumps `updatedAt`.
    public func markPaid(at date: Date = .now) throws {
        guard status == .sent else {
            throw InvoiceTransitionError.illegalTransition(from: status, to: .paid)
        }
        status = .paid
        paidAt = date
        updatedAt = date
        if let hook = Self.didMarkPaidHook {
            nonisolated(unsafe) let invoice = self
            Task { @MainActor in await hook(invoice) }
        }
    }

    /// Reverse a Sent invoice back to Draft (the only legal reverse transition).
    /// Clears `sentAt` and bumps `updatedAt`. Paid invoices cannot be reopened.
    /// The CALLER re-marks source entries uninvoiced and cancels reminders.
    public func reopenToDraft(at date: Date = .now) throws {
        guard status == .sent else {
            throw InvoiceTransitionError.illegalTransition(from: status, to: .draft)
        }
        status = .draft
        sentAt = nil
        updatedAt = date
    }
}
