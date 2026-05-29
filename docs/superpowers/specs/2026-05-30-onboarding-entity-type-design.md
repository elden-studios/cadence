# Onboarding Entity-Type Setup + Business Profile — Design Spec

- **Date:** 2026-05-30
- **Branch:** `feature/onboarding-entity-type` (forked from `feature/project-detail-ia` @ `692b9e4`)
- **Status:** Approved direction — **v2: UI/UX best-practices pass + code/test verification applied**
- **Market context:** US-first, ships globally (175 countries). Tax/locale logic must be globally robust, not region-specific.
- **Design confidence:** ~95% (see §13). Verified against the codebase + Apple HIG / UI-UX rules; residual 5% is implementation-time verification, not open design questions.

## 1. Goal

Replace the current onboarding's "add a client + hourly rate" second screen with **the user setting up their own identity first**: choosing **Freelancer** or **Organization**, then entering their name. The chosen entity type shapes the business-profile form (labels, tax-field emphasis) consistently in both onboarding and the Settings editor. After onboarding the user lands on **Today**, guided by **one** contextual nudge at a time. Also: fix the developer-credit string.

## 2. Background (current state, verified)

- **Onboarding** ([OnboardingView.swift](../../../App/Sources/Features/Onboarding/OnboardingView.swift)) is 3 steps: `welcome → client (name + hourlyRate + color) → timer`. On finish it creates a *blank* `BusinessProfile` (currency only), a `Client`, a `Project`, and starts a `TimeEntry`. The welcome tagline is `Text("Track hours.\nSend invoices.")`.
- **`BusinessProfile`** ([BusinessProfile.swift](../../../Packages/BillableCore/Sources/BillableCore/Models/BusinessProfile.swift)) is a CloudKit-mirrored `@Model` (confirmed: `BusinessProfile.self` is in `mirroredTypes`, [ModelContainer+Billable.swift:17](../../../Packages/BillableCore/Sources/BillableCore/Persistence/ModelContainer+Billable.swift)). No entity-type concept exists.
- **Tax** = a single `taxRate` (0…1) snapshotted onto each `Invoice` (`taxAmount = subtotal * taxRateSnapshot`). Issuer name on invoices is always `profile.name`.
- **Settings editor** ([BusinessProfileEditorView.swift](../../../App/Sources/Features/Settings/BusinessProfileEditorView.swift)) hard-labels the name field "Business name" and always shows the Tax section.
- **Today** ([TodayView.swift](../../../App/Sources/Features/Today/TodayView.swift)) shows `showEmptyBusinessBanner` (orange, "Add your business name to send invoices") when `!canSendInvoice` (name empty). No "add first client/project" guidance exists.
- **Adding work** ([WorkView.swift](../../../App/Sources/Features/Work/WorkView.swift)): a `Project` requires a `Client` first. `ClientEditorView(client:)` **has no `onSaved` callback — it self-dismisses** (so a guided card must react to data via `@Query`, not chain a callback). `ProjectEditorView(client:project:onSaved:)` does take `onSaved`. Hourly rate lives on the `Project` ([ProjectEditorView](../../../App/Sources/Features/Projects/ProjectEditorView.swift)).
- **Dev credit**: [SettingsView.swift:111](../../../App/Sources/Features/Settings/SettingsView.swift) shows `"Cadence by Elden Studios Company"`.

## 3. Locked decisions

1. **Onboarding structure:** profile-only. `welcome → choose Freelancer/Organization + name → finish → land on Today`. The forced first-client/timer is **removed** (hourly rate is collected later, when the user makes their first project).
2. **Tax is universal and OFF by default for everyone.** Entity type changes *presentation* (labels, default tax-section visibility), **never** tax capability. Rationale: tax liability depends on registration, not "freelancer vs company" — true across US sales tax, EU/UK VAT, AU/CA GST.
3. **Minimal onboarding fields:** entity type + name only. Tax/address/bank/logo deferred to the editor, prompted by the enrichment nudge.
4. **Entity type editable later** in the Settings editor; round-trips to `BusinessProfile`.
5. **Existing users** (no stored type) default to **Organization-style** labels — preserves the current "Business name" + visible Tax section.
6. **One nudge at a time on Today** (precedence in §7) — no banner stacking.
7. **Dev credit** → `"Elden Studios Company"`.

