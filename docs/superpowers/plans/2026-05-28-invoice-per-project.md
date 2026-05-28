# Invoice-per-Project Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user invoice a single project at a time (each invoice tied to one project, with an optional Scope-of-work block), plus an "Invoice all projects" shortcut — while leaving the existing client-combined path intact for the deferred recurrence flow.

**Architecture:** Purely additive. `Invoice` gains three nullable fields (`project`, `projectNameSnapshot`, `scopeOfWork`) → SwiftData lightweight migration, no migration code. `InvoiceBuilder` gains per-project `eligibleEntries` + `projectsWithEligibleEntries` + project/scope params on `createDraft`; the existing client overloads stay so `RecurrenceService` is untouched. The generator gains a Project picker + Scope field + "Invoice all"; the invoice document renders the project tag + scope when present.

**Tech Stack:** Swift 6, SwiftData, SwiftUI, Swift Testing (`@Suite`/`@Test`/`#expect`). Core in `Packages/BillableCore` (`cd Packages/BillableCore && swift test`, 239 green at start); UI in `App/Sources` (verify via `xcodebuild` + simulator). Spec: `docs/superpowers/specs/2026-05-28-invoice-per-project-design.md`.

**Worktree note:** Spec + this plan are on `main`. Create a feature branch/worktree for the code before Task 1 (the execution sub-skill prompts for this).

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `Packages/BillableCore/Sources/BillableCore/Models/Invoice.swift` | Invoice record | Add `project`/`projectNameSnapshot`/`scopeOfWork` (+ init) |
| `Packages/BillableCore/Sources/BillableCore/Invoicing/InvoiceBuilder.swift` | Build/finalize invoices | `eligibleEntries(for: project)`, `projectsWithEligibleEntries`, `createDraft` project+scope params |
| `App/Sources/Features/Invoicing/InvoiceGeneratorView.swift` | New-invoice flow | Project picker, Scope field, "Invoice all projects" |
| `App/Sources/Features/Invoicing/InvoicePreviewView.swift` | Preview + finalize | Accept + render + persist project & scope |
| `App/Sources/Features/Invoicing/InvoiceDetailView.swift` | Draft/Sent detail + PDF | Render project + scope; edit scope while Draft |
| `Packages/BillableCore/Tests/BillableCoreTests/InvoiceBuilderTests.swift` | Builder tests | New suites for per-project paths |

---

# Phase 1 — Core model & builder (BillableCore, TDD)

### Task 1: `Invoice` gains project + scope fields

**Files:**
- Modify: `Packages/BillableCore/Sources/BillableCore/Models/Invoice.swift`
- Test: `Packages/BillableCore/Tests/BillableCoreTests/InvoiceProjectFieldsTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `InvoiceProjectFieldsTests.swift`:

```swift
import Foundation
import Testing
@testable import BillableCore

@Suite("Invoice project + scope fields")
struct InvoiceProjectFieldsTests {
    private func make(project: String? = nil, scope: String? = nil) -> Invoice {
        Invoice(
            number: "INV-1", dueAt: Date(timeIntervalSince1970: 1_700_000_000),
            clientNameSnapshot: "Acme",
            issuerNameSnapshot: "Me", issuerAddressSnapshot: "", issuerEmailSnapshot: "",
            paymentTermsSnapshot: "Net 14", taxLabelSnapshot: "Tax", taxRateSnapshot: 0,
            currencyCodeSnapshot: "USD",
            projectNameSnapshot: project, scopeOfWork: scope
        )
    }

    @Test("Project + scope default to nil (client-combined / legacy invoices)")
    func defaultsNil() {
        let inv = make()
        #expect(inv.project == nil)
        #expect(inv.projectNameSnapshot == nil)
        #expect(inv.scopeOfWork == nil)
    }

