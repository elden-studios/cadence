# Onboarding Entity-Type Setup + Business Profile — Design Spec

- **Date:** 2026-05-30
- **Branch:** `feature/onboarding-entity-type` (forked from `feature/project-detail-ia` @ `692b9e4`)
- **Status:** Approved design — pending implementation plan
- **Market context:** US-first, ships globally (175 countries). Tax/locale logic must be globally robust, not region-specific.

## 1. Goal

Replace the current onboarding's "add a client + hourly rate" second screen with **the user setting up their own identity first**: choosing **Freelancer** or **Organization**, then entering their name. The chosen entity type shapes the business-profile form (labels, tax-field emphasis) consistently in both onboarding and the Settings editor. After onboarding the user lands on **Today**, guided by two nudges: "Add your first client and project" and a dismissible "Complete your profile."

Also: fix the developer-credit string in Settings → About.

## 2. Background (current state)

- **Onboarding** ([OnboardingView.swift](../../../App/Sources/Features/Onboarding/OnboardingView.swift)) is 3 steps: `welcome → client (name + hourlyRate + color) → timer`. On finish it creates a *blank* `BusinessProfile` (currency only), a `Client`, a `Project`, and starts a `TimeEntry`.
- **`BusinessProfile`** ([BusinessProfile.swift](../../../Packages/BillableCore/Sources/BillableCore/Models/BusinessProfile.swift)) is a CloudKit-mirrored `@Model`. It has `name`, `address`, `email`, `phone`, tax (`taxLabel`, `taxRate`), `taxIDLabel`/`taxIDNumber`, bank details, etc. **No entity-type concept exists.**
- **Tax** is a single `taxRate` (0…1) snapshotted onto each `Invoice` at creation (`taxRateSnapshot`; `taxAmount = subtotal * taxRateSnapshot`). The issuer name on invoices is always `profile.name`.
- **Settings editor** ([BusinessProfileEditorView.swift](../../../App/Sources/Features/Settings/BusinessProfileEditorView.swift)) hard-labels the name field "Business name" and always shows the Tax section.
- **Today** ([TodayView.swift](../../../App/Sources/Features/Today/TodayView.swift)) shows `showEmptyBusinessBanner` ("Add your business name to send invoices") when `!canSendInvoice` (i.e., name empty). There is **no** "add your first client/project" guidance today.
- **Adding work**: a `Project` requires a `Client` first ([NewProjectSheet](../../../App/Sources/Features/Work/WorkView.swift) — "Add a client first, then create a project"). The hourly rate lives on the `Project` ([ProjectEditorView](../../../App/Sources/Features/Projects/ProjectEditorView.swift)).
- **Dev credit**: [SettingsView.swift:111](../../../App/Sources/Features/Settings/SettingsView.swift) shows `"Cadence by Elden Studios Company"`.

## 3. Locked decisions

1. **Onboarding structure:** profile-only. `welcome → choose Freelancer/Organization + name → finish → land on Today`. The forced first-client/timer is **removed** (the hourly rate is collected later, naturally, when the user makes their first project).
2. **Tax is universal and OFF by default for everyone.** Entity type changes *presentation* (labels, default tax-section visibility), **never** tax capability. Rationale: tax liability depends on registration, not on "freelancer vs company" — true across US sales tax, EU/UK VAT, AU/CA GST. A hard "freelancers can't charge tax" rule would be wrong in most markets and would force VAT-registered sole traders to mislabel themselves.
3. **Minimal onboarding fields:** entity type + name only. Everything else (tax, address, bank, logo) is deferred to the Settings editor, prompted by the "Complete your profile" nudge.
4. **Entity type is editable later** in the Settings editor and round-trips to `BusinessProfile`.
5. **Existing users** (no stored type) default to **Organization-style** labels — preserves the current "Business name" label and always-visible Tax section, so nothing changes for them. They can switch anytime.
6. **Two Today nudges:** (a) "Add your first client and project" (data), (b) "Complete your profile" (enrichment, dismissible).
7. **Dev credit** → `"Elden Studios Company"` (drop "Cadence by").

## 4. Data model

New enum in BillableCore (`Models/EntityType.swift`):

```swift
public enum EntityType: String, CaseIterable, Sendable {
    case freelancer
    case organization
}
```

