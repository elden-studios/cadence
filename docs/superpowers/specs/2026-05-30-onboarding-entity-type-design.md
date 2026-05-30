# Onboarding Entity-Type Setup + Business Profile — Design Spec

- **Date:** 2026-05-30
- **Branch:** `feature/onboarding-entity-type` (forked from `feature/project-detail-ia` @ `692b9e4`)
- **Status:** **v5 — hardened by three review rounds** (R1: logic/product/market/engineering/UI-UX; R2: +security/resilience/i18n/analytics/maintainability; R3: 8-lens confirmation that tightened §8 reconciliation). All blockers + majors folded in.
- **Market context:** US-first, distributed on the App Store; **English-only by product decision** — the release is English-only and localization is out of scope (see §11).
- **Confidence:** v3 ~70%; v4 ~95% claim was over-confident — R3 found §8 reconciliation under-specified (resilience 58%, logic 72%). This v5 tightens §8 and the loose ends; honest design target ~93%, with the last few % on multi-device reconciliation deliberately deferred to TDD (see §15).

## 1. Goal

Profile-first onboarding: `welcome → choose Freelancer/Organization (framed by how you bill) + enter name → land on Today`. On Today, guide to first value via a **2-step setup checklist + one-tap "Start a timer now" quick-start**, then a well-timed enrichment prompt. Plus a dev-credit fix. Entity type shapes form labels + tax-section default in onboarding and Settings.

## 2. Background (verified)

- **Onboarding** ([OnboardingView.swift](../../../App/Sources/Features/Onboarding/OnboardingView.swift)) — 3 steps today; creates a profile (fetch-or-create), Client, Project, running TimeEntry. Tagline `Text("Track hours.\nSend invoices.")`; prompts at `white.opacity(0.3)`.
- **`BusinessProfile`** — CloudKit-mirrored `@Model` ([ModelContainer+Billable.swift:17]); has `createdAt`. **Singleton assumed, NOT enforced** — `profiles.first` read in ~12 sites; no `.unique`. Enum convention = raw `String` + accessor (`Client.colorRaw`, `Invoice.statusRaw`).
- **`saveOrLog`** ([ModelContext+SaveOrLog.swift]) is **fire-and-forget** (catches, logs `fileID/line/context/error.localizedDescription` — no PII — returns void). Cannot gate "set flag only on success."
- **`TimerService.start`** enforces "≤1 running entry" (no-ops same project; finalizes any other) — dedupes *timers*, NOT project inserts.
- **`Project.client` is optional**; `Client.projects` and `Project.entries` are `deleteRule: .cascade` (deleting a client deletes its projects + their time entries).
- **`OnboardingFlags.shouldShow`** evaluated once in `RootView.onAppear`; `--ui-test-show-onboarding` force-shows.
- **No analytics anywhere** (privacy.md: "no analytics pipelines… no error-reporting"); StoreKit is subscription-only; no `PrivacyInfo.xcprivacy`; no Data-Protection entitlement.
- **No localization infra** — zero `String(localized:)`/`.xcstrings`; `knownRegions = en`.

## 3. Locked decisions (incl. user choices)