## 4. Data model

New enum in BillableCore (`Models/EntityType.swift`):

```swift
public enum EntityType: String, CaseIterable, Sendable {
    case freelancer
    case organization
}
```

`BusinessProfile` gains one stored property + a typed accessor, stored as a `String` raw value with a **non-optional default** (CloudKit-mirror-safe):

```swift
public var entityTypeRaw: String = EntityType.organization.rawValue  // default preserves legacy labels

public var entityType: EntityType {
    get { EntityType(rawValue: entityTypeRaw) ?? .organization }
    set { entityTypeRaw = newValue.rawValue }
}
```

- Add `entityTypeRaw` to `init(...)` **with a default**, so existing call sites (`BusinessProfile(name:)`, `SampleData`, `MarketingData`, tests) compile unchanged and get `.organization`.
- **CloudKit / migration:** a non-optional attribute *with a default* is handled by SwiftData lightweight migration (no manual step); existing rows materialize with the default. `BusinessProfile` is already mirrored, so adding a property does not change the `mirroredTypes` array.
- **Enrichment signal** for the nudge (never blocks anything):

```swift
/// Name is the hard gate for sending (see `canSendInvoice`). "Enriched" means the
/// profile also has the fields that make an invoice look complete: a postal address
/// AND a payment route. Tunable.
public var isProfileEnriched: Bool {
    !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && hasBankDetails
}
```

- **Intent helpers** on `EntityType` (presentation strings live in the app layer; the model exposes intent):

```swift
extension EntityType {
    public var issuerNameFieldLabel: String { self == .freelancer ? "Your name" : "Business name" }
    public var taxIDFieldLabel: String { self == .freelancer ? "Tax ID (optional)" : "Business Tax ID (EIN, VAT, …)" }
    public var showsTaxByDefault: Bool { self == .organization }
}
```

## 5. Onboarding flow (UI/UX applied)

`Step` becomes `welcome → identity` (drop `.client`, `.timer`). Keep the 2-dot progress indicator (orientation), the Back affordance (`escape-routes`), and the existing slide animation **gated on `reduced-motion`**. Bottom CTA respects the safe-area inset.

**Welcome screen:** unchanged. **Preserve the tagline `Text("Track hours.\nSend invoices.")` verbatim** (guarded by `LaunchTaglineUITests`). Optional, test-safe copy tweak: subtitle "Made for freelancers and consultants." → "Made for freelancers and small businesses." (the test does not assert this line).

**Identity screen (new step 2):**
- Title (Dynamic Type `title`): "Tell us about you".
- **Entity-type chooser = two descriptive selectable cards** (NOT a segmented control — this is a first-time identity decision that deserves prominence and a one-line explainer; segmented controls are for compact, well-understood toggles):
  - **Freelancer** — icon `person.fill`, subtitle "You invoice under your own name."
  - **Organization** — icon `building.2.fill`, subtitle "You invoice under a business name."
  - Each card: full-width, ≥56pt tall (`touch-target-size`), 12pt gap (`touch-spacing`). **Selected state = accent border (2pt) + filled checkmark + subtle accent fill** — never color alone (`color-not-only`). Pre-select Freelancer (core audience); user can switch.
  - Accessibility: each card is a `Button` with `accessibilityLabel` = title, `accessibilityHint` = subtitle, and the `.isSelected` trait toggled (`voiceover-sr`).
