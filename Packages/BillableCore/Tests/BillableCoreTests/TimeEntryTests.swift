import Foundation
import Testing
@testable import BillableCore

@Suite("TimeEntry")
struct TimeEntryTests {
    @Test("Completed entry duration is end - start")
    func completedDuration() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(3600) // +1 hour
        let entry = TimeEntry(startedAt: start, endedAt: end)
        #expect(entry.duration() == 3600)
    }

    @Test("Running entry with active segment duration is computed against reference date")
    func runningDuration() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let now = start.addingTimeInterval(1800) // +30 min
        let entry = TimeEntry(startedAt: start, endedAt: nil, activeSegmentStartedAt: start)
        #expect(entry.duration(asOf: now) == 1800)
        #expect(entry.isRunning)
    }

    @Test("Negative duration is clamped to zero (end before start)")
    func negativeDurationClamped() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(-60)
        let entry = TimeEntry(startedAt: start, endedAt: end)
        #expect(entry.duration() == 0)
    }

    @Test("Amount uses project's hourly rate")
    func amountBillable() {
        let client = Client(name: "Acme")
        let project = Project(name: "Site", hourlyRate: 120, client: client)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(3600 * 2) // 2 hours
        let entry = TimeEntry(startedAt: start, endedAt: end, project: project)
        #expect(entry.amount() == 240)
    }

    @Test("Amount is zero for non-billable projects")
    func amountNonBillable() {
        let project = Project(name: "Admin", hourlyRate: 200, isBillable: false)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(3600)
        let entry = TimeEntry(startedAt: start, endedAt: end, project: project)
        #expect(entry.amount() == 0)
    }

    @Test("Amount is zero when project is nil")
    func amountOrphan() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(3600)
        let entry = TimeEntry(startedAt: start, endedAt: end, project: nil)
        #expect(entry.amount() == 0)
    }

    @Test("Amount on a running entry uses elapsed time vs reference")
    func runningAmount() {
        let project = Project(name: "Site", hourlyRate: 100)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let now = start.addingTimeInterval(1800) // 30 min
        let entry = TimeEntry(startedAt: start, endedAt: nil, project: project, activeSegmentStartedAt: start)
        #expect(entry.amount(asOf: now) == 50)
    }
}
