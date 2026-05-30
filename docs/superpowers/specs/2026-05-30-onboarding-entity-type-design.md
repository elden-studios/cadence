# Onboarding Entity-Type Setup + Business Profile — Design Spec

- **Date:** 2026-05-30
- **Branch:** `feature/onboarding-entity-type` (forked from `feature/project-detail-ia` @ `692b9e4`)
- **Status:** **v3 — pressure-tested by a 5-lens review (logic, product, market, engineering, UI/UX); blockers + fixes folded in.**
- **Market context:** US-first, ships globally (175 countries). Tax/locale logic must be globally robust, not region-specific.
- **Design confidence:** the 5-lens review scored the v2 spec ~70% as-written (logic 55 / product 55 / market 88 / engineering 88 / UI-UX 72). This v3 resolves the two blockers and the major findings, targeting ~90%+. Residual is implementation-time verification (§13).

## 1. Goal

Profile-first onboarding: `welcome → choose Freelancer/Organization (framed by how you bill) + enter name → land on Today`. Entity type shapes the profile form (labels, tax-section default) in onboarding and the Settings editor. On Today, the user is guided to first value by a **2-step setup checklist + a one-tap "Start a timer now" quick-start**, and (later) a well-timed enrichment prompt. Plus a dev-credit string fix.

## 2. Background (current state, verified)

- **Onboarding** ([OnboardingView.swift](../../../App/Sources/Features/Onboarding/OnboardingView.swift)) is 3 steps: `welcome → client (name + hourlyRate + color) → timer`. On finish it **fetches-or-creates** a BusinessProfile (insert only if fetch empty — see lines 303-308), creates a `Client` + `Project`, and starts a `TimeEntry`. Welcome tagline: `Text("Track hours.\nSend invoices.")`. Field prompts use `white.opacity(0.3)` (lines 111, 174).
- **`BusinessProfile`** ([BusinessProfile.swift](../../../Packages/BillableCore/Sources/BillableCore/Models/BusinessProfile.swift)) is a CloudKit-mirrored `@Model` (`BusinessProfile.self` in `mirroredTypes`, [ModelContainer+Billable.swift:17](../../../Packages/BillableCore/Sources/BillableCore/Persistence/ModelContainer+Billable.swift)). `name` is the only hard invoice gate (`canSendInvoice`). **Singleton is assumed but NOT enforced** — `profiles.first` is read in ~12 sites; no `.unique`.
- **Enum persistence convention:** `Client.colorRaw` and `Invoice.statusRaw` store enums as raw `String` + a computed typed accessor ("Codable enum in CloudKit can be fragile; raw string is safe"). We follow this.
- **Tax** = single `taxRate` snapshotted to `Invoice`; PDF renders the tax row only when `taxAmount > 0` ([InvoiceTemplate.swift:230]). Freelancer (rate 0) → no tax line. Entity type never enters tax math.
- **`Project.client` is optional** (WorkView groups a `nil`-client "No client" bucket) — so a clientless quick-start project is valid.
- **Adding work:** `ClientEditorView(client:)` **self-dismisses, no `onSaved`** → guided UI must be `@Query`-driven. `ProjectEditorView(client:project:onSaved:)` has `onSaved`. A `Project` needs a `Client` only via `NewProjectSheet`; the model allows `client == nil`.
- **`OnboardingFlags.shouldShow`** returns false if the device-local `UserDefaults` `completedKey` is set, else `clientCount == 0`. `RootView` also force-shows onboarding under `--ui-test-show-onboarding`.
- **Dev credit**: [SettingsView.swift:111](../../../App/Sources/Features/Settings/SettingsView.swift) shows `"Cadence by Elden Studios Company"`.

## 3. Locked decisions

