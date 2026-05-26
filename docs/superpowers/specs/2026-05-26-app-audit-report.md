# Cadence — App Audit Report (Post-v1.3)

**Date:** 2026-05-26
**Audit target:** `main` at `34c0abd` (v1.2 + v1.3 merged)
**Audit scope:** every page, every button, every flow — critical / important / polish / nits
**Auditor session:** brainstorming flow (superpowers:brainstorming) used as the wrapper for the audit + this remediation report; new features explicitly out of scope per user direction

---

## TL;DR

Cadence at v1.3 is **structurally healthy**. 156 tests pass, zero build warnings in Cadence code, all major flows work, no crashes observed across the screens that were driven this session. The wedge (Track → Review → Invoice) is intact and the soft-paywall + 7-day trial + watermark model is consistent across all entry points.

The audit identified **2 critical items**, **4 important items**, **7 polish items**, and **3 nits**. None are blockers to a closed TestFlight build. **2 critical items must be addressed before App Store submission** (the placeholder legal URLs are real, but the GitHub Pages enablement that resolves them is on the user; the missing accessibility label on the paywall close button could trigger an App Store accessibility-policy concern).

The pre-existing v1.1.3 polish queue (#118-#121) and the v1.2 holistic-review follow-ups partially overlap with this audit's findings — they're consolidated here.

---

## 1. State of the union (what's good)

Positive findings worth noting:

- **All 156 BillableCore tests pass in 0.5s.** No flakiness, no skips, no failures.
- **Zero new build warnings** in Cadence code (dependencies' warnings excluded). No deprecated-API usage in our own code on iOS 26.5 SDK.
- **No `print()` debug leftovers** anywhere in production code.
- **Empty states are well-covered** with `ContentUnavailableView` (Clients, Invoices, Recurring rules, Pending materializations, Reports) — descriptions tell the user what to do next.
- **Onboarding tagline is honest** ("Track hours. Send invoices." — no over-promised "get paid" claim).
- **All paywall triggers route to the right copy** after the v1.2 + v1.3 work (3 cases: .reports / .settings / .removeWatermark; no orphan .createInvoice or .extraClient).
- **Watermark renders as real PDF text** (PDFKit text-extraction verified in tests), so reviewers can confirm it without rendering.
- **PDF cache invalidates on entitlement change** (cacheIsStale heuristic added by v1.2 review fixup).
- **Resume Last @Query has fetchLimit 1** (perf concern flagged in v1.3 Task 2 review was already fixed in `f9fff44`).
- **Currency is locale-aware** end-to-end on Today, Timer, ClientDetail, PaymentReminders, LiveActivity, PDF — Saudi user gets SAR by default.
- **Business profile defense is in place** — banner on Today + Preview button disabled when business name is empty.

---

## 2. Critical (must fix before App Store submission)

### C-1. Paywall close button has no accessibility label

**File:** `App/Sources/Features/Paywall/PaywallView.swift:60`

```swift
Button { dismiss() } label: { Image(systemName: "xmark") }
```

The `xmark` icon-only button has no `.accessibilityLabel("Close")`. VoiceOver users hear nothing useful when they focus this button. App Store's accessibility guidelines flag icon-only buttons without labels.

**Fix:** Add `.accessibilityLabel("Close paywall")` to the button modifier chain.

**Effort:** 1 minute.

---

### C-2. Legal URLs require user-side GitHub Pages enablement to resolve

**Files:**
- `App/Sources/Features/Paywall/PaywallView.swift` lines 244-245 — points to `https://elden-studios.github.io/cadence/legal/{terms,privacy}`
- `docs/legal/terms.md` + `docs/legal/privacy.md` — template stubs, not real legal content yet
- `docs/_config.yml` — Jekyll config; GitHub Pages is NOT yet enabled on the repo

**Risk:** If a user (or App Store reviewer) taps Terms or Privacy on the paywall right now, they get a GitHub 404. Apple WILL reject the submission for "broken Terms of Use link."

**Fix sequence (user-side, not code):**
1. Enable GitHub Pages on the cadence repo: Settings → Pages → Source: "Deploy from a branch" → Branch: `main` / `/docs`.
2. Wait ~1 minute for the URLs to resolve.
3. Replace the markdown stubs with real legal text. Free generators: TermsFeed, iubenda.
4. Verify in a browser that both URLs render.

**Effort:** 30-45 minutes of user-side work; no code changes.

---

## 3. Important (high-priority polish before launch)

### I-1. Silent error swallow on `try? modelContext.save()` (15+ sites)

**Files (15 sites):** ClientsView (3), ClientDetailView (3), ClientEditorView (3), RecurringRulesView (2), PaymentRemindersView (1), BusinessProfileEditorView (1), ProjectEditorView (1), TodayView (1).

```swift
try? modelContext.save()  // silent swallow
```

If `save()` fails (CloudKit conflict, out-of-disk, schema validation), the user sees zero feedback. They believe they saved a client / project / profile but the data is gone. CloudKit conflicts are rare but real, especially when the user is on two devices simultaneously.

**Fix:** Introduce a `save(or:)` helper that surfaces failures via a toast or simple alert. For v1, a basic banner that says "Save failed — try again" is sufficient. Each call site changes from `try? modelContext.save()` to `try? modelContext.saveOrShowError()`.

**Effort:** 1-2 hours (helper + sweep + smoke test).

---

### I-2. Pre-existing v1.1.3 polish queue (#118-#121) is unaddressed

These were captured at v1.1.2 holistic review but not yet implemented:

- **#118:** `TodayView.showEmptyBusinessBanner` duplicates the trim-and-check logic from `BusinessProfile.canSendInvoice`. Replace inline with `!BusinessProfile.canSendInvoice(profile: profiles.first)`.
- **#119:** `Packages/BillableCore/Sources/BillableCore/Persistence/SampleData.swift:20` still has `currencyCode: "USD"` hardcoded. Should use `Locale.current.currency?.identifier ?? "USD"`.
- **#120:** `ClientDetailView.swift:153` has `?? "USD"` fallback. For consistency with `defaultForCurrentLocale`, should fall back via the same logic.
- **#121:** No UI test asserts the launch screen tagline. A regression could silently break "Track hours. Send invoices." back to old copy.

**Effort:** ~2 hours combined.

---

### I-3. Stale TODOs in code

**Files:**
- `App/Sources/Features/Recurrence/RecurrenceEditorView.swift:156` — `// TODO(v1.1.1): Add a permission banner on RecurringRulesView (sweep P3).` — Per the resume note, v1.1.1 P3 (#67) was already completed. The TODO is stale; the work is done.
- `App/Sources/Features/Today/TodayView.swift:146` — `// TODO(step5): surface error via toast` on `QuickStartRow`. Same concern as I-1 (silent error path). Resolves alongside I-1.
- `Packages/BillableCore/Sources/BillableCore/Subscriptions/SubscriptionManager.swift:241` — `// TODO: Propagate restore errors when the restore flow is redesigned`. Carried from v1.1.2 Task 1 review. Restore flow redesign is its own task.

**Fix:** Delete stale TODOs (RecurrenceEditorView) and link the other two to tracked tasks.

**Effort:** 5 minutes.

---

### I-4. App Store metadata + assets still needed

These are user-side parallel work, not code, but they're required before submission:

- **App Privacy questionnaire** in App Store Connect — declare what data is collected (CloudKit-only, no analytics).
- **App Store screenshots** at 6.7" / 6.5" / 5.5" — 3-10 each.
- **App Store listing copy** — title, subtitle, description, promotional text, keywords (max 100 chars).
- **Support URL** + **Marketing URL** (optional but recommended).
- **Age rating questionnaire**.
- **App icon at all sizes** — likely already configured, but verify.

**Fix:** Block out 2-3 hours user-side. Use the existing Cadence orange-ring brand for visual consistency in screenshots.

**Effort:** 2-3 hours of user-side asset work; no code changes.

---

## 4. Polish (nice-to-have improvements)

### P-1. `TodayView.swift` is 478 lines (8 nested private structs)

The file has grown to include `TodayView` + `TodayActiveTimerSection` + `RunningTimerCard` + `ResumePill` + `QuickStartRow` + `TodaySummarySection` + `UninvoicedTile` + a couple smaller subviews. None individually are too large, but the file is harder to scan.

**Fix:** Split into 3-4 files: `TodayView.swift` (root), `TodayActiveTimerSection.swift` (timer card + pill), `TodaySummarySection.swift` (today summary tiles). Mechanical refactor; no behavioral change.

**Effort:** 30-45 min including test runs.

---

### P-2. `_forceIsProForTesting` is dead code (carried v1.2 follow-up)

**File:** `Packages/BillableCore/Sources/BillableCore/Subscriptions/SubscriptionManager.swift` lines 111-113.

No test calls `_forceIsProForTesting` any more — all entitlement-related tests use `_setEntitlementForTesting`. The method is redundant.

**Fix:** Mark with `@available(*, deprecated, renamed: "_setEntitlementForTesting")`, or just delete. Carried from v1.2 holistic review.

**Effort:** 5 minutes.

---

### P-3. Hardcoded `7 * 24 * 60 * 60` trial duration (v1.2 follow-up)

**File:** `Packages/BillableCore/Sources/BillableCore/Subscriptions/SubscriptionManager.swift` — appears in `introOfferDaysRemaining` AND `currentIntroOfferDaysRemaining`. If the trial period changes in `Billable.storekit` (e.g., to 14 days), both magic numbers need updating in sync.

**Fix:** Extract `private static let trialDuration: TimeInterval = 7 * 24 * 60 * 60` and reference. Carried from v1.2 holistic review.

**Effort:** 10 minutes.

---

### P-4. Grace-period mapping missing in `Entitlement` resolution (v1.2 follow-up)

**File:** `Packages/BillableCore/Sources/BillableCore/Subscriptions/SubscriptionManager.swift` `refreshEntitlements`.

A user whose subscription is in Apple's grace period (failed auto-renewal but Apple is retrying) currently drops to `.free` because no active verified transaction exists. They should stay `.pro` until the grace period ends so they don't lose features during a transient billing issue.

**Fix:** Check `Product.SubscriptionInfo.Status.state` and map `.inGracePeriod` + `.inBillingRetryPeriod` to `.pro`.

**Effort:** 30 minutes + 1 test.

---

### P-5. SubscriptionManager test count is thin

The `PaywallEligibilityTests` covers default-false + the v1.3 backfill OR-logic (3 tests). `SubscriptionManagerEntitlementTests` covers the happy paths (6 tests). Missing:
- A test for `refreshEntitlements` end-to-end with a mocked verified transaction.
- A test for the grace-period mapping (P-4 above).

Acceptable for v1.3 — file for v1.4 alongside the grace-period work.

---

### P-6. Onboarding tagline + ResumePill banner + Today's empty-business banner all use slightly different styles

Visual consistency drift detected:
- Empty business banner uses `.orange.opacity(0.12)` + `.rect(cornerRadius: 12)` + `HStack spacing: 8` + chevron-right trailing.
- ResumePill (after Task 5 cosmetic fix) uses `.secondarySystemBackground` + `.rect(cornerRadius: 12)` + `HStack spacing: 8` + no chevron.

They're banners doing different jobs — orange = "warning, take action"; gray = "convenience offer". The styling difference encodes meaning correctly, but it's worth a deliberate decision to keep them visually distinct. No fix needed unless you decide they should look the same.

**Effort:** 0 (already aligned per Task 5 cosmetic fixup) — flagged just for awareness.

---

### P-7. No localization infrastructure — 185 hardcoded English strings in App/Sources

Cadence ships English-only for now. For Saudi market (which the v1.1.2 currency work targeted), invoice PDF copy is still English. Pre-TestFlight this is fine. Pre-App-Store Saudi launch, Arabic localization + RTL support is required.

**Fix:** Introduce `String(localized:)` + `Localizable.xcstrings`. Sweep 185 sites.

**Effort:** 1-2 days for the sweep + 1 day for Arabic translations + RTL layout fixes.

**Recommendation:** Defer until you have a confirmed market direction. English-first App Store launch is fine.

---

## 5. Nits (optional, low priority)

### N-1. `ModelContainer+Billable.swift:170` — `.first!` force-unwrap on `applicationSupportDirectory`

The `FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!` is technically a force-unwrap, but on iOS the Application Support directory ALWAYS exists. False alarm; standard pattern.

**Fix:** None needed. Could be defensively rewritten with `guard let` but adds no real safety.

---

### N-2. `restore()` error path swallows the message (v1.1.2 Task 1 partial refactor)

**File:** `Packages/BillableCore/Sources/BillableCore/Subscriptions/SubscriptionManager.swift` `restore()`.

Documented in code as a partial refactor — the lastError property was removed but restore's error path wasn't redesigned. Currently returns `false` silently. A redesign of the restore flow would address this cleanly.

**Effort:** Part of a "restore flow redesign" — small standalone task.

---

### N-3. Spec/plan markdown files appear in the published GitHub Pages site unless explicitly excluded

`docs/_config.yml` excludes `superpowers/` from the published site, which is correct. But if you add new docs (FAQ, About, Help), make sure they're either intentional or also excluded. No action needed today.

---

## 6. Summary: what to fix and in what order

### Pre-TestFlight (must)
- **C-1:** Add accessibility label to paywall close button. (1 min)

### Pre-App-Store-Submission (must)
- **C-2:** Enable GitHub Pages + write real legal content. (45 min, user-side)
- **I-4:** App Store Connect assets + metadata. (2-3 h, user-side)

### v1.3-batch polish (recommended next coding sprint)
- **I-1:** Surface save() errors via a tiny helper. (1-2 h)
- **I-2:** Knock out the four v1.1.3 queue items (#118-#121). (~2 h)
- **I-3:** Sweep stale TODOs. (5 min)
- **P-2:** Remove dead `_forceIsProForTesting`. (5 min)
- **P-3:** Extract `trialDuration` constant. (10 min)

### v1.4 candidate (when scale or market direction warrants)
- **P-4:** Grace-period mapping. (30 min)
- **P-5:** Backfill SubscriptionManager integration tests. (1 h)
- **P-1:** Split `TodayView.swift`. (45 min)
- **P-7:** Localization sweep + Arabic. (2-3 days)
- **N-2:** Restore flow redesign. (separate task)

### No-action
- **N-1, N-3, P-6** — flagged for awareness only.

---

## 7. Approval gate

User triages this list. Pick the ones to fix; the picks become a v1.3-polish plan via `superpowers:writing-plans`. Items not picked stay in this report as future-reference.

**User to confirm before plan-writing:**
1. ✅ Fix C-1 (1 min) — should be in any plan
2. ✅ User commits to C-2 + I-4 (user-side) before App Store submission
3. ⬜ Which of I-1, I-2, I-3 to include in the v1.3-batch coding plan?
4. ⬜ Which of P-1 through P-7 to include?
5. ⬜ Any item to skip entirely?
