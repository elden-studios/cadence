# Onboarding Entity-Type Setup + Business Profile — Design Spec

- **Date:** 2026-05-30
- **Branch:** `feature/onboarding-entity-type` (forked from `feature/project-detail-ia` @ `692b9e4`)
- **Status:** **v4 — hardened by two 5-lens review rounds** (R1: logic/product/market/engineering/UI-UX; R2: security/resilience/i18n/analytics/maintainability). All blockers + majors folded in.
- **Market context:** US-first, distributed on the App Store; **English-only by product decision** — the release is English-only and localization is out of scope (see §11).
- **Confidence:** v3 scored ~70% as-written; R2 exposed resilience at 45% (2 new blockers). This v4 addresses them; honest target ~95% (see §15).

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

// One-way first-run latches (never unset). Double as activation metrics (§14).
public var onboardingCompletedAt: Date? = nil    // set once in finish()
public var firstSetupCompletedAt: Date? = nil    // set once a Client AND a client-linked non-archived Project first coexist
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
- **`OnboardingFlags.shouldShow` = false** when any `BusinessProfile.onboardingCompletedAt != nil` (syncs cross-device) OR the local fast-path flag is set. **Re-evaluate on `scenePhase == .active`** (not just `onAppear`), or drive from a `@Query`. Reject saving a **blank** profile name in the editor (trim-and-reject).

## 6. Business Profile editor (Settings)

- Segmented entity `Picker` at the top of Issuer; footer explains the difference.
- **Shared `EntityType+Presentation.swift`** (App target) maps entity → name label + tax-ID label, used by BOTH onboarding and the editor (DRY; English literals today — see §11).
- Freelancer tax = collapsed `DisclosureGroup` "Add tax (if you charge it)"; **auto-expand if a non-zero rate exists**. Organization: expanded.
- **Harden financial fields** (IBAN/SWIFT/tax-ID): `.keyboardType(.asciiCapable)` + `.textContentType(nil)` (no keyboard-learning/AutoFill of identifiers; NOT `SecureField` — user must verify their own IBAN).
- Settings row: render **"Incomplete"** as its own `Text` (not a `"· "`-glued fragment) when `!isProfileEnriched`.

## 7. Today guidance — one element at a time

Precedence resolved by a **pure `TodayGuidance.resolve(...)` enum in BillableCore** (unit-tested, mirrors `BadgeCount`), from booleans the view already has:
1. `!canSendInvoice` (name missing, rare) → name-warning banner.
2. `onboardingCompletedAt != nil && firstSetupCompletedAt == nil` → **Get-started block**.
3. `firstSetupCompletedAt != nil && !isProfileEnriched && !snoozedThisSession` → enrichment nudge.
4. else → none.

The clientless quick-start "General" does **not** set `firstSetupCompletedAt`, so quick-start users keep the checklist (instant value + still guided). Archiving/deleting later never resurrects first-run (latch is one-way). `firstSetupCompletedAt` is stamped when a Client AND a client-linked non-archived Project first coexist.

### 7a. Get-started block — its own view `Features/Today/GetStartedSection.swift`
- **2-row checklist** (progress visible): Row 1 "Add a client" (`circle` → `checkmark.circle.fill` once any client exists) presents `ClientEditorView(client:nil)`; Row 2 "Create a project" becomes active once a client exists, presents `NewProjectSheet`. `@Query`-driven; reads in VoiceOver as two stateful items.
- **"Start a timer now" quick-start:** **fetch-or-create** a single canonical `Project(name:"General", client:nil, !isArchived)` (probe, fetchLimit 1 — reuse if present), then `TimerActions.start(...)`. **Debounce** via `@State startingQuickTimer` (disable while in flight) to prevent same-frame double-insert. (Rate 0 → existing 0-rate warning guides them later.)
- Existence checks use **bounded probes** (`fetchCount`/`fetchLimit 1`), never an unbounded `@Query var allProjects`.

### 7b. Enrichment prompt — re-timed
- **Primary at invoice creation:** opening the generator with `!isProfileEnriched` surfaces an inline "Add your address & payment details so this invoice looks complete" → editor (conditional copy if only one half is missing).
- **Secondary Today nudge** (tier 3): info card (icon+text), dismiss = **session-only `@State` "Not now"** (no cross-device flag); `isProfileEnriched` is the durable driver. Close control ≥44pt, `accessibilityLabel("Dismiss")`. (Note: session = until the view is rebuilt.)

## 8. Singleton reconciliation (resilience, in-scope)

- **Every `profiles.first` read becomes deterministic** via one helper: `sortBy createdAt asc, fetchLimit 1` (oldest-wins). 
- **On launch + on CloudKit remote-change:** if >1 `BusinessProfile` exists, keep the oldest as canonical, copy any non-empty field the oldest is missing from the others, then delete the extras. Converges multi-device duplicates deterministically and protects `nextInvoiceNumber`/`name`/`entityType`.
- Full `@Attribute(.unique)` enforcement (needs a `VersionedSchema` baseline) remains a **tracked follow-up**; reconciliation is the pragmatic in-scope fix.

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
- **Tier 2 (opt-in minimal telemetry):** **out of scope — owner confirmed privacy-pure** (Tier 0 + 1 only; no data leaves the device; no change to `privacy.md`).

## 15. Confidence & residual risk

Two review rounds took this from a claimed 95% (v2) → honest 70% (v3) → this v4, which folds every blocker/major. **Honest design confidence ~95%**, underpinned by code-traced fixes (quick-start fetch-or-create+debounce; deterministic singleton + reconciliation; throwing save; one-way completion/first-setup latches; redefined checklist suppression; pure `TodayGuidance`; keyboard hardening; English-only honesty; metrics plan). Residual <100%:
- Multi-device singleton is an inherently distributed problem; reconciliation mitigates but `.unique` enforcement is a tracked follow-up.
- **Release-gates that must actually be executed:** `PrivacyInfo.xcprivacy`, Data-Protection entitlement, **CloudKit reinstall smoke test** (TESTING.md), ASC baseline snapshot.
- Implementation-time on-device checks (Dynamic Type max, SE keyboard occlusion, light/dark).
- Forks active `feature/project-detail-ia` (which does NOT edit `TodayView` — verified — so merge risk is the onboarding-no-longer-seeds-a-project *contract* change; coordinate on rebase).

## 16. Testing

Unit (BillableCore): `EntityType` round-trip/`Codable`; profile default; latch setters; `isProfileEnriched` table; `canSendInvoice` unaffected; back-compat init; **`TodayGuidance.resolve` precedence (unit, not UI)**; **migration round-trip** (old store w/o new fields → defaults) — **gating**; **singleton reconciliation** (2 profiles → 1 oldest, fields merged).
UI: Freelancer/Org labels; **checklist reactivity** (add client → row advances); **quick-start** (double-tap → ONE General + running timer); enrichment precedence; `SettingsAboutUITests` updated; `LaunchTaglineUITests` preserved; `InvoicePreviewLineItemEditUITests` unaffected.

## 17. Out of scope (YAGNI)

Per-entity templates; region/auto tax; multiple profiles; forced re-onboarding; entity type on invoices; `.unique`/`VersionedSchema`; broad localization; Tier-2 telemetry; CSV/widget-scope hardening (tracked follow-ups).