1. **Profile-first onboarding**, keeping the **Freelancer/Organization choice** (framed by *how you bill*, not legal entity) — user decision.
2. **First-run = Hybrid** (user decision): land on Today with a **2-step setup checklist** (Add a client → Create a project) **and** a **"Start a timer now" quick-start** that creates a default clientless "General" project and starts the timer in one tap (restores the day-1 activation hook the review flagged as lost).
3. **Tax universal & OFF by default for everyone**; entity type changes only labels + default tax-section visibility, never capability.
4. **Onboarding "completed" is derived from persisted state** (a `BusinessProfile` with a non-blank `name` exists), not solely the device-local `UserDefaults` flag — fixes the multi-device re-onboarding trap.
5. **Singleton write is explicit fetch-then-mutate** (never `defaultForCurrentLocale()` on the exists path) — fixes the duplicate-profile risk.
6. **One nudge at a time on Today** (precedence in §7); "active project" defined precisely.
7. **Existing users** (no stored type) default to Organization-style labels (back-compat).
8. **Dev credit** → `"Elden Studios Company"`.

## 4. Data model

`Models/EntityType.swift` (BillableCore):

```swift
public enum EntityType: String, Codable, CaseIterable, Sendable {
    case freelancer
    case organization

    /// Presentation POLICY belongs in core; presentation STRINGS do not (see §6).
    public var showsTaxByDefault: Bool { self == .organization }
}
```

`BusinessProfile` gains a raw stored property + typed accessor (mirrors `colorRaw`/`statusRaw`):

```swift
public var entityTypeRaw: String = EntityType.organization.rawValue  // legacy default preserves "Business name" + visible tax

public var entityType: EntityType {
    get { EntityType(rawValue: entityTypeRaw) ?? .organization }
    set { entityTypeRaw = newValue.rawValue }
}
```

- Add `entityTypeRaw` to `init(...)` **with a default** → all existing call sites (`BusinessProfile(name:)`, SampleData, MarketingData, ~15 tests) compile unchanged.
- **Default rationale (resolves the "silent mis-tag" finding):** `.organization` is a *back-compat fallback* only. **Onboarding always sets `entityType` explicitly**, so new users are never mis-tagged. The one non-onboarding creation path — the editor's `newProfile()` — is rare (a profile normally exists post-onboarding); its always-visible segmented picker (§6) is the correction point. Documented, not silent.
- **CloudKit/migration:** non-optional `String` with a default = lightweight-migration-safe; no `mirroredTypes` change; no manual migration. (Matches every prior additive field: bank v1.4, tax-ID v1.5, email v1.6.)
- **Enrichment signal** (drives the §7b nudge; never blocks):

```swift
public var isProfileEnriched: Bool {
    !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && hasBankDetails
}
```

## 5. Onboarding flow (UI/UX applied)

`Step` becomes `welcome → identity`. **Drop the 2-dot progress indicator** (over-instrumented for 2 steps, and the current `ForEach(0..<3)` + `<=` logic is a fill-meter bug); Back + clear titles are sufficient wayfinding. Keep the slide animation **gated on `accessibilityReduceMotion`**; CTA respects safe-area.

**Welcome:** unchanged. **Preserve the tagline `Text("Track hours.\nSend invoices.")` verbatim** (`LaunchTaglineUITests`). Test-safe subtitle tweak: "Made for freelancers and consultants." → "Made for freelancers and small businesses."

**Identity screen (step 2):**
- Title (`title`): "Tell us about you".
- **Two descriptive selectable cards** (not segmented — first-time identity choice). Copy framed by **how you bill** (fixes the LLC/DBA ambiguity):
  - **Freelancer** — `person.fill` — "It's just me. I bill for my own time."
  - **Organization** — `building.2.fill` — "We're a team. We bill under one company name."
  - Each ≥56pt, 12pt gap; **selected = accent border (2pt) + filled checkmark + subtle fill** (never color alone); each is a `Button` with `accessibilityLabel`+`Hint` and the `.isSelected` trait. Pre-select Freelancer.
- **Name field:** visible caps label = view-layer `issuerNameLabel(for: type)` ("YOUR NAME"/"BUSINESS NAME"); prompt example at **`opacity ≥ 0.55`** (was 0.3 = 2.6:1, fails WCAG; 0.55 ≈ 4.6:1). `textContentType` `.name`/`.organizationName`; `.words`. **Do NOT auto-focus on appear** (it would raise the keyboard and hide the entity cards on small phones); focus only after a type is chosen. Wrap the screen in a `ScrollView`; add `.submitLabel(.done)` + `onSubmit { finish() }`.
- Reassurance (`footnote`): "You can add your logo, tax, and bank details anytime in Settings."
- **One primary CTA** "Finish setup", enabled when trimmed name is non-empty.