    @Test("Project name + scope round-trip when set")
    func storesValues() {
        let inv = make(project: "Dashboard MVP", scope: "Build v1 dashboard")
        #expect(inv.projectNameSnapshot == "Dashboard MVP")
        #expect(inv.scopeOfWork == "Build v1 dashboard")
    }
}
```

- [ ] **Step 2: Run to verify FAIL**

Run: `cd Packages/BillableCore && swift test --filter InvoiceProjectFieldsTests`
Expected: FAIL — `projectNameSnapshot` / `scopeOfWork` are not init params yet (compile error).

- [ ] **Step 3: Add the fields + init params**

In `Invoice.swift`, add the stored properties after `public var client: Client?` (line ~72):

```swift
    /// The project this invoice is for. `nil` for client-combined invoices
    /// (recurrence materializations + legacy invoices created before per-project).
    public var project: Project?
    /// Frozen project name for rendering (mirrors `clientNameSnapshot`). `nil` = combined.
    public var projectNameSnapshot: String?
    /// Optional scope-of-work text rendered above the line items.
    public var scopeOfWork: String?
```

Add to the `init` signature (after `client: Client? = nil,`):

```swift
        client: Client? = nil,
        project: Project? = nil,
        projectNameSnapshot: String? = nil,
        scopeOfWork: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
```

And assign in the body (after `self.client = client`):

```swift
        self.client = client
        self.project = project
        self.projectNameSnapshot = projectNameSnapshot
        self.scopeOfWork = scopeOfWork
```

- [ ] **Step 4: Run to verify PASS**

Run: `cd Packages/BillableCore && swift test --filter InvoiceProjectFieldsTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Run full suite (additive — existing invoice tests unaffected)**

Run: `cd Packages/BillableCore && swift test`
Expected: PASS (existing `createDraft` callers still compile — the new params default to nil).

- [ ] **Step 6: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Models/Invoice.swift Packages/BillableCore/Tests/BillableCoreTests/InvoiceProjectFieldsTests.swift
git commit -m "feat(core): Invoice gains project + scopeOfWork fields (nullable, no migration)"
```

---

### Task 2: `InvoiceBuilder.eligibleEntries(for: project)`

**Files:**
- Modify: `Packages/BillableCore/Sources/BillableCore/Invoicing/InvoiceBuilder.swift`
- Test: `Packages/BillableCore/Tests/BillableCoreTests/InvoiceBuilderTests.swift` (append a suite)

- [ ] **Step 1: Write the failing test** — append to `InvoiceBuilderTests.swift`:

```swift
@Suite("InvoiceBuilder per-project")
@MainActor
struct PerProjectEligibleTests {
    private func fixture() throws -> (ModelContext, Client, Project, Project) {
        let container = try BillableModelContainer.inMemory()
        let context = ModelContext(container)
        let client = Client(name: "Acme")
        let a = Project(name: "Site", hourlyRate: 100, isBillable: true, client: client)
        let b = Project(name: "Brand", hourlyRate: 150, isBillable: true, client: client)
        context.insert(client); context.insert(a); context.insert(b)
        try context.save()
        return (context, client, a, b)
    }

    @Test("eligibleEntries(for: project) returns only that project's entries")
    func filtersByProject() throws {
        let (context, _, a, b) = try fixture()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let ea = TimeEntry(startedAt: t0, endedAt: t0.addingTimeInterval(3600), project: a)
        let eb = TimeEntry(startedAt: t0, endedAt: t0.addingTimeInterval(3600), project: b)
        [ea, eb].forEach(context.insert); try context.save()

        let range = InvoiceDateRange(start: t0.addingTimeInterval(-60), end: t0.addingTimeInterval(7200))
        let result = InvoiceBuilder.eligibleEntries(for: a, in: range, context: context)
        #expect(result.count == 1)
        #expect(result.first?.persistentModelID == ea.persistentModelID)
    }

