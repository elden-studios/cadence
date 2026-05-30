# Onboarding Entity-Type — Plan 1: Foundation + Singleton Reconciliation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the `EntityType` model + `BusinessProfile` entity-type/latch/enrichment fields, and a proven, test-driven singleton reconciliation, with zero UI changes.

**Architecture:** Pure `BillableCore` logic. Enums stored as raw `String` (house pattern: `Client.colorRaw`). One-way `Date?` latches. Reconciliation clones the shipping `TimerService.reconcileActiveSessionOnLaunch` pattern: deterministic oldest-survivor, per-field merge (latest-`updatedAt` user fields, `max()` counter, earliest-non-nil latches), safe delete. Everything verified by `swift test` (no Xcode/UI).

**Tech Stack:** Swift 6 (strict concurrency), SwiftData, Swift Testing (`@Test`/`#expect`), `BillableCore` SPM package.

**Spec:** `docs/superpowers/specs/2026-05-30-onboarding-entity-type-design.md` (§4, §8, §16).

**Run all tests with:** `cd Packages/BillableCore && swift test` (filter per task below).

---

### Task 1: `EntityType` enum

**Files:**
- Create: `Packages/BillableCore/Sources/BillableCore/Models/EntityType.swift`
- Test: `Packages/BillableCore/Tests/BillableCoreTests/EntityTypeTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import BillableCore

@Suite("EntityType")
struct EntityTypeTests {
    @Test("raw values round-trip")
    func rawRoundTrip() {
        #expect(EntityType(rawValue: "freelancer") == .freelancer)
        #expect(EntityType(rawValue: "organization") == .organization)
        #expect(EntityType(rawValue: "bogus") == nil)
        #expect(EntityType.freelancer.rawValue == "freelancer")
    }

    @Test("exactly two cases")
    func allCases() {
        #expect(EntityType.allCases == [.freelancer, .organization])
    }

    @Test("tax-by-default policy")
    func taxPolicy() {
        #expect(EntityType.freelancer.showsTaxByDefault == false)
        #expect(EntityType.organization.showsTaxByDefault == true)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/BillableCore && swift test --filter EntityTypeTests`
Expected: FAIL — `cannot find 'EntityType' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Whether the user invoices as an individual or under a business.
/// Drives presentation only (labels + default tax-section visibility), never capability.
/// Stored on `BusinessProfile` as a raw `String` (CloudKit-safe; see `Client.colorRaw`).
public enum EntityType: String, Codable, CaseIterable, Sendable {
    case freelancer
    case organization

    /// Presentation *policy* (not strings — those live in the app layer).
    public var showsTaxByDefault: Bool { self == .organization }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Packages/BillableCore && swift test --filter EntityTypeTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Models/EntityType.swift Packages/BillableCore/Tests/BillableCoreTests/EntityTypeTests.swift
git commit -m "feat(core): add EntityType enum (freelancer/organization)"
```

---

### Task 2: `BusinessProfile` entity-type, latches, `isProfileEnriched`

**Files:**
- Modify: `Packages/BillableCore/Sources/BillableCore/Models/BusinessProfile.swift`
- Test: `Packages/BillableCore/Tests/BillableCoreTests/BusinessProfileEntityTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import BillableCore

@Suite("BusinessProfile entity-type & enrichment")
struct BusinessProfileEntityTests {
    @Test("entityType defaults to organization (back-compat label)")
    func defaultEntityType() {
        let p = BusinessProfile(name: "Acme")
        #expect(p.entityType == .organization)
        #expect(p.entityTypeRaw == "organization")
    }

    @Test("entityType accessor mutates the raw string")
    func accessorSetsRaw() {
        let p = BusinessProfile(name: "Jane")
        p.entityType = .freelancer
        #expect(p.entityTypeRaw == "freelancer")
        p.entityTypeRaw = "bogus"
        #expect(p.entityType == .organization) // unknown raw coalesces to .organization
    }

    @Test("latches default nil and are settable")
    func latches() {
        let p = BusinessProfile(name: "X")
        #expect(p.onboardingCompletedAt == nil)
        #expect(p.firstSetupCompletedAt == nil)
        let t = Date(timeIntervalSince1970: 1000)
        p.onboardingCompletedAt = t
        #expect(p.onboardingCompletedAt == t)
    }

    @Test("isProfileEnriched requires address AND bank details")
    func enriched() {
        let p = BusinessProfile(name: "X")
        #expect(p.isProfileEnriched == false)              // neither
        p.address = "1 Main St"
        #expect(p.isProfileEnriched == false)              // address only
        p.bankIBAN = "GB00 0000"
        #expect(p.isProfileEnriched == true)               // address + bank
        p.address = "   "
        #expect(p.isProfileEnriched == false)              // whitespace address doesn't count
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/BillableCore && swift test --filter BusinessProfileEntityTests`
Expected: FAIL — `value of type 'BusinessProfile' has no member 'entityType'`.