**`finish()` — explicit and crash-safe (fixes both blockers):**
```
1. Fetch the singleton: FetchDescriptor<BusinessProfile>, fetchLimit = 1.
2. If present → mutate it. Else → insert defaultForCurrentLocale(). (NEVER call defaultForCurrentLocale() on the exists path.)
3. Set profile.name = trimmedName; profile.entityType = selectedType.
4. saveOrLog("complete onboarding")  ← SAVE FIRST.
5. Only after a successful save: set OnboardingFlags.completedKey = true.
6. onFinish() → Today.
```
- **Do not** create a Client/Project/TimeEntry here (quick-start/checklist handle that on Today).
- **`OnboardingFlags.shouldShow`** also returns `false` when a `BusinessProfile` with a non-blank `name` exists (covers the CloudKit second-device + crash-after-save cases). Keep `--ui-test-show-onboarding` working; the new finish-flow UI test must launch with a reset/ephemeral store so it doesn't pollute shared state.

## 6. Business Profile editor (Settings)

- New `@State entityType`, loaded/saved with the profile.
- **Top of Issuer section: segmented `Picker`** (Freelancer/Organization) with a one-line footer: "Freelancers invoice under their own name; organizations under a business name."
- **Name + tax-ID labels come from a view-layer mapping** (`EntityType` → localized `String(localized:)`), NOT from strings on the core enum (avoids the localization trap — we ship 175 countries).
- **Freelancer tax = progressive disclosure:** when `entityType == .freelancer` **and no rate set**, the Tax section sits in a collapsed `DisclosureGroup` "Add tax (if you charge it)". **Auto-expand if a non-zero rate exists** (so configured tax never appears to vanish). Organization: expanded.
- **Settings list row:** append a passive "· Incomplete" hint when `!isProfileEnriched`.

## 7. Today guidance — one element at a time

Precedence (first match wins): **(1)** name missing (`!canSendInvoice`, rare) → orange warning banner only; **(2)** **no active project** → the Get-started block only; **(3)** `!isProfileEnriched` and not snoozed-this-session → enrichment nudge.

**"Active project" is defined** as: there exists a `Project` with `!isArchived`. Checked via a **bounded existence probe** (`fetchCount`/`fetchLimit = 1`), NOT an unbounded `@Query var allProjects` (TodayView already carries fetch-all perf debt).

### 7a. Get-started block (replaces the morphing CTA — UI/UX finding)
A **2-row checklist** (progress stays visible), `@Query`-driven:
- Row 1 "Add a client" — leading glyph `circle` → `checkmark.circle.fill` once any client exists. Tapping presents `ClientEditorView(client: nil)` in a `NavigationStack` sheet (self-dismisses; the row updates reactively via `@Query`).
- Row 2 "Create a project" — becomes the active CTA once a client exists; presents `NewProjectSheet`.
- Reads in VoiceOver as two items with state. The whole block hides once an active (`!isArchived`) project exists.

Plus a **"Start a timer now" quick-start** (the activation hook): creates a default clientless `Project(name: "General", client: nil)` and calls `TimerActions.start(...)` immediately. (Rate defaults to 0; the existing "billable project has a 0 rate" warning guides the user to set it later.) After quick-start, an active project exists → the block hides and the user is tracking.

### 7b. Enrichment prompt — re-timed (Product + Engineering finding)
- **Primary, well-timed prompt is at invoice creation:** when the user opens the invoice generator with a bare profile (`!isProfileEnriched`), surface an inline "Add your address & payment details so this invoice looks complete" affordance → `BusinessProfileEditorView`. This is the moment of motivation.
- **Secondary Today nudge** (tier 3): informational card (icon + text, not color-alone), `person.text.rectangle`, → editor. **Dismiss = "Not now" (session-only `@State`)**, not a persisted forever-flag — avoids the device-local `UserDefaults` cross-device problem entirely; `isProfileEnriched` is the durable driver, and the invoice-time prompt is the durable reminder. Close control ≥44pt with `accessibilityLabel("Dismiss")`.

