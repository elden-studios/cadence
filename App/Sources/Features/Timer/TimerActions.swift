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

    /// Atomic stop+start into `project`. No-op if it's already the running project.
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
}
