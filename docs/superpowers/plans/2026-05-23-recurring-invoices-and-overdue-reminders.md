# Cadence v1.1 — Recurring Invoices + Auto-Overdue Reminders — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Recurring invoices + Auto-overdue reminders as Cadence v1.1, local-first (no backend), in ~1 week including tests.

**Architecture:** One shared `Scheduler` primitive in `BillableCore` bridges SwiftData + `UNUserNotificationCenter`; two feature services (`RecurrenceService`, `ReminderService`) sit on top. App-target gains a minimal `AppDelegate` + `@Observable NotificationRouter` to handle taps. Three new SwiftData models go into the mirrored CloudKit schema; one (`ScheduledNotification`) lives in a separate local-only configuration.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, `UNUserNotificationCenter`, Swift Testing, CloudKit Mirror, `MFMailComposeViewController` / `mailto:`.

**Source spec:** [`docs/superpowers/specs/2026-05-23-recurring-invoices-and-overdue-reminders-design.md`](../specs/2026-05-23-recurring-invoices-and-overdue-reminders-design.md)

---

## File Structure

### Files to create

#### BillableCore (`Packages/BillableCore/Sources/BillableCore/`)

| Path | Responsibility |
|---|---|
| `Scheduling/Scheduler.swift` | Authorization, schedule/cancel, resync-on-launch, tap routing. No domain knowledge. |
| `Scheduling/SchedulerPayload.swift` | Opaque payload enum: `.recurrence(templateID)` `.reminder(scheduleID)` |
| `Models/ScheduledNotification.swift` | Local-only @Model: `id, fireAt, payloadType, payloadID` |
| `Models/RecurrenceTemplate.swift` | Mirrored @Model: client + cadence + nextFireDate + lastFiredAt |
| `Models/ReminderConfig.swift` | Mirrored singleton @Model: enabledOffsets + templates + masterEnabled |
| `Models/InvoiceReminderSchedule.swift` | Mirrored @Model: invoice + fireDates + firedDates |
| `Recurrence/RecurrenceCadence.swift` | Enum with raw String for SwiftData |
| `Recurrence/RangeRule.swift` | Enum with raw String; resolves to InvoiceDateRange |
| `Recurrence/RecurrenceService.swift` | computeNextFireDate, materializeDraft, reconcile |
| `Reminders/ReminderService.swift` | scheduleForInvoice, cancelForInvoice, composeReminderEmail |
| `Reminders/ReminderTemplateRenderer.swift` | Merge field renderer |
| `Routing/NotificationRouter.swift` | `@Observable` router with `pendingDestination` |

#### App (`App/Sources/`)

| Path | Responsibility |
|---|---|
| `App/AppDelegate.swift` | `UNUserNotificationCenterDelegate` shim that calls `Scheduler.handleNotificationTap` |
| `Features/Recurrence/RecurringRulesView.swift` | Manage list (4th segment of Invoices tab) |
| `Features/Recurrence/RecurrenceEditorView.swift` | Edit one template (Pause/Delete/Generate now) |
| `Features/Recurrence/CatchUpBanner.swift` | Today-screen banner for pending materializations |
| `Features/Settings/PaymentRemindersView.swift` | Global reminder config screen |
| `Features/Settings/DiagnosticsView.swift` | Gated by `--debug-scheduler` |

#### Tests

| Path | Responsibility |
|---|---|
| `Packages/BillableCore/Tests/BillableCoreTests/SchedulingTests.swift` | All scheduler/recurrence/reminder unit tests |
| `App/BillableUITests/NotificationTapFlowUITests.swift` | One UI test for tap-to-screen handoff |

### Files to modify

| Path | Change |
|---|---|
| `Packages/BillableCore/Sources/BillableCore/Models/Client.swift` | Add `reminderOffsets: [Int]?` |
| `Packages/BillableCore/Sources/BillableCore/Models/Invoice.swift` | Add `reminderSchedule: InvoiceReminderSchedule?` relationship |
| `Packages/BillableCore/Sources/BillableCore/Models/InvoiceStatusMachine.swift` | `markSent`/`markPaid` notify `ReminderService` via a closure or environment |
| `Packages/BillableCore/Sources/BillableCore/Persistence/ModelContainer+Billable.swift` | Add 4 models; split into 2 ModelConfigurations (mirrored + local-only) |
| `App/Sources/App/BillableApp.swift` | `@UIApplicationDelegateAdaptor`, inject `NotificationRouter` |
| `App/Sources/App/RootView.swift` | Observe `NotificationRouter`, apply navigation |
| `App/Sources/Features/Invoicing/InvoiceGeneratorView.swift` | "Make recurring" toggle + cadence controls |
| `App/Sources/Features/Invoicing/InvoicesView.swift` | "Recurring" segment in the existing filter |
| `App/Sources/Features/Invoicing/InvoiceDetailView.swift` | Overdue reminder banner + Send reminder CTA |
| `App/Sources/Features/Clients/ClientEditorView.swift` | Reminders section |
| `App/Sources/Features/Settings/SettingsView.swift` | "Payment reminders" row |
| `App/Sources/Features/Today/TodayView.swift` | Host `CatchUpBanner` |
| `project.yml` | Add `INFOPLIST_KEY_NSUserNotificationsUsageDescription` if needed |

---

## Conventions used in this plan

- All Swift code uses Swift 6 strict concurrency. `@MainActor` on UI-touching services; `Sendable` on plain value types.
- All tests use **Swift Testing** (`@Test`, `#expect`) — matches the existing 52-test suite.
- Build verification: `xcodebuild -project Billable.xcodeproj -scheme Billable -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -configuration Debug build`
- Test runs use the same scheme with `test` action and may target specific suites via `-only-testing`.
- After regenerating from `project.yml`, always run `xcodegen generate`.
- Commit messages use imperative mood and reference the task number from this plan.

---

## Phase 1 — Scheduler primitive (Day 1)

### Task 1.1: `ScheduledNotification` model (local-only)

**Files:**
- Create: `Packages/BillableCore/Sources/BillableCore/Models/ScheduledNotification.swift`
- Test: `Packages/BillableCore/Tests/BillableCoreTests/SchedulingTests.swift`

- [ ] **Step 1: Write the failing test**

Create `SchedulingTests.swift` with this content:

```swift
import Foundation
import SwiftData
import Testing
@testable import BillableCore

@Suite("Scheduling")
struct SchedulingTests {

    @Test("ScheduledNotification persists with all fields")
    @MainActor
    func scheduledNotificationPersists() throws {
        let container = try BillableModelContainer.inMemory()
        let context = container.mainContext
        let id = UUID()
        let fireAt = Date(timeIntervalSince1970: 1_900_000_000)
        let payloadID = UUID()

        let note = ScheduledNotification(
            id: id,
            fireAt: fireAt,
            payloadType: "recurrence",
            payloadID: payloadID
        )
        context.insert(note)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<ScheduledNotification>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.id == id)
        #expect(fetched.first?.fireAt == fireAt)
        #expect(fetched.first?.payloadType == "recurrence")
        #expect(fetched.first?.payloadID == payloadID)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Billable.xcodeproj -scheme Billable -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:BillableCoreTests/SchedulingTests test`
Expected: FAIL — "Cannot find 'ScheduledNotification' in scope" or similar.

- [ ] **Step 3: Implement the model**

Create `ScheduledNotification.swift`:

```swift
import Foundation
import SwiftData

/// Local-only bookkeeping for a pending iOS notification.
///
/// Stored in a SwiftData configuration that is NOT mirrored to CloudKit because
/// iOS notification state is device-specific. Each device rebuilds its own
/// rows via `Scheduler.resyncOnLaunch()` from the mirrored truth on
/// `RecurrenceTemplate` and `InvoiceReminderSchedule`.
@Model
public final class ScheduledNotification {
    /// Also used as the `UNNotificationRequest.identifier`.
    @Attribute(.unique) public var id: UUID

    /// When iOS should deliver the notification (absolute UTC moment).
    public var fireAt: Date

    /// "recurrence" | "reminder" — discriminator for `payloadID`.
    public var payloadType: String

    /// FK to either `RecurrenceTemplate.id` (when `payloadType == "recurrence"`)
    /// or `InvoiceReminderSchedule.id` (when `payloadType == "reminder"`).
    public var payloadID: UUID

    public init(
        id: UUID = UUID(),
        fireAt: Date,
        payloadType: String,
        payloadID: UUID
    ) {
        self.id = id
        self.fireAt = fireAt
        self.payloadType = payloadType
        self.payloadID = payloadID
    }
}
```

- [ ] **Step 4: Register the model in `BillableModelContainer`**

Modify `Packages/BillableCore/Sources/BillableCore/Persistence/ModelContainer+Billable.swift`. Replace the `schema` constant and update the in-memory factory to support a separate local-only configuration:

```swift
public enum BillableModelContainer {
    /// Mirrored models (sync to CloudKit private DB).
    public static let mirroredSchema = Schema([
        BusinessProfile.self,
        Client.self,
        Project.self,
        TimeEntry.self,
        Invoice.self,
    ])

    /// Local-only models (never sync to CloudKit).
    public static let localOnlySchema = Schema([
        ScheduledNotification.self,
    ])

    /// Convenience for SwiftData previews and tests that want a single schema.
    public static let schema = Schema(
        mirroredSchema.entities + localOnlySchema.entities
    )

    public static func inMemory() throws -> ModelContainer {
        let mirrored = ModelConfiguration(
            "mirrored",
            schema: mirroredSchema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let local = ModelConfiguration(
            "local",
            schema: localOnlySchema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema,
            configurations: [mirrored, local]
        )
    }

    // ... keep `local()`, `appGroup(...)`, `cloudKit(...)` but each builds
    // BOTH configurations. The mirrored config keeps its CloudKit setting;
    // the local config always uses `cloudKitDatabase: .none`.
}
```

For `appGroup(_:cloudKitContainerID:)`, the updated body:

```swift
public static func appGroup(
    _ groupID: String,
    cloudKitContainerID: String? = nil
) throws -> ModelContainer {
    guard let groupURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
        return try local()
    }
    let mirroredStoreURL = groupURL.appendingPathComponent("Billable.store")
    let localStoreURL = groupURL.appendingPathComponent("Billable-local.store")

    let mirroredConfig: ModelConfiguration
    if let cloudKitContainerID {
        mirroredConfig = ModelConfiguration(
            "mirrored",
            schema: mirroredSchema,
            url: mirroredStoreURL,
            cloudKitDatabase: .private(cloudKitContainerID)
        )
    } else {
        mirroredConfig = ModelConfiguration(
            "mirrored",
            schema: mirroredSchema,
            url: mirroredStoreURL,
            cloudKitDatabase: .none
        )
    }

    let localConfig = ModelConfiguration(
        "local",
        schema: localOnlySchema,
        url: localStoreURL,
        cloudKitDatabase: .none
    )

    do {
        return try ModelContainer(
            for: schema,
            configurations: [mirroredConfig, localConfig]
        )
    } catch {
        // CloudKit failed — drop the mirrored config to local-only.
        let fallback = ModelConfiguration(
            "mirrored-fallback",
            schema: mirroredSchema,
            url: mirroredStoreURL,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema,
            configurations: [fallback, localConfig]
        )
    }
}
```

(Update `local()` and `cloudKit(containerIdentifier:)` analogously — both schemas, two configurations, local schema always `.none`.)

- [ ] **Step 5: Run test to verify it passes**

Run: same command as Step 2.
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Models/ScheduledNotification.swift \
        Packages/BillableCore/Sources/BillableCore/Persistence/ModelContainer+Billable.swift \
        Packages/BillableCore/Tests/BillableCoreTests/SchedulingTests.swift
git commit -m "feat(scheduling): add ScheduledNotification local-only model

Task 1.1 of v1.1 plan. Splits BillableModelContainer into mirrored + local-only
configurations so notification bookkeeping never syncs to iCloud."
```

---

### Task 1.2: `SchedulerPayload` enum

**Files:**
- Create: `Packages/BillableCore/Sources/BillableCore/Scheduling/SchedulerPayload.swift`
- Test: append to `SchedulingTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `SchedulingTests.swift`:

```swift
@Test("SchedulerPayload encodes and decodes via String round-trip")
func payloadRoundTrip() throws {
    let recurrencePayloadID = UUID()
    let recurrence = SchedulerPayload.recurrence(templateID: recurrencePayloadID)
    let recEncoded = recurrence.encoded()
    let recDecoded = try #require(SchedulerPayload.decode(
        payloadType: recEncoded.type,
        payloadID: recEncoded.id
    ))
    #expect(recDecoded == .recurrence(templateID: recurrencePayloadID))

    let reminderScheduleID = UUID()
    let reminder = SchedulerPayload.reminder(scheduleID: reminderScheduleID)
    let remEncoded = reminder.encoded()
    let remDecoded = try #require(SchedulerPayload.decode(
        payloadType: remEncoded.type,
        payloadID: remEncoded.id
    ))
    #expect(remDecoded == .reminder(scheduleID: reminderScheduleID))

    // Unknown discriminator → nil
    #expect(SchedulerPayload.decode(payloadType: "garbage", payloadID: UUID()) == nil)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: same `-only-testing` command.
Expected: FAIL — "Cannot find 'SchedulerPayload' in scope".

- [ ] **Step 3: Implement the payload**

Create `SchedulerPayload.swift`:

```swift
import Foundation

/// Opaque payload routed by `Scheduler.handleNotificationTap`.
/// Kept here (and not in `Scheduler.swift`) so it can be referenced by
/// services without pulling in the full Scheduler implementation.
public enum SchedulerPayload: Equatable, Sendable {
    case recurrence(templateID: UUID)
    case reminder(scheduleID: UUID)

    /// String form stored in `ScheduledNotification.payloadType` +
    /// `ScheduledNotification.payloadID`.
    public func encoded() -> (type: String, id: UUID) {
        switch self {
        case .recurrence(let id): return ("recurrence", id)
        case .reminder(let id):   return ("reminder",   id)
        }
    }

    public static func decode(payloadType: String, payloadID: UUID) -> SchedulerPayload? {
        switch payloadType {
        case "recurrence": return .recurrence(templateID: payloadID)
        case "reminder":   return .reminder(scheduleID: payloadID)
        default:           return nil
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Scheduling/SchedulerPayload.swift \
        Packages/BillableCore/Tests/BillableCoreTests/SchedulingTests.swift
git commit -m "feat(scheduling): add SchedulerPayload routing enum (task 1.2)"
```

---

### Task 1.3: `Scheduler` skeleton + authorization

**Files:**
- Create: `Packages/BillableCore/Sources/BillableCore/Scheduling/Scheduler.swift`
- Test: append to `SchedulingTests.swift`

For tests, `UNUserNotificationCenter` is hard to fake directly. The `Scheduler` accepts an injected `NotificationCenterProtocol` so tests can supply a stub.

- [ ] **Step 1: Write the failing test**

Append:

```swift
final class FakeNotificationCenter: NotificationCenterProtocol, @unchecked Sendable {
    var authorized = false
    var pendingRequests: [UNNotificationRequest] = []
    var addedRequests: [UNNotificationRequest] = []
    var removedIdentifiers: [String] = []

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        authorized = true
        return true
    }
    func authorizationStatus() async -> UNAuthorizationStatus {
        authorized ? .authorized : .notDetermined
    }
    func add(_ request: UNNotificationRequest) async throws {
        addedRequests.append(request)
        pendingRequests.append(request)
    }
    func getPendingNotificationRequests() async -> [UNNotificationRequest] {
        pendingRequests
    }
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        removedIdentifiers.append(contentsOf: identifiers)
        pendingRequests.removeAll { identifiers.contains($0.identifier) }
    }
}

@Test("Scheduler.requestAuthorization caches granted state")
@MainActor
func authorizationGrantsAndCaches() async throws {
    let center = FakeNotificationCenter()
    let container = try BillableModelContainer.inMemory()
    let scheduler = Scheduler(
        center: center,
        modelContext: container.mainContext
    )

    let granted = try await scheduler.requestAuthorization()
    #expect(granted == true)
    #expect(center.authorized == true)
}

@Test("Scheduler.requestAuthorization returns false when user declines (simulated)")
@MainActor
func authorizationDeclined() async throws {
    final class DeclineCenter: NotificationCenterProtocol, @unchecked Sendable {
        func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool { false }
        func authorizationStatus() async -> UNAuthorizationStatus { .denied }
        func add(_ request: UNNotificationRequest) async throws {}
        func getPendingNotificationRequests() async -> [UNNotificationRequest] { [] }
        func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {}
    }
    let center = DeclineCenter()
    let container = try BillableModelContainer.inMemory()
    let scheduler = Scheduler(
        center: center,
        modelContext: container.mainContext
    )

    let granted = try await scheduler.requestAuthorization()
    #expect(granted == false)
}
```

- [ ] **Step 2: Run test to verify it fails**

Expected: FAIL — "Cannot find 'NotificationCenterProtocol'" / "Cannot find 'Scheduler'".

- [ ] **Step 3: Implement `NotificationCenterProtocol` + `Scheduler` (auth only)**

Create `Scheduler.swift`:

```swift
import Foundation
import SwiftData
import UserNotifications
import OSLog

/// Test seam over `UNUserNotificationCenter` — narrow to what `Scheduler` uses.
public protocol NotificationCenterProtocol: Sendable {
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func authorizationStatus() async -> UNAuthorizationStatus
    func add(_ request: UNNotificationRequest) async throws
    func getPendingNotificationRequests() async -> [UNNotificationRequest]
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
}

/// The real `UNUserNotificationCenter` adopts the protocol via this extension.
extension UNUserNotificationCenter: NotificationCenterProtocol {
    public func authorizationStatus() async -> UNAuthorizationStatus {
        await notificationSettings().authorizationStatus
    }
}

/// Domain-knowledge-free local-notification scheduler.
@MainActor
public final class Scheduler {
    public enum ScheduleResult: Equatable, Sendable {
        case scheduled
        case noPermission
        case capExceeded
    }