- [ ] **Step 3: Write minimal implementation**

In `BusinessProfile.swift`, add stored properties after `taxIDNumber` (keep the existing grouping/comment style):

```swift
    // MARK: - Entity type + first-run latches (onboarding redesign)

    /// Raw `EntityType`. Default `.organization` is a back-compat fallback that preserves
    /// the legacy "Business name" label + visible tax section; onboarding always sets it.
    public var entityTypeRaw: String = EntityType.organization.rawValue

    public var entityType: EntityType {
        get { EntityType(rawValue: entityTypeRaw) ?? .organization }
        set { entityTypeRaw = newValue.rawValue }
    }

    /// One-way latches (never unset). Stamped by a single owner; double as activation metrics.
    public var onboardingCompletedAt: Date? = nil
    public var firstSetupCompletedAt: Date? = nil
```

Add the computed enrichment flag near `hasBankDetails`/`hasTaxID`:

```swift
    /// "Enriched" = the invoice-completing fields beyond name are present (postal address + a
    /// payment route). Gates the dismissible enrichment nudge only — never blocks anything.
    public var isProfileEnriched: Bool {
        !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && hasBankDetails
    }
```

Add the three new params to `init(...)` (defaulted, so existing call sites are unchanged). Insert into the parameter list after `taxIDNumber: String = ""`:

```swift
        entityTypeRaw: String = EntityType.organization.rawValue,
        onboardingCompletedAt: Date? = nil,
        firstSetupCompletedAt: Date? = nil,
```

…and in the init body, after `self.taxIDNumber = taxIDNumber`:

```swift
        self.entityTypeRaw = entityTypeRaw
        self.onboardingCompletedAt = onboardingCompletedAt
        self.firstSetupCompletedAt = firstSetupCompletedAt
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Packages/BillableCore && swift test --filter BusinessProfileEntityTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Run the FULL suite to confirm back-compat**

Run: `cd Packages/BillableCore && swift test`
Expected: PASS — all prior tests (261) still green; the defaulted init params didn't break any call site.

- [ ] **Step 6: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Models/BusinessProfile.swift Packages/BillableCore/Tests/BillableCoreTests/BusinessProfileEntityTests.swift
git commit -m "feat(core): BusinessProfile entityType, first-run latches, isProfileEnriched"
```

---

### Task 3: Deterministic canonical-profile fetch

**Files:**
- Create: `Packages/BillableCore/Sources/BillableCore/Persistence/BusinessProfileStore.swift`
- Test: `Packages/BillableCore/Tests/BillableCoreTests/BusinessProfileStoreTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
import SwiftData
@testable import BillableCore

@MainActor
@Suite("BusinessProfileStore.canonical")
struct BusinessProfileStoreTests {
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: BillableModelContainer.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @Test("returns nil when empty")
    func empty() throws {
        let ctx = try makeContext()
        #expect(BusinessProfileStore.canonical(in: ctx) == nil)
    }

    @Test("returns the oldest by createdAt")
    func oldestWins() throws {
        let ctx = try makeContext()
        let older = BusinessProfile(name: "Older", createdAt: Date(timeIntervalSince1970: 100))
        let newer = BusinessProfile(name: "Newer", createdAt: Date(timeIntervalSince1970: 200))
        ctx.insert(newer); ctx.insert(older)
        try ctx.save()
        #expect(BusinessProfileStore.canonical(in: ctx)?.name == "Older")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/BillableCore && swift test --filter BusinessProfileStoreTests`
Expected: FAIL — `cannot find 'BusinessProfileStore' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation
import SwiftData

/// Deterministic access to the singleton `BusinessProfile`. SwiftData `@Query` sites can't
/// call this (they're macros) — they must add `sort: \.createdAt`; this is for non-view code
/// and for reconciliation. "Oldest by createdAt" is the canonical survivor; ties are broken by
/// a stable id string so every device agrees.
@MainActor
public enum BusinessProfileStore {
    /// All profiles, oldest-first, with a stable tie-break for equal `createdAt`.
    public static func allSorted(in context: ModelContext) -> [BusinessProfile] {
        let all = (try? context.fetch(FetchDescriptor<BusinessProfile>())) ?? []
        return all.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return String(describing: lhs.persistentModelID) < String(describing: rhs.persistentModelID)
        }
    }

    /// The canonical (oldest) profile, or nil if none exist.
    public static func canonical(in context: ModelContext) -> BusinessProfile? {
        allSorted(in: context).first
    }
}
```