    @Test("eligibleEntries(for: project) excludes non-billable / running / invoiced")
    func excludesIneligible() throws {
        let (context, _, a, _) = try fixture()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let ok = TimeEntry(startedAt: t0, endedAt: t0.addingTimeInterval(1800), project: a)
        let running = TimeEntry(startedAt: t0, endedAt: nil, project: a)
        let invoiced = TimeEntry(startedAt: t0, endedAt: t0.addingTimeInterval(900), project: a)
        invoiced.invoiceID = UUID()
        [ok, running, invoiced].forEach(context.insert); try context.save()

        let range = InvoiceDateRange(start: t0.addingTimeInterval(-60), end: t0.addingTimeInterval(7200))
        let result = InvoiceBuilder.eligibleEntries(for: a, in: range, context: context)
        #expect(result.count == 1)
        #expect(result.first?.persistentModelID == ok.persistentModelID)
    }
}
```

- [ ] **Step 2: Run to verify FAIL**

Run: `cd Packages/BillableCore && swift test --filter PerProjectEligibleTests`
Expected: FAIL — no `eligibleEntries(for: project:)` overload.

- [ ] **Step 3: Implement the overload**

In `InvoiceBuilder.swift`, add after the existing `eligibleEntries(for client:…)`:

```swift
    /// Like `eligibleEntries(for client:)` but scoped to a single `project`.
    @MainActor
    public static func eligibleEntries(
        for project: Project,
        in range: InvoiceDateRange,
        context: ModelContext
    ) -> [TimeEntry] {
        let start = range.start
        let end = range.end
        let projectID = project.persistentModelID
        guard project.isBillable else { return [] }

        let descriptor = FetchDescriptor<TimeEntry>(
            predicate: #Predicate { entry in
                entry.invoiceID == nil
                && entry.endedAt != nil
                && entry.startedAt < end
                && entry.startedAt >= start
            },
            sortBy: [SortDescriptor(\.startedAt)]
        )
        let entries = (try? context.fetch(descriptor)) ?? []
        return entries.filter { $0.project?.persistentModelID == projectID }
    }
```

- [ ] **Step 4: Run to verify PASS**

Run: `cd Packages/BillableCore && swift test --filter PerProjectEligibleTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Invoicing/InvoiceBuilder.swift Packages/BillableCore/Tests/BillableCoreTests/InvoiceBuilderTests.swift
git commit -m "feat(core): InvoiceBuilder.eligibleEntries(for: project)"
```

---

### Task 3: `InvoiceBuilder.projectsWithEligibleEntries`

**Files:**
- Modify: `Packages/BillableCore/Sources/BillableCore/Invoicing/InvoiceBuilder.swift`
- Test: `InvoiceBuilderTests.swift` (append to `PerProjectEligibleTests`)

- [ ] **Step 1: Append the failing test** (inside `PerProjectEligibleTests`):

```swift
    @Test("projectsWithEligibleEntries lists only projects that have billable time")
    func projectsWithWork() throws {
        let (context, client, a, b) = try fixture()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        // a has an entry; b has none
        context.insert(TimeEntry(startedAt: t0, endedAt: t0.addingTimeInterval(3600), project: a))
        try context.save()
        let range = InvoiceDateRange(start: t0.addingTimeInterval(-60), end: t0.addingTimeInterval(7200))
        let projects = InvoiceBuilder.projectsWithEligibleEntries(for: client, in: range, context: context)
        #expect(projects.map(\.persistentModelID) == [a.persistentModelID])
        #expect(!projects.map(\.persistentModelID).contains(b.persistentModelID))
    }
```

- [ ] **Step 2: Run to verify FAIL**

Run: `cd Packages/BillableCore && swift test --filter PerProjectEligibleTests`
Expected: FAIL — `projectsWithEligibleEntries` undefined.

- [ ] **Step 3: Implement** (in `InvoiceBuilder.swift`, after the new `eligibleEntries(for: project)`):

```swift
    /// The `client`'s non-archived projects that have ≥1 eligible entry in `range`.
    /// Sorted by name. Powers the "Invoice all projects" action and picker enablement.
    @MainActor
    public static func projectsWithEligibleEntries(
        for client: Client,
        in range: InvoiceDateRange,
        context: ModelContext
    ) -> [Project] {
        let entries = eligibleEntries(for: client, in: range, context: context)
        var seen = Set<PersistentIdentifier>()
        var projects: [Project] = []
        for entry in entries {
            guard let project = entry.project, !project.isArchived else { continue }
            if seen.insert(project.persistentModelID).inserted { projects.append(project) }
        }
        return projects.sorted { $0.name < $1.name }
    }
```

- [ ] **Step 4: Run to verify PASS**

Run: `cd Packages/BillableCore && swift test --filter PerProjectEligibleTests`
Expected: PASS (3 tests in the suite now).

- [ ] **Step 5: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Invoicing/InvoiceBuilder.swift Packages/BillableCore/Tests/BillableCoreTests/InvoiceBuilderTests.swift
git commit -m "feat(core): InvoiceBuilder.projectsWithEligibleEntries"
```

