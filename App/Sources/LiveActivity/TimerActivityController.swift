import Foundation
import SwiftData
@preconcurrency import ActivityKit
import BillableCore

/// Bridges `TimerService` events to ActivityKit Live Activities.
///
/// Lives in the app target (not `BillableCore`) because `Activity.request`
/// requires application-level scope. Stays a small `@MainActor` singleton so
/// callers (Today view actions, StartTimerSheet, App entry) can reach it
/// without dependency injection plumbing.
@MainActor
final class TimerActivityController {
    static let shared = TimerActivityController()

    /// The Activity we currently hold, if any. Cleared when the timer stops.
    private var current: Activity<TimerActivityAttributes>?

    private init() {}

    /// True when the system permits us to start Live Activities for this app.
    /// Driven by the user's iOS Settings → Billable → Live Activities toggle.
    var isPermitted: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// Start (or replace) the Live Activity for a freshly-started TimeEntry.
    /// Safe to call from any timer flow (start, switch). If a previous activity
    /// is still live, it's ended first to avoid duplicates.
    func startActivity(for entry: TimeEntry) async {
        guard isPermitted else { return }
        guard let project = entry.project else { return }

        let attributes = TimerActivityAttributes(
            clientName: project.client?.name ?? "",
            projectName: project.name,
            clientColorRaw: project.client?.colorRaw ?? ClientColor.blue.rawValue,
            hourlyRateString: NSDecimalNumber(decimal: project.hourlyRate).stringValue,
            currencyCode: "USD"
        )
        let state = TimerActivityAttributes.ContentState(startedAt: entry.startedAt)

        // End any in-flight activity first — a switch shouldn't leave two open.
        if let previous = current {
            await previous.end(nil, dismissalPolicy: .immediate)
            current = nil
        }

        do {
            current = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil),
                pushType: nil
            )
        } catch {
            // Live Activity startup can fail (system busy, too many open). We
            // swallow the error here — the timer itself is the source of truth.
        }
    }

    /// End the Live Activity (timer stop or app teardown).
    func endActivity() async {
        guard let activity = current else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
        current = nil
    }

    /// Defensive: when the app launches we may have a still-running TimeEntry
    /// in SwiftData but no in-memory activity reference (the app was killed
    /// and relaunched). Call this on `App.init` to re-attach.
    func reconcileOnLaunch(in context: ModelContext) async {
        // If we already have an activity object, trust it.
        if current != nil { return }

        // Match any system-tracked activity for our attributes type. If iOS
        // killed it across our session, this is empty and we'll just leave it
        // ended; the next timer start will request a fresh one.
        if let live = Activity<TimerActivityAttributes>.activities.first {
            current = live
            return
        }

        // No live activity, but a running entry exists in the store → restart it.
        if let running = TimerService.currentRunningEntry(in: context) {
            await startActivity(for: running)
        }
    }
}
