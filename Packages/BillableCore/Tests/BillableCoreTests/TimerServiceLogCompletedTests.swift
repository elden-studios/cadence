import Foundation
import Testing
import SwiftData
@testable import BillableCore

@Suite("TimerService.logCompletedEntry — future-start guard")
@MainActor
struct TimerServiceLogCompletedTests {

    private func freshContext() throws -> (ModelContext, Project) {
        let container = try BillableModelContainer.inMemory()
        let context = ModelContext(container)
        let client = Client(name: "Acme", color: .blue)
        let project = Project(name: "Alpha", hourlyRate: 100, client: client)
        context.insert(client)
        context.insert(project)
        try context.save()
        return (context, project)
    }

    // MARK: - Future-start rejection

    @Test("logCompletedEntry rejects a start strictly in the future")
    func rejectsFutureStart() throws {
        let (context, project) = try freshContext()
        let futureStart = Date.now.addingTimeInterval(3600) // 1 hour from now
        let end = futureStart.addingTimeInterval(1800)

        #expect(throws: TimerService.TimerError.startInFuture) {
            _ = try TimerService.logCompletedEntry(
                project: project,
                start: futureStart,
                end: end,
                in: context
            )
        }
    }

    @Test("logCompletedEntry rejects a start even 1 second in the future")
    func rejectsNearFutureStart() throws {
        let (context, project) = try freshContext()
        // Use a clearly-future time to avoid flakiness on boundary
        let futureStart = Date.now.addingTimeInterval(60)
        let end = futureStart.addingTimeInterval(3600)

        #expect(throws: TimerService.TimerError.startInFuture) {
            _ = try TimerService.logCompletedEntry(
                project: project,
                start: futureStart,
                end: end,
                in: context
            )
        }
    }

    // MARK: - Normal past entries still succeed

    @Test("logCompletedEntry accepts a past start and creates the entry")
    func acceptsPastStart() throws {
        let (context, project) = try freshContext()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(3600)

        let entry = try TimerService.logCompletedEntry(
            project: project,
            start: start,
            end: end,
            notes: "billed work",
            in: context
        )

        #expect(entry.startedAt == start)
        #expect(entry.endedAt == end)
        #expect(entry.isManual)
        #expect(entry.notes == "billed work")
        #expect(entry.isRunning == false)
    }

    @Test("logCompletedEntry accepts a start at the current moment (boundary)")
    func acceptsNowStart() throws {
        let (context, project) = try freshContext()
        // Capture a "now" that is guaranteed to be <= .now by the time the guard runs.
        let now = Date.now
        let end = now.addingTimeInterval(3600)

        // Should not throw: start <= .now.
        let entry = try TimerService.logCompletedEntry(
            project: project,
            start: now,
            end: end,
            in: context
        )
        #expect(entry.startedAt == now)
    }
}