> Note: `BillableModelContainer.schema` is the existing schema accessor in `ModelContainer+Billable.swift`. If the symbol differs, use the actual public schema property from that file.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Packages/BillableCore && swift test --filter BusinessProfileStoreTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Persistence/BusinessProfileStore.swift Packages/BillableCore/Tests/BillableCoreTests/BusinessProfileStoreTests.swift
git commit -m "feat(core): deterministic canonical BusinessProfile fetch (oldest + stable tie-break)"
```

---

### Task 4: `reconcile(in:)` — the merge matrix (the load-bearing TDD task)

**Files:**
- Modify: `Packages/BillableCore/Sources/BillableCore/Persistence/BusinessProfileStore.swift`
- Test: `Packages/BillableCore/Tests/BillableCoreTests/BusinessProfileReconcileTests.swift`

- [ ] **Step 1: Write the failing tests (the full matrix)**

```swift
import Testing
import Foundation
import SwiftData
@testable import BillableCore

@MainActor
@Suite("BusinessProfileStore.reconcile")
struct BusinessProfileReconcileTests {
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: BillableModelContainer.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @Test("no-op for zero or one profile (idempotent)")
    func noop() throws {
        let ctx = try makeContext()
        BusinessProfileStore.reconcile(in: ctx)               // empty: no crash
        let solo = BusinessProfile(name: "Solo")
        ctx.insert(solo); try ctx.save()
        BusinessProfileStore.reconcile(in: ctx)
        #expect((try ctx.fetchCount(FetchDescriptor<BusinessProfile>())) == 1)
    }

