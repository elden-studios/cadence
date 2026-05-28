import Foundation
import Testing
@testable import BillableCore

@Suite("TimeEntry duration (worked time)")
struct TimeEntryDurationTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Working: banked + current segment")
    func workingDuration() {
        let e = TimeEntry(startedAt: t0, accumulatedSeconds: 600, activeSegmentStartedAt: t0)
        #expect(e.duration(asOf: t0.addingTimeInterval(60)) == 660)
        #expect(e.isWorking)
        #expect(!e.isOnBreak)
    }

    @Test("On break: frozen at banked")
    func onBreakDuration() {
        let e = TimeEntry(startedAt: t0, accumulatedSeconds: 600, activeSegmentStartedAt: nil)
        #expect(e.duration(asOf: t0.addingTimeInterval(9999)) == 600)
        #expect(e.isOnBreak)
        #expect(!e.isWorking)
    }

    @Test("Finished with banked time returns banked, not wall-clock")
    func finishedBanked() {
        let e = TimeEntry(startedAt: t0, endedAt: t0.addingTimeInterval(3600), accumulatedSeconds: 1800)
        #expect(e.duration() == 1800)
    }

    @Test("Finished manual/legacy (no banked) falls back to wall-clock")
    func finishedFallback() {
        let e = TimeEntry(startedAt: t0, endedAt: t0.addingTimeInterval(3600), accumulatedSeconds: 0)
        #expect(e.duration() == 3600)
    }
}
