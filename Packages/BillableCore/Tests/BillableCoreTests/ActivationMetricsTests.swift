import Testing
import Foundation
import SwiftData
@testable import BillableCore

@MainActor
@Suite("ActivationMetrics")
struct ActivationMetricsTests {
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: BillableModelContainer.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private let onboarded = Date(timeIntervalSince1970: 1_000)

    /// `Invoice.init` requires ~10 non-defaulted snapshot args (number, dueAt, the
    /// client/issuer snapshots, payment terms, tax label/rate, currency code). Only
    /// `createdAt` is asserted by these tests, so the rest are arbitrary-but-valid.
    private func makeInvoice(number: String, createdAt: Date) -> Invoice {
        Invoice(
            number: number,
            dueAt: createdAt.addingTimeInterval(30 * 24 * 60 * 60),
            clientNameSnapshot: "Acme",
            issuerNameSnapshot: "Me",
            issuerAddressSnapshot: "1 St",
            issuerEmailSnapshot: "me@example.com",
            paymentTermsSnapshot: "Net 30",
            taxLabelSnapshot: "Tax",
            taxRateSnapshot: 0,
            currencyCodeSnapshot: "USD",
            createdAt: createdAt
        )
    }

    @Test("empty store: zeros and nils, not activated")
    func emptyStore() throws {
        let ctx = try makeContext()
        let m = ActivationMetrics.compute(in: ctx)
        #expect(m.freelancerCount == 0)
        #expect(m.organizationCount == 0)
        #expect(m.activationReached == false)
        #expect(m.timeToFirstTimer == nil)
        #expect(m.timeToFirstProject == nil)
        #expect(m.timeToFirstInvoice == nil)
        #expect(m.firstTimerKind == .none)
    }

    @Test("entity-type split counts profiles by entityType")
    func entitySplit() throws {
        let ctx = try makeContext()
        let f = BusinessProfile(name: "Solo"); f.entityType = .freelancer
        let o = BusinessProfile(name: "Acme"); o.entityType = .organization
        ctx.insert(f); ctx.insert(o); try ctx.save()
        let m = ActivationMetrics.compute(in: ctx)
        #expect(m.freelancerCount == 1)
        #expect(m.organizationCount == 1)
    }

    @Test("activation-reached flips once any TimeEntry exists")
    func activation() throws {
        let ctx = try makeContext()
        let p = BusinessProfile(name: "X"); p.onboardingCompletedAt = onboarded
        ctx.insert(p)
        #expect(ActivationMetrics.compute(in: ctx).activationReached == false)
        let proj = Project(name: "General", hourlyRate: 0, client: nil)
        ctx.insert(proj)
        ctx.insert(TimeEntry(startedAt: onboarded, project: proj,
                             createdAt: onboarded.addingTimeInterval(60)))
        try ctx.save()
        #expect(ActivationMetrics.compute(in: ctx).activationReached == true)
    }

    @Test("time-to-first-* measured from onboardingCompletedAt to earliest createdAt")
    func timeDeltas() throws {
        let ctx = try makeContext()
        let p = BusinessProfile(name: "X"); p.onboardingCompletedAt = onboarded
        ctx.insert(p)
        let client = Client(name: "Acme", color: .blue); ctx.insert(client)
        let proj = Project(name: "Site", hourlyRate: 100, client: client,
                           createdAt: onboarded.addingTimeInterval(120))
        ctx.insert(proj)
        ctx.insert(TimeEntry(startedAt: onboarded, project: proj,
                             createdAt: onboarded.addingTimeInterval(300)))
        let inv = makeInvoice(number: "0001", createdAt: onboarded.addingTimeInterval(600))
        ctx.insert(inv)
        try ctx.save()
        let m = ActivationMetrics.compute(in: ctx)
        #expect(m.timeToFirstTimer == 300)
        #expect(m.timeToFirstProject == 120)
        #expect(m.timeToFirstInvoice == 600)
    }

    @Test("deltas are nil when onboardingCompletedAt is unset")
    func nilWhenNotOnboarded() throws {
        let ctx = try makeContext()
        let p = BusinessProfile(name: "X")           // onboardingCompletedAt == nil
        ctx.insert(p)
        let proj = Project(name: "General", hourlyRate: 0, client: nil)
        ctx.insert(proj)
        ctx.insert(TimeEntry(startedAt: .now, project: proj))
        try ctx.save()
        let m = ActivationMetrics.compute(in: ctx)
        #expect(m.timeToFirstTimer == nil)
        #expect(m.timeToFirstProject == nil)
    }

    @Test("HEADLINE: earliest-entry project client == nil ⇒ quickStart")
    func headlineQuickStart() throws {
        let ctx = try makeContext()
        let p = BusinessProfile(name: "X"); p.onboardingCompletedAt = onboarded
        ctx.insert(p)
        let general = Project(name: "General", hourlyRate: 0, client: nil)
        ctx.insert(general)
        ctx.insert(TimeEntry(startedAt: onboarded, project: general,
                             createdAt: onboarded.addingTimeInterval(30)))
        try ctx.save()
        #expect(ActivationMetrics.compute(in: ctx).firstTimerKind == .quickStart)
    }

    @Test("HEADLINE: earliest-entry project has a client ⇒ checklist")
    func headlineChecklist() throws {
        let ctx = try makeContext()
        let p = BusinessProfile(name: "X"); p.onboardingCompletedAt = onboarded
        ctx.insert(p)
        let client = Client(name: "Acme", color: .blue); ctx.insert(client)
        let linked = Project(name: "Site", hourlyRate: 100, client: client)
        ctx.insert(linked)
        ctx.insert(TimeEntry(startedAt: onboarded, project: linked,
                             createdAt: onboarded.addingTimeInterval(45)))
        try ctx.save()
        #expect(ActivationMetrics.compute(in: ctx).firstTimerKind == .checklist)
    }

    @Test("HEADLINE uses the EARLIEST entry, not insertion order")
    func headlineEarliestWins() throws {
        let ctx = try makeContext()
        let p = BusinessProfile(name: "X"); p.onboardingCompletedAt = onboarded
        ctx.insert(p)
        let client = Client(name: "Acme", color: .blue); ctx.insert(client)
        let linked = Project(name: "Site", hourlyRate: 100, client: client)
        let general = Project(name: "General", hourlyRate: 0, client: nil)
        ctx.insert(linked); ctx.insert(general)
        // Insert the client-linked entry FIRST but with a LATER createdAt …
        ctx.insert(TimeEntry(startedAt: onboarded, project: linked,
                             createdAt: onboarded.addingTimeInterval(500)))
        // … and the quick-start entry SECOND with an EARLIER createdAt.
        ctx.insert(TimeEntry(startedAt: onboarded, project: general,
                             createdAt: onboarded.addingTimeInterval(100)))
        try ctx.save()
        #expect(ActivationMetrics.compute(in: ctx).firstTimerKind == .quickStart) // earliest-by-createdAt
    }
}
