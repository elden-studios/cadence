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

    @Test("Shifts startedAt backward by the given offset")
    func shiftsBackward() throws {
        let (context, _, project) = try freshContext()
        let original = Date(timeIntervalSince1970: 1_000_000)
        let entry = TimeEntry(startedAt: original, endedAt: nil, project: project)
        context.insert(entry)
        try context.save()

        let newStart = original.addingTimeInterval(-600)  // 10 minutes earlier
        try TimerService.adjustStart(entry: entry, to: newStart, in: context)

        #expect(entry.startedAt == newStart)
    }

    @Test("Throws startInFuture when newStart is strictly after Date.now")
    func rejectsFutureStart() throws {
        let (context, _, project) = try freshContext()
        let entry = TimeEntry(startedAt: .now.addingTimeInterval(-300), endedAt: nil, project: project)
        context.insert(entry)
        try context.save()

        let future = Date.now.addingTimeInterval(3600)
        #expect(throws: TimerService.AdjustError.startInFuture) {
            try TimerService.adjustStart(entry: entry, to: future, in: context)
        }
    }

    @Test("Accepts a start at the current moment (0-elapsed timer)")
    func acceptsNowStart() throws {
        let (context, _, project) = try freshContext()
        let entry = TimeEntry(startedAt: .now.addingTimeInterval(-300), endedAt: nil, project: project)
        context.insert(entry)
        try context.save()

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
        let entry = TimeEntry(startedAt: .now.addingTimeInterval(-1800), endedAt: nil, project: project)
        // Force the updatedAt to be in the past, so a successful adjustStart should bump it.
        entry.updatedAt = Date(timeIntervalSince1970: 1)
        context.insert(entry)
        try context.save()

        let before = Date.now
        try TimerService.adjustStart(entry: entry, to: .now.addingTimeInterval(-2400), in: context)
        #expect(entry.updatedAt >= before)
    }
}