1. **Profile-first onboarding**, keep the **Freelancer/Organization choice** framed by *how you bill*.
2. **First-run = Hybrid:** Today shows a **2-step checklist** (Add a client → Create a project) **and** a **"Start a timer now" quick-start**.
3. **Tax universal & OFF by default**; entity type changes only labels + default tax-section visibility.
4. **Completion + first-run progress = one-way persisted latches** on `BusinessProfile` (not a clearable name, not a device-local-only flag).
5. **Singleton: deterministic oldest-wins reads + on-launch reconciliation** (the duplicate-profile risk is now user-visible, so it's in-scope, not deferred).
6. **One guidance element at a time** on Today (§7).
7. Existing users default to Organization-style labels.
8. Dev credit → `"Elden Studios Company"`.

## 4. Data model

`Models/EntityType.swift` (BillableCore):
```swift
public enum EntityType: String, Codable, CaseIterable, Sendable {
    case freelancer, organization
    public var showsTaxByDefault: Bool { self == .organization }   // policy on enum; STRINGS live in the view layer (§6/§11)
}
```

`BusinessProfile` additions (all mirrored, additive non-optional-default or optional → lightweight-migration-safe; `createdAt` already exists):
```swift
public var entityTypeRaw: String = EntityType.organization.rawValue   // legacy default preserves "Business name" + visible tax
public var entityType: EntityType { get { .init(rawValue: entityTypeRaw) ?? .organization } set { entityTypeRaw = newValue.rawValue } }

// One-way first-run latches (never unset). Stamped by ONE owner (§7), never inside views. Double as activation metrics (§14).
public var onboardingCompletedAt: Date? = nil    // set once in finish()
public var firstSetupCompletedAt: Date? = nil    // stamped once (see §7 writer) when a Client AND a client-linked non-archived Project first coexist

// Derived — peer to hasBankDetails/hasTaxID/canSendInvoice. The gating input for the §7b enrichment prompt + the §6 Settings "Incomplete" hint. (R3 flagged it as referenced-but-undefined; defined here.)
public var isProfileEnriched: Bool {
    !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && hasBankDetails
}
```
- `init` gains defaulted params → all existing call sites + ~15 tests compile unchanged.
- **`entityType` default `.organization`** is a *back-compat fallback only*; onboarding always sets it explicitly. The editor's `newProfile()` is the rare exception and its always-visible picker (§6) is the correction point.

## 5. Onboarding flow

`Step = welcome → identity`. **Drop the 2-dot progress indicator** (over-instrumented + the `0..<3`/`<=` fill bug); drop `arrow.right` from the single CTA. Slide animation gated on `accessibilityReduceMotion`; CTA in safe area; **wrap content in a `ScrollView`**.

**Welcome:** unchanged; **preserve the tagline verbatim** (`LaunchTaglineUITests`). Subtitle → "Made for freelancers and small businesses."

**Identity screen:** two descriptive selectable cards, copy framed by how-you-bill (translation-shaped — one clause, em-dash, no contractions/idioms):
- **Freelancer** — `person.fill` — "Just me — I bill for my own time."
- **Organization** — `building.2.fill` — "A team — we bill under one company name."
- ≥56pt, 12pt gap; selected = accent border + checkmark + fill (not color-alone); each a `Button` with `accessibilityLabel`/`Hint` + `.isSelected` **trait**. Pre-select Freelancer.
- **Name field:** visible caps label from the shared `EntityType+Presentation` mapping (§6); prompt **`opacity ≥ 0.55`** (0.3 = 2.6:1 fails WCAG); `textContentType .name`/`.organizationName`; `.words`; `.submitLabel(.done)` + `onSubmit { finish() }`. **Do not auto-focus on appear** (would hide the cards); focus after a type is chosen.
- One CTA "Finish setup" (enabled when trimmed name non-empty).

**`finish()` — crash-safe, throwing save (fixes blockers):**
```
1. Fetch the canonical profile (sortBy createdAt asc, fetchLimit 1). If present → mutate; else → insert defaultForCurrentLocale(). NEVER call defaultForCurrentLocale() on the exists path.
2. profile.name = trimmedName; profile.entityType = selectedType.
3. do { try modelContext.save() } catch { present "Couldn't save — try again"; RETURN without step 4. }
4. profile.onboardingCompletedAt = .now; try? save; set UserDefaults fast-path flag; onFinish().
```
- Create no Client/Project/TimeEntry here.
- **`OnboardingFlags.shouldShow` = false** when any `BusinessProfile.onboardingCompletedAt != nil` (syncs cross-device) OR the local fast-path flag is set. **DELETE the legacy `clientCount == 0` branch** (the new flow no longer seeds a client, so it would falsely re-trigger onboarding — R3). **Re-evaluate in `RootView`'s existing `.onChange(of: scenePhase) where .active` block** (the same seam that already runs `BadgeCount.compute`), not just `onAppear`. Reject saving a **blank** profile name in the editor (trim-and-reject).

## 6. Business Profile editor (Settings)

- Segmented entity `Picker` at the top of Issuer; footer explains the difference.
- **Shared `EntityType+Presentation.swift`** (App target) maps entity → name label + tax-ID label, used by BOTH onboarding and the editor (DRY; English literals today — see §11).
- Freelancer tax = collapsed `DisclosureGroup` "Add tax (if you charge it)"; **auto-expand if a non-zero rate exists**. Organization: expanded.
- **Harden financial fields** (IBAN/SWIFT/tax-ID): `.keyboardType(.asciiCapable)` + `.textContentType(nil)` (no keyboard-learning/AutoFill of identifiers; NOT `SecureField` — user must verify their own IBAN).
- Settings row: render **"Incomplete"** as its own `Text` (not a `"· "`-glued fragment) when `!isProfileEnriched`.

## 7. Today guidance — one element at a time

Precedence resolved by a **pure, read-only `TodayGuidance.resolve(...)` enum in BillableCore** (unit-tested, mirrors `BadgeCount`), from booleans the view computes:
1. `!canSendInvoice` (name missing, rare) → name-warning banner.
2. `onboardingCompletedAt != nil && firstSetupCompletedAt == nil` → **Get-started block**.
3. `firstSetupCompletedAt != nil && !isProfileEnriched && !snoozedThisSession` → enrichment nudge.
4. else → none.

The clientless quick-start "General" does **not** set `firstSetupCompletedAt`, so quick-start users keep the checklist (instant value + still guided). Archiving/deleting later never resurrects first-run (latch is one-way).

**`firstSetupCompletedAt` has exactly ONE writer (R3 fix):** a `@MainActor` `BusinessProfile.stampFirstSetupIfReached(in:)`, guarded by `firstSetupCompletedAt == nil`, run from the **same launch + `scenePhase==.active` seam as §8 reconciliation** (so it also fires when a Client/Project arrive via CloudKit, or were made in the Work/Clients tabs). It is NOT stamped inside `TodayGuidance.resolve` (which stays pure) nor sprinkled across create sites. After §8 dedup it is **re-derived from the surviving Client/Project data**, not copied blindly.

### 7a. Get-started block — its own view `Features/Today/GetStartedSection.swift`
- **One PRIMARY CTA (R3 UI/UX):** "Start a timer now" is the single filled/accent primary (one tap to value). The checklist rows are **secondary** (tinted/plain) — the surface must not ship two co-equal primaries.
- **2-row checklist** (progress visible): Row 1 "Add a client" (`circle` → `checkmark.circle.fill` once any client exists) presents `ClientEditorView(client:nil)`; Row 2 "Create a project" is **disabled until a client exists** (VoiceOver hint "Add a client first"), then presents the existing add-project sheet (`ProjectEditorView` via the New-Project flow). Reuses Today's existing `allClients` `@Query` (no second client query).
- **Quick-start action:** **fetch-or-create** a single canonical `Project(name:"General", client:nil, !isArchived)` (probe, `fetchLimit 1` — reuse if present), then `TimerActions.start(...)`. **Debounce** via `@State startingQuickTimer` (disable + "Starting…" feedback while in flight) to prevent a same-frame double-insert.
- **Acknowledge the action (R3 UI/UX):** while a timer runs, the block header reframes "Get started" → "Timer running — add a client to invoice this time," so the tap produces a visible in-block change even though the latch is intentionally unset.
- **0-rate guidance (R3 product):** the "General" project is rate-0 and the existing 0-rate warning lives only in `ProjectEditorView`, which quick-start **bypasses** — so surface an inline **"Set your rate"** affordance on the running-timer row when its project rate is 0 (→ `ProjectEditorView`). "General" is explicitly a scratchpad; earnings need a rate or a real project.
- Existence checks use **bounded probes** (`fetchCount`/`fetchLimit 1`), never an unbounded `@Query var allProjects`.

### 7b. Enrichment prompt — re-timed
- **Primary at invoice creation:** opening the generator with `!isProfileEnriched` surfaces an inline "Add your address & payment details so this invoice looks complete" → editor (conditional copy if only one half is missing).
- **Secondary Today nudge** (tier 3): info card (icon+text), dismiss = **session-only `@State` "Not now"** (no cross-device flag); `isProfileEnriched` is the durable driver. Close control ≥44pt, `accessibilityLabel("Dismiss")`. (Note: session = until the view is rebuilt.)

## 8. Singleton reconciliation (resilience, in-scope — R3 hardened)

Duplicate `BusinessProfile`s are a real multi-device CloudKit hazard, and `.unique` is **not supported by the CloudKit mirror**, so reconciliation (not a constraint) is the standard fix. R3 found v4's one-line version under-specified and data-losing; this is the tightened design. It **clones the already-shipping, tested `TimerService.reconcileActiveSessionOnLaunch` pattern** (a `@MainActor` static repair wired in `BillableApp.performStartupWiring()` with its own test file) — **not** a new remote-change observer.

- **Deterministic reads (R3-BLOCKER — a `@Query` can't use a helper):** add `sort: \BusinessProfile.createdAt` (ascending) to **all ~12 `@Query private var profiles` sites** (TodayView ×2, SettingsView, InvoiceGeneratorView, BusinessProfileEditorView, WorkView, ReportsView, ProjectDetailView, ClientDetailView, CurrencyPickerView, PaymentRemindersView, StartTimerSheet) so `profiles.first` is the oldest. **Tie-break on the stable `persistentModelID`** when `createdAt` is equal (offline dup-creation can tie). **`max()`-guard `nextInvoiceNumber` at finalize** so an un-reconciled session can't collide invoice numbers.
- **Reconcile (`BusinessProfile.reconcile(in:)`) on launch (`performStartupWiring`) + `scenePhase==.active`** — existing seams, converges at next foreground, no new infra. `@MainActor`, **idempotent** (re-run = no-op):
  - **Survivor** = oldest `createdAt` (tie-break `persistentModelID`).
  - **Per-field merge (NOT "oldest wins, copy missing" — that destroyed newer data, R3-BLOCKER):** user fields (`name`, `entityType`, address, email, phone, `bank*`, `tax*`, `logoData`, templates) → **latest `updatedAt` wins**; `nextInvoiceNumber` → **`max()`** across duplicates (never regress); latches → **earliest non-nil** (fill, never clear), then **re-derive `firstSetupCompletedAt`** from surviving Client/Project data; `createdAt` → survivor's.
  - **Safe delete (R3-BLOCKER):** merge into survivor, then delete extras **only when the duplicate count is stable across two consecutive checks** and each `createdAt` has materialized; never hard-delete a record whose `createdAt` can't yet be compared. `BusinessProfile` has **no inbound `@Relationship`** (verified) → deleting a duplicate orphans nothing.
- Full `@Attribute(.unique)` (needs a `VersionedSchema` baseline + is CloudKit-incompatible anyway) stays a tracked follow-up. The hand-written merge carries a **field-merge-completeness** test guard (§16/§17).

## 9. Accessibility (cross-cutting)

Prompt contrast ≥0.55 (specified fix). Touch ≥44pt / spacing ≥8pt. Entity cards expose `.isSelected` trait; checklist rows announce state. Dynamic Type without truncation (verify SE-size + keyboard up for occlusion). Reduced motion on transitions. Verify light/dark for Today cards.

## 10. Invoice / PDF impact

None to tax/PDF math. The §7b invoice-time prompt is additive generator UI. No change to `Invoice`/`InvoiceBuilder`/`InvoiceTemplate`.

## 11. Localization posture

**Product decision (confirmed by owner): Cadence ships ENGLISH-ONLY to the App Store. Localization is not planned for this release and is explicitly out of scope.** No String Catalog; `knownRegions = en`. New strings are plain English literals, centralized in `EntityType+Presentation` + the views (centralization is for DRY/maintainability, not i18n). Copy is still written translation-shaped (single clause, no glued fragments, no `x ? "" : "s"` plurals) as zero-cost future insurance — no further i18n work in scope. Currency/number/date formatting is already locale-correct (`.currency(code:)`, `.number`, `.dateTime`), which is independent of UI-string localization. RTL is not in scope.

## 12. Developer credit fix

[SettingsView.swift:111] → `"Elden Studios Company"`; update [SettingsAboutUITests.swift:30-31]. ("Business" reads more US-natural than "Organization" — swappable later.)

## 13. Security / privacy (release-gates)

- **Add `PrivacyInfo.xcprivacy`** (app + widget + BillableCore bundle): `NSPrivacyTracking=false`, required-reason codes (UserDefaults, file-timestamp), collected types (name/address/email/phone/payment/financial, Linked=false, Tracking=false). **App Store gate.**
- **Set Data-Protection entitlement** `NSFileProtectionCompleteUntilFirstUserAuthentication` (can't use `Complete` — widget reads the App-Group store while locked); document why.
- Runtime data-handling of the *new* code is clean (no PII logging; no new egress). Tracked follow-ups (not this PR): CSV temp-file cleanup; stop replicating the full profile into widget scope (mirror only `currencyCode`).

## 14. How we measure success (was missing)

Activation is the redesign's justification, so make it observable without breaking the privacy stance:
- **Tier 0 (free, do BEFORE shipping — the baseline is destroyed on release):** snapshot App Store Connect → App Analytics D1/D7/D28 retention, sessions/active device, deletions, crashes (trailing 4–8 wks). Validation is **sequential before/after, not A/B** (one onboarding per version) — state this honestly.
- **Tier 1 (½ day, on-device, no transmission — within privacy.md):** derive from existing SwiftData + the new latches/`createdAt`: entity-type split, activation-reached (first TimeEntry), time-to-first-timer/project/invoice, quick-start-vs-checklist, enrichment conversion (Today vs invoice-time).
- **Tier 1 readout (R3 — close the loop):** surface Tier-1 via a `#if DEBUG` diagnostics row (no UI polish, no persistence, no egress). Headline = **quick-start-vs-checklist activation split** (`Project.client == nil` on the earliest-entry project) — the direct answer to "did the hybrid bet pay off." No `firstInvoiceAt` latch needed (derivable from `Invoice.createdAt`).
- **Tier 2 (opt-in minimal telemetry):** **out of scope — owner confirmed privacy-pure** (Tier 0 + 1 only; no data leaves the device; no change to `privacy.md`).

## 15. Confidence & residual risk

Three rounds drove this from v2's over-confident 95% claim through honest re-scoring (v3 ~70%; v4 found resilience 58% / logic 72% because v4's OWN §8 was loose) to this v5, which tightens §8 (per-field merge table, deterministic sorted reads, safe idempotent delete) and — crucially — reuses the **already-shipping** `reconcileActiveSessionOnLaunch` pattern rather than new infra, plus defines `isProfileEnriched`, names the latch writer, fixes the 0-rate gap, and designates one primary CTA.

**Honest design confidence ~93%.** The remaining gap sits in one place: **multi-device singleton reconciliation correctness is a distributed-systems property prose cannot fully prove — it must be demonstrated by tests.** That's not a spec failure; the right way to reach AND prove 95% is the §16 TDD matrix (both-non-empty merge preserves newer name/counter; concurrent reconcile → exactly one survivor, never zero; latch re-derive), not a 4th review round — spec-only review has hit clear diminishing returns here.

Other residual:
- **Release-gates (must be executed):** `PrivacyInfo.xcprivacy`, Data-Protection entitlement, **CloudKit reinstall smoke test** (TESTING.md), ASC baseline snapshot before ship.
- Implementation-time on-device checks (Dynamic Type max, SE keyboard occlusion, light/dark, *measured* contrast ratios).
- Forks active `feature/project-detail-ia` (does NOT edit `TodayView` — verified); real merge risk is the onboarding-no-longer-seeds-a-project contract change — coordinate on rebase.
- Cascade-delete of a client still destroys its projects + time entries; a delete-confirmation showing affected counts is a tracked fast-follow (§17).

## 16. Testing

Unit (BillableCore): `EntityType` round-trip/`Codable`; profile default; one-way latch setters; `isProfileEnriched` truth table; `canSendInvoice` unaffected; back-compat init; **`TodayGuidance.resolve` precedence (unit, not UI)**; **`stampFirstSetupIfReached` guard** (no-op if set; re-derives).
- **Migration round-trip — gating, ON-DISK** (write an old-schema store to a temp URL, reopen new, assert defaults; in-memory passes vacuously — R3).
- **Reconciliation matrix (R3):** (a) both-non-empty conflict → survivor keeps **latest-`updatedAt`** name/entityType + **`max()`** `nextInvoiceNumber` (no data loss / no counter regress); (b) concurrent reconcile → **exactly one survivor, never zero**; (c) latches nil pre-merge but client+project exist → `firstSetupCompletedAt` re-derived; (d) field-merge-completeness guard (fails if a new stored property lacks a merge line).
UI: Freelancer/Org labels; **checklist reactivity** (add client → row 1 advances, row 2 enables); **quick-start** (double-tap → ONE "General" + running timer; header reframes); **enrichment precedence** (exactly one element shows); `SettingsAboutUITests` updated; `LaunchTaglineUITests` preserved; `InvoicePreviewLineItemEditUITests` unaffected.

## 17. Out of scope (YAGNI)

Per-entity templates; region/auto tax; multiple profiles; forced re-onboarding; entity type on invoices; `.unique`/`VersionedSchema`; broad localization; Tier-2 telemetry; CSV/widget-scope hardening (tracked follow-ups).