- **Name field:** visible caps label above the field (`input-labels`) = `selectedType.issuerNameFieldLabel` ("YOUR NAME" / "BUSINESS NAME"), reusing the existing onboarding `fieldLabel` style. Prompt = example ("Jane Smith" / "Acme Studio"). `textContentType` = `.name` (freelancer) / `.organizationName` (organization) for autofill (`autofill-support`); `.words` capitalization. **Auto-focus on appear** to cut friction.
- Reassurance (Dynamic Type `footnote`): "You can add your logo, tax, and bank details anytime in Settings."
- **One primary CTA** (`primary-action`): "Finish setup", enabled when the trimmed name is non-empty (validate on submit, not per-keystroke).

**`finish()` rewrite:**
- Fetch-or-create the singleton `BusinessProfile` via `defaultForCurrentLocale()`; set `entityType = selectedType`, `name = trimmedName`.
- **Do not** create a `Client`, `Project`, or `TimeEntry`.
- Set `OnboardingFlags.completedKey = true`; `onFinish()` → Today.

`OnboardingFlags.shouldShow` is unchanged in intent (flag-gated; `clientCount == 0` stays a safety net). **Keep the `--ui-test-show-onboarding` launch flag working** (used by `LaunchTaglineUITests`); optionally wire the reserved `--ui-test-skip-onboarding` flag.

## 6. Business Profile editor (Settings)

