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

// MARK: - Resume pill visibility

extension TimeEntry {
    /// Whether the "Resume Last" pill should appear on Today, given the most-recently
    /// stopped TimeEntry. Returns false in any of:
    /// - lastStopped is nil
    /// - lastStopped has no endedAt (still running)
    /// - lastStopped has no project (data corruption edge case)
    /// - lastStopped ended more than 60 min ago
    /// - lastStopped ended on a different calendar day than `now`
    ///
    /// Pure function — pass an explicit calendar for tests across time zones.
    public static func shouldShowResumePill(
        lastStopped: TimeEntry?,
        now: Date,
        calendar: Calendar = .current
    ) -> Bool {
        guard let entry = lastStopped else { return false }
        guard let endedAt = entry.endedAt else { return false }
        guard entry.project != nil else { return false }
        let secondsSince = now.timeIntervalSince(endedAt)
        guard secondsSince >= 0, secondsSince < 60 * 60 else { return false }
        guard calendar.isDate(now, inSameDayAs: endedAt) else { return false }
        return true
    }
}
