import Foundation
import Testing
import SwiftData
@testable import BillableCore

@Suite("TimerService reconcile on launch")
@MainActor
struct TimerServiceReconcileTests {
    private func ctx() throws -> (ModelContext, Project) {
        let container = try BillableModelContainer.inMemory()
        let context = ModelContext(container)
        let client = Client(name: "Acme")
        let p = Project(name: "Site", hourlyRate: 100, client: client)
        context.insert(client); context.insert(p)
        try context.save()
        return (context, p)
    }
    private let cal = Calendar.current

    @Test("Cross-day active session finalizes to banked worked time")
    func staleFinalizes() throws {
        let (context, p) = try ctx()
        let yesterday = cal.date(byAdding: .day, value: -1, to: .now)!
        _ = try TimerService.start(project: p, at: yesterday, in: context)
        _ = try TimerService.takeBreak(at: yesterday.addingTimeInterval(3600), in: context)
        try TimerService.reconcileActiveSessionOnLaunch(now: .now, in: context)
        let all = try context.fetch(FetchDescriptor<TimeEntry>())
        #expect(all.count == 1)
        #expect(all[0].endedAt != nil)
        #expect(all[0].duration() == 3600)
        #expect(TimerService.currentRunningEntry(in: context) == nil)
    }

    @Test("Legacy same-day running entry (no segment) becomes Working")
    func legacyRunningAdopted() throws {
        let (context, p) = try ctx()
        let legacy = TimeEntry(startedAt: .now.addingTimeInterval(-300), endedAt: nil, project: p)
        legacy.activeSegmentStartedAt = nil
        legacy.accumulatedSeconds = 0
        context.insert(legacy); try context.save()
        try TimerService.reconcileActiveSessionOnLaunch(now: .now, in: context)
        #expect(legacy.isWorking)
    }

    @Test("Genuine same-day On-Break session is left untouched")
    func sameDayBreakUntouched() throws {
        let (context, p) = try ctx()
        let t = Date.now.addingTimeInterval(-1800)
        _ = try TimerService.start(project: p, at: t, in: context)
        _ = try TimerService.takeBreak(at: t.addingTimeInterval(600), in: context)
        try TimerService.reconcileActiveSessionOnLaunch(now: .now, in: context)
        let running = TimerService.currentRunningEntry(in: context)
        #expect(running != nil)
        #expect(running!.isOnBreak)
    }
}