---

### Task 4: `createDraft` accepts project + scope

**Files:**
- Modify: `Packages/BillableCore/Sources/BillableCore/Invoicing/InvoiceBuilder.swift`
- Test: `InvoiceBuilderTests.swift` (append a suite)

- [ ] **Step 1: Write the failing test** — append:

```swift
@Suite("InvoiceBuilder.createDraft project + scope")
@MainActor
struct CreateDraftProjectTests {
    private func setup() throws -> (ModelContext, BusinessProfile, Client, Project) {
        let container = try BillableModelContainer.inMemory()
        let context = ModelContext(container)
        let profile = BusinessProfile(invoiceNumberPrefix: "INV-", nextInvoiceNumber: 5)
        let client = Client(name: "Acme")
        let p = Project(name: "Dashboard MVP", hourlyRate: 175, client: client)
        context.insert(profile); context.insert(client); context.insert(p)
        try context.save()
        return (context, profile, client, p)
    }
    private let items = [InvoiceLineItem(description: "Work", hours: 2, hourlyRate: 175)]

    @Test("createDraft with project sets project, snapshot, and scope")
    func setsProjectAndScope() throws {
        let (context, profile, client, p) = try setup()
        let inv = try InvoiceBuilder.createDraft(
            for: client, lineItems: items, project: p, scopeOfWork: "Build v1",
            profile: profile, context: context
        )
        #expect(inv.project?.persistentModelID == p.persistentModelID)
        #expect(inv.projectNameSnapshot == "Dashboard MVP")
        #expect(inv.scopeOfWork == "Build v1")
    }

    @Test("createDraft without project leaves project/snapshot/scope nil (combined path)")
    func combinedStaysNil() throws {
        let (context, profile, client, _) = try setup()
        let inv = try InvoiceBuilder.createDraft(
            for: client, lineItems: items, profile: profile, context: context
        )
        #expect(inv.project == nil)
        #expect(inv.projectNameSnapshot == nil)
        #expect(inv.scopeOfWork == nil)
    }
}
```

- [ ] **Step 2: Run to verify FAIL**

Run: `cd Packages/BillableCore && swift test --filter CreateDraftProjectTests`
Expected: FAIL — `createDraft` has no `project:`/`scopeOfWork:` params.

- [ ] **Step 3: Add the params to `createDraft`**

In `InvoiceBuilder.createDraft(...)`, add to the signature (after `for client: Client,`):

```swift
    public static func createDraft(
        for client: Client,
        lineItems: [InvoiceLineItem],
        project: Project? = nil,
        scopeOfWork: String? = nil,
        notes: String? = nil,
        issuedAt: Date = .now,
        profile: BusinessProfile,
        context: ModelContext
    ) throws -> Invoice {
```

And pass them into the `Invoice(...)` constructor (add after `client: client,`):

```swift
            client: client,
            project: project,
            projectNameSnapshot: project?.name,
            scopeOfWork: scopeOfWork
```

(Leave everything else in `createDraft` unchanged. Existing callers that omit `project`/`scopeOfWork` get nil — the recurrence/combined path is unaffected.)

- [ ] **Step 4: Run to verify PASS**

Run: `cd Packages/BillableCore && swift test --filter CreateDraftProjectTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Full suite incl. recurrence regression**

Run: `cd Packages/BillableCore && swift test`
Expected: PASS — especially the existing `FinalizeAndSendTests`, `InvoiceBuilderTaxIDTests`, and any `RecurrenceService` tests (combined path unchanged).

- [ ] **Step 6: Commit**

```bash
git add Packages/BillableCore/Sources/BillableCore/Invoicing/InvoiceBuilder.swift Packages/BillableCore/Tests/BillableCoreTests/InvoiceBuilderTests.swift
git commit -m "feat(core): createDraft accepts project + scopeOfWork (defaults nil)"
```

---

# Phase 2 — Generator UI

**Simulator setup (reused):**
```bash
xcodebuild -project Billable.xcodeproj -scheme Billable -configuration Debug \
  -destination 'id=A946AE5D-C969-4EB2-8384-001B3451A6A4' -derivedDataPath build/DerivedData build