    @Test("both-non-empty conflict: newer user fields + max counter survive")
    func conflictKeepsNewerAndMax() throws {
        let ctx = try makeContext()
        // Older record (canonical survivor by createdAt) but STALE edits.
        let older = BusinessProfile(
            name: "Jane", createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        older.nextInvoiceNumber = 1
        older.entityType = .freelancer
        // Newer record: the user's real, most-recent edits + advanced counter.
        let newer = BusinessProfile(
            name: "Jane Doe Studio", createdAt: Date(timeIntervalSince1970: 200),
            updatedAt: Date(timeIntervalSince1970: 999)
        )
        newer.nextInvoiceNumber = 12
        newer.entityType = .organization
        ctx.insert(older); ctx.insert(newer); try ctx.save()

        BusinessProfileStore.reconcile(in: ctx)

        let survivors = try ctx.fetch(FetchDescriptor<BusinessProfile>())
        #expect(survivors.count == 1)                          // exactly one
        let s = survivors[0]
        #expect(s.name == "Jane Doe Studio")                  // latest-updatedAt user fields win
        #expect(s.entityType == .organization)
        #expect(s.nextInvoiceNumber == 12)                    // max() — no counter regression
        #expect(s.createdAt == Date(timeIntervalSince1970: 100)) // survivor identity = oldest
    }

    @Test("latches merge as earliest non-nil; never cleared")
    func latchesEarliestNonNil() throws {
        let ctx = try makeContext()
        let a = BusinessProfile(name: "A", createdAt: Date(timeIntervalSince1970: 100),
                                updatedAt: Date(timeIntervalSince1970: 100))
        a.onboardingCompletedAt = nil
        let b = BusinessProfile(name: "B", createdAt: Date(timeIntervalSince1970: 200),
                                updatedAt: Date(timeIntervalSince1970: 200))
        b.onboardingCompletedAt = Date(timeIntervalSince1970: 250)
        ctx.insert(a); ctx.insert(b); try ctx.save()

        BusinessProfileStore.reconcile(in: ctx)

        let s = try #require(BusinessProfileStore.canonical(in: ctx))
        #expect(s.onboardingCompletedAt == Date(timeIntervalSince1970: 250)) // filled from the set
    }

    @Test("running reconcile twice yields the same single survivor (idempotent)")
    func idempotent() throws {
        let ctx = try makeContext()
        ctx.insert(BusinessProfile(name: "A", createdAt: Date(timeIntervalSince1970: 100)))
        ctx.insert(BusinessProfile(name: "B", createdAt: Date(timeIntervalSince1970: 200)))
        try ctx.save()
        BusinessProfileStore.reconcile(in: ctx)
        BusinessProfileStore.reconcile(in: ctx)
        #expect((try ctx.fetchCount(FetchDescriptor<BusinessProfile>())) == 1)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Packages/BillableCore && swift test --filter BusinessProfileReconcileTests`
Expected: FAIL — `type 'BusinessProfileStore' has no member 'reconcile'`.

- [ ] **Step 3: Write minimal implementation**

Add to `BusinessProfileStore`:

```swift
    /// Converge duplicate singletons (multi-device CloudKit). Survivor = oldest `createdAt`
    /// (stable tie-break); user fields taken from the latest-`updatedAt` record; `nextInvoiceNumber`
    /// = max() (never regress → no invoice-number collisions); one-way latches = earliest non-nil
    /// (fill, never clear). Idempotent. `BusinessProfile` has no inbound relationship, so deleting
    /// extras orphans nothing. Call from launch + scenePhase==.active (see Plan 2).
    public static func reconcile(in context: ModelContext) {
        let all = allSorted(in: context)
        guard all.count > 1 else { return }

        let survivor = all[0]                                   // oldest
        let source = all.max { $0.updatedAt < $1.updatedAt } ?? survivor  // most-recently-edited

        if source !== survivor { copyUserFields(from: source, to: survivor) }

        survivor.nextInvoiceNumber = all.map(\.nextInvoiceNumber).max() ?? survivor.nextInvoiceNumber
        survivor.onboardingCompletedAt = earliest(all.compactMap(\.onboardingCompletedAt))
        survivor.firstSetupCompletedAt = earliest(all.compactMap(\.firstSetupCompletedAt))

        for extra in all where extra !== survivor { context.delete(extra) }
        survivor.updatedAt = .now
        try? context.save()
    }

    private static func earliest(_ dates: [Date]) -> Date? { dates.min() }

    /// Copies every user-entered field. NOTE: keep in sync with `BusinessProfile`'s stored
    /// user fields — `BusinessProfileMergeCompletenessTests` fails if a property is added without
    /// a line here.
    private static func copyUserFields(from src: BusinessProfile, to dst: BusinessProfile) {
        dst.name = src.name
        dst.entityTypeRaw = src.entityTypeRaw
        dst.address = src.address
        dst.email = src.email
        dst.phone = src.phone
        dst.logoData = src.logoData
        dst.paymentTerms = src.paymentTerms
        dst.defaultDueAfterDays = src.defaultDueAfterDays
        dst.invoiceNumberPrefix = src.invoiceNumberPrefix
        dst.taxLabel = src.taxLabel
        dst.taxRate = src.taxRate
        dst.currencyCode = src.currencyCode
        dst.bankBeneficiaryName = src.bankBeneficiaryName
        dst.bankName = src.bankName
        dst.bankLocation = src.bankLocation
        dst.bankIBAN = src.bankIBAN
        dst.bankSWIFT = src.bankSWIFT
        dst.taxIDLabel = src.taxIDLabel
        dst.taxIDNumber = src.taxIDNumber
        dst.invoiceEmailSubjectTemplate = src.invoiceEmailSubjectTemplate
        dst.invoiceEmailBodyTemplate = src.invoiceEmailBodyTemplate
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Packages/BillableCore && swift test --filter BusinessProfileReconcileTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Persistence/BusinessProfileStore.swift Packages/BillableCore/Tests/BillableCoreTests/BusinessProfileReconcileTests.swift
git commit -m "feat(core): BusinessProfile.reconcile — per-field merge (latest-updatedAt, max counter, earliest latch)"
```

---

### Task 5: `stampFirstSetupIfReached(in:)` — the single latch writer

**Files:**
- Modify: `Packages/BillableCore/Sources/BillableCore/Persistence/BusinessProfileStore.swift`
- Test: `Packages/BillableCore/Tests/BillableCoreTests/FirstSetupStampTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
import SwiftData
@testable import BillableCore

@MainActor
@Suite("stampFirstSetupIfReached")
struct FirstSetupStampTests {
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: BillableModelContainer.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @Test("does not stamp when no client-linked project exists")
    func noStampWithoutLinkedProject() throws {
        let ctx = try makeContext()
        let p = BusinessProfile(name: "X"); ctx.insert(p)
        // A clientless 'General' (quick-start) must NOT satisfy first-setup.
        ctx.insert(Project(name: "General", hourlyRate: 0, isBillable: true, client: nil))
        try ctx.save()
        BusinessProfileStore.stampFirstSetupIfReached(in: ctx)
        #expect(BusinessProfileStore.canonical(in: ctx)?.firstSetupCompletedAt == nil)
    }

    @Test("stamps when a client + client-linked non-archived project coexist")
    func stampsWhenReached() throws {
        let ctx = try makeContext()
        let p = BusinessProfile(name: "X"); ctx.insert(p)
        let client = Client(name: "Acme", color: .blue)
        ctx.insert(client)
        ctx.insert(Project(name: "Site", hourlyRate: 100, isBillable: true, client: client))
        try ctx.save()
        BusinessProfileStore.stampFirstSetupIfReached(in: ctx)
        #expect(BusinessProfileStore.canonical(in: ctx)?.firstSetupCompletedAt != nil)
    }

    @Test("is a one-way no-op once set")
    func oneWay() throws {
        let ctx = try makeContext()
        let p = BusinessProfile(name: "X")
        p.firstSetupCompletedAt = Date(timeIntervalSince1970: 500)
        ctx.insert(p)
        let client = Client(name: "Acme", color: .blue); ctx.insert(client)
        ctx.insert(Project(name: "Site", hourlyRate: 100, isBillable: true, client: client))
        try ctx.save()
        BusinessProfileStore.stampFirstSetupIfReached(in: ctx)
        #expect(BusinessProfileStore.canonical(in: ctx)?.firstSetupCompletedAt == Date(timeIntervalSince1970: 500))
    }
}
```

> Verify `Client(name:color:)` and `Project(name:hourlyRate:isBillable:client:)` signatures against the models before running; adjust the constructor calls if the real initializers differ.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/BillableCore && swift test --filter FirstSetupStampTests`
Expected: FAIL — `no member 'stampFirstSetupIfReached'`.

- [ ] **Step 3: Write minimal implementation**

Add to `BusinessProfileStore`:

```swift
    /// The SINGLE writer of `firstSetupCompletedAt`. Idempotent + one-way: stamps the canonical
    /// profile the first time a Client AND a client-linked, non-archived Project coexist. A
    /// clientless quick-start "General" project does NOT count. Call from the same launch +
    /// scenePhase seam as `reconcile`.
    public static func stampFirstSetupIfReached(in context: ModelContext) {
        guard let profile = canonical(in: context), profile.firstSetupCompletedAt == nil else { return }
        guard (try? context.fetchCount(FetchDescriptor<Client>())) ?? 0 > 0 else { return }
        var linked = FetchDescriptor<Project>(predicate: #Predicate { !$0.isArchived && $0.client != nil })
        linked.fetchLimit = 1
        guard ((try? context.fetchCount(linked)) ?? 0) > 0 else { return }
        profile.firstSetupCompletedAt = .now
        try? context.save()
    }
```

> If `Project`'s `client` relationship isn't expressible in `#Predicate` as `$0.client != nil` (SwiftData optional-to-one quirk), fall back to fetching non-archived projects (`fetchLimit` bounded) and checking `contains { $0.client != nil }` in memory.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Packages/BillableCore && swift test --filter FirstSetupStampTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Persistence/BusinessProfileStore.swift Packages/BillableCore/Tests/BillableCoreTests/FirstSetupStampTests.swift
git commit -m "feat(core): stampFirstSetupIfReached — single one-way first-setup latch writer"
```

---

### Task 6: Field-merge-completeness guard

**Files:**
- Test: `Packages/BillableCore/Tests/BillableCoreTests/BusinessProfileMergeCompletenessTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import BillableCore

@Suite("merge completeness")
struct BusinessProfileMergeCompletenessTests {
    /// Tripwire: if someone adds a stored property to BusinessProfile, this fails so they
    /// consciously decide whether reconcile's copyUserFields must carry it. Update BOTH the
    /// count here AND copyUserFields when intentionally adding a field.
    @Test("stored-property count is locked")
    func storedPropertyCountLocked() {
        let mirror = Mirror(reflecting: BusinessProfile(name: "x"))
        #expect(mirror.children.count == BusinessProfile.expectedStoredPropertyCount)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/BillableCore && swift test --filter BusinessProfileMergeCompletenessTests`
Expected: FAIL — `no member 'expectedStoredPropertyCount'`.

- [ ] **Step 3: Write minimal implementation**

Determine the real count first:

Run: `cd Packages/BillableCore && swift -e 'print("count via mirror at runtime")'` — instead, temporarily add `print(Mirror(reflecting: BusinessProfile(name:"x")).children.count)` in the test, run once, read the number, then hardcode it. Add to `BusinessProfile`:

```swift
    /// Locked count guarding `BusinessProfileStore.copyUserFields`. Bump intentionally when
    /// adding/removing a stored property (and update copyUserFields if it's a user field).
    static let expectedStoredPropertyCount = <N>   // set to the value printed by the mirror
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Packages/BillableCore && swift test --filter BusinessProfileMergeCompletenessTests`
Expected: PASS (1 test).

- [ ] **Step 5: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Models/BusinessProfile.swift Packages/BillableCore/Tests/BillableCoreTests/BusinessProfileMergeCompletenessTests.swift
git commit -m "test(core): lock BusinessProfile stored-property count to guard reconcile merge"
```

---

### Task 7: Migration round-trip (gating, ON-DISK)

**Files:**
- Test: `Packages/BillableCore/Tests/BillableCoreTests/BusinessProfileMigrationTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
import SwiftData
@testable import BillableCore

@MainActor
@Suite("BusinessProfile additive migration")
struct BusinessProfileMigrationTests {
    /// Proves lightweight migration: a real on-disk store created with the CURRENT schema,
    /// closed, then reopened, materializes the new defaulted fields. (An in-memory store can't
    /// exercise store reopen, so this MUST be on disk.)
    @Test("defaulted fields survive a store close/reopen")
    func reopenAppliesDefaults() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("billable-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Billable.store")

        // Write a profile, then fully release the container.
        do {
            let c = try ModelContainer(for: BillableModelContainer.schema,
                                       configurations: ModelConfiguration(url: url))
            let ctx = ModelContext(c)
            ctx.insert(BusinessProfile(name: "Persisted"))
            try ctx.save()
        }

        // Reopen and assert defaults materialized.
        let c2 = try ModelContainer(for: BillableModelContainer.schema,
                                    configurations: ModelConfiguration(url: url))
        let ctx2 = ModelContext(c2)
        let p = try #require(try ctx2.fetch(FetchDescriptor<BusinessProfile>()).first)
        #expect(p.name == "Persisted")
        #expect(p.entityType == .organization)
        #expect(p.onboardingCompletedAt == nil)
        #expect(p.isProfileEnriched == false)
    }
}
```

- [ ] **Step 2: Run test to verify it fails or passes**

Run: `cd Packages/BillableCore && swift test --filter BusinessProfileMigrationTests`
Expected: PASS (the fields already exist from Task 2). If it FAILS to open the store, the migration is NOT lightweight-safe — STOP and investigate before proceeding (this is the gating check).

- [ ] **Step 3: Commit**

```bash
git add Packages/BillableCore/Tests/BillableCoreTests/BusinessProfileMigrationTests.swift
git commit -m "test(core): on-disk migration round-trip for new BusinessProfile fields (gating)"
```

---

### Task 8: Full-suite green gate

- [ ] **Step 1: Run the entire BillableCore suite**

Run: `cd Packages/BillableCore && swift test`
Expected: PASS — all prior tests + the ~14 new tests from this plan. Zero failures.

- [ ] **Step 2: Commit any incidental fixes, then stop**

Plan 1 is complete: the entity-type model, latches, enrichment flag, and a *proven* reconciliation are in place and fully unit-tested. Proceed to Plan 2 (onboarding flow + editor).

---

## Self-review notes (author)

- **Spec coverage (Plan 1 scope):** §4 model (Tasks 1–2), §8 deterministic reads + reconciliation + merge table + safe delete (Tasks 3–4), §7 latch writer (Task 5), §16 reconciliation matrix + on-disk migration + merge-completeness (Tasks 4/6/7). Deferred to later plans: §5 onboarding UI, §6 editor, §7 Today UI, §7b enrichment UI, §13 release-gates, §14 readout, §12 dev credit.
- **Verify-before-coding flags for the implementer:** `BillableModelContainer.schema` symbol name; `Client`/`Project` initializer signatures; whether `$0.client != nil` is expressible in `#Predicate` (fallback noted); the real stored-property count for Task 6.
- **Open contract (carried to Plan 2):** `reconcile`/`stampFirstSetupIfReached` must be wired into `BillableApp.performStartupWiring()` + `RootView`'s `scenePhase==.active` block, with the "count stable across two checks" delete-safety guard at that call site.
