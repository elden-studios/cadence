import Foundation
import SwiftData

/// Stateless service for starting/stopping/switching the timer.
///
/// Lives in `BillableCore` so the same logic is reachable from the iOS app,
/// the watchOS companion, App Intents (Siri / Shortcuts), and widget intents.
/// Operates directly on a `ModelContext` — callers supply the right one for
/// their target (main app context, intent-isolated context, etc.).
///
/// Invariant: there is **at most one** running `TimeEntry` at a time.
/// `start(project:in:)` and `switchTo(project:in:)` both enforce this by
/// stopping any existing running entry before creating the new one.
public enum TimerService {

    public enum TimerError: Error, Equatable {
        /// The project the caller wants to start a timer for is archived.
        case projectIsArchived
        /// No timer is currently running, but the caller asked to stop one.
        case noRunningTimer
        /// The caller asked to switch into the same project that's already running.
        case alreadyTrackingSameProject
        /// Caller asked to take a break but the active session is already on break.
        case alreadyOnBreak
        /// Caller asked to resume but the active session is not on break.
        case notOnBreak
    }

    public enum AdjustError: Error, Equatable, Sendable {
        case startInFuture
        case entryNotRunning
    }

    /// The currently running TimeEntry, if any. `nil` when idle.
    @MainActor
    public static func currentRunningEntry(in context: ModelContext) -> TimeEntry? {
        var descriptor = FetchDescriptor<TimeEntry>(
            predicate: #Predicate { $0.endedAt == nil }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// Start tracking time for `project`. If a different timer is currently
    /// running, it is stopped at `at` (the same instant) so there are no gaps
    /// or overlaps in the timeline.
    @MainActor
    @discardableResult
    public static func start(
        project: Project,
        at start: Date = .now,
        notes: String? = nil,
        in context: ModelContext
    ) throws -> TimeEntry {
        guard !project.isArchived else { throw TimerError.projectIsArchived }

        if let running = currentRunningEntry(in: context) {
            if running.project?.persistentModelID == project.persistentModelID {
                // Caller is asking to start a timer for the project that's already running.
                // Treat as a no-op — the running entry continues uninterrupted.
                return running
            }
            finalize(running, at: start)
        }

        let entry = TimeEntry(
            startedAt: start,
            endedAt: nil,
            notes: notes,
            isManual: false,
            project: project,
            activeSegmentStartedAt: start
        )
        context.insert(entry)
        try context.save()
        return entry
    }

    /// Stop the currently running timer. Errors if nothing is running so the
    /// caller can decide whether that's surprising (UI should suppress; intents
    /// surface as "no timer to stop").
    @MainActor
    public static func stop(
        at end: Date = .now,
        in context: ModelContext
    ) throws -> TimeEntry {
        guard let running = currentRunningEntry(in: context) else {
            throw TimerError.noRunningTimer
        }
        finalize(running, at: end)
        try context.save()
        return running
    }

    /// Finalize an active entry at `end`: bank any open working segment, clear
    /// the segment marker, and set `endedAt`. Clamps `end` to ≥ startedAt+1s.
    @MainActor
    private static func finalize(_ entry: TimeEntry, at end: Date) {
        let safeEnd = max(end, entry.startedAt.addingTimeInterval(1))
        if let segStart = entry.activeSegmentStartedAt {
            entry.accumulatedSeconds += max(0, safeEnd.timeIntervalSince(segStart))
            entry.activeSegmentStartedAt = nil
        }
        entry.endedAt = safeEnd
        entry.updatedAt = safeEnd
    }

    /// Pause the active session: bank the current working segment and freeze the
    /// count. The entry stays active (`endedAt == nil`) but `isOnBreak`.
    @MainActor
    @discardableResult
    public static func takeBreak(at instant: Date = .now, in context: ModelContext) throws -> TimeEntry {
        guard let running = currentRunningEntry(in: context) else { throw TimerError.noRunningTimer }
        guard let segStart = running.activeSegmentStartedAt else { throw TimerError.alreadyOnBreak }
        running.accumulatedSeconds += max(0, instant.timeIntervalSince(segStart))
        running.activeSegmentStartedAt = nil
        running.updatedAt = instant
        try context.save()
        return running
    }

    /// Resume an On-Break session: start a new working segment.
    @MainActor
    @discardableResult
    public static func resume(at instant: Date = .now, in context: ModelContext) throws -> TimeEntry {
        guard let running = currentRunningEntry(in: context) else { throw TimerError.noRunningTimer }
        guard running.activeSegmentStartedAt == nil else { throw TimerError.notOnBreak }
        running.activeSegmentStartedAt = instant
        running.updatedAt = instant
        try context.save()
        return running
    }

    /// Atomic stop + start: ends any running timer and starts a new one at the
    /// same instant. Convenience wrapper around `start(project:in:)`.
    @MainActor
    @discardableResult
    public static func switchTo(
        project: Project,
        at instant: Date = .now,
        in context: ModelContext
    ) throws -> TimeEntry {
        guard !project.isArchived else { throw TimerError.projectIsArchived }

        if let running = currentRunningEntry(in: context),
           running.project?.persistentModelID == project.persistentModelID {
            throw TimerError.alreadyTrackingSameProject
        }
        return try start(project: project, at: instant, in: context)
    }

    /// Log a completed entry with explicit start/end times (after-the-fact entry).
    /// Marks `isManual = true`.
    @MainActor
    @discardableResult
    public static func logCompletedEntry(
        project: Project,
        start: Date,
        end: Date,
        notes: String? = nil,
        in context: ModelContext
    ) throws -> TimeEntry {
        guard !project.isArchived else { throw TimerError.projectIsArchived }
        let safeEnd = max(end, start.addingTimeInterval(1))
        let entry = TimeEntry(
            startedAt: start,
            endedAt: safeEnd,
            notes: notes,
            isManual: true,
            project: project
        )
        context.insert(entry)
        try context.save()
        return entry
    }

    /// Shift a running entry's startedAt backward (or forward, within constraints).
    /// Throws if `newStart >= Date.now` (would create negative duration) or if
    /// the entry is no longer running.
    ///
    /// Used by the Today screen's RunningTimerCard to let users correct a
    /// "forgot to start the timer" mistake without stopping the entry.
    @MainActor
    public static func adjustStart(
        entry: TimeEntry,
        to newStart: Date,
        in context: ModelContext
    ) throws {
        guard entry.endedAt == nil else { throw AdjustError.entryNotRunning }
        // `<=` not `<`: a timer can legitimately start exactly "now" (0 elapsed)
        // — that's how every timer begins. Only a strictly-FUTURE start is
        // invalid. Using `<=` also avoids a millisecond boundary rejection when
        // the caller's captured "now" equals this execution's `.now`.
        guard newStart <= .now else { throw AdjustError.startInFuture }
        entry.startedAt = newStart
        entry.updatedAt = .now
        try context.save()
    }
}
