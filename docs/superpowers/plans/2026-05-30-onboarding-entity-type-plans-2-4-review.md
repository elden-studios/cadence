# Plans 2–4 — Consistency Review Punch-List

Cross-plan consistency review of Plans 2–4 (authored in parallel from spec v5). **Verdict: cross-plan consistent ✅, spec coverage complete ✅ (§5–§14), verification realism ✅.** Apply the fixes below **during execution** (they were not surgically patched into the long plan files). Severity-ordered.

## [MAJOR] Plan 3 · Task 8 — `--seed-onboarding-needs-setup` won't compile as written
The snippet does `container.mainContext.insert(profile)` but **never builds the App-Group container nor assigns `self.container`** → use-before-assignment of the `let` stored property + undefined `container`. Every real branch in `BillableApp.init()` (`--seed-demo`, `--seed-marketing`, production `else`) builds a local container and ends with `self.container = appGroup`.
**Fix:** mirror the `--seed-marketing` branch exactly — build `let appGroup = try BillableModelContainer.appGroup("group.com.eldenstudios.billable")`, `self.container = appGroup`, **then** insert + save the seeded profile into `appGroup.mainContext`. Note: the reset helper takes the literal group string `"group.com.eldenstudios.billable"` (there is no `appGroupID` constant).

## [minor] Plan 4 · Task 2 — `Invoice(...)` test call is missing required args
`ActivationMetricsTests` calls `Invoice(number: "0001", createdAt: …)`, but `Invoice.init` has ~10 **required** non-defaulted params (`number`, `dueAt`, `clientNameSnapshot`, `issuerNameSnapshot`, `issuerAddressSnapshot`, `issuerEmailSnapshot`, `paymentTermsSnapshot`, `taxLabelSnapshot`, `taxRateSnapshot`, `currencyCodeSnapshot`). The two-arg call won't compile.
**Fix:** read `Invoice.init` and supply all required snapshot args in the test (or add/locate an `Invoice` test factory). Only `createdAt` is asserted, so the other values are arbitrary-but-valid.

## [minor] Plan 2 · self-review note — false claim about §12 dev credit
Plan 2's self-review says the dev credit is "already 'Elden Studios Company' … no edit." **This is false** — `SettingsView.swift:111` currently reads `Text("Cadence by Elden Studios Company")`. **Plan 4 · Task 1 correctly owns** the fix (TDD: flip the `SettingsAboutUITests` assertion → watch it fail against "Cadence by …" → change L111 → pass). Ignore Plan 2's note; do NOT skip Plan 4 T1.

## [minor] Plan 2 · Task 8 — make `--ui-test-skip-onboarding` wiring UNCONDITIONAL
Plan 2 makes the RootView `--ui-test-skip-onboarding` branch conditional ("only if the suite fails"). For deterministic onboarding gating regardless of seed/launch-arg order, wire it **unconditionally** in `RootView.onAppear` + the scenePhase re-eval.

## [minor] Plan 3 · Task 3 — `startingQuickTimer` debounce is synchronous
`startQuickTimer()` sets the flag true, calls `TimerActions.start`, then resets it false synchronously — so a same-frame double-tap isn't actually blocked by the flag. The **real** dedupe guarantees are (a) the idempotent fetch-or-create of the single `name=="General"` clientless project and (b) `TimerService.start` no-op'ing a same-project timer (and the Task-9 UI test asserts exactly one General).
**Fix:** either clear `startingQuickTimer` asynchronously (after the running entry is observed) so the disabled state is real, or add a code comment stating the flag is only for the "Starting…" affordance and the dedupe lives in fetch-or-create + TimerService.

## [minor] Copy-consistency pass — `isProfileEnriched` surfaces
Three+ surfaces key off `!isProfileEnriched` with similar wording (editor "Incomplete" section, Settings-row "Incomplete", Today enrichment nudge, invoice-time prompt). Ownership is correct (distinct surfaces per §6 vs §7b), but do a quick copy pass so they don't read as duplicated nags.

---
*No blanket TBD/TODO placeholders were found. The only intentional placeholders are the Plan-4 `project.pbxproj` 24-hex IDs (regenerate fresh, or use Xcode's drag-to-build-phase) and the flagged `Invoice.init` test args above.*