xcrun simctl install A946AE5D-C969-4EB2-8384-001B3451A6A4 build/DerivedData/Build/Products/Debug-iphonesimulator/Billable.app
xcrun simctl launch A946AE5D-C969-4EB2-8384-001B3451A6A4 com.eldenstudios.billable --seed-marketing --reset-store
```

### Task 5: Project picker + Scope field in the generator

**Files:**
- Modify: `App/Sources/Features/Invoicing/InvoiceGeneratorView.swift`
- Modify: `App/Sources/Features/Invoicing/InvoicePreviewView.swift`

- [ ] **Step 1: Add state + project-scoped line items**

In `InvoiceGeneratorView`, add state (near `@State private var selectedClient`):

```swift
    @State private var selectedProject: Project?
    @State private var scopeOfWork: String = ""
```

Replace `eligibleEntries` and `canPreview` so they key off the project:

```swift
    private var eligibleEntries: [TimeEntry] {
        guard let project = selectedProject else { return [] }
        return InvoiceBuilder.eligibleEntries(for: project, in: resolvedRange, context: modelContext)
    }

    private var canPreview: Bool {
        selectedClient != nil && selectedProject != nil && profile != nil && !lineItems.isEmpty
            && Self.canSendInvoice(profile: profile)
    }
```

Reset the project when the client changes (add `.onChange` to the client menu selection or after `selectedClient = client` in `clientPicker`): set `selectedProject = nil`.

- [ ] **Step 2: Add a Project section + Scope field to the form**

After the `Section("Client")` block, add:

```swift
                Section("Project") {
                    if let client = selectedClient {
                        let projects = client.projects.filter { !$0.isArchived }.sorted { $0.name < $1.name }
                        if projects.isEmpty {
                            Text("This client has no active projects.").foregroundStyle(.secondary)
                        } else {
                            Picker("Project", selection: $selectedProject) {
                                Text("Choose").tag(Project?.none)
                                ForEach(projects) { p in Text(p.name).tag(Project?.some(p)) }
                            }
                        }
                    } else {
                        Text("Pick a client first.").foregroundStyle(.secondary)
                    }
                }

                Section("Scope of work (optional)") {
                    TextField("e.g. Build the v1 analytics dashboard", text: $scopeOfWork, axis: .vertical)
                        .lineLimit(2...6)
                }
```

- [ ] **Step 3: Pass project + scope to the preview**

In the `.sheet(isPresented: $showingPreview)`, pass the new values:

```swift
                    InvoicePreviewView(
                        client: client,
                        project: selectedProject,
                        profile: profile,
                        lineItems: lineItems,
                        sourceEntries: eligibleEntries,
                        scopeOfWork: scopeOfWork.isEmpty ? nil : scopeOfWork,
                        notes: notes.isEmpty ? nil : notes,
                        onDone: { dismiss() }
                    )
