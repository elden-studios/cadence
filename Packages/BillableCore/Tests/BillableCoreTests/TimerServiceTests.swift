import Foundation
import Testing
import SwiftData
@testable import BillableCore

@Suite("TimerService")
@MainActor
struct TimerServiceTests {

    // MARK: - Helpers

    private func freshContext() throws -> (ModelContext, Client, Project, Project) {
        let container = try BillableModelContainer.inMemory()
        let context = ModelContext(container)
        let client = Client(name: "Acme")
        let p1 = Project(name: "Site", hourlyRate: 100, client: client)
        let p2 = Project(name: "Brand", hourlyRate: 150, client: client)
        context.insert(client)
        context.insert(p1)
        context.insert(p2)
        try context.save()
        return (context, client, p1, p2)
    }

    // MARK: - start

    @Test("start creates a running entry on the given project")
    func startCreatesRunningEntry() throws {
        let (context, _, p1, _) = try freshContext()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = try TimerService.start(project: p1, at: t0, in: context)

        #expect(entry.startedAt == t0)
        #expect(entry.endedAt == nil)
        #expect(entry.isRunning)
        #expect(entry.project?.persistentModelID == p1.persistentModelID)
        #expect(entry.isManual == false)

        let running = TimerService.currentRunningEntry(in: context)
        #expect(running?.persistentModelID == entry.persistentModelID)
    }

    @Test("start on an archived project throws")
    func startOnArchivedProject() throws {
        let (context, _, p1, _) = try freshContext()
        p1.isArchived = true
        try context.save()

        #expect(throws: TimerService.TimerError.projectIsArchived) {
            _ = try TimerService.start(project: p1, in: context)
        }
    }

    @Test("Starting same project while it's already running is a no-op")
    func startSameProjectNoOp() throws {
        let (context, _, p1, _) = try freshContext()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try TimerService.start(project: p1, at: t0, in: context)
        let second = try TimerService.start(project: p1, at: t0.addingTimeInterval(60), in: context)

        #expect(first.persistentModelID == second.persistentModelID)
        let count = try context.fetchCount(FetchDescriptor<TimeEntry>())
        #expect(count == 1)
    }

    @Test("Starting a different project stops the running one at the same instant")
    func startDifferentProjectStopsRunning() throws {
        let (context, _, p1, p2) = try freshContext()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t1 = t0.addingTimeInterval(600) // 10 minutes later

        let first = try TimerService.start(project: p1, at: t0, in: context)
        let second = try TimerService.start(project: p2, at: t1, in: context)

        #expect(first.endedAt == t1)
        #expect(first.isRunning == false)
        #expect(second.startedAt == t1)
        #expect(second.isRunning == true)
        #expect(TimerService.currentRunningEntry(in: context)?.persistentModelID == second.persistentModelID)
    }

    // MARK: - stop

    @Test("stop ends the running timer at the given instant")
    func stopEndsRunning() throws {
        let (context, _, p1, _) = try freshContext()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t1 = t0.addingTimeInterval(900)
        _ = try TimerService.start(project: p1, at: t0, in: context)
        let stopped = try TimerService.stop(at: t1, in: context)
        #expect(stopped.endedAt == t1)
        #expect(TimerService.currentRunningEntry(in: context) == nil)
    }

    @Test("stop throws when nothing is running")
    func stopWithoutRunningTimer() throws {
        let (context, _, _, _) = try freshContext()
        #expect(throws: TimerService.TimerError.noRunningTimer) {
            _ = try TimerService.stop(in: context)
        }
    }

    @Test("stop clamps end to start+1s if a backward clock would create a negative duration")
    func stopClampsBackwardClock() throws {
        let (context, _, p1, _) = try freshContext()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try TimerService.start(project: p1, at: t0, in: context)
        let stopped = try TimerService.stop(at: t0.addingTimeInterval(-60), in: context)
        #expect(stopped.endedAt == t0.addingTimeInterval(1))
        #expect(stopped.duration() >= 1)
    }

    // MARK: - switchTo

    @Test("switchTo ends running, starts new, no gap")
    func switchSeamless() throws {
        let (context, _, p1, p2) = try freshContext()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t1 = t0.addingTimeInterval(120)
        let first = try TimerService.start(project: p1, at: t0, in: context)
        let second = try TimerService.switchTo(project: p2, at: t1, in: context)
        #expect(first.endedAt == t1)
        #expect(second.startedAt == t1)
        #expect(second.isRunning)
    }

    @Test("switchTo same project throws")
    func switchToSameProject() throws {
        let (context, _, p1, _) = try freshContext()
        _ = try TimerService.start(project: p1, in: context)
        #expect(throws: TimerService.TimerError.alreadyTrackingSameProject) {
            _ = try TimerService.switchTo(project: p1, in: context)
        }
    }

    // MARK: - logCompletedEntry

    @Test("logCompletedEntry creates a manual entry")
    func logManualEntry() throws {
        let (context, _, p1, _) = try freshContext()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(3600)
        let entry = try TimerService.logCompletedEntry(
            project: p1, start: start, end: end, notes: "test", in: context
        )
        #expect(entry.startedAt == start)
        #expect(entry.endedAt == end)
        #expect(entry.isManual)
        #expect(entry.notes == "test")
        #expect(entry.isRunning == false)
    }

    @Test("logCompletedEntry clamps end > start")
    func logManualClampsBadRange() throws {
        let (context, _, p1, _) = try freshContext()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(-60)
        let entry = try TimerService.logCompletedEntry(
            project: p1, start: start, end: end, in: context
        )
        #expect(entry.endedAt == start.addingTimeInterval(1))
    }
}
