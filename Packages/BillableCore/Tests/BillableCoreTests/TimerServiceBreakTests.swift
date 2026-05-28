import Foundation
import Testing
import SwiftData
@testable import BillableCore

@Suite("TimerService break/resume")
@MainActor
struct TimerServiceBreakTests {
    private func ctx() throws -> (ModelContext, Project) {
        let container = try BillableModelContainer.inMemory()
        let context = ModelContext(container)
        let client = Client(name: "Acme")
        let p = Project(name: "Site", hourlyRate: 100, client: client)
        context.insert(client); context.insert(p)
        try context.save()
        return (context, p)
    }
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("takeBreak banks the current segment and freezes the count")
    func takeBreakBanks() throws {
        let (context, p) = try ctx()
        _ = try TimerService.start(project: p, at: t0, in: context)
        let onBreak = try TimerService.takeBreak(at: t0.addingTimeInterval(600), in: context)
        #expect(onBreak.isOnBreak)
        #expect(onBreak.accumulatedSeconds == 600)
        #expect(onBreak.duration(asOf: t0.addingTimeInterval(9999)) == 600)
    }

    @Test("resume continues counting from banked total")
    func resumeContinues() throws {
        let (context, p) = try ctx()
        _ = try TimerService.start(project: p, at: t0, in: context)
        _ = try TimerService.takeBreak(at: t0.addingTimeInterval(600), in: context)
        let resumed = try TimerService.resume(at: t0.addingTimeInterval(1200), in: context)
        #expect(resumed.isWorking)
        #expect(resumed.duration(asOf: t0.addingTimeInterval(1260)) == 660)
    }

    @Test("takeBreak throws when already on break")
    func takeBreakAlreadyOnBreak() throws {
        let (context, p) = try ctx()
        _ = try TimerService.start(project: p, at: t0, in: context)
        _ = try TimerService.takeBreak(at: t0.addingTimeInterval(60), in: context)
        #expect(throws: TimerService.TimerError.alreadyOnBreak) {
            _ = try TimerService.takeBreak(at: t0.addingTimeInterval(120), in: context)
        }
    }

    @Test("takeBreak throws when nothing is running")
    func takeBreakNoTimer() throws {
        let (context, _) = try ctx()
        #expect(throws: TimerService.TimerError.noRunningTimer) {
            _ = try TimerService.takeBreak(in: context)
        }
    }

    @Test("resume throws when not on break")
    func resumeNotOnBreak() throws {
        let (context, p) = try ctx()
        _ = try TimerService.start(project: p, at: t0, in: context)
        #expect(throws: TimerService.TimerError.notOnBreak) {
            _ = try TimerService.resume(at: t0.addingTimeInterval(60), in: context)
        }
    }

    @Test("backward clock on takeBreak clamps to zero (no negative bank)")
    func takeBreakBackwardClock() throws {
        let (context, p) = try ctx()
        _ = try TimerService.start(project: p, at: t0, in: context)
        let onBreak = try TimerService.takeBreak(at: t0.addingTimeInterval(-60), in: context)
        #expect(onBreak.accumulatedSeconds == 0)
    }
}