`BusinessProfile` gains one stored property + one typed accessor. Stored as a `String` raw value with a **non-optional default** to satisfy CloudKit mirroring:

```swift
// Stored — default preserves legacy "Business name" + visible Tax section for existing users.
public var entityTypeRaw: String = EntityType.organization.rawValue

public var entityType: EntityType {
    get { EntityType(rawValue: entityTypeRaw) ?? .organization }
    set { entityTypeRaw = newValue.rawValue }
}
```

- Add `entityTypeRaw` to the `init(...)` (defaulted) so existing call sites compile unchanged.
- **CloudKit safety:** the new attribute is non-optional *with a default*, which is valid for the CloudKit mirror, so SwiftData lightweight migration handles it — existing rows materialize with the default, no manual migration step. `BusinessProfile` is already in the container's `mirroredTypes`; adding a property to an already-mirrored model does not change that array.
- **Label helpers** (presentation lives in the app layer, but the model exposes intent):

```swift
extension EntityType {
    public var issuerNameFieldLabel: String {     // form field label
        switch self { case .freelancer: "Your name"; case .organization: "Business name" }
    }
    public var taxIDFieldLabel: String {
        switch self { case .freelancer: "Tax ID (optional)"; case .organization: "Business Tax ID (EIN, VAT, …)" }
    }
    public var showsTaxByDefault: Bool { self == .organization }
}
```

**Profile-enrichment signal** for the nudge (on `BusinessProfile`):

```swift
/// Name is the hard gate for sending (see `canSendInvoice`). "Enriched" means the
/// profile also has the fields that make an invoice look complete: a postal address
/// and a payment route. Used only to decide whether to show the (dismissible)
/// "Complete your profile" nudge — never blocks anything.
public var isProfileEnriched: Bool {
    !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && hasBankDetails
}
```

## 5. Onboarding flow redesign

`OnboardingView` `Step` becomes `welcome → identity` (drop `.client`, `.timer`).

**Welcome screen:** unchanged, except the subtitle "Made for freelancers and consultants." → "Made for freelancers and small businesses." (inclusive of the new Organization path; minor copy tweak).

