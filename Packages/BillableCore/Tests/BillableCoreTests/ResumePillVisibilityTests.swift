import Testing
import Foundation
import SwiftData
@testable import BillableCore

@Suite("Resume pill visibility")
@MainActor
struct ResumePillVisibilityTests {

    private func makeContext() throws -> ModelContext {
        let container = try BillableModelContainer.inMemory()
        return ModelContext(container)
    }

    private func makeStoppedEntry(
        in context: ModelContext,
        endedAt: Date,
        withProject: Bool = true
    ) -> TimeEntry {
        let project: Project?
        if withProject {
            let client = Client(name: "Acme")
            context.insert(client)
            let p = Project(name: "Project X", hourlyRate: 100, client: client)
            context.insert(p)
            project = p
        } else {
            project = nil
        }
        let entry = TimeEntry(
            startedAt: endedAt.addingTimeInterval(-1800),
            endedAt: endedAt,
            project: project
        )
        context.insert(entry)
        return entry
    }

    @Test("nil last entry → no pill")
    func nilLastEntry() {
        #expect(TimeEntry.shouldShowResumePill(lastStopped: nil, now: .now) == false)
    }

    @Test("entry without project → no pill")
    func noProject() throws {
        let context = try makeContext()
        let entry = makeStoppedEntry(in: context, endedAt: .now, withProject: false)
        #expect(TimeEntry.shouldShowResumePill(lastStopped: entry, now: .now) == false)
    }

    @Test("stopped 30 min ago, same day → pill shown")
    func recentSameDay() throws {
        let context = try makeContext()
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let endedAt = now.addingTimeInterval(-30 * 60)
        let entry = makeStoppedEntry(in: context, endedAt: endedAt)
        #expect(TimeEntry.shouldShowResumePill(lastStopped: entry, now: now) == true)
    }

    @Test("stopped 90 min ago → no pill (over window)")
    func tooOld() throws {
        let context = try makeContext()
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let endedAt = now.addingTimeInterval(-90 * 60)
        let entry = makeStoppedEntry(in: context, endedAt: endedAt)
        #expect(TimeEntry.shouldShowResumePill(lastStopped: entry, now: now) == false)
    }

    @Test("stopped 30 min ago but yesterday → no pill (crossed midnight)")
    func crossedMidnight() throws {
        let context = try makeContext()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let nowComponents = DateComponents(year: 2026, month: 5, day: 27, hour: 0, minute: 15)
        let endedAtComponents = DateComponents(year: 2026, month: 5, day: 26, hour: 23, minute: 45)
        let now = calendar.date(from: nowComponents)!
        let endedAt = calendar.date(from: endedAtComponents)!
        let entry = makeStoppedEntry(in: context, endedAt: endedAt)
        #expect(TimeEntry.shouldShowResumePill(lastStopped: entry, now: now, calendar: calendar) == false)
    }

    @Test("entry still running (endedAt == nil) → no pill")
    func stillRunning() throws {
        let context = try makeContext()
        let client = Client(name: "Acme")
        context.insert(client)
        let project = Project(name: "Project X", hourlyRate: 100, client: client)
        context.insert(project)
        let entry = TimeEntry(startedAt: .now, endedAt: nil, project: project)
        context.insert(entry)
        #expect(TimeEntry.shouldShowResumePill(lastStopped: entry, now: .now) == false)
    }
}
