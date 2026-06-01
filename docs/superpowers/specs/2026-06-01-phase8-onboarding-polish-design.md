# Phase 8 — Onboarding/entity + clients/currency polish (design)

**Date:** 2026-06-01
**Program:** Cadence product-review fix program — **the final phase** (Phases 1–7 shipped; `main` = `1500c48`).
**Source:** the remaining backlog cluster (`docs/reviews/2026-05-31-cadence-verified-backlog.md`), **re-baselined against current `main`** by a 14-agent workflow.
**Branch:** `feature/phase8-onboarding-polish` (worktree off `origin/main` `1500c48`).

## Scope & constraint

The last parked cluster — entity-type/business-profile coherence, payment-reminders polish, and empty-state/recurrence/onboarding cleanup. **Hard constraint: no net-new features** — every item surfaces broken state, reconciles a default, aligns copy, wires an existing property, gates a preview, or removes dead code.

**Re-baseline result:** of 13 candidates, **11 are genuinely open**, **1 is dropped**:
- **F44 (WorkView "No client" group) — FALSE POSITIVE, do NOT action.** The backlog said "no creation path produces a client-less project," but onboarding's quickStart now persists a client-less **"General"** project (`GetStartedSection.fetchOrCreateGeneralProject`), and Phase 7 made `ProjectEditor.client` optional — so the "No client" group is **load-bearing** for the activation funnel's only Work-tab surface. Removing it would break quickStart. (Optional: a one-line clarifying comment at `WorkView.swift:~111` so a future reviewer doesn't repeat the misdiagnosis.)

**Locked fork decisions (user):** (1) align EntityType default → **`.freelancer`**; (2) entity control → **rewrite the editor footer copy** (keep the segmented Picker); (3) reminder preview → **hide when off**; (4) "Incomplete" badge → **fix the `isProfileEnriched` definition**.

**BillableCore touches** (need a package test pass, not just app build): NEW-S2-2 (`BusinessProfile` default) and NEW-S7-5 (`isProfileEnriched`); NEW-S2-1 exercises the existing `EntityType.showsTaxByDefault` (covered by `EntityTypeTests`). Everything else is App view-layer.

---

## WS-A — Entity-type & business-profile coherence  ·  `BusinessProfileEditorView.swift`, `BusinessProfile.swift` [BillableCore], `SettingsView.swift`, `BillableApp.swift`, tests

Five items that cluster in `BusinessProfileEditorView` + the `EntityType`/`BusinessProfile` model — build together (heavy file overlap).

- **NEW-S2-1 (dead-code policy → single source of truth).** `EntityType.showsTaxByDefault` (`{ self == .organization }`) is referenced only in its def/doc/test, never in app code; `BusinessProfileEditorView.swift:~93` re-encodes the rule as a literal `if entityType == .organization { taxFields } else { DisclosureGroup(...) }`. **Fix:** replace the literal with `if entityType.showsTaxByDefault`. No behavior change; wires the existing property into the place that implies it.
- **NEW-S2-2 (default reconciliation → `.freelancer`).** Model/seed/locale-helper default to `.organization` while both UIs start at `.freelancer`. **Fix (decided):** set the stored `entityTypeRaw` default (`BusinessProfile.swift:~65`) **and** the `init` default (`~110`) to **`.freelancer`**; **keep** the CloudKit-decode getter fallback (`~68`) at `.organization` **with a clarifying comment** (it only fires for corrupt/unknown raw values — a conservative "show more UI" decode guard). Update the `--seed-onboarding-needs-setup` fixture expectation (`BillableApp.swift:~68`) and **any test asserting the old `.organization` default** (grep `EntityTypeTests` / BusinessProfile default tests). `defaultForCurrentLocale()` (`~218-225`) inherits the new default. **This is a behavioral default shift for newly-created profiles** — verify tests.
- **NEW-S2-3 (control consistency → footer copy).** Onboarding teaches with descriptive cards (title + subtitle); the editor's segmented Picker drops the subtitle. **Fix (decided):** keep the segmented Picker; **rewrite the editor's section footer (`~:73`)** to use onboarding's `cardSubtitle` wording (`EntityType+Presentation.swift`) so the explanation matches. Copy-only.
- **NEW-S7-3 (live tax-rate hidden on toggle).** The tax Section renders Org inline vs Freelancer-inside-`DisclosureGroup(isExpanded:$taxExpanded)`; `taxExpanded` is set only in `loadIfNeeded` (`~:267`), so switching entityType live to Freelancer hides a freshly-entered rate. **Fix:** add `.onChange(of: entityType)` that sets `taxExpanded = (taxRatePercent != 0)` (mirroring `loadIfNeeded`), so a non-zero rate is never hidden. (Coheres with NEW-S2-1 — same tax-section branch `~92-99`.)
- **NEW-S7-5 (Incomplete badge → fix the definition).** `isProfileEnriched = !address.isEmpty && hasBankDetails` (`BusinessProfile.swift:~78-80`) flags bank-less profiles, contradicting the editor footer ("Leave blank to hide") and `canSendInvoice` (gates on name only). **Fix (decided):** rebase `isProfileEnriched` on **name + address only** (drop `hasBankDetails`); the `SettingsView` "Incomplete" badge (`~41-47`) then only fires when name/address are missing. **Remove the now-redundant in-editor "Incomplete" row** (`BusinessProfileEditorView.swift:~184-197`). **Add/Update a BillableCore test** for `isProfileEnriched` (name+address only; bank-less = enriched). [BillableCore]

## WS-B — Payment reminders  ·  `PaymentRemindersView.swift` (one file)

Three adjacent edits in the same Form.

- **F26 (preview sender name).** `senderName: "Studio Lina"` literal at `~:149` and `~:155` → **`profiles.first?.name ?? "Your business"`** (the `profiles` `@Query` is already in scope, used at `:13`). Two one-line changes.
- **NEW-S7-1 (zero-offsets silent no-op).** When `masterEnabled` is true but all four offset toggles are off (`enabledSet.isEmpty`), no reminder ever sends with no warning. **Fix:** add a conditional `footer` to `offsetsSection` (`~77-91`) shown only when `masterEnabled && enabledSet.isEmpty`: *"Pick at least one timing or no reminders will send."* (reuse the `.caption`/`.secondary` styling at `~65-67`).
- **NEW-S7-2 (preview renders when off → hide).** `previewSection` (`~144-181`) renders unconditionally even though the editor fields grey out when off. **Fix (decided):** gate it — `if masterEnabled { previewSection }` (matches the disabled-field communication).

## WS-C — Empty-states / recurrence copy / onboarding cleanup  ·  3 independent App files

- **F4 (empty-state CTAs).** WorkView "No projects yet" (`WorkView.swift:~138-143`) has no action; add an `actions:` closure surfacing the existing **"Add Client"** (`showingNewClient = true`) + **"New Project"** (`showingNewProject = true`) — both `@State` already declared — mirroring `ClientsListContent`'s `borderedProminent` pattern. NewProjectSheet "No clients yet" (`~193-198`) add an **"Add Client"** action (new `@State showingAddClient` + `.sheet { NavigationStack { ClientEditorView(client: nil) } }`) so the user isn't forced to back out. (Fold the optional F44 clarifying comment here — same file.)
- **F27 (recurrence copy + ended-template actions).** Empty-state copy (`RecurringRulesView.swift:~23`) names a non-existent "New Invoice screen" → rewrite to the real entry point: *"To set up recurring billing, open the Invoices tab, tap +, then turn on 'Make this recurring'."* And the swipe actions (`~31-39`) always offer Pause/Resume even for **Ended** templates (`isEnded()`, `~122-124`) → **hide Pause/Resume when `isEnded()`** (leave Delete). (The PendingMaterializationsView sub-claim is a *false positive* — `pendingMaterializations` already filters out ended templates — so no change there.)
- **NEW-S2-4 (inert FocusState cleanup).** `@FocusState private var nameFocused` (`OnboardingView.swift:~18`) + `.focused($nameFocused)` (`~119`) is never assigned (intentionally, so the keyboard can't hide the entity cards). **Fix:** remove the unused `@FocusState`/`.focused` pair (pure dead-code cleanup; keep the no-auto-focus behavior the comment describes).

## Coupling & build order

1. **WS-A** is the most coupled (4–5 items overlapping `BusinessProfileEditorView` + the BillableCore model) and the **only BillableCore-default change** — build it **first** to set the entity baseline. One PR-unit.
2. **WS-B** is one file (`PaymentRemindersView`), 3 small adjacent edits — independent.
3. **WS-C** is 3 disjoint files — independent.

All three can land in **one Phase 8 PR** (sequential subagent tasks: WS-A → WS-B → WS-C). WS-B/WS-C are App-only.

## Test plan

- **BillableCore `swift test`:** update the EntityType/BusinessProfile default test to expect **`.freelancer`** (NEW-S2-2); add/adjust an `isProfileEnriched` test (name+address only; bank-less = enriched) (NEW-S7-5). All green (≈345 ± the adjusted tests).
- **App + widget build:** `** BUILD SUCCEEDED **` after each WS + at the end.
- **Runtime (seeded sim):** new profile defaults to Freelancer; editor entity footer matches onboarding wording; switching Org→Freelancer with a typed rate keeps it visible; an intentionally bank-less profile is NOT flagged "Incomplete"; reminders with master-on/zero-offsets shows the warning caption; preview hidden when reminders off; preview signs the real business name; Work "No projects yet" + NewProject "No clients yet" show working CTAs; RecurringRules empty-state copy points to the real flow; an Ended template offers only Delete.

## Out of scope / not actioned

- **F44** (remove "No client" group) — false positive; the group is load-bearing for quickStart (keep; optional clarifying comment only).
- **NEW-S2-2 getter-fallback flip** to `.freelancer` (option 2) — not taken; fallback stays `.organization` (conservative decode guard).
- **NEW-S7-2 dimmed-preview** (option B) — not taken; preview hidden when off.
- **NEW-S7-5 reword-badge** (option B) — not taken; fixed the definition instead.
- This is the **last phase** — after it merges, the product-review fix program is complete.