```

- [ ] **Step 4: Thread project + scope through `InvoicePreviewView`**

In `InvoicePreviewView`, add stored props `let project: Project?` and `let scopeOfWork: String?` (next to `client`). At every `InvoiceBuilder.createDraft(...)` call site (there are two — search for `createDraft(`), add `project: project, scopeOfWork: scopeOfWork,` to the arguments. (Don't change finalize logic.)

- [ ] **Step 5: Build + run**

Build/install/launch (Simulator setup). 
Expected: BUILD SUCCEEDED. New-invoice form shows Client → Project → Scope; preview/send works for the chosen project only.

- [ ] **Step 6: Verify on the simulator (screenshot)**

```bash
xcrun simctl io A946AE5D-C969-4EB2-8384-001B3451A6A4 screenshot /tmp/inv_generator.png
```
Open New invoice, pick Apex Analytics → Dashboard MVP, type a scope. Confirm only that project's hours show, and Preview renders. Read the screenshot.

- [ ] **Step 7: Commit**

```bash
git add App/Sources/Features/Invoicing/InvoiceGeneratorView.swift App/Sources/Features/Invoicing/InvoicePreviewView.swift
git commit -m "feat(invoicing): project picker + scope field in the generator"
```

---

### Task 6: "Invoice all projects" action

**Files:**
- Modify: `App/Sources/Features/Invoicing/InvoiceGeneratorView.swift`

- [ ] **Step 1: Add the action + a result alert**

Add state: `@State private var invoiceAllResult: Int?`. Add a method:

```swift
    @MainActor
    private func invoiceAllProjects() {
        guard let client = selectedClient, let profile else { return }
        let projects = InvoiceBuilder.projectsWithEligibleEntries(for: client, in: resolvedRange, context: modelContext)
        var created = 0
        for project in projects {
            let entries = InvoiceBuilder.eligibleEntries(for: project, in: resolvedRange, context: modelContext)
            let items = InvoiceBuilder.buildLineItems(from: entries, grouping: grouping)
            guard !items.isEmpty else { continue }
            if (try? InvoiceBuilder.createDraft(
                for: client, lineItems: items, project: project,
                scopeOfWork: nil, notes: notes.isEmpty ? nil : notes,
                profile: profile, context: modelContext
            )) != nil { created += 1 }
        }
        invoiceAllResult = created
    }
```

- [ ] **Step 2: Add the button (in the Project section, when a client is chosen)**

```swift
                    if let client = selectedClient,
                       !InvoiceBuilder.projectsWithEligibleEntries(for: client, in: resolvedRange, context: modelContext).isEmpty {
                        Button { invoiceAllProjects() } label: {
                            Label("Invoice all projects (separate drafts)", systemImage: "doc.on.doc")
                        }
                    }
```

Add the result alert to the form:

```swift
            .alert("Drafts created", isPresented: Binding(get: { invoiceAllResult != nil }, set: { if !$0 { invoiceAllResult = nil } })) {
                Button("OK") { invoiceAllResult = nil; dismiss() }
            } message: {
                Text("Created \(invoiceAllResult ?? 0) draft invoice(s) — one per project with billable time. Open each from Invoices to add a scope and send.")
            }
```

- [ ] **Step 3: Build + run + verify**

Build/install/launch. With the seeded data (Apex Analytics has 2 projects with time), tap "Invoice all projects" → alert reports the count → Invoices tab shows that many new Drafts, each tagged with its project.
```bash
xcrun simctl io A946AE5D-C969-4EB2-8384-001B3451A6A4 screenshot /tmp/inv_all.png
```
Read the screenshot.

- [ ] **Step 4: Commit**

```bash
git add App/Sources/Features/Invoicing/InvoiceGeneratorView.swift
git commit -m "feat(invoicing): Invoice all projects → one draft per project"
```

---

# Phase 3 — Invoice rendering (client-facing)

### Task 7: Render the project tag + Scope block; edit scope while Draft

**Files:**
- Modify: `App/Sources/Features/Invoicing/InvoicePreviewView.swift`
- Modify: `App/Sources/Features/Invoicing/InvoiceDetailView.swift`

> The invoice document is the client-facing artifact. Implement the structure below, then **use the frontend-design skill** to polish the project tag + scope block to match the approved mockup (`.superpowers/brainstorm/72360-*/content/invoice-b-refined.html`): a project tag under Bill-to and a highlighted "Scope of work" block above the line-items table. Report the rendered look back for sign-off.

- [ ] **Step 1: Read both views fully**

Read `InvoicePreviewView.swift` and `InvoiceDetailView.swift` to find the shared invoice-document layout (header / bill-to / line-items table) and the PDF render path (`pdfDataCached` / `ensurePDFData`).

- [ ] **Step 2: Render project tag + scope (only when present)**

Wherever the document renders the Bill-to / before the line-items table, add (guarding on the invoice's fields):

```swift
            if let projectName = invoice.projectNameSnapshot {
                HStack(spacing: 6) {
                    Circle().fill(invoice.clientColor.swiftUIColor).frame(width: 8, height: 8)
                    Text(projectName).font(.subheadline.weight(.semibold))
                }
            }
            if let scope = invoice.scopeOfWork, !scope.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("SCOPE OF WORK").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                    Text(scope).font(.subheadline).italic()
                }
                .padding(10)
                .background(.yellow.opacity(0.12), in: .rect(cornerRadius: 8))
            }
