import Foundation
import SwiftData
import WidgetKit
import BillableCore

/// Single source of truth for timer mutations and their side effects
/// (Live Activity, widget reload, Siri-intent donation). Used by TodayView,
/// StartTimerSheet, OnboardingView, and ProjectDetailView so the behavior
/// never drifts between entry points.
@MainActor
enum TimerActions {
    /// Start tracking `project`. Stops any other running timer first
    /// (`TimerService.start` finalizes it). Returns the new running entry.
    @discardableResult
    static func start(project: Project, currencyCode: String, in context: ModelContext) -> TimeEntry? {
        guard let entry = try? TimerService.start(project: project, in: context) else { return nil }
        Task { await TimerActivityController.shared.startActivity(for: entry, currencyCode: currencyCode) }
        if let entity = ProjectEntity(from: project) {
            Task { try? await StartTimerIntent(project: entity).donate() }
        }
        WidgetCenter.shared.reloadAllTimelines()
        return entry
    }

    /// Atomic stop+start into `project`. Returns `nil` if the project is already
    /// running or if any other error occurs (matches StartTimerSheet's prior behavior).
    @discardableResult
    static func switchTo(project: Project, currencyCode: String, in context: ModelContext) -> TimeEntry? {
        do {
            let entry = try TimerService.switchTo(project: project, in: context)
            Task { await TimerActivityController.shared.startActivity(for: entry, currencyCode: currencyCode) }
            if let entity = ProjectEntity(from: project) {
                Task { try? await SwitchTimerIntent(project: entity).donate() }
            }
            WidgetCenter.shared.reloadAllTimelines()
            return entry
        } catch {
            // alreadyTrackingSameProject / archived etc. — match StartTimerSheet: swallow.
            return nil
        }
    }

    /// Pause the running timer (bank the current segment, freeze the clock).
    static func takeBreak(in context: ModelContext) {
        guard let entry = try? TimerService.takeBreak(in: context) else { return }
        let elapsed = entry.duration()
        Task { await TimerActivityController.shared.pause(elapsed: elapsed) }
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Resume an on-break timer.
    static func resume(in context: ModelContext) {
        guard let entry = try? TimerService.resume(in: context) else { return }
        Task { await TimerActivityController.shared.resumeActivity(runningEntry: entry) }
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// End the running session ("Done for now").
    static func stop(in context: ModelContext) {
        _ = try? TimerService.stop(in: context)
        Task { await TimerActivityController.shared.endActivity() }
        Task { try? await StopTimerIntent().donate() }
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Log a manually-entered completed entry and reload widgets.
    /// Returns `nil` on failure (archived project, future start, save error, etc.).
    @discardableResult
    static func logCompleted(
        project: Project,
        start: Date,
        end: Date,
        notes: String?,
        in context: ModelContext
    ) -> TimeEntry? {
        guard let entry = try? TimerService.logCompletedEntry(
            project: project, start: start, end: end, notes: notes, in: context
        ) else { return nil }
        WidgetCenter.shared.reloadAllTimelines()
        return entry
    }

    /// Persist edits to an existing completed entry and reload widgets.
    /// Running entries are not editable via this path (ManualEntrySheet blocks
    /// them), so no Live-Activity reconcile is needed here.
    /// Returns `false` on save failure.
    @discardableResult
    static func saveEdit(
        entry: TimeEntry,
        project: Project,
        start: Date,
        end: Date,
        notes: String?,
        flattenBreaks: Bool,
        in context: ModelContext
    ) -> Bool {
        // Defense-in-depth: mirror logCompletedEntry's future-start guard so a
        // future start cannot be written even if a caller bypasses the picker bound.
        guard start <= .now else { return false }
        guard !project.isArchived else { return false }
        entry.project = project
        if flattenBreaks {
            entry.accumulatedSeconds = 0
            entry.activeSegmentStartedAt = nil
            entry.isManual = true
        }
        entry.startedAt = start
        entry.endedAt = end
        entry.notes = notes
        entry.updatedAt = .now
        do {
            try context.save()
        } catch {
            context.rollback()
            return false
        }
        WidgetCenter.shared.reloadAllTimelines()
        return true
    }
}