## 8. Accessibility & interaction (cross-cutting)

- **Contrast fix is specified, not residual:** field-prompt opacity ≥0.55 (the 0.55–0.85 label/body text already passes 5.25:1+).
- Touch targets ≥44pt (cards, checklist rows, quick-start, dismiss); ≥8pt spacing.
- VoiceOver: entity cards expose the `.isSelected` **trait** (`accessibilityAddTraits`), not a label suffix; checklist rows announce state; logical order.
- Dynamic Type: identity labels/body use text styles, no truncation at largest size; verify on SE-class hardware with the keyboard up (occlusion).
- Reduced motion on transitions; verify light/dark for Today cards.

## 9. Invoice / PDF impact

None to tax/PDF math (freelancer rate 0 → no tax line; entity type not printed; issuer is `profile.name`). The §7b invoice-time enrichment prompt is additive UI on the generator — no change to `Invoice`/`InvoiceBuilder`/`InvoiceTemplate`.

## 10. Developer credit fix

- [SettingsView.swift:111](../../../App/Sources/Features/Settings/SettingsView.swift): `"Cadence by Elden Studios Company"` → `"Elden Studios Company"`.
- [SettingsAboutUITests.swift:30-31](../../../App/BillableUITests/SettingsAboutUITests.swift): update lookup + message.
- *Terminology note:* the market review suggests "Business" reads more US-natural than "Organization"; keeping "Organization" per the user's wording — trivially swappable later.

## 11. Testing

**BillableCore unit:**
- `EntityType` raw round-trip; two cases; `Codable`.
- `BusinessProfile` default `entityType == .organization`; accessor get/set.
- `isProfileEnriched` truth table (address AND bank).
- `canSendInvoice` unaffected; back-compat `init`.
- **NEW [must]: migration round-trip** — open a store seeded *without* `entityTypeRaw` (older-schema fixture) with the new schema; assert it reads `.organization`. (Backs the headline migration claim.)

**UI (BillableUITests):**
- Onboarding: pick Freelancer → label "Your name" → Finish → Today shows the **checklist (row 1 active)** and a **"Start a timer now"** control; **no auto-started timer**. Pick Organization → "Business name".
- **NEW: checklist reactivity** — create a client; assert row 1 flips to done and row 2 becomes active.
- **NEW: quick-start** — tap "Start a timer now"; assert a running timer + the get-started block hides.
- **NEW: nudge precedence** — assert only one of {name-banner, get-started, enrichment} shows per state, and get-started suppresses enrichment.
- Update `SettingsAboutUITests` → `"Elden Studios Company"`. Preserve `LaunchTaglineUITests` (tagline + flag). `InvoicePreviewLineItemEditUITests` unaffected (seeds → skips onboarding).

## 12. Out of scope (YAGNI)

Per-entity invoice templates; region-aware/automated tax; multiple profiles; forced re-onboarding for existing users; entity type on the rendered invoice; full singleton `.unique` enforcement (tracked follow-up — see §13).

## 13. Confidence & residual risk

The 5-lens review took v2 from a claimed 95% to an honest ~70% by surfacing two blockers (singleton create-vs-fetch; multi-device re-onboarding) plus the activation regression and the morphing-CTA/contrast UX issues — all now addressed (§3-§8). **Target ~90%+.** Residual:
- **Singleton dedupe** is a *pre-existing* latent issue (no `.unique`); `finish()` now guards the onboarding path and §3.4 narrows the create window, but full reconciliation/`.unique` (which needs a `VersionedSchema` baseline) is a **tracked follow-up**, not blocking.
- On-device checks: Dynamic Type at max, SE keyboard occlusion, dark/light Today cards, prompt contrast value.
- `isProfileEnriched` rule (address AND bank) is a tunable judgment.
- Forks the active `feature/project-detail-ia`; `TodayView` is the shared surface → rebase/coordinate before merge.
- **CloudKit reinstall smoke test** (TESTING.md) before any TestFlight build.