    private let center: any NotificationCenterProtocol
    private let modelContext: ModelContext
    private let log = Logger(subsystem: "com.eldenstudios.billable", category: "Scheduler")

    /// Soft cap to stay under iOS's 64-pending hard cap with headroom.
    public static let softCap = 60

    public init(center: any NotificationCenterProtocol, modelContext: ModelContext) {
        self.center = center
        self.modelContext = modelContext
    }

    public func requestAuthorization() async throws -> Bool {
        let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        log.info("Authorization request: granted=\(granted, privacy: .public)")
        return granted
    }

    public func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        await center.authorizationStatus()
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Scheduling/Scheduler.swift \
        Packages/BillableCore/Tests/BillableCoreTests/SchedulingTests.swift
git commit -m "feat(scheduling): Scheduler skeleton with auth (task 1.3)"
```

---

### Task 1.4: `Scheduler.schedule(payload:fireAt:)` + `cancel(id:)`

**Files:**
- Modify: `Packages/BillableCore/Sources/BillableCore/Scheduling/Scheduler.swift`
- Test: append to `SchedulingTests.swift`

- [ ] **Step 1: Write the failing test**

Append:

```swift
@Test("Scheduler.schedule registers iOS request + persists ScheduledNotification")
@MainActor
func scheduleRegistersBoth() async throws {
    let center = FakeNotificationCenter()
    center.authorized = true
    let container = try BillableModelContainer.inMemory()
    let scheduler = Scheduler(center: center, modelContext: container.mainContext)
    _ = try await scheduler.requestAuthorization()

    let payloadID = UUID()
    let fireAt = Date().addingTimeInterval(3600)
    let result = try await scheduler.schedule(
        payload: .recurrence(templateID: payloadID),
        fireAt: fireAt,
        title: "Test",
        body: "Body"
    )

    #expect(result == .scheduled)
    #expect(center.addedRequests.count == 1)
    let fetched = try container.mainContext.fetch(FetchDescriptor<ScheduledNotification>())
    #expect(fetched.count == 1)
    #expect(fetched.first?.payloadType == "recurrence")
    #expect(fetched.first?.payloadID == payloadID)
    #expect(fetched.first?.fireAt == fireAt)
}

@Test("Scheduler.schedule returns .noPermission when unauthorized")
@MainActor
func scheduleNoPermission() async throws {
    let center = FakeNotificationCenter()
    // Note: authorized stays false
    let container = try BillableModelContainer.inMemory()
    let scheduler = Scheduler(center: center, modelContext: container.mainContext)

    let result = try await scheduler.schedule(
        payload: .reminder(scheduleID: UUID()),
        fireAt: Date().addingTimeInterval(3600),
        title: "T",
        body: "B"
    )

    #expect(result == .noPermission)
    #expect(center.addedRequests.isEmpty)
    let fetched = try container.mainContext.fetch(FetchDescriptor<ScheduledNotification>())
    #expect(fetched.isEmpty)
}

@Test("Scheduler.cancel removes iOS request + SwiftData row")
@MainActor
func cancelRemovesBoth() async throws {
    let center = FakeNotificationCenter()
    center.authorized = true
    let container = try BillableModelContainer.inMemory()
    let scheduler = Scheduler(center: center, modelContext: container.mainContext)
    _ = try await scheduler.requestAuthorization()

    let payloadID = UUID()
    _ = try await scheduler.schedule(
        payload: .reminder(scheduleID: payloadID),
        fireAt: Date().addingTimeInterval(3600),
        title: "T",
        body: "B"
    )
    let id = try #require(
        container.mainContext.fetch(FetchDescriptor<ScheduledNotification>()).first?.id
    )

    scheduler.cancel(id: id)

    #expect(center.removedIdentifiers.contains(id.uuidString))
    let remaining = try container.mainContext.fetch(FetchDescriptor<ScheduledNotification>())
    #expect(remaining.isEmpty)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL — "Value of type 'Scheduler' has no member 'schedule'".

- [ ] **Step 3: Implement schedule + cancel**

Add to `Scheduler.swift` (inside the class):

```swift
    /// Register a local notification + persist its bookkeeping row.
    /// Returns `.noPermission` if the user hasn't authorized; in that case
    /// no iOS request is registered and no SwiftData row is created.
    @discardableResult
    public func schedule(
        payload: SchedulerPayload,
        fireAt: Date,
        title: String,
        body: String
    ) async throws -> ScheduleResult {
        guard await center.authorizationStatus() == .authorized else {
            log.info("schedule(): no permission; skipping")
            return .noPermission
        }

        let pending = await center.getPendingNotificationRequests().count
        guard pending < Self.softCap else {
            log.notice("schedule(): soft cap reached (\(pending, privacy: .public))")
            // Persist the row so resync can register it later when capacity frees up.
            let (type, id) = payload.encoded()
            let note = ScheduledNotification(
                fireAt: fireAt, payloadType: type, payloadID: id
            )
            modelContext.insert(note)
            try modelContext.save()
            return .capExceeded
        }

        let (type, id) = payload.encoded()
        let note = ScheduledNotification(
            fireAt: fireAt, payloadType: type, payloadID: id
        )
        modelContext.insert(note)
        try modelContext.save()

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let trigger = UNCalendarNotificationTrigger(
            dateMatching: Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: fireAt
            ),
            repeats: false
        )
        let request = UNNotificationRequest(
            identifier: note.id.uuidString,
            content: content,
            trigger: trigger
        )
        try await center.add(request)
        log.info("schedule(): id=\(note.id.uuidString, privacy: .public) fireAt=\(fireAt, privacy: .public)")
        return .scheduled
    }

    /// Cancel a previously-registered notification by id.
    public func cancel(id: UUID) {
        center.removePendingNotificationRequests(withIdentifiers: [id.uuidString])
        let descriptor = FetchDescriptor<ScheduledNotification>(
            predicate: #Predicate { $0.id == id }
        )
        if let rows = try? modelContext.fetch(descriptor) {
            for row in rows { modelContext.delete(row) }
            try? modelContext.save()
        }
        log.info("cancel(): id=\(id.uuidString, privacy: .public)")
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Scheduling/Scheduler.swift \
        Packages/BillableCore/Tests/BillableCoreTests/SchedulingTests.swift
git commit -m "feat(scheduling): Scheduler.schedule/cancel (task 1.4)"
```

---

### Task 1.5: `Scheduler.resyncOnLaunch` + tap routing

**Files:**
- Modify: `Packages/BillableCore/Sources/BillableCore/Scheduling/Scheduler.swift`
- Test: append to `SchedulingTests.swift`

- [ ] **Step 1: Write the failing test**

Append:

```swift
@Test("Scheduler.resyncOnLaunch re-registers SwiftData rows missing iOS-side")
@MainActor
func resyncReRegistersMissing() async throws {
    let center = FakeNotificationCenter()
    center.authorized = true
    let container = try BillableModelContainer.inMemory()
    let scheduler = Scheduler(center: center, modelContext: container.mainContext)
    _ = try await scheduler.requestAuthorization()

    // Insert two rows directly, simulating a state where iOS has lost the requests.
    let id1 = UUID(), id2 = UUID()
    let future = Date().addingTimeInterval(3600)
    container.mainContext.insert(ScheduledNotification(
        id: id1, fireAt: future, payloadType: "recurrence", payloadID: UUID()
    ))
    container.mainContext.insert(ScheduledNotification(
        id: id2, fireAt: future, payloadType: "reminder", payloadID: UUID()
    ))
    try container.mainContext.save()
    // iOS-side starts empty (center.pendingRequests already empty)

    let result = await scheduler.resyncOnLaunch(now: Date())

    #expect(result.reregistered == 2)
    #expect(center.addedRequests.count == 2)
    let identifiers = Set(center.addedRequests.map(\.identifier))
    #expect(identifiers.contains(id1.uuidString))
    #expect(identifiers.contains(id2.uuidString))
}

@Test("Scheduler.resyncOnLaunch prunes already-fired (past) rows")
@MainActor
func resyncPrunesPast() async throws {
    let center = FakeNotificationCenter()
    center.authorized = true
    let container = try BillableModelContainer.inMemory()
    let scheduler = Scheduler(center: center, modelContext: container.mainContext)
    _ = try await scheduler.requestAuthorization()

    let past = Date().addingTimeInterval(-3600)
    container.mainContext.insert(ScheduledNotification(
        fireAt: past, payloadType: "recurrence", payloadID: UUID()
    ))
    try container.mainContext.save()

    _ = await scheduler.resyncOnLaunch(now: Date())

    let remaining = try container.mainContext.fetch(FetchDescriptor<ScheduledNotification>())
    #expect(remaining.isEmpty)
}

@Test("Scheduler.handleNotificationTap decodes payload by id")
@MainActor
func tapDecodesPayload() async throws {
    let center = FakeNotificationCenter()
    center.authorized = true
    let container = try BillableModelContainer.inMemory()
    let scheduler = Scheduler(center: center, modelContext: container.mainContext)
    _ = try await scheduler.requestAuthorization()

    let payloadID = UUID()
    _ = try await scheduler.schedule(
        payload: .reminder(scheduleID: payloadID),
        fireAt: Date().addingTimeInterval(60),
        title: "T", body: "B"
    )
    let id = try #require(
        container.mainContext.fetch(FetchDescriptor<ScheduledNotification>()).first?.id
    )

    let payload = scheduler.handleNotificationTap(requestIdentifier: id.uuidString)
    #expect(payload == .reminder(scheduleID: payloadID))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL on `resyncOnLaunch` and `handleNotificationTap` not found.

- [ ] **Step 3: Implement resync + tap routing**

Add to `Scheduler.swift`:

```swift
    public struct ResyncResult: Equatable, Sendable {
        public let reregistered: Int
        public let pruned: Int
    }

    /// Called from `AppDelegate` / `App.scene(_:willConnectTo:options:)` on
    /// cold launch. Reconciles SwiftData rows against iOS pending requests.
    @discardableResult
    public func resyncOnLaunch(now: Date = .now) async -> ResyncResult {
        // 1. Prune rows whose fireAt is in the past — iOS has already delivered
        //    them (or dropped them), and the owning service updates state on tap.
        let descriptor = FetchDescriptor<ScheduledNotification>(
            predicate: #Predicate { $0.fireAt < now }
        )
        var pruned = 0
        if let pastRows = try? modelContext.fetch(descriptor) {
            for row in pastRows { modelContext.delete(row) }
            pruned = pastRows.count
        }

        // 2. For rows in the future, check whether iOS still has the request.
        //    Re-register any that have gone missing.
        let pending = await center.getPendingNotificationRequests()
        let pendingIDs = Set(pending.map(\.identifier))
        let futureDescriptor = FetchDescriptor<ScheduledNotification>(
            predicate: #Predicate { $0.fireAt >= now }
        )
        var reregistered = 0
        if let futureRows = try? modelContext.fetch(futureDescriptor) {
            for row in futureRows where !pendingIDs.contains(row.id.uuidString) {
                let content = UNMutableNotificationContent()
                // Copy minimal title/body — the rich content is rebuilt by
                // services that own this payload type. For resync we use a
                // generic placeholder so the notification still arrives;
                // services overwrite via cancel+schedule when they care.
                content.title = "Cadence"
                content.body  = "Tap to review."
                content.sound = .default
                let trigger = UNCalendarNotificationTrigger(
                    dateMatching: Calendar.current.dateComponents(
                        [.year, .month, .day, .hour, .minute],
                        from: row.fireAt
                    ),
                    repeats: false
                )
                let request = UNNotificationRequest(
                    identifier: row.id.uuidString,
                    content: content,
                    trigger: trigger
                )
                try? await center.add(request)
                reregistered += 1
            }
        }

        try? modelContext.save()
        log.info("resyncOnLaunch(): reregistered=\(reregistered, privacy: .public) pruned=\(pruned, privacy: .public)")
        return ResyncResult(reregistered: reregistered, pruned: pruned)
    }

    /// Called by `AppDelegate` when the user taps a delivered notification.
    /// Returns the decoded payload (or nil if unknown), so the caller can
    /// route to the appropriate destination via `NotificationRouter`.
    public func handleNotificationTap(requestIdentifier: String) -> SchedulerPayload? {
        guard let id = UUID(uuidString: requestIdentifier) else { return nil }
        let descriptor = FetchDescriptor<ScheduledNotification>(
            predicate: #Predicate { $0.id == id }
        )
        guard let row = try? modelContext.fetch(descriptor).first else { return nil }
        return SchedulerPayload.decode(payloadType: row.payloadType, payloadID: row.payloadID)
    }
```

> **Note for the engineer:** The placeholder title/body in `resyncOnLaunch` is intentionally generic. The services (`RecurrenceService`/`ReminderService`) re-issue richer notifications via `cancel(id:)` + `schedule(...)` whenever they detect they need to. The generic version is the safety net for when iOS dropped a request and no service has reason to recompute.

- [ ] **Step 4: Run tests to verify they pass**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Scheduling/Scheduler.swift \
        Packages/BillableCore/Tests/BillableCoreTests/SchedulingTests.swift
git commit -m "feat(scheduling): Scheduler.resyncOnLaunch + handleNotificationTap (task 1.5)"
```

---

## Phase 2 — Recurrence domain (Day 2)

### Task 2.1: `RecurrenceCadence` enum

**Files:**
- Create: `Packages/BillableCore/Sources/BillableCore/Recurrence/RecurrenceCadence.swift`
- Test: append to `SchedulingTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
@Test("RecurrenceCadence round-trips via raw String")
func cadenceRoundTrip() throws {
    let monthly = RecurrenceCadence.monthly(dayOfMonth: 1)
    let weekly  = RecurrenceCadence.weekly(weekday: .monday)
    let biweekly = RecurrenceCadence.biweekly(weekday: .friday)

    #expect(RecurrenceCadence.from(raw: monthly.rawValue) == monthly)
    #expect(RecurrenceCadence.from(raw: weekly.rawValue) == weekly)
    #expect(RecurrenceCadence.from(raw: biweekly.rawValue) == biweekly)
    #expect(RecurrenceCadence.from(raw: "garbage") == nil)
}
```

- [ ] **Step 2: Run test (fail)**

Expected: FAIL — type not found.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// How often a `RecurrenceTemplate` fires.
public enum RecurrenceCadence: Equatable, Hashable, Sendable {
    case monthly(dayOfMonth: Int)       // 1...31, with clamp-to-last-day for short months
    case weekly(weekday: Weekday)
    case biweekly(weekday: Weekday)

    public enum Weekday: String, Sendable {
        case sunday = "sun", monday = "mon", tuesday = "tue", wednesday = "wed"
        case thursday = "thu", friday = "fri", saturday = "sat"

        public var calendarComponent: Int {
            switch self {
            case .sunday: 1; case .monday: 2; case .tuesday: 3
            case .wednesday: 4; case .thursday: 5; case .friday: 6
            case .saturday: 7
            }
        }
    }

    /// Stored form on `RecurrenceTemplate.cadence`.
    public var rawValue: String {
        switch self {
        case .monthly(let d):  "monthlyDay:\(d)"
        case .weekly(let w):   "weekly:\(w.rawValue)"
        case .biweekly(let w): "biweekly:\(w.rawValue)"
        }
    }

