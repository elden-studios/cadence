import Foundation

/// Errors raised by Invoice state-machine transitions.
public enum InvoiceTransitionError: Error, Equatable {
    /// The transition requested is not legal from the current status.
    case illegalTransition(from: InvoiceStatus, to: InvoiceStatus)
}

extension Invoice {
    /// Move a Draft invoice to Sent. Records `sentAt` and bumps `updatedAt`.
    /// Once `sent`, the invoice's line items are conceptually frozen.
    public func markSent(at date: Date = .now) throws {
        guard status == .draft else {
            throw InvoiceTransitionError.illegalTransition(from: status, to: .sent)
        }
        status = .sent
        sentAt = date
        updatedAt = date
    }

    /// Move a Sent invoice to Paid. Records `paidAt` and bumps `updatedAt`.
    public func markPaid(at date: Date = .now) throws {
        guard status == .sent else {
            throw InvoiceTransitionError.illegalTransition(from: status, to: .paid)
        }
        status = .paid
        paidAt = date
        updatedAt = date
    }
}