**Identity screen (new step 2):**
- Title: "Tell us about you" (or similar).
- **Entity-type chooser:** two large selectable cards / a segmented control — **Freelancer** | **Organization**. Default selection: Freelancer (the app's core audience; the user explicitly picks, so this is just the pre-highlight).
- **Name field** with a label that switches live with the choice: `selectedType.issuerNameFieldLabel` ("Your name" / "Business name"), prompt e.g. "Jane Smith" / "Acme Studio LLC".
- Reassurance line: "You can add your logo, tax, and bank details anytime in Settings."
- Primary button enabled when name is non-empty. Label: "Finish setup".

**`finish()` rewrite:**
- Create (or fetch) the singleton `BusinessProfile` via `defaultForCurrentLocale()`, set `entityType = selectedType` and `name = trimmedName`.
- **Do not** create a `Client`, `Project`, or start a `TimeEntry`.
- Set `OnboardingFlags.completedKey = true`.
- `onFinish()` → app lands on **Today**.

`OnboardingFlags.shouldShow` is unchanged in intent (flag-gated; `clientCount == 0` remains a safety net), and still returns `false` once the flag is set even though no client exists.

## 6. Business Profile editor (Settings)

[BusinessProfileEditorView.swift](../../../App/Sources/Features/Settings/BusinessProfileEditorView.swift) changes:
- New `@State private var entityType: EntityType`, loaded/saved with the profile.
- **Top of the Issuer section:** an entity-type `Picker` (segmented): Freelancer / Organization.
- **Name field label** = `entityType.issuerNameFieldLabel` (was hard-coded "Business name").
- **Tax section** becomes collapsible: when `entityType == .freelancer` and the user hasn't set a rate, render it behind a `DisclosureGroup` titled "Add tax (if you charge it)" — collapsed by default → the *simpler freelancer form*. For `.organization`, show it expanded as today. Either way the same fields are available; capability is identical.
- **Tax-ID label** = `entityType.taxIDFieldLabel`.
- `loadIfNeeded()` reads `profile.entityType`; `save()` writes it.

**Settings list row** ([SettingsView.swift](../../../App/Sources/Features/Settings/SettingsView.swift)): the Business-profile `NavigationLink` subtitle gains an "Incomplete" hint when `!profile.isProfileEnriched` (e.g., append " · Incomplete" or a small chip), giving a passive signal alongside the Today nudge.

## 7. Today nudges

Both are additive cards in `TodayView`, reusing the existing banner visual style.

### 7a. "Add your first client and project" (data nudge)
- **Shown when** the user has no active projects (no `Project` with `!isArchived`). (Using projects, not just clients, so it persists through "client exists but no project yet".)
- **Hero placement** — prominent card where the empty dashboard would otherwise be barren (above/in place of `JumpBackInSection`).
- **Two-state CTA** reusing existing editors:
  - No clients yet → "Add your first client" → presents `ClientEditorView(client: nil)` sheet.
  - Has a client, no project → "Add your first project" → presents `NewProjectSheet`.
- Disappears once an active project exists.
- Copy mirrors the existing Work-tab empty state ("Add a client and a project to start tracking").

### 7b. "Complete your profile" (enrichment nudge)
- **Shown when** `profiles.first` exists, `!isProfileEnriched`, and not dismissed.
- **Dismissible** — an "x" sets `UserDefaults` key `cadence.nudge.completeProfile.dismissed = true`; never shown again once dismissed.
- CTA → `BusinessProfileEditorView`.
- **Distinct from** the existing `showEmptyBusinessBanner` (name-only), which is now satisfied by onboarding but kept as a safety fallback (e.g., if the user clears their name).

**Card ordering on Today:** business-name banner (rare) → complete-profile nudge → first-steps card → `JumpBackInSection` → `TodaySummarySection`.

## 8. Invoice / PDF impact

- **None to the model's tax math.** Freelancer = `taxRate 0` → `taxAmount 0` → existing renderer already omits the tax line at rate 0. Organization sets a rate when applicable.
- Entity type is **not** printed on the invoice; the issuer is `profile.name` regardless. So "Your name" vs "Business name" is purely a UI label.
- No changes to `Invoice`, `InvoiceBuilder`, `InvoiceTemplate`, or the PDF renderer.

## 9. Developer credit fix

- [SettingsView.swift:111](../../../App/Sources/Features/Settings/SettingsView.swift): `"Cadence by Elden Studios Company"` → `"Elden Studios Company"`.
- [SettingsAboutUITests.swift:30-31](../../../App/BillableUITests/SettingsAboutUITests.swift): update both the lookup and the assertion message to `"Elden Studios Company"`.

## 10. Testing

**BillableCore unit tests (Swift Testing):**
- `EntityType` raw-value round-trips; `CaseIterable` has exactly the two cases.
- `BusinessProfile` default `entityType == .organization`; `entityType` get/set mutates `entityTypeRaw`.
- `isProfileEnriched`: false when address empty or no bank details; true when both present.
- `canSendInvoice` unaffected by entity type (still name-gated).
- Label helpers return expected strings per case.

**UI tests (BillableUITests):**
- Onboarding: welcome → pick **Freelancer** → name field label reads "Your name" → Finish → Today shows the "Add your first client" card (no timer auto-started).
- Onboarding: pick **Organization** → label reads "Business name".
- Settings → About shows `"Elden Studios Company"` (update existing `SettingsAboutUITests`).
- Profile editor: entity-type picker present; switching to Freelancer collapses the Tax section.

**Existing tests to update:** any onboarding UI test that assumed the client/timer steps; `SettingsAboutUITests`; check `LaunchTaglineUITests` for the welcome subtitle copy.

## 11. Out of scope (YAGNI)

- No separate invoice templates per entity type.
- No region-based automatic tax rates or tax-rule engine.
- No multiple business profiles.
- No forced re-onboarding prompt for existing users (they get the default label + can switch in Settings).
- Entity type does not appear on the rendered invoice.

## 12. Risks / notes

- **Parallel work:** this branch forks `feature/project-detail-ia` (an actively-developed branch). `TodayView` is the main shared surface — coordinate/rebase before merge. `OnboardingView`, `BusinessProfile`, `BusinessProfileEditorView`, `SettingsView` have low overlap with the project-detail screen work.
- **CloudKit:** adding `entityTypeRaw` with a default is mirror-safe; still worth the manual CloudKit reinstall smoke test (per `TESTING.md`) before any TestFlight build, since it touches a mirrored model.