    public static func from(raw: String) -> RecurrenceCadence? {
        let parts = raw.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let kind = String(parts[0])
        let value = String(parts[1])
        switch kind {
        case "monthlyDay":
            guard let d = Int(value), (1...31).contains(d) else { return nil }
            return .monthly(dayOfMonth: d)
        case "weekly":
            guard let w = Weekday(rawValue: value) else { return nil }
            return .weekly(weekday: w)
        case "biweekly":
            guard let w = Weekday(rawValue: value) else { return nil }
            return .biweekly(weekday: w)
        default:
            return nil
        }
    }
}
```

- [ ] **Step 4: Run test (pass)**
- [ ] **Step 5: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Recurrence/RecurrenceCadence.swift \
        Packages/BillableCore/Tests/BillableCoreTests/SchedulingTests.swift
git commit -m "feat(recurrence): RecurrenceCadence enum (task 2.1)"
```

---

### Task 2.2: `RangeRule` + date math

**Files:**
- Create: `Packages/BillableCore/Sources/BillableCore/Recurrence/RangeRule.swift`
- Test: append to `SchedulingTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
@Test("RangeRule.previousMonth resolves from a fire date")
func rangeRulePreviousMonth() throws {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!

    let fireAt = cal.date(from: DateComponents(year: 2026, month: 6, day: 1, hour: 8))!
    let range = RangeRule.previousMonth.resolve(from: fireAt, calendar: cal)

    let expectedStart = cal.date(from: DateComponents(year: 2026, month: 5, day: 1))!
    let expectedEnd   = cal.date(from: DateComponents(year: 2026, month: 6, day: 1))!
    #expect(range.start == expectedStart)
    #expect(range.end == expectedEnd)
}

@Test("RangeRule.previousWeek resolves to Mon–Sun before the fire date")
func rangeRulePreviousWeek() throws {
    var cal = Calendar(identifier: .gregorian)
    cal.firstWeekday = 2 // Monday-first
    cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!

    let fireAt = cal.date(from: DateComponents(year: 2026, month: 6, day: 8))! // Monday
    let range = RangeRule.previousWeek.resolve(from: fireAt, calendar: cal)

    let expectedStart = cal.date(from: DateComponents(year: 2026, month: 6, day: 1))! // prior Mon
    let expectedEnd   = fireAt
    #expect(range.start == expectedStart)
    #expect(range.end == expectedEnd)
}
```

- [ ] **Step 2: Run test (fail)**
- [ ] **Step 3: Implement**

```swift
import Foundation

/// Which span of time entries a recurrence's materialized invoice covers.
public enum RangeRule: String, Sendable {
    case previousMonth
    case previousWeek
    case previousBiweek

    /// Resolve the rule against a fire date into an `InvoiceDateRange`.
    /// Convention: `[start, end)` half-open interval.
    public func resolve(
        from fireDate: Date,
        calendar: Calendar = .current
    ) -> InvoiceDateRange {
        switch self {
        case .previousMonth:
            let startOfFireMonth = calendar.date(
                from: calendar.dateComponents([.year, .month], from: fireDate)
            )!
            let startOfPrevMonth = calendar.date(
                byAdding: .month, value: -1, to: startOfFireMonth
            )!
            return InvoiceDateRange(start: startOfPrevMonth, end: startOfFireMonth)

        case .previousWeek:
            let startOfFireWeek = calendar.date(
                from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: fireDate)
            )!
            let startOfPrevWeek = calendar.date(byAdding: .day, value: -7, to: startOfFireWeek)!
            return InvoiceDateRange(start: startOfPrevWeek, end: startOfFireWeek)

        case .previousBiweek:
            let startOfFireWeek = calendar.date(
                from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: fireDate)
            )!
            let startOfPrevBiweek = calendar.date(byAdding: .day, value: -14, to: startOfFireWeek)!
            return InvoiceDateRange(start: startOfPrevBiweek, end: startOfFireWeek)
        }
    }

    /// Implied range rule from a cadence (used when the UI does not expose
    /// the range rule directly in v1.1).
    public static func implied(from cadence: RecurrenceCadence) -> RangeRule {
        switch cadence {
        case .monthly:  .previousMonth
        case .weekly:   .previousWeek
        case .biweekly: .previousBiweek
        }
    }
}
```

- [ ] **Step 4: Run test (pass)**
- [ ] **Step 5: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Recurrence/RangeRule.swift \
        Packages/BillableCore/Tests/BillableCoreTests/SchedulingTests.swift
git commit -m "feat(recurrence): RangeRule resolver (task 2.2)"
```

---

### Task 2.3: `RecurrenceTemplate` @Model

**Files:**
- Create: `Packages/BillableCore/Sources/BillableCore/Models/RecurrenceTemplate.swift`
- Modify: `Packages/BillableCore/Sources/BillableCore/Persistence/ModelContainer+Billable.swift` — add to `mirroredSchema`
- Test: append to `SchedulingTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
@Test("RecurrenceTemplate persists with cadence + client + nextFireDate")
@MainActor
func recurrenceTemplatePersists() throws {
    let container = try BillableModelContainer.inMemory()
    let context = container.mainContext

    let client = Client(name: "Acme", color: .blue)
    context.insert(client)

    let cadence = RecurrenceCadence.monthly(dayOfMonth: 1)
    let next = Date(timeIntervalSince1970: 1_900_000_000)
    let template = RecurrenceTemplate(
        client: client,
        cadence: cadence,
        grouping: .perEntry,
        notesTemplate: "Services for {clientName} — {month} {year}",
        nextFireDate: next
    )
    context.insert(template)
    try context.save()

    let fetched = try context.fetch(FetchDescriptor<RecurrenceTemplate>())
    #expect(fetched.count == 1)
    let t = try #require(fetched.first)
    #expect(t.client?.name == "Acme")
    #expect(t.cadenceValue == cadence)
    #expect(t.rangeRuleValue == .previousMonth)
    #expect(t.nextFireDate == next)
    #expect(t.isActive == true)
    #expect(t.lastFiredAt == nil)
}
```

- [ ] **Step 2: Run test (fail)**

- [ ] **Step 3: Implement the @Model + extend ModelContainer**

Create `RecurrenceTemplate.swift`:

```swift
import Foundation
import SwiftData

/// Mirrored @Model. A user-defined rule that, on a schedule, generates a draft
/// invoice from tracked time.
@Model
public final class RecurrenceTemplate {
    @Attribute(.unique) public var id: UUID

    public var client: Client?

    /// `RecurrenceCadence.rawValue` — kept as String for SwiftData/CloudKit safety.
    public var cadence: String

    /// `RangeRule.rawValue`. v1.1 derives this from cadence at creation;
    /// stored for clarity and future decoupling.
    public var rangeRule: String

    /// `LineItemGrouping.rawValue`.
    public var grouping: String

    /// Notes template with merge fields `{month} {year} {clientName}`.
    public var notesTemplate: String?

    public var nextFireDate: Date
    public var lastFiredAt: Date?
    public var endDate: Date?

    public var isActive: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        client: Client?,
        cadence: RecurrenceCadence,
        rangeRule: RangeRule? = nil,
        grouping: LineItemGrouping,
        notesTemplate: String? = nil,
        nextFireDate: Date,
        endDate: Date? = nil,
        isActive: Bool = true,
        createdAt: Date = .now
    ) {
        self.id = id
        self.client = client
        self.cadence = cadence.rawValue
        self.rangeRule = (rangeRule ?? RangeRule.implied(from: cadence)).rawValue
        self.grouping = grouping.rawValue
        self.notesTemplate = notesTemplate
        self.nextFireDate = nextFireDate
        self.lastFiredAt = nil
        self.endDate = endDate
        self.isActive = isActive
        self.createdAt = createdAt
    }

    // MARK: - Convenience typed accessors

    public var cadenceValue: RecurrenceCadence {
        get { RecurrenceCadence.from(raw: cadence) ?? .monthly(dayOfMonth: 1) }
        set { cadence = newValue.rawValue }
    }

    public var rangeRuleValue: RangeRule {
        get { RangeRule(rawValue: rangeRule) ?? .previousMonth }
        set { rangeRule = newValue.rawValue }
    }

    public var groupingValue: LineItemGrouping {
        get { LineItemGrouping(rawValue: grouping) ?? .perEntry }
        set { grouping = newValue.rawValue }
    }

    /// `true` if `endDate` has been reached and `RecurrenceService` should stop firing.
    public func isEnded(now: Date = .now) -> Bool {
        guard let endDate else { return false }
        return endDate <= now
    }
}
```

Modify `ModelContainer+Billable.swift` — add `RecurrenceTemplate.self` to `mirroredSchema`:

```swift
public static let mirroredSchema = Schema([
    BusinessProfile.self,
    Client.self,
    Project.self,
    TimeEntry.self,
    Invoice.self,
    RecurrenceTemplate.self,   // ← added
])
```

- [ ] **Step 4: Run test (pass)**
- [ ] **Step 5: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Models/RecurrenceTemplate.swift \
        Packages/BillableCore/Sources/BillableCore/Persistence/ModelContainer+Billable.swift \
        Packages/BillableCore/Tests/BillableCoreTests/SchedulingTests.swift
git commit -m "feat(recurrence): RecurrenceTemplate @Model (task 2.3)"
```

---

### Task 2.4: `RecurrenceService.computeNextFireDate`

**Files:**
- Create: `Packages/BillableCore/Sources/BillableCore/Recurrence/RecurrenceService.swift`
- Test: append to `SchedulingTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
@Test("computeNextFireDate: monthly day=1 → first of next month at 8am local")
func nextFireMonthlyDayOne() throws {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!

    let from = cal.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 10))!
    let next = RecurrenceService.computeNextFireDate(
        cadence: .monthly(dayOfMonth: 1),
        after: from,
        calendar: cal
    )
    let expected = cal.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 8))!
    #expect(next == expected)
}

@Test("computeNextFireDate: monthly day=31 → clamps to last day of short month")
func nextFireMonthlyDay31Feb() throws {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!

    let from = cal.date(from: DateComponents(year: 2026, month: 1, day: 31, hour: 12))!
    let next = RecurrenceService.computeNextFireDate(
        cadence: .monthly(dayOfMonth: 31),
        after: from,
        calendar: cal
    )
    let expected = cal.date(from: DateComponents(year: 2026, month: 2, day: 28, hour: 8))!
    #expect(next == expected)
}

@Test("computeNextFireDate: weekly Mon → next Monday at 8am")
func nextFireWeeklyMonday() throws {
    var cal = Calendar(identifier: .gregorian)
    cal.firstWeekday = 2
    cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!

    // 2026-06-03 is a Wednesday
    let from = cal.date(from: DateComponents(year: 2026, month: 6, day: 3, hour: 12))!
    let next = RecurrenceService.computeNextFireDate(
        cadence: .weekly(weekday: .monday),
        after: from,
        calendar: cal
    )
    // Next Monday is 2026-06-08
    let expected = cal.date(from: DateComponents(year: 2026, month: 6, day: 8, hour: 8))!
    #expect(next == expected)
}
```

- [ ] **Step 2: Run test (fail)**
- [ ] **Step 3: Implement**

Create `RecurrenceService.swift`:

```swift
import Foundation
import SwiftData
import OSLog

@MainActor
public enum RecurrenceService {
    private static let log = Logger(subsystem: "com.eldenstudios.billable", category: "RecurrenceService")

    /// 8:00am local, the fixed v1.1 fire-of-day slot.
    public static let fireHour = 8

    /// Compute the next fire date after `from`. Always returns a date strictly
    /// greater than `from`. Handles monthly day clamps, weekly/biweekly walk.
    public static func computeNextFireDate(
        cadence: RecurrenceCadence,
        after from: Date,
        calendar: Calendar = .current
    ) -> Date {
        switch cadence {
        case .monthly(let day):
            return nextMonthlyDate(dayOfMonth: day, after: from, calendar: calendar)
        case .weekly(let weekday):
            return nextWeekdayDate(weekday: weekday, after: from, calendar: calendar, weeksOffset: 1)
        case .biweekly(let weekday):
            return nextWeekdayDate(weekday: weekday, after: from, calendar: calendar, weeksOffset: 2)
        }
    }

    private static func nextMonthlyDate(dayOfMonth: Int, after from: Date, calendar: Calendar) -> Date {
        var cursor = from
        for monthsAhead in 0...2 {
            let advanced = calendar.date(byAdding: .month, value: monthsAhead, to: cursor)!
            let components = calendar.dateComponents([.year, .month], from: advanced)
            let candidateComponents = DateComponents(
                year: components.year, month: components.month,
                day: clampedDayOfMonth(dayOfMonth, in: advanced, calendar: calendar),
                hour: fireHour, minute: 0, second: 0
            )
            if let candidate = calendar.date(from: candidateComponents), candidate > from {
                return candidate
            }
            cursor = advanced
        }
        // Defensive fallback
        return calendar.date(byAdding: .month, value: 1, to: from)!
    }

    private static func clampedDayOfMonth(_ day: Int, in date: Date, calendar: Calendar) -> Int {
        let range = calendar.range(of: .day, in: .month, for: date) ?? 1..<29
        return min(day, range.upperBound - 1)
    }

    private static func nextWeekdayDate(
        weekday: RecurrenceCadence.Weekday,
        after from: Date,
        calendar: Calendar,
        weeksOffset: Int
    ) -> Date {
        let targetWeekday = weekday.calendarComponent
        var components = DateComponents()
        components.weekday = targetWeekday
        components.hour = fireHour
        components.minute = 0
        // Find the next occurrence of the target weekday at 8am strictly after `from`.
        let firstNext = calendar.nextDate(
            after: from, matching: components, matchingPolicy: .nextTime
        )!
        if weeksOffset == 1 {
            return firstNext
        }
        return calendar.date(byAdding: .day, value: (weeksOffset - 1) * 7, to: firstNext)!
    }
}
```

- [ ] **Step 4: Run test (pass)**
- [ ] **Step 5: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Recurrence/RecurrenceService.swift \
        Packages/BillableCore/Tests/BillableCoreTests/SchedulingTests.swift
git commit -m "feat(recurrence): RecurrenceService.computeNextFireDate (task 2.4)"
```

---

### Task 2.5: `RecurrenceService.materializeDraft`

**Files:**
- Modify: `Packages/BillableCore/Sources/BillableCore/Recurrence/RecurrenceService.swift`
- Test: append to `SchedulingTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
@Test("materializeDraft creates a Draft Invoice from prior-month entries and advances lastFiredAt")
@MainActor
func materializeDraftHappyPath() async throws {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!

    let container = try BillableModelContainer.inMemory()
    let context = container.mainContext

    let profile = BusinessProfile(name: "Me", currencyCode: "USD")
    let client = Client(name: "Acme", color: .blue)
    let project = Project(name: "Web", client: client, hourlyRate: 100, isBillable: true)
    let entry = TimeEntry(
        startedAt: cal.date(from: DateComponents(year: 2026, month: 5, day: 15, hour: 10))!,
        endedAt:   cal.date(from: DateComponents(year: 2026, month: 5, day: 15, hour: 12))!,
        project: project
    )
    context.insert(profile); context.insert(client); context.insert(project); context.insert(entry)

    let fireAt = cal.date(from: DateComponents(year: 2026, month: 6, day: 1, hour: 8))!
    let template = RecurrenceTemplate(
        client: client,
        cadence: .monthly(dayOfMonth: 1),
        grouping: .perEntry,
        notesTemplate: "Services — {month} {year}",
        nextFireDate: fireAt
    )
    context.insert(template)
    try context.save()

    let draft = try RecurrenceService.materializeDraft(
        template: template,
        now: fireAt,
        calendar: cal,
        context: context
    )

    #expect(draft.status == .draft)
    #expect(draft.clientNameSnapshot == "Acme")
    #expect(draft.lineItems.count == 1)
    #expect(draft.notes == "Services — May 2026")
    #expect(template.lastFiredAt == fireAt)
    let expectedNext = cal.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 8))!
    #expect(template.nextFireDate == expectedNext)
}

