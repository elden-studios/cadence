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
    /// Pass `currencyCode` from the active BusinessProfile so the Live Activity
    /// displays the correct currency symbol for the user's locale.
    func startActivity(for entry: TimeEntry, currencyCode: String) async {
        guard isPermitted else { return }
        guard let project = entry.project else { return }

        let attributes = TimerActivityAttributes(
            clientName: project.client?.name ?? "",
            projectName: project.name,
            clientColorRaw: project.client?.colorRaw ?? ClientColor.blue.rawValue,
            hourlyRateString: NSDecimalNumber(decimal: project.hourlyRate).stringValue,
            currencyCode: currencyCode
        )
        let state = TimerActivityAttributes.ContentState(
            startedAt: workedTimeAnchor(for: entry),
            isOnBreak: entry.isOnBreak,
            frozenElapsed: entry.isOnBreak ? entry.duration() : 0
        )

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

    /// Push an On-Break update to the running Activity, freezing the elapsed
    /// display at `elapsed` seconds of worked time.
    /// No-ops if there is no current activity.
    func pause(elapsed: TimeInterval) async {
        guard let activity = current else { return }
        let state = TimerActivityAttributes.ContentState(
            startedAt: activity.content.state.startedAt,
            isOnBreak: true,
            frozenElapsed: elapsed
        )
        await activity.update(.init(state: state, staleDate: nil))
    }

    /// Push a resume update to the running Activity, un-freezing the elapsed
    /// counter so it ticks the WORKED time (break excluded). The anchor is
    /// recomputed from the resumed entry — reusing the pre-break anchor would
    /// inflate the displayed time by the break duration.
    /// No-ops if there is no current activity.
    func resumeActivity(runningEntry entry: TimeEntry) async {
        guard let activity = current else { return }
        let state = TimerActivityAttributes.ContentState(
            startedAt: workedTimeAnchor(for: entry),
            isOnBreak: false,
            frozenElapsed: 0
        )
        await activity.update(.init(state: state, staleDate: nil))
    }

    /// Synthetic `Text(timerInterval:)` anchor that makes the Live Activity tick
    /// WORKED time (banked + current segment), excluding break gaps. Shared by
    /// `startActivity` and `resumeActivity` so the two can't drift apart.
    private func workedTimeAnchor(for entry: TimeEntry) -> Date {
        if entry.isWorking, let seg = entry.activeSegmentStartedAt {
            return seg.addingTimeInterval(-entry.accumulatedSeconds)
        }
        return entry.startedAt
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
            var profileDescriptor = FetchDescriptor<BusinessProfile>()
            profileDescriptor.fetchLimit = 1
            let profileCode = (try? context.fetch(profileDescriptor))?.first?.currencyCode ?? "USD"
            await startActivity(for: running, currencyCode: profileCode)
        }
    }
}
