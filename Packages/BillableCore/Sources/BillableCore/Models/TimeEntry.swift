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

    /// Worked seconds banked from completed work segments (before the current
    /// active segment / before each break). The source of truth for billable
    /// time once breaks exist. 0 for manual/legacy entries (see `duration`).
    public var accumulatedSeconds: Double = 0

    /// Start of the current *working* segment. `nil` while On Break or finished.
    public var activeSegmentStartedAt: Date? = nil

    public var createdAt: Date
    public var updatedAt: Date

    public var project: Project?

    public init(
        startedAt: Date,
        endedAt: Date? = nil,
        notes: String? = nil,
        isManual: Bool = false,
        project: Project? = nil,
        accumulatedSeconds: Double = 0,
        activeSegmentStartedAt: Date? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.notes = notes
        self.isManual = isManual
        self.project = project
        self.accumulatedSeconds = accumulatedSeconds
        self.activeSegmentStartedAt = activeSegmentStartedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var isRunning: Bool { endedAt == nil }
    /// Active session, currently counting.
    public var isWorking: Bool { endedAt == nil && activeSegmentStartedAt != nil }
    /// Active session, paused (count frozen).
    public var isOnBreak: Bool { endedAt == nil && activeSegmentStartedAt == nil }

    /// WORKED duration in seconds, breaks excluded.
    /// - Finished: banked worked time; manual/legacy entries (no banking) fall
    ///   back to wall-clock end-start.
    /// - Working: banked + the live segment.
    /// - On break: banked (frozen).
    public func duration(asOf referenceDate: Date = .now) -> TimeInterval {
        if let end = endedAt {
            return accumulatedSeconds > 0 ? accumulatedSeconds : max(0, end.timeIntervalSince(startedAt))
        }
        if let segStart = activeSegmentStartedAt {
            return accumulatedSeconds + max(0, referenceDate.timeIntervalSince(segStart))
        }
        // On Break: count is frozen at the banked worked total.
        return accumulatedSeconds
    }

    /// Amount earned for this entry, computed against the project's current rate.
    /// Returns 0 for non-billable projects.
    public func amount(asOf referenceDate: Date = .now) -> Decimal {
        guard let project, project.isBillable else { return 0 }
        let hours = Decimal(duration(asOf: referenceDate) / 3600)
        return hours * project.hourlyRate
    }
}
