import Foundation
import SwiftData
import Testing
@testable import BillableCore

@Suite("TimerService.adjustStart")
@MainActor
struct TimerServiceAdjustStartTests {

    private func freshContext() throws -> (ModelContext, Client, Project) {
        let container = try BillableModelContainer.inMemory()
        let context = ModelContext(container)
        let client = Client(name: "Acme", color: .blue)
        let project = Project(name: "P", hourlyRate: 100, client: client)
        context.insert(client)
        context.insert(project)
        try context.save()
        return (context, client, project)
    }

    // MARK: - Existing tests (updated to use real Working entries)

    @Test("Shifts startedAt backward by the given offset")
    func shiftsBackward() throws {
        let (context, _, project) = try freshContext()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let entry = try TimerService.start(project: project, at: t0, in: context)

        let newStart = t0.addingTimeInterval(-600)  // 10 minutes earlier
        try TimerService.adjustStart(entry: entry, to: newStart, in: context)

        #expect(entry.startedAt == newStart)
    }

    @Test("Throws startInFuture when newStart is strictly after Date.now")
    func rejectsFutureStart() throws {
        let (context, _, project) = try freshContext()
        let entry = try TimerService.start(project: project, at: .now.addingTimeInterval(-300), in: context)

        let future = Date.now.addingTimeInterval(3600)
        #expect(throws: TimerService.AdjustError.startInFuture) {
            try TimerService.adjustStart(entry: entry, to: future, in: context)
        }
    }

    @Test("Accepts a start at the current moment (0-elapsed timer)")
    func acceptsNowStart() throws {
        let (context, _, project) = try freshContext()
        // Start 5 minutes ago so we have a working entry with a segment.
        let entry = try TimerService.start(project: project, at: .now.addingTimeInterval(-300), in: context)

        // `now` is captured here; by the time adjustStart runs, `.now` has
        // advanced microseconds, so `now <= .now` holds. This is the
        // "start the timer right now" adjustment (0 elapsed) the `<=` guard
        // permits. (The exact same-instant boundary that distinguishes `<=`
        // from `<` can't be tested deterministically — the clock always moves
        // between capture and execution — so this asserts the user-facing
        // behavior: a start at the present moment is accepted, not rejected.)
        let now = Date.now
        try TimerService.adjustStart(entry: entry, to: now, in: context)
        #expect(entry.startedAt == now)
    }

    @Test("Throws entryNotRunning on stopped entries")
    func rejectsStoppedEntries() throws {
        let (context, _, project) = try freshContext()
        let entry = TimeEntry(
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            endedAt: Date(timeIntervalSince1970: 1_001_000),
            project: project
        )
        context.insert(entry)
        try context.save()

        #expect(throws: TimerService.AdjustError.entryNotRunning) {
            try TimerService.adjustStart(
                entry: entry,
                to: Date(timeIntervalSince1970: 999_000),
                in: context
            )
        }
    }

    @Test("Updates updatedAt to the present moment after a successful shift")
    func updatesTimestamp() throws {
        let (context, _, project) = try freshContext()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let entry = try TimerService.start(project: project, at: t0, in: context)
        // Force the updatedAt to be in the past, so a successful adjustStart should bump it.
        entry.updatedAt = Date(timeIntervalSince1970: 1)
        try context.save()

        let before = Date.now
        try TimerService.adjustStart(entry: entry, to: t0.addingTimeInterval(-600), in: context)
        #expect(entry.updatedAt >= before)
    }

    // MARK: - New tests

    @Test("Adjust shifts both startedAt and segment so duration reflects it")
    func shiftsSegmentAndDuration() throws {
        let (context, _, project) = try freshContext()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let entry = try TimerService.start(project: project, at: t0, in: context)

        // Shift start 300 s earlier.
        try TimerService.adjustStart(entry: entry, to: t0.addingTimeInterval(-300), in: context)

        #expect(entry.startedAt == t0.addingTimeInterval(-300))
        #expect(entry.activeSegmentStartedAt == t0.addingTimeInterval(-300))
        // duration as measured at t0 should now be 300 s.
        #expect(entry.duration(asOf: t0) == 300)
    }

    @Test("No-op when On Break")
    func noOpWhenOnBreak() throws {
        let (context, _, project) = try freshContext()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let entry = try TimerService.start(project: project, at: t0, in: context)
        try TimerService.takeBreak(at: t0.addingTimeInterval(60), in: context)

        // Entry is now On Break — adjustStart should be a no-op.
        try TimerService.adjustStart(entry: entry, to: t0.addingTimeInterval(-300), in: context)

        #expect(entry.startedAt == t0)
    }

    @Test("No-op when breaks exist (working after a resume)")
    func noOpWhenBreaksExist() throws {
        let (context, _, project) = try freshContext()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let entry = try TimerService.start(project: project, at: t0, in: context)
        try TimerService.takeBreak(at: t0.addingTimeInterval(60), in: context)
        try TimerService.resume(at: t0.addingTimeInterval(120), in: context)

        // Entry is Working again but accumulatedSeconds > 0 — adjustStart is a no-op.
        try TimerService.adjustStart(entry: entry, to: t0.addingTimeInterval(-300), in: context)

        #expect(entry.startedAt == t0)
    }
}