@Test("materializeDraft creates zero-amount draft when no eligible entries")
@MainActor
func materializeDraftZeroEntries() async throws {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    let container = try BillableModelContainer.inMemory()
    let context = container.mainContext

    let profile = BusinessProfile(name: "Me", currencyCode: "USD")
    let client = Client(name: "Acme", color: .blue)
    context.insert(profile); context.insert(client)

    let fireAt = cal.date(from: DateComponents(year: 2026, month: 6, day: 1, hour: 8))!
    let template = RecurrenceTemplate(
        client: client,
        cadence: .monthly(dayOfMonth: 1),
        grouping: .perEntry,
        nextFireDate: fireAt
    )
    context.insert(template)
    try context.save()

    let draft = try RecurrenceService.materializeDraft(
        template: template, now: fireAt, calendar: cal, context: context
    )

    #expect(draft.status == .draft)
    #expect(draft.lineItems.isEmpty)
    #expect(draft.subtotal == 0)
}
```

- [ ] **Step 2: Run test (fail)**
- [ ] **Step 3: Implement**

Add to `RecurrenceService.swift`:

```swift
    public enum MaterializationError: Error, Equatable {
        case noBusinessProfile
        case noClient
        case ended
    }

    /// Resolve the prior period, build line items from eligible entries, and
    /// insert a Draft `Invoice`. Updates `lastFiredAt` and `nextFireDate` on
    /// the template. Returns the inserted Invoice.
    ///
    /// Zero-entry case is allowed — produces an empty draft so the user sees
    /// "nothing to bill this period" rather than silently swallowing the fire.
    public static func materializeDraft(
        template: RecurrenceTemplate,
        now: Date = .now,
        calendar: Calendar = .current,
        context: ModelContext
    ) throws -> Invoice {
        guard !template.isEnded(now: now) else {
            throw MaterializationError.ended
        }
        guard let client = template.client else {
            throw MaterializationError.noClient
        }
        let profiles = try context.fetch(FetchDescriptor<BusinessProfile>())
        guard let profile = profiles.first else {
            throw MaterializationError.noBusinessProfile
        }

        let range = template.rangeRuleValue.resolve(from: now, calendar: calendar)
        let invoiceRange = InvoiceDateRange(start: range.start, end: range.end)

        let entries = InvoiceBuilder.eligibleEntries(
            for: client, in: invoiceRange, context: context
        )
        let lineItems = InvoiceBuilder.buildLineItems(
            from: entries, grouping: template.groupingValue
        )

        let resolvedNotes = renderNotes(
            template.notesTemplate,
            client: client,
            forDate: range.start,
            calendar: calendar
        )

        // For zero-entry materialization we still want an Invoice row to show
        // up in Drafts. `InvoiceBuilder.createDraft` throws on empty items, so
        // we synthesize a placeholder line item with zero hours.
        let effectiveLineItems = lineItems.isEmpty
            ? [InvoiceLineItem(
                description: "No tracked time for this period",
                hours: 0,
                hourlyRate: 0,
                sourceTimeEntryRef: nil
              )]
            : lineItems

        let invoice = try InvoiceBuilder.createDraft(
            for: client,
            lineItems: effectiveLineItems,
            notes: resolvedNotes,
            issuedAt: now,
            profile: profile,
            context: context
        )

        // Stamp source entries as invoiced (only the ones that actually got billed).
        if !lineItems.isEmpty {
            for entry in entries { entry.invoiceID = invoice.uuid }
        }

        // Advance template state.
        template.lastFiredAt = now
        template.nextFireDate = computeNextFireDate(
            cadence: template.cadenceValue, after: now, calendar: calendar
        )
        try context.save()

        log.info("materializeDraft(): templateID=\(template.id.uuidString, privacy: .public) lineItems=\(lineItems.count, privacy: .public)")
        return invoice
    }

    /// Render notes template with `{month}` `{year}` `{clientName}` merge fields.
    /// `forDate` is the start of the range — we name the period by its start
    /// month/year (May 2026 even though the invoice fires June 1).
    public static func renderNotes(
        _ template: String?,
        client: Client,
        forDate: Date,
        calendar: Calendar
    ) -> String? {
        guard let template, !template.isEmpty else { return nil }
        let monthFormatter = DateFormatter()
        monthFormatter.calendar = calendar
        monthFormatter.dateFormat = "LLLL"
        let yearFormatter = DateFormatter()
        yearFormatter.calendar = calendar
        yearFormatter.dateFormat = "yyyy"

        return template
            .replacingOccurrences(of: "{month}", with: monthFormatter.string(from: forDate))
            .replacingOccurrences(of: "{year}", with: yearFormatter.string(from: forDate))
            .replacingOccurrences(of: "{clientName}", with: client.name)
    }
```

- [ ] **Step 4: Run test (pass)**
- [ ] **Step 5: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Recurrence/RecurrenceService.swift \
        Packages/BillableCore/Tests/BillableCoreTests/SchedulingTests.swift
git commit -m "feat(recurrence): RecurrenceService.materializeDraft + renderNotes (task 2.5)"
```

---

### Task 2.6: `RecurrenceService.reconcile` (catch-up)

**Files:**
- Modify: `Packages/BillableCore/Sources/BillableCore/Recurrence/RecurrenceService.swift`
- Test: append to `SchedulingTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
@Test("reconcile returns pending templates whose nextFireDate is in the past")
@MainActor
func reconcileReturnsOverdue() throws {
    let container = try BillableModelContainer.inMemory()
    let context = container.mainContext

    let client = Client(name: "Acme", color: .blue)
    context.insert(client)

    let now = Date()
    let pastFire = now.addingTimeInterval(-3600 * 24 * 3) // 3 days ago
    let futureFire = now.addingTimeInterval(3600 * 24 * 5) // 5 days from now

    let pending = RecurrenceTemplate(
        client: client, cadence: .monthly(dayOfMonth: 1),
        grouping: .perEntry, nextFireDate: pastFire
    )
    let later = RecurrenceTemplate(
        client: client, cadence: .monthly(dayOfMonth: 15),
        grouping: .perEntry, nextFireDate: futureFire
    )
    context.insert(pending); context.insert(later)
    try context.save()

    let overdue = RecurrenceService.pendingMaterializations(now: now, context: context)
    #expect(overdue.count == 1)
    #expect(overdue.first?.id == pending.id)
}

@Test("reconcile excludes inactive and ended templates")
@MainActor
func reconcileExcludesInactiveAndEnded() throws {
    let container = try BillableModelContainer.inMemory()
    let context = container.mainContext
    let client = Client(name: "Acme", color: .blue)
    context.insert(client)

    let now = Date()
    let past = now.addingTimeInterval(-3600 * 24 * 3)

    let inactive = RecurrenceTemplate(
        client: client, cadence: .monthly(dayOfMonth: 1),
        grouping: .perEntry, nextFireDate: past, isActive: false
    )
    let ended = RecurrenceTemplate(
        client: client, cadence: .monthly(dayOfMonth: 1),
        grouping: .perEntry, nextFireDate: past,
        endDate: now.addingTimeInterval(-3600 * 24 * 10)
    )
    context.insert(inactive); context.insert(ended)
    try context.save()

    let overdue = RecurrenceService.pendingMaterializations(now: now, context: context)
    #expect(overdue.isEmpty)
}
```

- [ ] **Step 2: Run test (fail)**
- [ ] **Step 3: Implement**

Add to `RecurrenceService.swift`:

```swift
    /// Return templates whose `nextFireDate` is `<= now` and which are still
    /// eligible to fire (active + not ended). Used by the Today screen's
    /// Catch-up banner.
    public static func pendingMaterializations(
        now: Date = .now,
        context: ModelContext
    ) -> [RecurrenceTemplate] {
        let descriptor = FetchDescriptor<RecurrenceTemplate>(
            predicate: #Predicate { template in
                template.isActive == true
                && template.nextFireDate <= now
            },
            sortBy: [SortDescriptor(\.nextFireDate)]
        )
        let candidates = (try? context.fetch(descriptor)) ?? []
        return candidates.filter { !$0.isEnded(now: now) }
    }
```

- [ ] **Step 4: Run test (pass)**
- [ ] **Step 5: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Recurrence/RecurrenceService.swift \
        Packages/BillableCore/Tests/BillableCoreTests/SchedulingTests.swift
git commit -m "feat(recurrence): pendingMaterializations for catch-up (task 2.6)"
```

---

## Phase 3 — Recurrence UI + routing (Day 3)

### Task 3.1: `NotificationRouter`

**Files:**
- Create: `Packages/BillableCore/Sources/BillableCore/Routing/NotificationRouter.swift`

This type carries no logic that needs unit testing — it's a single `@Observable` with a `pendingDestination` property. We add an integration test later in Phase 6 (UI test for the tap handoff).

- [ ] **Step 1: Implement**

Create `NotificationRouter.swift`:

```swift
import Foundation
import Observation

/// Bridge between the AppDelegate's notification-tap callback and the SwiftUI
/// navigation tree. Set by `Scheduler.handleNotificationTap`-derived flows in
/// the AppDelegate; observed by `RootView`, which clears after navigating.
@MainActor
@Observable
public final class NotificationRouter {
    public enum Destination: Hashable, Sendable {
        case invoicePreview(invoiceID: UUID)
        case invoiceDetail(invoiceID: UUID)
        case recurringList
    }

    public var pendingDestination: Destination?

    public init(pendingDestination: Destination? = nil) {
        self.pendingDestination = pendingDestination
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
xcodebuild -project Billable.xcodeproj -scheme Billable \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -configuration Debug build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Routing/NotificationRouter.swift
git commit -m "feat(routing): NotificationRouter observable (task 3.1)"
```

---

### Task 3.2: `AppDelegate` + adaptor wiring

**Files:**
- Create: `App/Sources/App/AppDelegate.swift`
- Modify: `App/Sources/App/BillableApp.swift`
- Modify: `App/Sources/App/RootView.swift`

This task wires the iOS notification-tap event into `NotificationRouter`. We do an integration smoke (UI test) in Phase 6.

- [ ] **Step 1: Create `AppDelegate.swift`**

```swift
import UIKit
import UserNotifications
import SwiftData
import BillableCore

/// Minimal AppDelegate whose sole job is to be the
/// `UNUserNotificationCenterDelegate` and route taps into `NotificationRouter`.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    /// Set by `BillableApp.init()` so the delegate can use the same instance
    /// that's injected into the SwiftUI environment.
    static var sharedRouter: NotificationRouter?

    /// Set similarly so we can run `Scheduler.handleNotificationTap` against the
    /// real model context.
    static var sharedSchedulerFactory: (() -> Scheduler)?

    /// Set so the tap resolver can fetch InvoiceReminderSchedule rows directly
    /// when resolving `.reminder` destinations.
    static var sharedModelContext: ModelContext?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    // Foreground delivery: still show the banner + sound (default is silent).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // Tap handler.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let requestID = response.notification.request.identifier
        defer { completionHandler() }

        guard let router = Self.sharedRouter,
              let factory = Self.sharedSchedulerFactory else { return }

        let scheduler = factory()
        guard let payload = scheduler.handleNotificationTap(requestIdentifier: requestID) else {
            return
        }

        switch payload {
        case .recurrence(let templateID):
            router.pendingDestination = resolveRecurrenceDestination(templateID: templateID, scheduler: scheduler)
        case .reminder(let scheduleID):
            router.pendingDestination = resolveReminderDestination(scheduleID: scheduleID, scheduler: scheduler)
        }
    }

    private func resolveRecurrenceDestination(
        templateID: UUID, scheduler: Scheduler
    ) -> NotificationRouter.Destination {
        // For v1.1 we route the tap to the Recurring list — RecurrenceService.materializeDraft
        // is invoked from the editor row when the user confirms. (Alternative: materialize
        // on tap and route to InvoicePreview; deferred to a Phase 6 polish task once UX
        // testing tells us which feels better.)
        .recurringList
    }

    private func resolveReminderDestination(
        scheduleID: UUID, scheduler: Scheduler
    ) -> NotificationRouter.Destination {
        // ReminderService surfaces the actual Invoice for the schedule (Phase 4).
        // For routing purposes we encode the scheduleID and let RootView lookup.
        // Phase 5 will refine this so we resolve to the owning invoice's UUID directly.
        .recurringList // placeholder, replaced in Task 5.4
    }
}
```

> **Note:** The reminder-destination wiring is a placeholder until `ReminderService` exists (Phase 4). Task 5.4 replaces this body to resolve the owning invoice's UUID and return `.invoiceDetail(invoiceID:)`.

- [ ] **Step 2: Modify `BillableApp.swift` to install the adaptor + inject router**

`BillableApp` currently holds `private let container: ModelContainer` (set in `init()`). Add the delegate adaptor, hold a `NotificationRouter`, and inject it. Do NOT do the wiring inside `init()` — escape-of-`self` is awkward; the wiring happens from `RootView.task` (Step 3).

Add these stored properties at the top of `BillableApp`:

```swift
@UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
@MainActor private let notificationRouter = NotificationRouter()
```

Change the Scene body to inject the router:

```swift
var body: some Scene {
    WindowGroup {
        RootView()
            .environment(notificationRouter)
            .task { await reconcileLiveActivity() }
            .task { performStartupWiring() }
    }
    .modelContainer(container)
}
```

Add the wiring function (uses `self` legally because it's called from `.task`, after init completes):

```swift
@MainActor
private func performStartupWiring() {
    AppDelegate.sharedRouter = notificationRouter
    AppDelegate.sharedSchedulerFactory = { [container] in
        Scheduler(
            center: UNUserNotificationCenter.current(),
            modelContext: container.mainContext
        )
    }
    // Invoice state-machine hooks installed in Task 5.4.
}
```

- [ ] **Step 3: Modify `RootView.swift` to observe the router**

Add at the top of `RootView`:

```swift
@Environment(NotificationRouter.self) private var router
```

In the body's main `NavigationStack` / `TabView`, add an `.onChange(of: router.pendingDestination)` modifier that:
- If `.invoicePreview(invoiceID)`: switches to Invoices tab and pushes `InvoicePreviewView(invoiceID:)`.
- If `.invoiceDetail(invoiceID)`: switches to Invoices tab and pushes `InvoiceDetailView(invoice:)`.
- If `.recurringList`: switches to Invoices tab and sets the segmented filter to "Recurring" (a new state introduced in Task 3.4).
- Clears `router.pendingDestination = nil` after handling.

Since `RootView`'s current structure is unknown without reading it, the engineer should:
1. Read `App/Sources/App/RootView.swift` to find the tab-switching state (likely a `@State var selectedTab: Tab`).
2. Add `@State var invoicesSubsegment: InvoicesView.Segment = .outstanding` if not present (this state is introduced fully in Task 3.4).
3. Wire `onChange` accordingly.

A representative diff:

```swift
.onChange(of: router.pendingDestination) { _, newValue in
    guard let destination = newValue else { return }
    switch destination {
    case .invoicePreview(let id):
        selectedTab = .invoices
        invoicesNavigationPath.append(InvoicesView.NavigationTarget.preview(invoiceID: id))
    case .invoiceDetail(let id):
        selectedTab = .invoices
        invoicesNavigationPath.append(InvoicesView.NavigationTarget.detail(invoiceID: id))
    case .recurringList:
        selectedTab = .invoices
        invoicesSubsegment = .recurring
    }
    router.pendingDestination = nil
}
```

> **Note:** `InvoicesView.NavigationTarget` is introduced in Task 3.4. If RootView's current `NavigationStack` doesn't use a path, refactor to use one as part of this task.

- [ ] **Step 4: Build to verify**

```bash
xcodebuild -project Billable.xcodeproj -scheme Billable \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add App/Sources/App/AppDelegate.swift \
        App/Sources/App/BillableApp.swift \
        App/Sources/App/RootView.swift
git commit -m "feat(routing): AppDelegate + NotificationRouter wire-up (task 3.2)"
```

---

### Task 3.3: "Make recurring" toggle on `InvoiceGeneratorView`

**Files:**
- Modify: `App/Sources/Features/Invoicing/InvoiceGeneratorView.swift`

This is mostly UI work — adds new state vars + a Section block. Skipping the unit-test step because UI tests for this come in Phase 6.

- [ ] **Step 1: Add state for recurrence configuration**

In `InvoiceGeneratorView`, add `@State`:

```swift
@State private var makeRecurring: Bool = false
@State private var recurrenceCadenceKind: RecurrenceCadenceKind = .monthly
@State private var recurrenceDayOfMonth: Int = 1
@State private var recurrenceWeekday: RecurrenceCadence.Weekday = .monday
@State private var recurrenceEndDate: Date? = nil
```

Plus a small helper enum:

```swift
enum RecurrenceCadenceKind: String, CaseIterable, Identifiable {
    case weekly, biweekly, monthly
    var id: String { rawValue }
    var label: String {
        switch self {
        case .weekly: "Weekly"; case .biweekly: "Biweekly"; case .monthly: "Monthly"
        }
    }
}
```

- [ ] **Step 2: Add the toggle Section below the existing controls**

Insert before the Notes field (or wherever the existing Section closes):

```swift
Section {
    Toggle(isOn: $makeRecurring) {
        Label("Make this recurring", systemImage: "arrow.triangle.2.circlepath")
    }
    if makeRecurring {
        Picker("Cadence", selection: $recurrenceCadenceKind) {
            ForEach(RecurrenceCadenceKind.allCases) { kind in
                Text(kind.label).tag(kind)
            }
        }
        .pickerStyle(.segmented)

        switch recurrenceCadenceKind {
        case .monthly:
            Picker("Day of month", selection: $recurrenceDayOfMonth) {
                ForEach(1...31, id: \.self) { day in
                    Text("\(day)").tag(day)
                }
            }
        case .weekly, .biweekly:
            Picker("Day of week", selection: $recurrenceWeekday) {
                ForEach([RecurrenceCadence.Weekday.monday, .tuesday, .wednesday,
                         .thursday, .friday, .saturday, .sunday], id: \.rawValue) { w in
                    Text(w.rawValue.capitalized).tag(w)
                }
            }
        }

        DatePicker(
            "Until (optional)",
            selection: Binding(
                get: { recurrenceEndDate ?? Date.distantFuture },
                set: { recurrenceEndDate = ($0 == Date.distantFuture) ? nil : $0 }
            ),
            displayedComponents: [.date]
        )
    }
}
```

- [ ] **Step 3: Change the primary action when `makeRecurring == true`**

The existing finalize button should change behavior:

```swift
private var primaryActionTitle: String {
    makeRecurring ? "Save recurring schedule" : "Preview invoice"
}

