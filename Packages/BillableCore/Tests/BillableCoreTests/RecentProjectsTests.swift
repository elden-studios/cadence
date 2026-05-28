import Foundation
import Testing
import SwiftData
@testable import BillableCore

@Suite("RecentProjects.rank")
@MainActor
struct RecentProjectsTests {
    private func fixture() throws -> (ModelContext, Client) {
        let container = try BillableModelContainer.inMemory()
        let context = ModelContext(container)
        let client = Client(name: "Acme")
        context.insert(client)
        try context.save()
        return (context, client)
    }

    private func project(_ ctx: ModelContext, _ client: Client, _ name: String, archived: Bool = false) -> Project {
        let p = Project(name: name, hourlyRate: 50, isArchived: archived, client: client)
        ctx.insert(p)
        return p
    }

    private func entry(_ ctx: ModelContext, _ p: Project, at: Date) {
        ctx.insert(TimeEntry(startedAt: at, endedAt: at.addingTimeInterval(60), isManual: true, project: p))
    }

    private let t0 = Date(timeIntervalSince1970: 1_779_000_000)

    @Test("ranks distinct projects by most-recent entry, newest first")
    func ranksByRecency() throws {
        let (ctx, client) = try fixture()
        let a = project(ctx, client, "A"); let b = project(ctx, client, "B"); let c = project(ctx, client, "C")
        entry(ctx, a, at: t0)
        entry(ctx, b, at: t0.addingTimeInterval(100))
        entry(ctx, c, at: t0.addingTimeInterval(200))
        try ctx.save()
        let all = try ctx.fetch(FetchDescriptor<TimeEntry>())
        let ranked = RecentProjects.rank(from: all, limit: 5)
        #expect(ranked.map(\.name) == ["C", "B", "A"])
    }

    @Test("dedupes a project with multiple recent entries to its latest")
    func dedupes() throws {
        let (ctx, client) = try fixture()
        let a = project(ctx, client, "A"); let b = project(ctx, client, "B")
        entry(ctx, a, at: t0)
        entry(ctx, b, at: t0.addingTimeInterval(50))
        entry(ctx, a, at: t0.addingTimeInterval(100))
        try ctx.save()
        let all = try ctx.fetch(FetchDescriptor<TimeEntry>())
        let ranked = RecentProjects.rank(from: all, limit: 5)
        #expect(ranked.map(\.name) == ["A", "B"])
    }

    @Test("excludes archived projects")
    func excludesArchived() throws {
        let (ctx, client) = try fixture()
        let a = project(ctx, client, "A", archived: true); let b = project(ctx, client, "B")
        entry(ctx, a, at: t0.addingTimeInterval(100))
        entry(ctx, b, at: t0)
        try ctx.save()
        let all = try ctx.fetch(FetchDescriptor<TimeEntry>())
        #expect(RecentProjects.rank(from: all, limit: 5).map(\.name) == ["B"])
    }

    @Test("caps at limit")
    func caps() throws {
        let (ctx, client) = try fixture()
        for i in 0..<6 { entry(ctx, project(ctx, client, "P\(i)"), at: t0.addingTimeInterval(Double(i))) }
        try ctx.save()
        let all = try ctx.fetch(FetchDescriptor<TimeEntry>())
        #expect(RecentProjects.rank(from: all, limit: 3).count == 3)
    }

    @Test("limit <= 0 and empty input return no projects")
    func boundaries() throws {
        let (ctx, client) = try fixture()
        entry(ctx, project(ctx, client, "A"), at: t0)
        try ctx.save()
        let all = try ctx.fetch(FetchDescriptor<TimeEntry>())
        #expect(RecentProjects.rank(from: all, limit: 0).isEmpty)
        #expect(RecentProjects.rank(from: [], limit: 5).isEmpty)
    }
}
