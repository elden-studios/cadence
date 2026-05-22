import Foundation
import SwiftData

@Model
public final class TimeEntry {
    public var startedAt: Date
    /// `nil` indicates the entry is still running.
    public var endedAt: Date?
    public var notes: String?
    /// True when added/edited by hand rather than by the live timer. Useful in audit trails and reports.
    public var isManual: Bool

    /// Set to the `Invoice.uuid` once the entry is included in a finalized (`Sent`) invoice.
    /// Used to compute "uninvoiced amount" and prevent double-invoicing.
    /// Stored as a UUID (not a SwiftData PersistentIdentifier) so it survives
    /// store re-creation, CloudKit sync, and CSV export cleanly.
    public var invoiceID: UUID?

    public var createdAt: Date
    public var updatedAt: Date

    public var project: Project?

    public init(
        startedAt: Date,
        endedAt: Date? = nil,
        notes: String? = nil,
        isManual: Bool = false,
        project: Project? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.notes = notes
        self.isManual = isManual
        self.project = project
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var isRunning: Bool { endedAt == nil }

    /// Duration in seconds. For running timers, computed against `referenceDate` (default = now).
    public func duration(asOf referenceDate: Date = .now) -> TimeInterval {
        let end = endedAt ?? referenceDate
        return max(0, end.timeIntervalSince(startedAt))
    }

    /// Amount earned for this entry, computed against the project's current rate.
    /// Returns 0 for non-billable projects.
    public func amount(asOf referenceDate: Date = .now) -> Decimal {
        guard let project, project.isBillable else { return 0 }
        let hours = Decimal(duration(asOf: referenceDate) / 3600)
        return hours * project.hourlyRate
    }
}