private func primaryAction() {
    if makeRecurring {
        saveRecurrence()
    } else {
        showPreview = true
    }
}

private func saveRecurrence() {
    guard let client = selectedClient else { return }
    let cadence: RecurrenceCadence = switch recurrenceCadenceKind {
    case .monthly:  .monthly(dayOfMonth: recurrenceDayOfMonth)
    case .weekly:   .weekly(weekday: recurrenceWeekday)
    case .biweekly: .biweekly(weekday: recurrenceWeekday)
    }
    let next = RecurrenceService.computeNextFireDate(
        cadence: cadence, after: Date()
    )
    let template = RecurrenceTemplate(
        client: client,
        cadence: cadence,
        grouping: selectedGrouping,
        notesTemplate: notes.isEmpty ? nil : notes,
        nextFireDate: next,
        endDate: recurrenceEndDate
    )
    modelContext.insert(template)
    try? modelContext.save()
    confirmationToast = "Saved. Cadence will remind you to send \(client.name)'s invoice on \(formatted(next))."
    dismiss()
}
```

> **Permission ask:** Wrap `saveRecurrence` so it requests authorization just-in-time. Pseudocode:
>
> ```swift
> Task {
>     let granted = await scheduler.requestAuthorization()
>     guard granted else { showSoftBlock = true; return }
>     // proceed with save
> }
> ```
>
> `scheduler` here is the one created inside the view via `Environment(\.modelContext)`. If you prefer to inject a Scheduler factory, add `@Environment(SchedulerFactory.self)` and read it that way.

- [ ] **Step 4: Build + manual smoke**

```bash
xcodebuild ... build
```

Then run the app in Simulator: Invoices tab → New invoice → toggle "Make this recurring" → confirm controls appear correctly.

- [ ] **Step 5: Commit**

```bash
git add App/Sources/Features/Invoicing/InvoiceGeneratorView.swift
git commit -m "feat(recurrence): Make recurring toggle on InvoiceGenerator (task 3.3)"
```

---

### Task 3.4: "Recurring" segment on `InvoicesView`

**Files:**
- Modify: `App/Sources/Features/Invoicing/InvoicesView.swift`

- [ ] **Step 1: Extend the existing segment enum**

Find the existing filter state (probably an enum like `enum Filter { case outstanding, paid, drafts }`). Add a `.recurring` case:

```swift
enum Segment: String, CaseIterable, Identifiable {
    case outstanding, paid, drafts, recurring
    var id: String { rawValue }
    var label: String {
        switch self {
        case .outstanding: "Outstanding"; case .paid: "Paid"
        case .drafts: "Drafts"; case .recurring: "Recurring"
        }
    }
}
```

- [ ] **Step 2: Render the Recurring segment with a list view**

When `segment == .recurring`, render `RecurringRulesView()` (built next task) instead of the existing invoice list:

```swift
if segment == .recurring {
    RecurringRulesView()
} else {
    // existing invoice list filtered by segment
}
```

Also add a navigation-target enum if `RootView` doesn't already have one:

```swift
public enum NavigationTarget: Hashable {
    case detail(invoiceID: UUID)
    case preview(invoiceID: UUID)
}
```

Plus `navigationDestination(for: NavigationTarget.self) { target in ... }` that resolves an `Invoice` by UUID and pushes the appropriate view.

- [ ] **Step 3: Build + manual smoke**

```bash
xcodebuild ... build
```

Simulator: Invoices tab → see four segments. Tapping "Recurring" shows the (empty for now) list.

- [ ] **Step 4: Commit**

```bash
git add App/Sources/Features/Invoicing/InvoicesView.swift
git commit -m "feat(recurrence): Recurring segment on InvoicesView (task 3.4)"
```

---

### Task 3.5: `RecurringRulesView` + `RecurrenceEditorView`

**Files:**
- Create: `App/Sources/Features/Recurrence/RecurringRulesView.swift`
- Create: `App/Sources/Features/Recurrence/RecurrenceEditorView.swift`

- [ ] **Step 1: Create `RecurringRulesView.swift`**

```swift
import SwiftUI
import SwiftData
import BillableCore

struct RecurringRulesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RecurrenceTemplate.nextFireDate) private var templates: [RecurrenceTemplate]

    @State private var selectedTemplateID: UUID?

    var body: some View {
        Group {
            if templates.isEmpty {
                ContentUnavailableView(
                    "No recurring schedules",
                    systemImage: "arrow.triangle.2.circlepath",
                    description: Text("Set up monthly billing for a retainer client from the New Invoice screen.")
                )
            } else {
                List {
                    ForEach(templates) { template in
                        NavigationLink(value: InvoicesView.NavigationTarget.recurrenceEditor(templateID: template.id)) {
                            row(template)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { delete(template) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button { togglePause(template) } label: {
                                Label(template.isActive ? "Pause" : "Resume",
                                      systemImage: template.isActive ? "pause" : "play")
                            }
                            .tint(.orange)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ template: RecurrenceTemplate) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color(template.client?.color ?? .blue))
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(template.client?.name ?? "—").font(.headline)
                Text(cadenceSummary(template))
                    .font(.caption).foregroundStyle(.secondary)
                Text("Next: \(template.nextFireDate.formatted(.dateTime.month().day()))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            statusPill(template)
        }
    }

    private func cadenceSummary(_ template: RecurrenceTemplate) -> String {
        switch template.cadenceValue {
        case .monthly(let d): "Monthly · \(d)"
        case .weekly(let w): "Weekly · \(w.rawValue.capitalized)"
        case .biweekly(let w): "Biweekly · \(w.rawValue.capitalized)"
        }
    }

    private func statusPill(_ template: RecurrenceTemplate) -> some View {
        let (label, color): (String, Color) = {
            if template.isEnded() { return ("Ended", .secondary) }
            return template.isActive ? ("Active", .green) : ("Paused", .orange)
        }()
        return Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.18), in: .capsule)
            .foregroundStyle(color)
    }

    private func delete(_ template: RecurrenceTemplate) {
        // Cancel any pending Scheduler entry for this template
        let cancelID = template.id
        let scheduler = Scheduler(
            center: UNUserNotificationCenter.current(),
            modelContext: modelContext
        )
        scheduler.cancel(id: cancelID) // safe even if not registered
        modelContext.delete(template)
        try? modelContext.save()
    }

    private func togglePause(_ template: RecurrenceTemplate) {
        template.isActive.toggle()
        try? modelContext.save()
    }
}
```

> **Note:** `Client.color` returns `ClientColor`; map it to SwiftUI's `Color` using whatever bridge `v1` already uses (e.g., `clientColor.swiftUIColor` if defined, or a switch statement mirroring InvoiceTemplate's accent rendering).
>
> Also add a new case to `InvoicesView.NavigationTarget` from Task 3.4:
> ```swift
> case recurrenceEditor(templateID: UUID)
> ```
> and a `navigationDestination` clause that resolves the editor.

- [ ] **Step 2: Create `RecurrenceEditorView.swift`**

```swift
import SwiftUI
import SwiftData
import BillableCore

struct RecurrenceEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let template: RecurrenceTemplate

    @State private var cadenceKind: RecurrenceCadenceKind
    @State private var dayOfMonth: Int
    @State private var weekday: RecurrenceCadence.Weekday
    @State private var endDate: Date?
    @State private var notesTemplate: String
    @State private var grouping: LineItemGrouping
    @State private var generatingNow = false

    init(template: RecurrenceTemplate) {
        self.template = template
        switch template.cadenceValue {
        case .monthly(let d):
            _cadenceKind = State(initialValue: .monthly)
            _dayOfMonth = State(initialValue: d)
            _weekday = State(initialValue: .monday)
        case .weekly(let w):
            _cadenceKind = State(initialValue: .weekly)
            _dayOfMonth = State(initialValue: 1)
            _weekday = State(initialValue: w)
        case .biweekly(let w):
            _cadenceKind = State(initialValue: .biweekly)
            _dayOfMonth = State(initialValue: 1)
            _weekday = State(initialValue: w)
        }
        _endDate = State(initialValue: template.endDate)
        _notesTemplate = State(initialValue: template.notesTemplate ?? "")
        _grouping = State(initialValue: template.groupingValue)
    }

    var body: some View {
        Form {
            // Same fields as InvoiceGenerator's recurring section, but editable on `template`.
            // ... (mirror the layout from Task 3.3 step 2)

            Section {
                Button("Generate now") {
                    generateNow()
                }
                .disabled(generatingNow)
            }
        }
        .navigationTitle("Recurring schedule")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { save() }
            }
        }
    }

    private func save() {
        let cadence: RecurrenceCadence = switch cadenceKind {
        case .monthly: .monthly(dayOfMonth: dayOfMonth)
        case .weekly: .weekly(weekday: weekday)
        case .biweekly: .biweekly(weekday: weekday)
        }
        template.cadenceValue = cadence
        template.rangeRuleValue = RangeRule.implied(from: cadence)
        template.groupingValue = grouping
        template.notesTemplate = notesTemplate.isEmpty ? nil : notesTemplate
        template.endDate = endDate
        // Recompute next fire after cadence change.
        template.nextFireDate = RecurrenceService.computeNextFireDate(
            cadence: cadence, after: Date()
        )
        try? modelContext.save()
        dismiss()
    }

    private func generateNow() {
        generatingNow = true
        defer { generatingNow = false }
        do {
            _ = try RecurrenceService.materializeDraft(
                template: template, now: .now, context: modelContext
            )
            dismiss()
        } catch {
            // Show error sheet (deferred polish)
        }
    }
}
```

- [ ] **Step 3: Build + manual smoke**

Simulator: Invoices → Recurring → empty state shows. Create one via InvoiceGenerator, return → row appears. Tap → editor shows. Swipe → Pause/Delete actions visible.

- [ ] **Step 4: Commit**

```bash
git add App/Sources/Features/Recurrence/
git commit -m "feat(recurrence): RecurringRulesView + Editor (task 3.5)"
```

---

### Task 3.6: `CatchUpBanner` on `TodayView`

**Files:**
- Create: `App/Sources/Features/Recurrence/CatchUpBanner.swift`
- Modify: `App/Sources/Features/Today/TodayView.swift`

- [ ] **Step 1: Create the banner view**

```swift
import SwiftUI
import SwiftData
import BillableCore

struct CatchUpBanner: View {
    @Environment(\.modelContext) private var modelContext
    @State private var pending: [RecurrenceTemplate] = []