- New `@State entityType: EntityType`, loaded/saved with the profile.
- **Top of the Issuer section: a segmented `Picker`** (Freelancer / Organization) — compact native control is right here (repeat visitor, dense form; `system-controls`), with a one-line footer: "Freelancers invoice under their own name; organizations under a business name."
- **Name field label** = `entityType.issuerNameFieldLabel` (was hard-coded "Business name"); add `textContentType` as in onboarding.
- **Tax section is progressively disclosed for freelancers** (`progressive-disclosure`): when `entityType == .freelancer` and no rate is set, render it inside a collapsed `DisclosureGroup` "Add tax (if you charge it)" → the *simpler freelancer form*. For `.organization`, show it expanded (today's behavior). Same fields either way; capability is identical.
- **Tax-ID label** = `entityType.taxIDFieldLabel`.
- `loadIfNeeded()`/`save()` read/write `entityType`.
- **Settings list row** ([SettingsView.swift](../../../App/Sources/Features/Settings/SettingsView.swift)): append a passive "· Incomplete" hint to the Business-profile subtitle when `!profile.isProfileEnriched` (a quiet signal in a different screen — does not compete with the Today nudge).

## 7. Today nudges — **one at a time** (anti-clutter)

The previous draft risked stacking up to three banners. Per `primary-action` + `visual-hierarchy`, **show at most one guidance element**, by precedence (first match wins):

1. **Name missing** (`!canSendInvoice`, rare post-onboarding edge case, e.g. user cleared name) → the existing orange **"Add your business name"** warning banner only. Kept as a safety fallback.
2. **No active project** → the **"Get started" card** only. Suppress the enrichment nudge — don't pile onto a brand-new user.
3. **Profile not enriched** (`!isProfileEnriched`) **and not dismissed** → the **"Complete your profile"** nudge.

### 7a. "Get started" card (data nudge)
- Hero placement where the empty dashboard is otherwise barren (above `JumpBackInSection`).
- **One primary button** whose label is the single next step, plus a tiny "Step 1 of 2 · Client → Project" hint for orientation:
  - No client yet → "Add your first client" → presents `ClientEditorView(client: nil)` in a `NavigationStack` sheet.
  - Client exists, no project → "Create your first project" → presents `NewProjectSheet`.
- **Data-driven via `@Query`** (because `ClientEditorView` self-dismisses with no callback): when a client is created, the card reactively advances its CTA; when an active project exists, the card disappears.
- Copy aligns with the Work-tab empty state ("Add a client and a project to start tracking").

### 7b. "Complete your profile" nudge (enrichment)
- **Informational**, not a warning — distinct visual from the orange name banner (which actually blocks Send). Use an accent/neutral card with a `person.text.rectangle` icon; `color-not-only` (icon + text).
- **Dismissible:** a close control with a ≥44pt hit area (`.contentShape` + padding) and `accessibilityLabel("Dismiss")`; persists `UserDefaults` key `cadence.nudge.completeProfile.dismissed`.
- CTA → `BusinessProfileEditorView`.

## 8. Accessibility & interaction (cross-cutting)

- **Touch targets ≥44pt**, ≥8pt spacing — entity cards, the get-started button, the dismiss control.
- **VoiceOver:** descriptive `accessibilityLabel`/`Hint` on entity cards (with `.isSelected`), the dismiss button, and the get-started CTA; logical reading order.
- **Dynamic Type:** identity-screen labels/body use system text styles and must not truncate at the largest size (the welcome hero may keep its display size).
- **Reduced motion:** gate onboarding step transitions and any card entrance on `accessibilityReduceMotion`.
- **Contrast:** verify low-opacity onboarding text (e.g. `white.opacity(0.6)` on the dark gradient) meets ≥4.5:1; bump opacity if not. Verify both light/dark for the Today cards.
- **One primary action per screen**; secondary actions visually subordinate.

## 9. Invoice / PDF impact

None. Freelancer = `taxRate 0` → no tax line (renderer already omits at rate 0). Entity type is not printed; issuer is `profile.name`. No changes to `Invoice`, `InvoiceBuilder`, `InvoiceTemplate`, or the PDF renderer.

## 10. Developer credit fix

- [SettingsView.swift:111](../../../App/Sources/Features/Settings/SettingsView.swift): `"Cadence by Elden Studios Company"` → `"Elden Studios Company"`.
- [SettingsAboutUITests.swift:30-31](../../../App/BillableUITests/SettingsAboutUITests.swift): update lookup + assertion message to `"Elden Studios Company"`.

## 11. Testing

**BillableCore unit tests (Swift Testing):**
- `EntityType` raw round-trips; exactly two cases.
- `BusinessProfile` default `entityType == .organization`; `entityType` set mutates `entityTypeRaw`.
- `isProfileEnriched`: false when address empty OR no bank details; true when both present.
- `canSendInvoice` unaffected (still name-gated).
- Label helpers per case.
- **Back-compat:** existing `BusinessProfile(name:)` initializers still compile/behave (defaulted param).

**UI tests (BillableUITests):**
- New: onboarding picks **Freelancer** → name label "Your name" → Finish → Today shows the "Add your first client" card and **no auto-started timer**; picks **Organization** → label "Business name".
- Update `SettingsAboutUITests` → `"Elden Studios Company"`.
- **Preserve** `LaunchTaglineUITests`: keep the `"Track hours.\nSend invoices."` tagline and the `--ui-test-show-onboarding` flag.

**Verified non-impact:** `InvoicePreviewLineItemEditUITests` seeds data (skips onboarding) and is unaffected; the new defaulted field is back-compatible with its seeded profile.

## 12. Out of scope (YAGNI)

Per-entity invoice templates; region-based auto tax rates; multiple profiles; forced re-onboarding for existing users; entity type on the rendered invoice.

## 13. Confidence & residual risk

**~95% on the design/approach.** Underpinned by: tax model traced end-to-end (rate → snapshot → PDF); CloudKit mirror + lightweight-migration safety confirmed from `mirroredTypes`; editor/sheet signatures verified (the `@Query`-driven card fix); precise test-impact map (only `SettingsAboutUITests` must change); UI/UX decisions checked against Apple HIG / UI-UX rules (one-nudge precedence, descriptive cards, accessible dismissible nudges, autofill, progressive disclosure).

**Residual 5% (implementation-time verification, not open design questions):**
- On-device checks: Dynamic Type at largest size, dark/light contrast of low-opacity onboarding text, reduced-motion.
- `isProfileEnriched` rule (address AND bank) is a tunable product judgment.
- This branch forks the active `feature/project-detail-ia`; `TodayView` is the shared surface — rebase/coordinate before merge.
- **CloudKit reinstall smoke test** (per `TESTING.md`) must run before any TestFlight build since a mirrored model changed.