```

(For the preview-before-send case in `InvoicePreviewView`, use the local `project?.name` / `scopeOfWork` props passed in Task 5 instead of `invoice.*`, since the Invoice isn't created until finalize.)

- [ ] **Step 3: Edit scope while Draft (InvoiceDetailView)**

In `InvoiceDetailView`, when `invoice.status == .draft`, render an editable scope `TextField` bound to `invoice.scopeOfWork` (empty-string ↔ nil), saving via the view's existing `modelContext.saveOrLog(...)` pattern and invalidating the cached PDF (`invoice.pdfDataCached = nil`) so it regenerates. When not Draft, render scope read-only.

- [ ] **Step 4: Ensure the PDF picks up the new fields**

Confirm the PDF render path reads the same document view (so project + scope appear in the shared/exported PDF). If the PDF caches, clear `pdfDataCached` when scope changes (Step 3).

- [ ] **Step 5: Build + run + verify (look at screenshots)**

Build/install/launch. Generate a per-project invoice with a scope → Preview shows the project tag + scope block → Send → open from Invoices → detail + shared PDF show them. Generate a recurrence/combined draft (or view a legacy invoice) → confirm NO project tag/scope (renders as before).
```bash
xcrun simctl io A946AE5D-C969-4EB2-8384-001B3451A6A4 screenshot /tmp/inv_render.png
```
Read the screenshot. **Then run the frontend-design polish pass and capture the final look for the user.**

- [ ] **Step 6: Commit**

```bash
git add App/Sources/Features/Invoicing/InvoicePreviewView.swift App/Sources/Features/Invoicing/InvoiceDetailView.swift
git commit -m "feat(invoicing): render project tag + scope-of-work block; edit scope while draft"
```

---

# Phase 4 — Verification

### Task 8: Full sweep + recurrence regression

- [ ] **Step 1: Full BillableCore suite**

Run: `cd Packages/BillableCore && swift test`
Expected: PASS (existing 239 + new per-project/createDraft/model tests). Confirm recurrence-related suites pass (combined path unchanged).

- [ ] **Step 2: Debug + Release builds, zero warnings**

```bash
xcodebuild -project Billable.xcodeproj -scheme Billable -configuration Debug -destination 'id=A946AE5D-C969-4EB2-8384-001B3451A6A4' build
xcodebuild -project Billable.xcodeproj -scheme Billable -configuration Release -destination 'id=A946AE5D-C969-4EB2-8384-001B3451A6A4' build
```
Expected: BUILD SUCCEEDED, no new warnings (repo bar = zero warnings).

- [ ] **Step 3: UI smoke tests**

```bash
xcodebuild -project Billable.xcodeproj -scheme Billable -destination 'id=A946AE5D-C969-4EB2-8384-001B3451A6A4' -only-testing:BillableUITests test
```
Expected: 5/5 pass.

- [ ] **Step 4: End-to-end manual flow (screenshots)**

Launch with `--seed-marketing --reset-store`. Verify: New invoice → pick client → pick one project → scope → Preview (project tag + scope visible) → Send. "Invoice all projects" → N drafts, each project-tagged. Edit a draft's scope. Confirm the **Recurring** path still materializes a client-combined draft (no project tag) via the Catch-Up banner.

- [ ] **Step 5: Commit (if any verification fixups)**

```bash
git add -A && git commit -m "test(invoicing): verification sweep for invoice-per-project"
```

---

## Self-Review

- **Spec coverage:** §4 model (Task 1) · §5 model fields (Task 1) · §6 generator flow + scope + Invoice-all (Tasks 5, 6) · §7 builder eligibleEntries(project)/projectsWithEligibleEntries/createDraft params (Tasks 2, 3, 4) · §8 recurrence retained (Task 4 Step 5 regression; Task 8) · §9 rendering + scope editable while Draft (Task 7) · §10 edge cases (Tasks 2, 3, 6 empty-project guards) · §11 testing (each task + Task 8). All covered.
- **Type consistency:** `eligibleEntries(for: project:in:context:)`, `projectsWithEligibleEntries(for:in:context:)`, `createDraft(for:lineItems:project:scopeOfWork:notes:issuedAt:profile:context:)`, `Invoice.project`/`projectNameSnapshot`/`scopeOfWork`, `InvoicePreviewView(client:project:profile:lineItems:sourceEntries:scopeOfWork:notes:onDone:)` — consistent across tasks.
- **Risk note:** UI tasks verified by build + simulator (repo convention). Invoice-document visual polish delegated to frontend-design with user sign-off, per the user's emphasis on presentation.