    var body: some View {
        Group {
            if !pending.isEmpty {
                NavigationLink(value: InvoicesView.NavigationTarget.pendingMaterializations) {
                    HStack(spacing: 12) {
                        Image(systemName: "tray.full.fill")
                            .font(.title3)
                            .foregroundStyle(.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(pending.count) recurring invoice\(pending.count == 1 ? "" : "s") to review")
                                .font(.subheadline.weight(.semibold))
                            Text("Tap to materialize one at a time")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(14)
                    .background(Color.accentColor.opacity(0.10), in: .rect(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
        }
        .task(id: ModelContext.didChangeID) {
            recompute()
        }
        .onAppear { recompute() }
    }

    private func recompute() {
        pending = RecurrenceService.pendingMaterializations(context: modelContext)
    }
}

// Helper for SwiftData change-tracking in this view.
private extension ModelContext {
    static var didChangeID: UUID { UUID() }
}
```

> **Note:** `InvoicesView.NavigationTarget.pendingMaterializations` is a new case to add to the enum (alongside `.detail`, `.preview`, `.recurrenceEditor`). Its destination view is a list of pending templates with a tap-to-materialize action — implement that list as a small view inside `RecurringRulesView.swift` or as a separate `PendingMaterializationsView`.

- [ ] **Step 2: Add `CatchUpBanner` to `TodayView`**

In `TodayView.swift`, near the top of the main content `VStack`, add:

```swift
CatchUpBanner()
    .padding(.horizontal)
    .padding(.top, 8)
```

- [ ] **Step 3: Build + manual smoke**

Simulator: create a recurrence with a `nextFireDate` in the past (via direct SwiftData manipulation in a debug helper, or wait until the next day). The Today screen should show the banner.

- [ ] **Step 4: Commit**

```bash
git add App/Sources/Features/Recurrence/CatchUpBanner.swift \
        App/Sources/Features/Today/TodayView.swift
git commit -m "feat(recurrence): CatchUpBanner on Today (task 3.6)"
```

---

## Phase 4 — Reminder domain (Day 4)

### Task 4.1: `ReminderConfig` @Model (singleton)

**Files:**
- Create: `Packages/BillableCore/Sources/BillableCore/Models/ReminderConfig.swift`
- Modify: `Packages/BillableCore/Sources/BillableCore/Persistence/ModelContainer+Billable.swift` — add to `mirroredSchema`
- Test: append to `SchedulingTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
@Test("ReminderConfig persists with default offsets and templates")
@MainActor
func reminderConfigPersists() throws {
    let container = try BillableModelContainer.inMemory()
    let context = container.mainContext

    let config = ReminderConfig.defaultConfig()
    context.insert(config)
    try context.save()

    let fetched = try context.fetch(FetchDescriptor<ReminderConfig>())
    #expect(fetched.count == 1)
    let c = try #require(fetched.first)
    #expect(c.enabledOffsets == [3, 7, 14])
    #expect(c.subjectTemplate.contains("{invoiceNumber}"))
    #expect(c.bodyTemplate.contains("{clientFirstName}"))
    #expect(c.masterEnabled == false)  // off until user enables explicitly
}
```

- [ ] **Step 2: Run test (fail)**

- [ ] **Step 3: Implement**

```swift
import Foundation
import SwiftData

/// Mirrored singleton @Model holding global reminder configuration.
@Model
public final class ReminderConfig {
    @Attribute(.unique) public var id: UUID

    /// Days-past-due offsets that are currently active. Default [3, 7, 14].
    /// UI shows fixed chips [3, 7, 14, 30] that toggle membership.
    public var enabledOffsets: [Int]

    public var subjectTemplate: String
    public var bodyTemplate: String

    /// Master on/off switch. When false, ReminderService.scheduleForInvoice
    /// becomes a no-op even if offsets are non-empty.
    public var masterEnabled: Bool

    public init(
        id: UUID = UUID(),
        enabledOffsets: [Int] = [3, 7, 14],
        subjectTemplate: String = ReminderConfig.defaultSubjectTemplate,
        bodyTemplate: String = ReminderConfig.defaultBodyTemplate,
        masterEnabled: Bool = false
    ) {
        self.id = id
        self.enabledOffsets = enabledOffsets
        self.subjectTemplate = subjectTemplate
        self.bodyTemplate = bodyTemplate
        self.masterEnabled = masterEnabled
    }

    public static func defaultConfig() -> ReminderConfig {
        ReminderConfig()
    }

    public static let defaultSubjectTemplate = "Friendly reminder: {invoiceNumber}"

    public static let defaultBodyTemplate = """
Hi {clientFirstName},

Just a quick nudge — invoice {invoiceNumber} for {amount} was due on {dueDate}, \
and it looks like it's a few days outstanding. If you've already sent it, \
please disregard. If not, no rush — just wanted to flag.

Attached is the invoice again for convenience.

Thanks!
{senderName}
"""
}
```

Add `ReminderConfig.self` to `mirroredSchema` in `ModelContainer+Billable.swift`.

- [ ] **Step 4: Run test (pass)**

- [ ] **Step 5: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Models/ReminderConfig.swift \
        Packages/BillableCore/Sources/BillableCore/Persistence/ModelContainer+Billable.swift \
        Packages/BillableCore/Tests/BillableCoreTests/SchedulingTests.swift
git commit -m "feat(reminders): ReminderConfig @Model (task 4.1)"
```

---

### Task 4.2: `InvoiceReminderSchedule` @Model

**Files:**
- Create: `Packages/BillableCore/Sources/BillableCore/Models/InvoiceReminderSchedule.swift`
- Modify: `ModelContainer+Billable.swift` — add to `mirroredSchema`
- Test: append to `SchedulingTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
@Test("InvoiceReminderSchedule stores fireDates and tracks firedDates")
@MainActor
func reminderSchedulePersists() throws {
    let container = try BillableModelContainer.inMemory()
    let context = container.mainContext

    let dueAt = Date(timeIntervalSince1970: 1_900_000_000)
    let fires = [3, 7, 14].map { Calendar.current.date(byAdding: .day, value: $0, to: dueAt)! }
    let schedule = InvoiceReminderSchedule(fireDates: fires)
    context.insert(schedule)
    try context.save()

    let fetched = try context.fetch(FetchDescriptor<InvoiceReminderSchedule>())
    #expect(fetched.first?.fireDates == fires)
    #expect(fetched.first?.firedDates.isEmpty == true)
}
```

- [ ] **Step 2: Run test (fail)**

- [ ] **Step 3: Implement**

```swift
import Foundation
import SwiftData

/// Mirrored @Model. Per-invoice list of when reminder notifications should
/// fire (`fireDates`) and which have already been acted on (`firedDates`).
@Model
public final class InvoiceReminderSchedule {
    @Attribute(.unique) public var id: UUID

    public var invoice: Invoice?

    /// All scheduled fire moments (absolute Dates at 8am local on each offset day).
    public var fireDates: [Date]

    /// Subset of `fireDates` that have already been acted on by the user
    /// (either via tapping the notification and sending, or via the user
    /// dismissing the prompt — both prevent the same step from repeating).
    public var firedDates: [Date]

    public init(
        id: UUID = UUID(),
        invoice: Invoice? = nil,
        fireDates: [Date] = [],
        firedDates: [Date] = []
    ) {
        self.id = id
        self.invoice = invoice
        self.fireDates = fireDates
        self.firedDates = firedDates
    }
}
```

Add `InvoiceReminderSchedule.self` to `mirroredSchema`.

- [ ] **Step 4: Run test (pass)**

- [ ] **Step 5: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Models/InvoiceReminderSchedule.swift \
        Packages/BillableCore/Sources/BillableCore/Persistence/ModelContainer+Billable.swift \
        Packages/BillableCore/Tests/BillableCoreTests/SchedulingTests.swift
git commit -m "feat(reminders): InvoiceReminderSchedule @Model (task 4.2)"
```

---

### Task 4.3: `Client.reminderOffsets` + `Invoice.reminderSchedule`

**Files:**
- Modify: `Packages/BillableCore/Sources/BillableCore/Models/Client.swift`
- Modify: `Packages/BillableCore/Sources/BillableCore/Models/Invoice.swift`
- Test: append to `SchedulingTests.swift`

> **Migration note:** Adding optional fields to existing `@Model` types is migration-safe (defaults to nil for existing rows). No explicit migration code needed for v1.1.

- [ ] **Step 1: Write the failing test**

```swift
@Test("Client.reminderOffsets defaults to nil; Invoice.reminderSchedule starts nil")
@MainActor
func clientAndInvoiceFieldsAdded() throws {
    let container = try BillableModelContainer.inMemory()
    let context = container.mainContext

    let client = Client(name: "Acme", color: .blue)
    context.insert(client)
    try context.save()

    #expect(client.reminderOffsets == nil)

    let profile = BusinessProfile(name: "Me", currencyCode: "USD")
    context.insert(profile)
    let invoice = Invoice(
        number: "INV-0001", dueAt: Date(),
        clientNameSnapshot: "Acme",
        issuerNameSnapshot: "Me", issuerAddressSnapshot: "", issuerEmailSnapshot: "",
        paymentTermsSnapshot: "Net 14", taxLabelSnapshot: "Tax", taxRateSnapshot: 0,
        currencyCodeSnapshot: "USD"
    )
    context.insert(invoice)
    try context.save()

    #expect(invoice.reminderSchedule == nil)
}
```

- [ ] **Step 2: Run test (fail)**

- [ ] **Step 3: Add the fields**

In `Client.swift`, add inside the `@Model` class:

```swift
/// Per-client override for reminder offsets. `nil` → use ReminderConfig.enabledOffsets.
public var reminderOffsets: [Int]?
```

Update the `init`:
```swift
public init(..., reminderOffsets: [Int]? = nil) {
    ...
    self.reminderOffsets = reminderOffsets
}
```

In `Invoice.swift`, add inside the `@Model` class:

```swift
public var reminderSchedule: InvoiceReminderSchedule?
```

(Default `nil`; no `init` change required since SwiftData treats nullable refs as initialized.)

- [ ] **Step 4: Run test (pass)**

- [ ] **Step 5: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Models/Client.swift \
        Packages/BillableCore/Sources/BillableCore/Models/Invoice.swift \
        Packages/BillableCore/Tests/BillableCoreTests/SchedulingTests.swift
git commit -m "feat(reminders): add Client.reminderOffsets + Invoice.reminderSchedule (task 4.3)"
```

---

### Task 4.4: `ReminderTemplateRenderer`

**Files:**
- Create: `Packages/BillableCore/Sources/BillableCore/Reminders/ReminderTemplateRenderer.swift`
- Test: append to `SchedulingTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
@Test("ReminderTemplateRenderer resolves all merge fields")
@MainActor
func renderResolvesAllFields() throws {
    let container = try BillableModelContainer.inMemory()
    let context = container.mainContext

    let client = Client(
        name: "Acme Corp",
        contactName: "Jane Doe",
        color: .blue
    )
    context.insert(client)

    let profile = BusinessProfile(name: "Louay Bazerbashi", currencyCode: "USD")
    context.insert(profile)

    let due = Date(timeIntervalSince1970: 1_900_000_000)
    let invoice = Invoice(
        number: "INV-0042",
        dueAt: due,
        clientNameSnapshot: "Acme Corp",
        issuerNameSnapshot: "Louay Bazerbashi",
        issuerAddressSnapshot: "",
        issuerEmailSnapshot: "",
        paymentTermsSnapshot: "Net 14",
        taxLabelSnapshot: "Tax",
        taxRateSnapshot: 0,
        currencyCodeSnapshot: "USD",
        lineItems: [InvoiceLineItem(description: "Work", hours: 10, hourlyRate: 100, sourceTimeEntryRef: nil)],
        client: client
    )
    context.insert(invoice)
    try context.save()

    let template = "Hi {clientFirstName}, {invoiceNumber} for {amount} was due {dueDate}. — {senderName}"
    let now = due.addingTimeInterval(3 * 86400)
    let rendered = ReminderTemplateRenderer.render(
        template: template,
        invoice: invoice,
        senderName: "Louay Bazerbashi",
        now: now
    )

    #expect(rendered.contains("Hi Jane"))
    #expect(rendered.contains("INV-0042"))
    #expect(rendered.contains("$1,000")) // 10h * $100
    #expect(rendered.contains("Louay Bazerbashi"))
    // {dueDate} resolves to a localized date; we just check it's substituted
    #expect(rendered.contains("{dueDate}") == false)
}

@Test("ReminderTemplateRenderer computes daysOverdue from now and dueAt")
@MainActor
func renderDaysOverdue() throws {
    let container = try BillableModelContainer.inMemory()
    let context = container.mainContext
    let client = Client(name: "Acme", color: .blue)
    let profile = BusinessProfile(name: "Me", currencyCode: "USD")
    context.insert(client); context.insert(profile)

    let due = Date(timeIntervalSince1970: 1_900_000_000)
    let invoice = Invoice(
        number: "INV-0007", dueAt: due,
        clientNameSnapshot: "Acme",
        issuerNameSnapshot: "Me", issuerAddressSnapshot: "", issuerEmailSnapshot: "",
        paymentTermsSnapshot: "", taxLabelSnapshot: "Tax", taxRateSnapshot: 0,
        currencyCodeSnapshot: "USD",
        client: client
    )
    context.insert(invoice)
    try context.save()

    let now = due.addingTimeInterval(7 * 86400)
    let rendered = ReminderTemplateRenderer.render(
        template: "{daysOverdue} days overdue",
        invoice: invoice, senderName: "Me", now: now
    )
    #expect(rendered == "7 days overdue")
}
```

- [ ] **Step 2: Run test (fail)**

- [ ] **Step 3: Implement**

```swift
import Foundation

public enum ReminderTemplateRenderer {

    /// Render a reminder template (subject or body) by substituting all
    /// supported merge fields. Unknown fields are left untouched.
    public static func render(
        template: String,
        invoice: Invoice,
        senderName: String,
        now: Date = .now,
        locale: Locale = .current
    ) -> String {
        let clientName = invoice.client?.name ?? invoice.clientNameSnapshot
        let clientFirstName = firstName(of: invoice.client?.contactName ?? clientName)
        let invoiceNumber = invoice.number
        let amountFormatter = NumberFormatter()
        amountFormatter.numberStyle = .currency
        amountFormatter.currencyCode = invoice.currencyCodeSnapshot
        amountFormatter.locale = locale
        let amount = amountFormatter.string(from: invoice.total as NSDecimalNumber) ?? ""

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.locale = locale
        let dueDate = dateFormatter.string(from: invoice.dueAt)

        let daysOverdue = Calendar.current.dateComponents(
            [.day], from: invoice.dueAt, to: now
        ).day.map(max) ?? 0

        return template
            .replacingOccurrences(of: "{clientName}",      with: clientName)
            .replacingOccurrences(of: "{clientFirstName}", with: clientFirstName)
            .replacingOccurrences(of: "{invoiceNumber}",   with: invoiceNumber)
            .replacingOccurrences(of: "{amount}",          with: amount)
            .replacingOccurrences(of: "{dueDate}",         with: dueDate)
            .replacingOccurrences(of: "{daysOverdue}",     with: "\(daysOverdue)")
            .replacingOccurrences(of: "{senderName}",      with: senderName)
    }

    private static func firstName(of fullName: String) -> String {
        fullName.split(separator: " ").first.map(String.init) ?? fullName
    }
}

private func max(_ x: Int) -> Int { Swift.max(x, 0) }
```

- [ ] **Step 4: Run tests (pass)**

- [ ] **Step 5: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Reminders/ReminderTemplateRenderer.swift \
        Packages/BillableCore/Tests/BillableCoreTests/SchedulingTests.swift
git commit -m "feat(reminders): ReminderTemplateRenderer (task 4.4)"
```

---

### Task 4.5: `ReminderService.scheduleForInvoice`

**Files:**
- Create: `Packages/BillableCore/Sources/BillableCore/Reminders/ReminderService.swift`
- Test: append to `SchedulingTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
@Test("scheduleForInvoice resolves offsets and creates fire dates at 8am local")
@MainActor
func scheduleForInvoiceCreatesFires() async throws {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!

    let center = FakeNotificationCenter()
    center.authorized = true
    let container = try BillableModelContainer.inMemory()
    let context = container.mainContext

    let config = ReminderConfig.defaultConfig()
    config.masterEnabled = true
    context.insert(config)

    let client = Client(name: "Acme", color: .blue)
    let profile = BusinessProfile(name: "Me", currencyCode: "USD")
    context.insert(client); context.insert(profile)

    let due = cal.date(from: DateComponents(year: 2026, month: 6, day: 15))!
    let invoice = Invoice(
        number: "INV-0010", dueAt: due,
        clientNameSnapshot: "Acme",
        issuerNameSnapshot: "Me", issuerAddressSnapshot: "", issuerEmailSnapshot: "",
        paymentTermsSnapshot: "", taxLabelSnapshot: "Tax", taxRateSnapshot: 0,
        currencyCodeSnapshot: "USD",
        client: client
    )
    try invoice.markSent(at: due.addingTimeInterval(-86400)) // Sent yesterday
    context.insert(invoice)
    try context.save()

    let scheduler = Scheduler(center: center, modelContext: context)
    _ = try await scheduler.requestAuthorization()
    let reminderService = ReminderService(scheduler: scheduler, modelContext: context, calendar: cal)

    try await reminderService.scheduleForInvoice(invoice)

    let schedule = try #require(invoice.reminderSchedule)
    let expected3  = cal.date(from: DateComponents(year: 2026, month: 6, day: 18, hour: 8))!
    let expected7  = cal.date(from: DateComponents(year: 2026, month: 6, day: 22, hour: 8))!
    let expected14 = cal.date(from: DateComponents(year: 2026, month: 6, day: 29, hour: 8))!
    #expect(schedule.fireDates == [expected3, expected7, expected14])
    #expect(center.addedRequests.count == 3)
}

@Test("scheduleForInvoice no-ops when masterEnabled is false")
@MainActor
func scheduleForInvoiceMasterDisabled() async throws {
    let center = FakeNotificationCenter()
    center.authorized = true
    let container = try BillableModelContainer.inMemory()
    let context = container.mainContext

    let config = ReminderConfig.defaultConfig()
    config.masterEnabled = false
    context.insert(config)

    let client = Client(name: "Acme", color: .blue)
    let profile = BusinessProfile(name: "Me", currencyCode: "USD")
    context.insert(client); context.insert(profile)

    let invoice = Invoice(
        number: "INV-0011", dueAt: Date().addingTimeInterval(86400),
        clientNameSnapshot: "Acme",
        issuerNameSnapshot: "Me", issuerAddressSnapshot: "", issuerEmailSnapshot: "",
        paymentTermsSnapshot: "", taxLabelSnapshot: "Tax", taxRateSnapshot: 0,
        currencyCodeSnapshot: "USD",
        client: client
    )
    try invoice.markSent()
    context.insert(invoice)
    try context.save()

    let scheduler = Scheduler(center: center, modelContext: context)
    _ = try await scheduler.requestAuthorization()
    let service = ReminderService(scheduler: scheduler, modelContext: context)

    try await service.scheduleForInvoice(invoice)
    #expect(invoice.reminderSchedule == nil)
    #expect(center.addedRequests.isEmpty)
}

@Test("scheduleForInvoice respects per-client override")
@MainActor
func scheduleForInvoiceClientOverride() async throws {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    let center = FakeNotificationCenter()
    center.authorized = true
    let container = try BillableModelContainer.inMemory()
    let context = container.mainContext

    let config = ReminderConfig.defaultConfig()
    config.masterEnabled = true
    config.enabledOffsets = [3, 7]
    context.insert(config)

    let client = Client(name: "Acme", color: .blue, reminderOffsets: [5])
    let profile = BusinessProfile(name: "Me", currencyCode: "USD")
    context.insert(client); context.insert(profile)

    let due = cal.date(from: DateComponents(year: 2026, month: 6, day: 15))!
    let invoice = Invoice(
        number: "INV-0012", dueAt: due,
        clientNameSnapshot: "Acme",
        issuerNameSnapshot: "Me", issuerAddressSnapshot: "", issuerEmailSnapshot: "",
        paymentTermsSnapshot: "", taxLabelSnapshot: "Tax", taxRateSnapshot: 0,
        currencyCodeSnapshot: "USD",
        client: client
    )
    try invoice.markSent()
    context.insert(invoice)
    try context.save()

    let scheduler = Scheduler(center: center, modelContext: context)
    _ = try await scheduler.requestAuthorization()
    let service = ReminderService(scheduler: scheduler, modelContext: context, calendar: cal)
    try await service.scheduleForInvoice(invoice)

    let schedule = try #require(invoice.reminderSchedule)
    #expect(schedule.fireDates.count == 1)
    let expected5 = cal.date(from: DateComponents(year: 2026, month: 6, day: 20, hour: 8))!
    #expect(schedule.fireDates.first == expected5)
}
```

- [ ] **Step 2: Run tests (fail)**

- [ ] **Step 3: Implement**

```swift
import Foundation
import SwiftData
import OSLog

@MainActor
public final class ReminderService {
    private let scheduler: Scheduler
    private let modelContext: ModelContext
    private let calendar: Calendar
    private let log = Logger(subsystem: "com.eldenstudios.billable", category: "ReminderService")

    public init(
        scheduler: Scheduler,
        modelContext: ModelContext,
        calendar: Calendar = .current
    ) {
        self.scheduler = scheduler
        self.modelContext = modelContext
        self.calendar = calendar
    }

    /// Compute fire dates from the resolved offsets, persist them, and register
    /// each with the Scheduler. No-op when masterEnabled is false or offsets empty.
    public func scheduleForInvoice(_ invoice: Invoice) async throws {
        let configs = try modelContext.fetch(FetchDescriptor<ReminderConfig>())
        guard let config = configs.first, config.masterEnabled else {
            log.info("scheduleForInvoice(): master disabled or no config — no-op")
            return
        }

        let offsets: [Int] = invoice.client?.reminderOffsets ?? config.enabledOffsets
        guard !offsets.isEmpty else {
            log.info("scheduleForInvoice(): no offsets — no-op")
            return
        }

        // Compute fire dates at 8am local on each offset day from dueAt.
        let fireDates = offsets.compactMap { offset -> Date? in
            let plus = calendar.date(byAdding: .day, value: offset, to: invoice.dueAt)
            guard let plus else { return nil }
            var comps = calendar.dateComponents([.year, .month, .day], from: plus)
            comps.hour = 8
            comps.minute = 0
            return calendar.date(from: comps)
        }
        .sorted()

        let schedule = InvoiceReminderSchedule(fireDates: fireDates, firedDates: [])
        schedule.invoice = invoice
        invoice.reminderSchedule = schedule
        modelContext.insert(schedule)
        try modelContext.save()

        let clientName = invoice.client?.name ?? invoice.clientNameSnapshot
        let amountFormatter = NumberFormatter()
        amountFormatter.numberStyle = .currency
        amountFormatter.currencyCode = invoice.currencyCodeSnapshot
        let amount = amountFormatter.string(from: invoice.total as NSDecimalNumber) ?? ""

        for (i, fireAt) in fireDates.enumerated() {
            let title = notificationTitle(
                offsetIndex: i, totalOffsets: offsets, clientName: clientName,
                amount: amount, invoiceNumber: invoice.number
            )
            let body = notificationBody(
                offsetIndex: i, offsetDays: offsets[i], invoiceNumber: invoice.number
            )
            _ = try await scheduler.schedule(
                payload: .reminder(scheduleID: schedule.id),
                fireAt: fireAt,
                title: title,
                body: body
            )
        }

        log.info("scheduleForInvoice(): invoiceID=\(invoice.uuid.uuidString, privacy: .public) fires=\(fireDates.count, privacy: .public)")
    }

    private func notificationTitle(
        offsetIndex: Int, totalOffsets: [Int],
        clientName: String, amount: String, invoiceNumber: String
    ) -> String {
        let offset = totalOffsets[offsetIndex]
        switch offset {
        case ...3:  return "\(clientName) owes you \(amount)"
        case 4...7: return "Still waiting on \(clientName): \(amount)"
        case 8...14: return "\(invoiceNumber) is 2 weeks overdue"
        default:    return "\(invoiceNumber) is a month overdue"
        }
    }

    private func notificationBody(
        offsetIndex: Int, offsetDays: Int, invoiceNumber: String
    ) -> String {
        switch offsetDays {
        case ...3:   return "\(invoiceNumber) is \(offsetDays) days overdue. Send a reminder?"
        case 4...7:  return "\(invoiceNumber) is now a week overdue."
        case 8...14: return "Time for a stronger nudge?"
        default:     return "Consider escalating or adding a late fee."
        }
    }
}
```

- [ ] **Step 4: Run tests (pass)**

- [ ] **Step 5: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Reminders/ReminderService.swift \
        Packages/BillableCore/Tests/BillableCoreTests/SchedulingTests.swift
git commit -m "feat(reminders): ReminderService.scheduleForInvoice (task 4.5)"
```

---

### Task 4.6: `ReminderService.cancelForInvoice` + `recordFired`

**Files:**
- Modify: `Packages/BillableCore/Sources/BillableCore/Reminders/ReminderService.swift`
- Test: append to `SchedulingTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
@Test("cancelForInvoice removes all pending fires + deletes schedule")
@MainActor
func cancelForInvoiceClears() async throws {
    let (service, invoice, container) = try await makeScheduledReminderFixture()
    let scheduleID = try #require(invoice.reminderSchedule?.id)
    let priorCount = try container.mainContext.fetch(FetchDescriptor<ScheduledNotification>()).count
    #expect(priorCount > 0)

    try await service.cancelForInvoice(invoice)

    #expect(invoice.reminderSchedule == nil)
    let after = try container.mainContext.fetch(FetchDescriptor<ScheduledNotification>())
    #expect(after.isEmpty)
    // Schedule row also gone
    let scheduleRows = try container.mainContext.fetch(
        FetchDescriptor<InvoiceReminderSchedule>(predicate: #Predicate { $0.id == scheduleID })
    )
    #expect(scheduleRows.isEmpty)
}

@Test("recordFired appends to firedDates so the step doesn't repeat")
@MainActor
func recordFiredAppends() async throws {
    let (service, invoice, _) = try await makeScheduledReminderFixture()
    let schedule = try #require(invoice.reminderSchedule)
    let firstFire = try #require(schedule.fireDates.first)

    service.recordFired(invoice: invoice, at: firstFire)

    #expect(invoice.reminderSchedule?.firedDates == [firstFire])
    // Second call is idempotent
    service.recordFired(invoice: invoice, at: firstFire)
    #expect(invoice.reminderSchedule?.firedDates.count == 1)
}

// Helper used by both tests above:
@MainActor
func makeScheduledReminderFixture() async throws -> (ReminderService, Invoice, ModelContainer) {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    let center = FakeNotificationCenter()
    center.authorized = true
    let container = try BillableModelContainer.inMemory()
    let context = container.mainContext

    let config = ReminderConfig.defaultConfig()
    config.masterEnabled = true
    context.insert(config)

    let client = Client(name: "Acme", color: .blue)
    let profile = BusinessProfile(name: "Me", currencyCode: "USD")
    context.insert(client); context.insert(profile)

    let invoice = Invoice(
        number: "INV-0013",
        dueAt: cal.date(from: DateComponents(year: 2026, month: 6, day: 15))!,
        clientNameSnapshot: "Acme",
        issuerNameSnapshot: "Me", issuerAddressSnapshot: "", issuerEmailSnapshot: "",
        paymentTermsSnapshot: "", taxLabelSnapshot: "Tax", taxRateSnapshot: 0,
        currencyCodeSnapshot: "USD",
        client: client
    )
    try invoice.markSent()
    context.insert(invoice)
    try context.save()

    let scheduler = Scheduler(center: center, modelContext: context)
    _ = try await scheduler.requestAuthorization()
    let service = ReminderService(scheduler: scheduler, modelContext: context, calendar: cal)
    try await service.scheduleForInvoice(invoice)
    return (service, invoice, container)
}
```

- [ ] **Step 2: Run tests (fail)**

- [ ] **Step 3: Implement**

Add to `ReminderService.swift`:

```swift
    /// Cancel all remaining iOS-side reminder fires for the invoice and delete
    /// the schedule row. Idempotent.
    public func cancelForInvoice(_ invoice: Invoice) async throws {
        guard let schedule = invoice.reminderSchedule else { return }
        let scheduleID = schedule.id

        // Find every ScheduledNotification rows whose payload is this schedule.
        let descriptor = FetchDescriptor<ScheduledNotification>(
            predicate: #Predicate { row in
                row.payloadType == "reminder" && row.payloadID == scheduleID
            }
        )
        if let rows = try? modelContext.fetch(descriptor) {
            for row in rows { scheduler.cancel(id: row.id) }
        }

        invoice.reminderSchedule = nil
        modelContext.delete(schedule)
        try modelContext.save()
        log.info("cancelForInvoice(): invoiceID=\(invoice.uuid.uuidString, privacy: .public)")
    }

    /// Mark one fire step as acted-on so it doesn't repeat. Idempotent.
    public func recordFired(invoice: Invoice, at fireDate: Date) {
        guard let schedule = invoice.reminderSchedule else { return }
        if !schedule.firedDates.contains(fireDate) {
            schedule.firedDates.append(fireDate)
            try? modelContext.save()
        }
    }
```

- [ ] **Step 4: Run tests (pass)**

- [ ] **Step 5: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Reminders/ReminderService.swift \
        Packages/BillableCore/Tests/BillableCoreTests/SchedulingTests.swift
git commit -m "feat(reminders): cancelForInvoice + recordFired (task 4.6)"
```

---

## Phase 5 — Reminder UI + integration (Day 5)

### Task 5.1: `PaymentRemindersView`

**Files:**
- Create: `App/Sources/Features/Settings/PaymentRemindersView.swift`

- [ ] **Step 1: Implement the view**

```swift
import SwiftUI
import SwiftData
import BillableCore

struct PaymentRemindersView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var configs: [ReminderConfig]

    private var config: ReminderConfig {
        if let existing = configs.first { return existing }
        let new = ReminderConfig.defaultConfig()
        modelContext.insert(new)
        try? modelContext.save()
        return new
    }

    @State private var enabledSet: Set<Int> = []
    @State private var subject: String = ""
    @State private var body: String = ""
    @State private var masterEnabled: Bool = false
    @State private var permissionDenied: Bool = false

    private let allOffsets: [Int] = [3, 7, 14, 30]

    var body: some View {
        Form {
            Section {
                Toggle("Send reminders for overdue invoices", isOn: $masterEnabled)
                    .onChange(of: masterEnabled) { _, newValue in
                        if newValue { Task { await requestPermissionIfNeeded() } }
                        config.masterEnabled = newValue
                        try? modelContext.save()
                    }
                if permissionDenied {
                    Label("Notifications are off — reminders won't fire.", systemImage: "bell.slash")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
            } header: { Text("Reminders") }

            Section {
                ForEach(allOffsets, id: \.self) { offset in
                    Toggle("After \(offset) days overdue", isOn: Binding(
                        get: { enabledSet.contains(offset) },
                        set: { isOn in
                            if isOn { enabledSet.insert(offset) } else { enabledSet.remove(offset) }
                            config.enabledOffsets = enabledSet.sorted()
                            try? modelContext.save()
                        }
                    ))
                    .disabled(!masterEnabled)
                }
            } header: { Text("When to send") }

            Section {
                TextField("Subject", text: $subject)
                    .onChange(of: subject) { _, v in config.subjectTemplate = v; try? modelContext.save() }
                    .disabled(!masterEnabled)
                TextEditor(text: $body)
                    .frame(minHeight: 160)
                    .onChange(of: body) { _, v in config.bodyTemplate = v; try? modelContext.save() }
                    .disabled(!masterEnabled)
                Text("Merge fields: {clientName} {clientFirstName} {invoiceNumber} {amount} {dueDate} {daysOverdue} {senderName}")
                    .font(.caption2).foregroundStyle(.tertiary)
            } header: { Text("Email template") }
        }
        .navigationTitle("Payment reminders")
        .onAppear { syncFromConfig() }
    }

    private func syncFromConfig() {
        let c = config
        enabledSet = Set(c.enabledOffsets)
        subject = c.subjectTemplate
        body = c.bodyTemplate
        masterEnabled = c.masterEnabled
        Task { await checkPermission() }
    }

    private func requestPermissionIfNeeded() async {
        let scheduler = Scheduler(
            center: UNUserNotificationCenter.current(),
            modelContext: modelContext
        )
        let status = await scheduler.currentAuthorizationStatus()
        switch status {
        case .notDetermined:
            let granted = (try? await scheduler.requestAuthorization()) ?? false
            if !granted {
                masterEnabled = false
                config.masterEnabled = false
                permissionDenied = true
                try? modelContext.save()
            }
        case .denied:
            masterEnabled = false
            config.masterEnabled = false
            permissionDenied = true
            try? modelContext.save()
        default:
            permissionDenied = false
        }
    }

    private func checkPermission() async {
        let scheduler = Scheduler(
            center: UNUserNotificationCenter.current(),
            modelContext: modelContext
        )
        let status = await scheduler.currentAuthorizationStatus()
        permissionDenied = (status == .denied)
    }
}
```

- [ ] **Step 2: Build + manual smoke**

```bash
xcodebuild ... build
```

- [ ] **Step 3: Commit**

```bash
git add App/Sources/Features/Settings/PaymentRemindersView.swift
git commit -m "feat(reminders): PaymentRemindersView (task 5.1)"
```

---

### Task 5.2: Add "Payment reminders" row to `SettingsView`

**Files:**
- Modify: `App/Sources/Features/Settings/SettingsView.swift`

- [ ] **Step 1: Add the row between Subscription and About**

Find the existing Settings form. Add a new Section between the "Subscription" section and the "About" section:

```swift
Section {
    NavigationLink {
        PaymentRemindersView()
    } label: {
        Label("Payment reminders", systemImage: "bell.badge")
    }
} header: { Text("Reminders") }
```

- [ ] **Step 2: Build + manual smoke**

Simulator: Settings tab → see new "Payment reminders" row → tap → screen appears.

- [ ] **Step 3: Commit**

```bash
git add App/Sources/Features/Settings/SettingsView.swift
git commit -m "feat(reminders): Add Payment reminders row to Settings (task 5.2)"
```

---

### Task 5.3: Add Reminders section to `ClientEditorView`

**Files:**
- Modify: `App/Sources/Features/Clients/ClientEditorView.swift`

- [ ] **Step 1: Add state + section**

Add to `ClientEditorView`:

```swift
@State private var reminderMode: ReminderMode = .useDefault
@State private var clientCustomOffsets: Set<Int> = []

enum ReminderMode: String, CaseIterable {
    case useDefault, custom
    var label: String { self == .useDefault ? "Use default" : "Custom for this client" }
}

// In init/onAppear, sync from client:
private func loadReminderState() {
    if let offsets = client.reminderOffsets {
        reminderMode = .custom
        clientCustomOffsets = Set(offsets)
    } else {
        reminderMode = .useDefault
        clientCustomOffsets = []
    }
}
```

Add a new Section after the existing fields:

```swift
Section {
    Picker("Reminders", selection: $reminderMode) {
        Text(ReminderMode.useDefault.label).tag(ReminderMode.useDefault)
        Text(ReminderMode.custom.label).tag(ReminderMode.custom)
    }
    .pickerStyle(.segmented)
    .onChange(of: reminderMode) { _, newMode in
        if newMode == .useDefault {
            client.reminderOffsets = nil
            clientCustomOffsets = []
        } else {
            // Seed with current global defaults if available
            if let config = try? modelContext.fetch(FetchDescriptor<ReminderConfig>()).first {
                clientCustomOffsets = Set(config.enabledOffsets)
            } else {
                clientCustomOffsets = [3, 7, 14]
            }
            client.reminderOffsets = clientCustomOffsets.sorted()
        }
        try? modelContext.save()
    }

    if reminderMode == .custom {
        ForEach([3, 7, 14, 30], id: \.self) { offset in
            Toggle("After \(offset) days overdue", isOn: Binding(
                get: { clientCustomOffsets.contains(offset) },
                set: { isOn in
                    if isOn { clientCustomOffsets.insert(offset) } else { clientCustomOffsets.remove(offset) }
                    client.reminderOffsets = clientCustomOffsets.sorted()
                    try? modelContext.save()
                }
            ))
        }
    }
} header: { Text("Reminders") }
```

Add `.onAppear { loadReminderState() }` to the Form.

- [ ] **Step 2: Build + manual smoke**

Simulator: Clients tab → tap a client → Edit → Reminders section visible → switching to Custom reveals checkboxes.

- [ ] **Step 3: Commit**

```bash
git add App/Sources/Features/Clients/ClientEditorView.swift
git commit -m "feat(reminders): Per-client override on ClientEditor (task 5.3)"
```

---

### Task 5.4: Hook `ReminderService` into `Invoice.markSent`/`markPaid` + finish AppDelegate routing

**Files:**
- Modify: `Packages/BillableCore/Sources/BillableCore/Models/InvoiceStatusMachine.swift` — add hook closures
- Modify: `App/Sources/App/BillableApp.swift` — wire the hooks at startup
- Modify: `App/Sources/App/AppDelegate.swift` — fill in the reminder-destination resolver

> **Design note on hooks:** `InvoiceStatusMachine.swift` lives in `BillableCore`, which doesn't know about `ReminderService` directly (avoids circular dependency since `ReminderService` references `Invoice`). We use a static closure that the app target sets on launch.

- [ ] **Step 1: Add static hook in `InvoiceStatusMachine.swift`**

Modify `InvoiceStatusMachine.swift`:

```swift
extension Invoice {
    /// Set by the app target at startup so `markSent` can schedule reminders
    /// without `BillableCore` directly depending on `ReminderService`.
    nonisolated(unsafe) public static var didMarkSentHook: (@MainActor (Invoice) async -> Void)?
    nonisolated(unsafe) public static var didMarkPaidHook: (@MainActor (Invoice) async -> Void)?

    public func markSent(at date: Date = .now) throws {
        guard status == .draft else {
            throw InvoiceTransitionError.illegalTransition(from: status, to: .sent)
        }
        status = .sent
        sentAt = date
        updatedAt = date
        // Fire the hook (if any) — async, fire-and-forget so the caller stays sync.
        if let hook = Self.didMarkSentHook {
            Task { @MainActor in await hook(self) }
        }
    }

    public func markPaid(at date: Date = .now) throws {
        guard status == .sent else {
            throw InvoiceTransitionError.illegalTransition(from: status, to: .paid)
        }
        status = .paid
        paidAt = date
        updatedAt = date
        if let hook = Self.didMarkPaidHook {
            Task { @MainActor in await hook(self) }
        }
    }
}
```

> **Note:** `nonisolated(unsafe)` here is acceptable because the hooks are set exactly once at app startup before any invoice transitions can run. If your strict-concurrency settings complain, wrap in a `@MainActor` singleton instead.

- [ ] **Step 2: Extend `BillableApp.performStartupWiring()` (introduced in Task 3.2) with the Invoice hooks**

Add to the body of `performStartupWiring()`:

```swift
Invoice.didMarkSentHook = { [container] invoice in
    let scheduler = Scheduler(
        center: UNUserNotificationCenter.current(),
        modelContext: container.mainContext
    )
    let service = ReminderService(scheduler: scheduler, modelContext: container.mainContext)
    try? await service.scheduleForInvoice(invoice)
}
Invoice.didMarkPaidHook = { [container] invoice in
    let scheduler = Scheduler(
        center: UNUserNotificationCenter.current(),
        modelContext: container.mainContext
    )
    let service = ReminderService(scheduler: scheduler, modelContext: container.mainContext)
    try? await service.cancelForInvoice(invoice)
}
```

- [ ] **Step 3: Fill in `AppDelegate.resolveReminderDestination`**

Replace the placeholder in `AppDelegate.swift`:

```swift
private func resolveReminderDestination(
    scheduleID: UUID, scheduler: Scheduler
) -> NotificationRouter.Destination {
    guard let context = Self.sharedModelContext else { return .recurringList }
    let descriptor = FetchDescriptor<InvoiceReminderSchedule>(
        predicate: #Predicate { $0.id == scheduleID }
    )
    if let schedule = try? context.fetch(descriptor).first,
       let invoice = schedule.invoice {
        return .invoiceDetail(invoiceID: invoice.uuid)
    }
    return .recurringList  // fallback
}
```

Wire `AppDelegate.sharedModelContext` inside `BillableApp.performStartupWiring()` (added in Task 3.2):

```swift
AppDelegate.sharedModelContext = container.mainContext
```

Add this line alongside `AppDelegate.sharedRouter = notificationRouter`.

- [ ] **Step 4: Build + run integration**

```bash
xcodebuild ... build
```

Simulator: enable Payment reminders → create an invoice with `dueAt` 3 days ago → markSent → wait briefly → confirm a notification is scheduled (verify via Diagnostics screen in Phase 6, or via Console.app).

- [ ] **Step 5: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Models/InvoiceStatusMachine.swift \
        Packages/BillableCore/Sources/BillableCore/Scheduling/Scheduler.swift \
        App/Sources/App/BillableApp.swift \
        App/Sources/App/AppDelegate.swift
git commit -m "feat(reminders): hook ReminderService into Invoice state machine (task 5.4)"
```

---

### Task 5.5: `InvoiceDetailView` overdue banner + Send reminder CTA + Mail prefill

**Files:**
- Modify: `App/Sources/Features/Invoicing/InvoiceDetailView.swift`

- [ ] **Step 1: Add state + computed banner**

Add to `InvoiceDetailView`:

```swift
@State private var showingMailComposer = false
@State private var pendingMailBody: String = ""
@State private var pendingMailSubject: String = ""

private var pendingReminderStep: (offsetDays: Int, fireDate: Date)? {
    guard let schedule = invoice.reminderSchedule else { return nil }
    let now = Date()
    // Find the first fireDate that has happened (<=now) but is not yet in firedDates.
    for fire in schedule.fireDates where fire <= now {
        if !schedule.firedDates.contains(fire) {
            let daysOverdue = Calendar.current.dateComponents([.day], from: invoice.dueAt, to: now).day ?? 0
            return (max(daysOverdue, 0), fire)
        }
    }
    return nil
}
```

- [ ] **Step 2: Show the banner above the existing PDF preview**

In the body, just below the status banner, conditionally render:

```swift
if let step = pendingReminderStep {
    HStack(spacing: 12) {
        Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
        Text("\(step.offsetDays) days overdue — send reminder?")
            .font(.subheadline.weight(.semibold))
        Spacer()
        Button("Send reminder") { composeReminder(for: step.fireDate) }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
    }
    .padding(12)
    .background(Color.orange.opacity(0.12), in: .rect(cornerRadius: 12))
    .padding(.horizontal)
}
```

- [ ] **Step 3: Implement `composeReminder`**

```swift
private func composeReminder(for fireDate: Date) {
    guard let configs = try? modelContext.fetch(FetchDescriptor<ReminderConfig>()),
          let config = configs.first else { return }
    let profile = (try? modelContext.fetch(FetchDescriptor<BusinessProfile>()))?.first

    pendingMailSubject = ReminderTemplateRenderer.render(
        template: config.subjectTemplate,
        invoice: invoice,
        senderName: profile?.name ?? "",
        now: Date()
    )
    pendingMailBody = ReminderTemplateRenderer.render(
        template: config.bodyTemplate,
        invoice: invoice,
        senderName: profile?.name ?? "",
        now: Date()
    )

    // Record fired BEFORE presenting so the step doesn't repeat even if user cancels the mail sheet.
    let scheduler = Scheduler(center: UNUserNotificationCenter.current(), modelContext: modelContext)
    let service = ReminderService(scheduler: scheduler, modelContext: modelContext)
    service.recordFired(invoice: invoice, at: fireDate)

    showingMailComposer = true
}
```

- [ ] **Step 4: Present the mail composer**

Cadence v1 likely already has a `MailComposer` SwiftUI wrapper (used for the existing "Send reminder" toolbar item). Reuse it:

```swift
.sheet(isPresented: $showingMailComposer) {
    MailComposeView(
        subject: pendingMailSubject,
        body: pendingMailBody,
        toRecipients: [invoice.client?.email].compactMap { $0 },
        attachment: invoice.pdfDataCached.map { MailAttachment(data: $0, mimeType: "application/pdf", filename: "\(invoice.number).pdf") }
    )
}
```

> **Note:** If `MailComposeView` doesn't exist yet in v1, create it as a thin `UIViewControllerRepresentable` around `MFMailComposeViewController` (fallback to `mailto:` URL if mail isn't configured). If unsure, mirror the implementation that powers the existing toolbar "Send reminder" item.

- [ ] **Step 5: Build + manual smoke**

Simulator with a Sent invoice that's overdue: open InvoiceDetail → banner shows → tap "Send reminder" → mail composer opens with templated subject + body → close → reopen InvoiceDetail → banner is gone (firedDates updated).

- [ ] **Step 6: Commit**

```bash
git add App/Sources/Features/Invoicing/InvoiceDetailView.swift
git commit -m "feat(reminders): InvoiceDetail banner + Send reminder CTA (task 5.5)"
```

---

## Phase 6 — Polish, observability, acceptance (Day 6)

### Task 6.1: `--debug-scheduler` flag + `DiagnosticsView`

**Files:**
- Create: `App/Sources/Features/Settings/DiagnosticsView.swift`
- Modify: `App/Sources/Features/Settings/SettingsView.swift`
- Modify: `App/Sources/App/BillableApp.swift` (no-op if already pattern-matches; just confirm flag detection)

- [ ] **Step 1: Implement DiagnosticsView**

```swift
import SwiftUI
import SwiftData
import UserNotifications
import BillableCore

struct DiagnosticsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ScheduledNotification.fireAt) private var rows: [ScheduledNotification]
    @State private var iosPending: [UNNotificationRequest] = []
    @State private var lastResync: Date?

    var body: some View {
        List {
            Section {
                LabeledContent("SwiftData rows", value: "\(rows.count)")
                LabeledContent("iOS pending", value: "\(iosPending.count)")
                LabeledContent("Δ (rows − iOS)", value: "\(rows.count - iosPending.count)")
                if let lastResync {
                    LabeledContent("Last resync", value: lastResync.formatted(date: .abbreviated, time: .shortened))
                }
                Button("Run resyncOnLaunch") {
                    Task { await runResync() }
                }
            } header: { Text("Scheduler") }

            Section {
                ForEach(rows) { row in
                    VStack(alignment: .leading) {
                        Text(row.id.uuidString).font(.caption.monospaced())
                        Text("\(row.payloadType) · \(row.fireAt.formatted(.dateTime.month().day().hour().minute()))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } header: { Text("Pending (SwiftData)") }
        }
        .navigationTitle("Diagnostics")
        .task { await refresh() }
    }

    private func refresh() async {
        iosPending = await UNUserNotificationCenter.current().pendingNotificationRequests()
    }

    private func runResync() async {
        let scheduler = Scheduler(
            center: UNUserNotificationCenter.current(),
            modelContext: modelContext
        )
        _ = await scheduler.resyncOnLaunch()
        lastResync = Date()
        await refresh()
    }
}
```

- [ ] **Step 2: Gate from `SettingsView`**

In `SettingsView.swift`, add inside the form body:

```swift
if CommandLine.arguments.contains("--debug-scheduler") {
    Section {
        NavigationLink {
            DiagnosticsView()
        } label: {
            Label("Diagnostics", systemImage: "stethoscope")
        }
    } header: { Text("Debug") }
}
```

- [ ] **Step 3: Build + smoke**

```bash
xcrun simctl launch booted com.eldenstudios.billable --debug-scheduler
```

Open Settings → Diagnostics row visible only with the flag.

- [ ] **Step 4: Commit**

```bash
git add App/Sources/Features/Settings/DiagnosticsView.swift \
        App/Sources/Features/Settings/SettingsView.swift
git commit -m "feat(observability): --debug-scheduler DiagnosticsView (task 6.1)"
```

---

### Task 6.2: Run `resyncOnLaunch` on app launch

**Files:**
- Modify: `App/Sources/App/BillableApp.swift` (or `App/Sources/App/RootView.swift`)

- [ ] **Step 1: Trigger resync from a `.task` modifier on `RootView`**

In `RootView`, add:

```swift
.task(id: scenePhase) {
    if scenePhase == .active {
        let scheduler = Scheduler(
            center: UNUserNotificationCenter.current(),
            modelContext: modelContext
        )
        _ = await scheduler.resyncOnLaunch()
    }
}
```

Add `@Environment(\.scenePhase) private var scenePhase` and `@Environment(\.modelContext) private var modelContext` if not already present.

- [ ] **Step 2: Build + manual smoke**

Force-quit the app, relaunch — Diagnostics screen should show "Last resync" updated to recent.

- [ ] **Step 3: Commit**

```bash
git add App/Sources/App/RootView.swift
git commit -m "feat(scheduling): resyncOnLaunch on app active (task 6.2)"
```

---

### Task 6.3: Recompute app badge count on `scenePhase == .active`

**Files:**
- Modify: `App/Sources/App/RootView.swift`
- Create: `Packages/BillableCore/Sources/BillableCore/Scheduling/BadgeCount.swift`
- Test: append to `SchedulingTests.swift`

- [ ] **Step 1: Write failing test**

```swift
@Test("BadgeCount.compute counts pending materializations + pending reminders")
@MainActor
func badgeCountCombines() async throws {
    let container = try BillableModelContainer.inMemory()
    let context = container.mainContext

    // Pending recurrence
    let client = Client(name: "Acme", color: .blue)
    let profile = BusinessProfile(name: "Me", currencyCode: "USD")
    context.insert(client); context.insert(profile)
    let past = Date().addingTimeInterval(-3600)
    context.insert(RecurrenceTemplate(
        client: client, cadence: .monthly(dayOfMonth: 1),
        grouping: .perEntry, nextFireDate: past
    ))

    // Sent invoice with a pending reminder fire (fireDate in past, not yet fired)
    let invoice = Invoice(
        number: "INV-0099",
        dueAt: Date().addingTimeInterval(-86400 * 4),
        clientNameSnapshot: "Acme",
        issuerNameSnapshot: "Me", issuerAddressSnapshot: "", issuerEmailSnapshot: "",
        paymentTermsSnapshot: "", taxLabelSnapshot: "Tax", taxRateSnapshot: 0,
        currencyCodeSnapshot: "USD",
        client: client
    )
    try invoice.markSent()
    let schedule = InvoiceReminderSchedule(
        invoice: invoice,
        fireDates: [Date().addingTimeInterval(-3600)],
        firedDates: []
    )
    invoice.reminderSchedule = schedule
    context.insert(invoice); context.insert(schedule)
    try context.save()

    let count = BadgeCount.compute(context: context, now: Date())
    #expect(count == 2) // 1 recurrence + 1 reminder
}
```

- [ ] **Step 2: Run test (fail)**

- [ ] **Step 3: Implement**

Create `BadgeCount.swift`:

```swift
import Foundation
import SwiftData

@MainActor
public enum BadgeCount {
    /// Computed badge value: pending recurrence materializations +
    /// pending overdue-reminder steps not yet acted on.
    public static func compute(context: ModelContext, now: Date = .now) -> Int {
        let pendingRecurrences = RecurrenceService.pendingMaterializations(
            now: now, context: context
        ).count

        let schedules = (try? context.fetch(FetchDescriptor<InvoiceReminderSchedule>())) ?? []
        let pendingReminders = schedules.reduce(into: 0) { acc, schedule in
            // Only count if owning invoice is still .sent (not paid).
            guard let invoice = schedule.invoice, invoice.status == .sent else { return }
            for fire in schedule.fireDates where fire <= now && !schedule.firedDates.contains(fire) {
                acc += 1
            }
        }
        return pendingRecurrences + pendingReminders
    }
}
```

- [ ] **Step 4: Apply badge on `scenePhase == .active`**

In `RootView`'s `.task(id: scenePhase)` block (from Task 6.2):

```swift
.task(id: scenePhase) {
    if scenePhase == .active {
        let scheduler = Scheduler(
            center: UNUserNotificationCenter.current(),
            modelContext: modelContext
        )
        _ = await scheduler.resyncOnLaunch()
        let count = BadgeCount.compute(context: modelContext)
        try? await UNUserNotificationCenter.current().setBadgeCount(count)
    }
}
```

- [ ] **Step 5: Run test (pass), build + smoke**

- [ ] **Step 6: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Scheduling/BadgeCount.swift \
        App/Sources/App/RootView.swift \
        Packages/BillableCore/Tests/BillableCoreTests/SchedulingTests.swift
git commit -m "feat(scheduling): app badge count recompute (task 6.3)"
```

---

### Task 6.4: UI smoke test — notification tap → screen handoff

**Files:**
- Create: `App/BillableUITests/NotificationTapFlowUITests.swift` (if `BillableUITests` doesn't exist, add the target via `project.yml` first)

> **Note:** A true notification-tap UI test on iOS Simulator requires the `simctl push` workflow; in v1.1 we get most of the value from a programmatic test that drives `NotificationRouter.pendingDestination` directly through SwiftUI environment.

- [ ] **Step 1: Add a UI test target to `project.yml` if missing**

```yaml
  BillableUITests:
    type: bundle.ui-testing
    platform: iOS
    deploymentTarget: "17.0"
    sources:
      - path: App/BillableUITests
    dependencies:
      - target: Billable
```

- [ ] **Step 2: Implement the test**

```swift
import XCTest

final class NotificationTapFlowUITests: XCTestCase {
    func test_recurrenceNotificationRoutesToRecurringList() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-route-recurring"]
        app.launch()

        // Custom launch argument should cause the App to seed a pendingDestination
        // and verify we land on the Invoices tab with the Recurring segment active.
        XCTAssertTrue(app.staticTexts["Recurring"].waitForExistence(timeout: 3))
    }
}
```

Add a corresponding branch in `BillableApp.init()`:

```swift
if CommandLine.arguments.contains("--ui-test-route-recurring") {
    notificationRouter.pendingDestination = .recurringList
}
```

- [ ] **Step 3: Run + verify**

```bash
xcodebuild -project Billable.xcodeproj \
  -scheme Billable \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BillableUITests test
```
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add App/BillableUITests/ project.yml
git commit -m "test(ui): notification tap routes to Recurring (task 6.4)"
```

---

### Task 6.5: Final acceptance sweep

- [ ] **Step 1: Re-read spec §10 acceptance criteria and check off each box**

Open `docs/superpowers/specs/2026-05-23-recurring-invoices-and-overdue-reminders-design.md` and walk through every checkbox. For each:
- If it's verified by an existing test in `SchedulingTests`, note that.
- If it needs a manual simulator run, run it now.
- If anything fails, fix it before continuing.

Specifically, manually verify:
- "Make recurring" toggle on InvoiceGenerator saves a template
- Invoices tab shows the "Recurring" segment with the saved template
- Marking an invoice Paid removes any pending reminder fires (verify via Diagnostics)
- Deleting a client cascades to delete its RecurrenceTemplate rows (add cascade if missing)
- Permission denial soft-blocks the toggles and shows the Settings link

- [ ] **Step 2: Run the full test suite**

```bash
xcodebuild -project Billable.xcodeproj -scheme Billable \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```
Expected: PASS, with the BillableCore test count having risen from 52 to ~77.

- [ ] **Step 3: Final commit + push**

```bash
git push origin main
```

---

## Appendix A — Cascade behavior on Client deletion

The spec calls for: deleting a Client cascades to delete its `RecurrenceTemplate` rows and cancel their `Scheduler` entries.

Current v1 cascade rules (in `Client.swift`'s `@Relationship` declarations) handle Projects and TimeEntries. Add an explicit pre-delete step in `ClientDetailView` or wherever delete is initiated:

```swift
private func deleteClient(_ client: Client) {
    let templateDescriptor = FetchDescriptor<RecurrenceTemplate>(
        predicate: #Predicate { $0.client == client }
    )
    if let templates = try? modelContext.fetch(templateDescriptor) {
        let scheduler = Scheduler(
            center: UNUserNotificationCenter.current(),
            modelContext: modelContext
        )
        for template in templates {
            scheduler.cancel(id: template.id) // safe if not registered
            modelContext.delete(template)
        }
    }
    modelContext.delete(client)
    try? modelContext.save()
}
```

This is most cleanly added as part of Task 5.3 or Task 6.5.

---

## Appendix B — Soft-cap behavior reference

`Scheduler.softCap = 60`. When the iOS pending-request count is at or above 60, `schedule(...)` returns `.capExceeded`. The SwiftData row is still inserted so `resyncOnLaunch` can register it later when capacity frees up (e.g., after a paid invoice's reminders are canceled).

This is automatic — no app-level handling needed.

---

