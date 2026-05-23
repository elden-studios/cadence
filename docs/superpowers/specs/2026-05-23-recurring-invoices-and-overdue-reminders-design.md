# Cadence v1.1 — Recurring Invoices + Auto-Overdue Reminders

**Status:** Design approved · ready for implementation plan
**Date:** 2026-05-23
**Phase:** v1.1 (of the post-v1 four-phase roadmap)
**Estimated scope:** ~1 week
**Spec author session:** brainstorming flow (superpowers:brainstorming)

---

## 1. Summary

Two small, compounding features that ship together as Cadence v1.1:

1. **Recurring invoices** — schedule monthly / weekly / biweekly auto-generation of invoice drafts for retainer-style clients. On the scheduled date, Cadence reminds the user, drafts the invoice from tracked time, and routes them to review and send.
2. **Auto-overdue reminders** — when an invoice goes overdue, Cadence schedules escalating local notifications (default +3 / +7 / +14 days after `dueAt`). Tapping a notification opens the invoice with a pre-filled reminder email ready for the user to send.

Both features share one new internal primitive (`Scheduler`) and a single design philosophy: **local-first** — Cadence never sends an email or finalizes an invoice on the user's behalf. iOS fires the notification; the user opens the app and presses Send. No server, no email provider, no cost, no PDPL custody on our side.

---

## 2. Goals & non-goals

### Goals
- Give every existing Pro user a real reason to renew without expanding the support surface (no new infra to operate).
- Use mostly existing primitives — `InvoiceBuilder`, `MFMailComposeViewController` / `mailto:`, the v1 invoice state machine.
- Ship in ~1 week, including tests.
- Lay a small internal foundation (`Scheduler`) that pays back when v1.2 (Stripe Connect) introduces backend infra.

### Non-goals (deferred)
- **Backend-driven sending** — Cadence does not auto-send emails or finalize invoices in the background. User is always in the loop. Reconsider if/when v1.2 introduces backend infra anyway.
- **Per-client reminder templates** — global subject/body only. Per-client *schedule* override is in scope.
- **Recurring with fixed-amount invoices** — Cadence's wedge is time-driven; fixed-amount recurring (à la QuickBooks retainer) is out of scope until user demand asks.
- **Notification action buttons** (inline "Skip this month", "Send reminder") — defer to v1.2+.
- **App Intents for Recurring/Reminders** — defer to v1.3+ alongside Expenses.
- **User-configurable fire time of day** — fixed at 8:00am local for v1.1.
- **Per-cycle tz/DST rebuild of pending fires** — accept one cycle of drift on tz change.

### Forward references to v1.2 (Payment Links)
Three lines in the design acknowledge but do not design v1.2:
- The `Scheduler` primitive's payload routing is built to extend to Stripe webhook dispatch when v1.2 lands.
- Reminder emails will continue to go through Mail.app; v1.2's Stripe Connect changes nothing about this.
- Observability via `OSLog` is local; structured remote events can ship upstream if/when v1.2 introduces backend infra.

---

## 3. Architecture

Three new modules in `BillableCore`:

```
┌─────────────────────────────────────────────────────────────┐
│  App layer (SwiftUI views)                                  │
│  ┌───────────────────────┐    ┌──────────────────────────┐ │
│  │ RecurringRulesView    │    │ PaymentRemindersView     │ │
│  │ "🔁 Make recurring"   │    │ (Settings)               │ │
│  │ on InvoiceGenerator   │    │ + ClientEditor override  │ │
│  └───────────────────────┘    └──────────────────────────┘ │
└─────────────┬───────────────────────────────┬──────────────┘
              │                               │
              ▼                               ▼
┌─────────────────────────────────────────────────────────────┐
│  BillableCore — feature services                            │
│  ┌───────────────────────┐    ┌──────────────────────────┐ │
│  │ RecurrenceService     │    │ ReminderService          │ │
│  │ - createTemplate      │    │ - scheduleForInvoice     │ │
│  │ - nextOccurrence      │    │ - cancelForInvoice       │ │
│  │ - materializeDraft    │    │ - composeReminderEmail   │ │
│  │ - reconcile           │    │                          │ │
│  └─────────────┬─────────┘    └────────────┬─────────────┘ │
│                │                           │               │
│                └───────────┬───────────────┘               │
│                            ▼                               │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ Scheduler (shared primitive, domain-knowledge-free)  │  │
│  │ - schedule(id:, fireAt:, payload:)                   │  │
│  │ - cancel(id:)                                        │  │
│  │ - resyncOnLaunch()  ← reconciles SwiftData ↔ iOS     │  │
│  │ - handleNotificationTap(payload:)                    │  │
│  └──────────────────┬───────────────────────────────────┘  │
└─────────────────────┼───────────────────────────────────────┘
                      ▼
          UNUserNotificationCenter (iOS)
                      +
           SwiftData (persisted state)
```

### Module responsibilities

**`Scheduler`** — single narrow primitive (~80–120 lines). Wraps `UNUserNotificationCenter` requests; persists each pending notification's `(id, fireAt, payload)` to SwiftData for cold-launch reconciliation (iOS drops scheduled notifications across force-quits, reboots, and the 64-pending overflow). One opaque `SchedulerPayload` enum routes notification taps to the right service. **No domain knowledge of invoices or reminders** — `Scheduler` is a calendar with callbacks.

**`RecurrenceService`** — owns the `RecurrenceTemplate` model and the logic for "given a template and today's date, what's the next occurrence?". On occurrence fire (via `Scheduler` tap handoff), materializes a *Draft* invoice using existing `InvoiceBuilder.createDraft(...)` (no new finalize/PDF code) and routes the user to `InvoicePreviewView`. Updates `lastFiredAt` only when materialization actually happens — not when the iOS notification fires.

**`ReminderService`** — owns `ReminderConfig` (global default) and `InvoiceReminderSchedule` (per-invoice). On `Invoice.markSent(at:)`, computes the fire schedule and registers fires with `Scheduler`. On `Invoice.markPaid(at:)`, cancels all remaining fires. On tap, opens `InvoiceDetailView` and pre-populates the existing v1 reminder mail composer.

### Why three modules instead of two

The `Scheduler` genuinely doesn't know what an invoice is, and that's the point — it can be tested in isolation against a fake `UNUserNotificationCenter`, and it's the same primitive that would route (say) a Year-in-Review nudge in a later release. `RecurrenceService` and `ReminderService` *do* know about invoices, so they live above it.

### App-target footprint

- One `@UIApplicationDelegateAdaptor`-backed `AppDelegate` (currently absent — Cadence is pure SwiftUI App). Sole job: be the `UNUserNotificationCenterDelegate`.
- One new `@Observable NotificationRouter` consumed by `RootView`.
- Two new SwiftUI views (`RecurringRulesView`, `PaymentRemindersView`).
- Three small additions to existing views (`InvoiceGenerator` toggle, `ClientEditor` section, `Invoices` tab segment).

No other app-target changes.

---

## 4. Data model

Four new SwiftData `@Model` classes in `BillableCore/Models/`, plus one field on `Client` and one inverse relationship on `Invoice`.

### New models

```swift
// — Recurrence ———————————————————————————————————————————————

@Model public final class RecurrenceTemplate {
    @Attribute(.unique) public var id: UUID
    public var client: Client?
    public var rangeRule: String         // "previousMonth" | "previousWeek" | "previousBiweek" — implied by cadence; stored for clarity, not exposed in v1.1 UI
    public var grouping: String          // LineItemGrouping raw value: "perEntry" | "perProject"
    public var notesTemplate: String?    // supports {month}, {year}, {clientName} merge fields
    public var cadence: String           // "monthlyDay:1" | "weekly:mon" | "biweekly:mon"
    public var nextFireDate: Date
    public var lastFiredAt: Date?
    public var endDate: Date?            // optional auto-stop
    public var isActive: Bool
    public var createdAt: Date
}

// — Reminders ————————————————————————————————————————————————

@Model public final class ReminderConfig {                  // singleton, one per user
    @Attribute(.unique) public var id: UUID
    public var enabledOffsets: [Int]     // active offset days; default [3, 7, 14]. UI shows fixed chips [3, 7, 14, 30] that toggle membership.
    public var subjectTemplate: String   // "Friendly reminder: {invoiceNumber}"
    public var bodyTemplate: String      // multi-line, supports {clientName} {clientFirstName} {amount} {dueDate} {daysOverdue} {senderName} {invoiceNumber}
    public var masterEnabled: Bool       // overall on/off switch
}

@Model public final class InvoiceReminderSchedule {
    @Attribute(.unique) public var id: UUID
    public var invoice: Invoice?         // owning invoice
    public var fireDates: [Date]         // resolved at the Sent transition
    public var firedDates: [Date]        // each entry recorded after user actually opens via the notification
}

// — Scheduler bookkeeping (local-only, NOT CloudKit-mirrored) —

@Model public final class ScheduledNotification {
    @Attribute(.unique) public var id: UUID    // also the UNNotificationRequest identifier
    public var fireAt: Date
    public var payloadType: String      // "recurrence" | "reminder"
    public var payloadID: UUID          // FK to RecurrenceTemplate.id or InvoiceReminderSchedule.id
}
```

### Existing model touches

- `Client.reminderOffsets: [Int]? = nil` — `nil` means "use `ReminderConfig.enabledOffsets`".
- `Invoice.reminderSchedule: InvoiceReminderSchedule?` — created in `markSent(at:)`, deleted in `markPaid(at:)`.

### Enums-as-strings rationale

SwiftData + CloudKit Mirror's safest scalar attribute types are `String`, `Int`, `Date`, `Bool`, `Data`. Enums are kept as Swift types in code (`RecurrenceCadence`, `RangeRule`, plus the existing `LineItemGrouping`) and serialized via raw-value bridges. Matches the existing `InvoiceStatus` pattern on `Invoice`.

### CloudKit mirroring

| Model | Mirrored to iCloud? | Reason |
|---|---|---|
| `RecurrenceTemplate` | ✅ | Set on iPhone, see on iPad. |
| `ReminderConfig` | ✅ | Config follows the user. |
| `InvoiceReminderSchedule` | ✅ | Status of pending steps must be consistent across devices. |
| `Client.reminderOffsets` | ✅ | Already-mirrored model. |
| `Invoice.reminderSchedule` | ✅ | Already-mirrored model. |
| `ScheduledNotification` | ❌ | iOS notification state is device-specific. Each device rebuilds its own from the mirrored truth on `Scheduler.resyncOnLaunch()`. |

### Section 1 ↔ Section 4 cross-walk

| Architecture component | Data backing |
|---|---|
| `Scheduler` | `ScheduledNotification` (local-only) |
| `Scheduler.handleNotificationTap(payload:)` | `ScheduledNotification.payloadType` + `payloadID` |
| `RecurrenceService.createTemplate` | Inserts `RecurrenceTemplate` |
| `RecurrenceService.nextOccurrence` | `RecurrenceTemplate.cadence` + `lastFiredAt` → `nextFireDate` |
| `RecurrenceService.materializeDraft` | Reads `client`, `rangeRule`, `grouping`, `notesTemplate` → calls `InvoiceBuilder` |
| `ReminderService.scheduleForInvoice` | Creates `InvoiceReminderSchedule` in `Invoice.markSent` using `Client.reminderOffsets ?? ReminderConfig.enabledOffsets` |
| `ReminderService.cancelForInvoice` | `Invoice.markPaid` deletes the `InvoiceReminderSchedule` + unregisters `Scheduler` entries |
| `ReminderService.composeReminderEmail` | `ReminderConfig.subjectTemplate` + `bodyTemplate` with merge fields resolved |
| `RecurringRulesView` | `@Query` over `RecurrenceTemplate` filtered by `isActive` |
| `PaymentRemindersView` | `@Query` for `ReminderConfig` singleton + per-Client overrides |
| AppDelegate tap handler | Looks up `ScheduledNotification` by `UNNotificationRequest.identifier` |

No orphans either direction.

### `lastFiredAt` ownership

`Scheduler` updates `ScheduledNotification` (local) when iOS fires the notification, but **does not** touch `RecurrenceTemplate.lastFiredAt` (mirrored). `RecurrenceTemplate.lastFiredAt` advances only when `RecurrenceService.materializeDraft` actually runs — i.e., when the user taps the notification (or opens the app and `reconcile()` notices pending work).

This is intentional:
- A missed notification doesn't silently advance the schedule. Next launch surfaces a *Catch up* banner showing the user what they missed.
- CloudKit-mirrored `lastFiredAt` stays honest across devices: only confirmed user-acknowledged occurrences move it forward.

---

## 5. User flows

### Flow 1 — Create a recurring schedule

Entry: existing `InvoiceGeneratorView`. Below the existing controls add one new row: **"🔁 Make this recurring"** toggle.

When toggled on, three controls reveal:
- Cadence segmented control: **Weekly | Biweekly | Monthly** (default: Monthly)
- Day picker:
  - Monthly → day-of-month (default: 1st)
  - Weekly / Biweekly → day-of-week (default: Monday)
- Optional "Until…" end date

The notes field becomes a *template* (supports `{month}` `{year}` `{clientName}` merge fields with a help hint).

Saving with recurring=on does **not** create an invoice. It writes a `RecurrenceTemplate` and shows a toast: *"Saved. Cadence will remind you to send Acme's invoice on the 1st of every month."*

### Flow 2 — Manage recurring schedules

The Invoices tab's existing segmented filter (Outstanding | Paid | Drafts) gains a fourth segment: **Recurring**.

Each row: client + color dot, cadence summary ("Monthly · 1st"), "Next: Jun 1", an Active/Paused/Ended pill. Swipe → Pause / Delete (delete confirms). Tap → detail with the same form as creation, plus a **"Generate now"** button.

### Flow 3 — A recurrence fires

8:00am local on the fire date, a local notification appears:

> **Acme's June invoice is ready to send**
> Tap to review and send.

Tap → app opens → `RecurrenceService.materializeDraft()`:
1. Calls existing `InvoiceBuilder.createDraft(...)` with template params (range "previous month" resolved to May 1–31, grouping, notes with `{month}=June {year}=2026`)
2. Inserts `Invoice(status: .draft)`, stamps source `TimeEntry.invoiceID`
3. Updates `lastFiredAt = now`, recomputes `nextFireDate`, registers the next Scheduler fire
4. Routes user straight to `InvoicePreviewView` for that Draft

User reviews → **Finalize & share** → existing v1 finalize flow. If they dismiss without finalizing, the Draft stays in Drafts.

### Flow 3a — Missed fires (catch-up banner)

If the user ignored the notification and never opened the app, `lastFiredAt` doesn't move. On next launch, `RecurrenceService.reconcile()` notices pending work and surfaces a single banner on the Today screen:

> 📬 3 recurring invoices to review

Tap → list of pending materializations → each row materializes on tap. No auto-stampede.

### Flow 4 — Configure default reminder schedule

Entry: Settings → new **"Payment reminders"** row, between Subscription and About.

Screen:
- Master toggle: "Send reminders for overdue invoices"
- Days chips: **[+3] [+7] [+14] [+30]** multi-select. Default: 3 / 7 / 14 enabled, 30 disabled.
- Subject template: textfield with merge-field hint chips (`{invoiceNumber}` `{clientName}`)
- Body template: TextEditor (~6 lines), same merge-fields plus `{amount}` `{dueDate}` `{daysOverdue}` `{senderName}`
- Live preview: "On a sample $1,200 invoice 3 days overdue, the email subject will read…"

Persists to `ReminderConfig`.

### Flow 5 — Per-client reminder override

Entry: existing `ClientEditorView` gains a **Reminders** section.

Segmented choice:
- **Use default** (shows the global "+3, +7, +14")
- **Custom for this client** → reveals the same chips picker

Persists to `Client.reminderOffsets` (nil → use global).

### Flow 6 — Invoice goes overdue → reminder fires

When `Invoice.markSent(at:)` runs, `ReminderService.scheduleForInvoice(invoice)`:
- Resolves offsets: `Client.reminderOffsets ?? ReminderConfig.enabledOffsets`
- Computes `fireDates` from `dueAt` + each offset (each at 8:00am local on that date)
- Creates `InvoiceReminderSchedule`, registers each fire with `Scheduler`

8:00am local on each fire date, notification appears:

> **Acme owes you $1,200 — 3 days overdue**
> INV-0042. Tap to send a friendly reminder.

Tap → app opens → `InvoiceDetailView` for that invoice → banner at top:

> ⚠️ 3 days overdue — send reminder?  **[Send reminder]**

Tap the CTA → existing v1 Mail composer opens, prefilled from `ReminderConfig` templates with merge fields resolved. When the sheet returns (sent or cancelled), `firedDates.append(today)` so the same step doesn't repeat. The +7 and +14 fires remain scheduled.

### Flow 7 — Invoice marked Paid → reminders auto-cancel

User taps "Mark as paid" → existing `markPaid(at:)` → `ReminderService.cancelForInvoice(invoice)` runs: cancels remaining `Scheduler` entries, deletes the `InvoiceReminderSchedule`. No orphan notifications.

---

## 6. Notifications, permissions, copy & badging

### Permission ask (just-in-time)

Cadence already requests notification permission for Live Activities. Local notifications need an explicit `requestAuthorization([.alert, .sound, .badge])`.

The app **does not ask on launch**. It asks the first time the user does one of:
1. Saves an `InvoiceGenerator` with the *Make recurring* toggle on, OR
2. Flips the *Send reminders for overdue invoices* master toggle on in Settings.

If denied: one-time soft block — *"Cadence needs notifications to remind you. Open Settings to enable."* with a deep link via `UIApplication.openSettingsURLString`. The toggle reverts; no model write happens.

If revoked later via Settings: `Scheduler.schedule(...)` silently no-ops. Data model stays intact. On re-grant, `resyncOnLaunch` re-registers everything. A passive banner on `RecurringRulesView` + `PaymentRemindersView` explains the silent failure with the same deep link.

### Time of day

All fires happen at **8:00am local** (user's current timezone, recomputed when timezone changes). One predictable morning slot. Not user-configurable in v1.1.

### Deep-link routing

Cadence is SwiftUI-first with no `AppDelegate`. v1.1 adds a minimal `@UIApplicationDelegateAdaptor`-backed `AppDelegate` whose sole job is to be the `UNUserNotificationCenterDelegate`.

```swift
// BillableCore/Routing/NotificationRouter.swift
@MainActor @Observable
public final class NotificationRouter {
    public enum Destination: Hashable {
        case invoicePreview(invoiceID: UUID)         // from recurrence
        case invoiceDetail(invoiceID: UUID)          // from overdue reminder
        case recurringList                            // from catch-up banner tap
    }
    public var pendingDestination: Destination?
}
```

Flow:
1. `AppDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:)` reads `UNNotificationRequest.identifier`
2. Looks up the `ScheduledNotification` in SwiftData
3. Calls `Scheduler.handleNotificationTap(...)` which sets `NotificationRouter.pendingDestination`
4. `RootView` watches the router via `@Environment(NotificationRouter.self)` and applies navigation (push onto the appropriate `NavigationStack`, switching tabs first if needed)
5. After consumption, the router clears `pendingDestination`

Cold launch from a tapped notification is handled the same way — the OS calls the delegate after launch finishes, the router gets set, SwiftUI picks it up on first render.

### App badging

Badge count = **unresolved actionable items**, recomputed on every `scenePhase == .active`:

- Pending recurrence materializations: `RecurrenceTemplate` rows where `lastFiredAt < (most recent fire date ≤ now)` AND `isActive` AND (`endDate == nil || endDate > now`)
- Pending overdue reminders: across all `InvoiceReminderSchedule`, sum of `fireDates ≤ now` not in `firedDates`, scoped to invoices whose status is still `.sent`

Recompute-from-truth (rather than increment/decrement) is robust against multi-device sync, missed notifications, and reboots.

### Notification copy (localizable)

| Trigger | Title | Body |
|---|---|---|
| Recurrence fire | **{clientName}'s {month} invoice is ready** | Tap to review and send. |
| Overdue +3 days | **{clientName} owes you {amount}** | {invoiceNumber} is 3 days overdue. Send a reminder? |
| Overdue +7 days | **Still waiting on {clientName}: {amount}** | {invoiceNumber} is now a week overdue. |
| Overdue +14 days | **{invoiceNumber} is 2 weeks overdue** | Time for a stronger nudge to {clientName}? |
| Overdue +30 days | **{invoiceNumber} is a month overdue** | Consider escalating or adding a late fee. |

All strings extracted to `Localizable.strings` from day one.

### Default email templates (user-editable)

Subject: `Friendly reminder: {invoiceNumber}`

Body:
```
Hi {clientFirstName},

Just a quick nudge — invoice {invoiceNumber} for {amount}
was due on {dueDate}, and it looks like it's a few days
outstanding. If you've already sent it, please disregard.
If not, no rush — just wanted to flag.

Attached is the invoice again for convenience.

Thanks!
{senderName}
```

The escalation tone of the *notification* changes by step; the *email body* stays user-controlled (one template). Users who want escalating emails write their own escalation using `{daysOverdue}`.

### Sender identity

Reminder emails are sent through the user's Mail.app composer. From: is `BusinessProfile.email`. No sender-domain authentication, no SPF/DKIM, no bounce handling on Cadence's side — the user's own mail provider handles all of that. **This is the core local-first benefit on the email side.**

---

## 7. Edge cases

### Time & calendar

- **Timezone change.** Stored fires are absolute `Date` instants. If the user flies PST → JST mid-cycle, an existing fire stays at its original UTC moment (so 8am LA = 12am Tokyo for one cycle). The next fire computed by `RecurrenceService` uses `Calendar.current` (new timezone) and snaps back to local 8am. **Drift never compounds beyond one cycle.**
- **DST transition.** Same mechanism — absolute fires hold; next computed fire re-aligns via `Calendar.current` DST rules.
- **Monthly day=31 in February.** `Calendar.date(bySetting: .day, value: 31)` returns nil for short months → fallback to **last day of that month** (Feb 28 / 29).

### iOS plumbing

- **64-pending-request cap.** `Scheduler` enforces a soft cap of 60 — extras live as `ScheduledNotification` rows without an iOS registration. On any state change, `Scheduler` tops up to 60 by registering the next-soonest pending entries.
- **Force-quit / phone reboot.** `Scheduler.resyncOnLaunch()` cross-checks `UNUserNotificationCenter.getPendingNotificationRequests()` against `ScheduledNotification` rows; missing iOS-side gets re-registered.
- **Permission revoked mid-life.** `Scheduler.schedule(...)` silently no-ops. Data model intact. Re-grant triggers `resyncOnLaunch` to re-register.
- **Reinstall.** Empty local SwiftData; CloudKit Mirror pulls schedules back; `ScheduledNotification` is gone; iOS has no pending requests. `resyncOnLaunch()` rebuilds from `RecurrenceTemplate.nextFireDate` + `InvoiceReminderSchedule.fireDates` minus `firedDates`.

### Multi-device (CloudKit)

- **Both devices fire same reminder.** iPhone fires +3, user sends → `firedDates.append(today)` → CloudKit pushes to iPad. If iPad's notification already delivered, user sees a duplicate. Tapping iPad → InvoiceDetail shows up-to-date "step already sent" state; banner suppressed. Acceptable for v1.1.
- **Mark Paid on iPhone, iPad has pending fires.** `Invoice.markPaid` deletes `InvoiceReminderSchedule` via mirrored relationship. iPad receives deletion via CloudKit; its local `ScheduledNotification` rows reconcile on next `resyncOnLaunch`. In the gap, a stale fire *could* surface on iPad — the InvoiceDetail it routes to clearly shows Paid status.
- **Recurrence materialized on two devices at 8:01am.** `RecurrenceService.materializeDraft` wraps `lastFiredAt` update + Invoice insert in a single transaction. Slower device's CloudKit merge loses; on next sync it observes `lastFiredAt` already moved and abandons its own draft. CloudKit's last-writer-wins handles it.

### Data-shape

- **Zero-entry materialization.** Recurrence fires but previous month has no time entries for this client. `RecurrenceService` still creates the Draft (subtotal $0, empty line items snapshot) and routes the user to review. User can delete from Drafts. Better than silently swallowing.
- **Client deleted with active recurrence.** Existing v1 cascade extends to delete owned `RecurrenceTemplate` + cancel `Scheduler` entries. Existing confirm dialog gets one more line: *"X recurring schedule(s) will also be removed."*
- **`BusinessProfile.email` changed while reminders pending.** No-op — composer reads `BusinessProfile.email` at compose time.
- **`ReminderConfig` templates changed while reminders pending.** No-op — templates resolve at compose time.
- **Recurrence with `endDate` in the past.** `computeNextFireDate` returns nil → `nextFireDate` cleared, `isActive` flipped to false, "Ended" pill in `RecurringRulesView`.

---

## 8. Testing strategy

Add `BillableCoreTests/SchedulingTests` suite. Coverage by area:

| Area | Tests |
|---|---|
| **Cadence math** | Monthly day=1, 15, 31; weekly Mon/Wed/Fri; biweekly; correct across DST + leap years |
| **Range resolution** | `previousMonth` from any day; `previousWeek`; end-of-month edges |
| **Scheduler** | Reconcile when iOS has fewer pending than SwiftData rows; 64-cap & top-up; idempotent re-schedule |
| **RecurrenceService** | `materializeDraft` produces correct range/grouping/notes; updates `lastFiredAt`; correct `nextFireDate`; zero-entry case |
| **ReminderService** | Offset resolution (per-client override > global); `InvoiceReminderSchedule.fireDates` correctness; `cancelForInvoice` clears all; idempotent |
| **Templates** | Merge field resolution: `{month}` `{year}` `{clientName}` `{clientFirstName}` `{amount}` (currency-formatted) `{dueDate}` (localized) `{daysOverdue}` `{invoiceNumber}` `{senderName}` |
| **Permission denied** | `Scheduler.schedule(...)` returns `.noPermission`; no iOS request; data model unchanged |
| **Catch-up** | After 3 missed monthly fires, `reconcile()` surfaces 3 pending; tapping one materializes only that one |
| **Concurrent materialize** | Two `materializeDraft` calls on same template → one Invoice persists, `lastFiredAt` advances once |
| **State-machine integration** | `Invoice.markSent` creates schedule; `markPaid` cancels; Client delete cascades |

UI test in `BillableUITests`: simulate a delivered notification → tap → assert the right screen (InvoicePreview for recurrence, InvoiceDetail for reminder) appears.

**Target: ~25 new tests**, bringing the BillableCore suite from 52 to ~77. Approximately one day of test writing within the one-week scope.

---

## 9. Observability

No backend = no remote analytics. For v1.1:

- **`OSLog` signposts** for every Scheduler state change, RecurrenceService materialization, ReminderService schedule create/cancel. Visible in Console.app and Xcode's Devices window. Zero release-build cost.
- **`--debug-scheduler` launch flag** (mirrors the `--pretend-pro` pattern in `SubscriptionManager`) surfaces a hidden Settings → Diagnostics screen: pending `ScheduledNotification` rows, iOS pending requests, count delta, last `resyncOnLaunch` timestamp. For internal QA before TestFlight.

If/when v1.2 introduces backend infra, structured events can ship upstream. For v1.1, Console.app is enough.

---

## 10. Acceptance criteria

A v1.1 build is shippable when:

### Functional
- [ ] A user can toggle "Make recurring" on `InvoiceGenerator`, configure cadence and day, save, and see the template appear in the Recurring segment of the Invoices tab.
- [ ] On a recurrence's scheduled date at 8:00am local, a notification fires with the correct copy and merge fields.
- [ ] Tapping the recurrence notification opens `InvoicePreviewView` with the correct draft (correct date range, grouping, notes with resolved merge fields).
- [ ] If the user dismisses the notification and opens the app later, the Today screen shows a Catch-up banner with the right pending count.
- [ ] A user can flip the master "Send reminders" toggle in Settings, configure offset chips, edit subject/body templates with merge fields, and see the live preview update.
- [ ] A user can override reminders per-client in `ClientEditorView` and confirm the per-client values are used when an invoice from that client goes overdue.
- [ ] When an invoice transitions Sent → Overdue, notifications fire at the configured offsets with correct escalation copy.
- [ ] Tapping an overdue notification opens `InvoiceDetailView` with the reminder CTA pre-armed and a Mail composer prefilled with templates resolved.
- [ ] Marking an invoice Paid cancels all remaining reminder fires for it (verified via Scheduler state).
- [ ] Deleting a client cascades to delete its `RecurrenceTemplate` rows and cancel their `Scheduler` entries.

### Permissions
- [ ] First-time enable of recurring OR reminders triggers the iOS notification permission prompt.
- [ ] Denial reverts the toggle and shows the soft-block message with a deep link to Settings.
- [ ] Permission revoked mid-life produces silent no-ops; banner appears on relevant screens.

### Robustness
- [ ] After force-quit + relaunch, `Scheduler.resyncOnLaunch()` restores all pending iOS notifications.
- [ ] After reinstall, schedules are restored from CloudKit Mirror and re-registered with iOS.
- [ ] DST transition does not skip or duplicate a recurring fire across the transition.
- [ ] Two-device simultaneous materialize results in exactly one Invoice persisted and `lastFiredAt` advancing once.

### Testing
- [ ] `BillableCoreTests/SchedulingTests` contains ≥25 tests covering all areas in §8.
- [ ] `BillableUITests` contains a notification-tap-to-screen smoke test.
- [ ] All existing tests (the v1 suite of 52) continue to pass.

### Observability
- [ ] OSLog signposts emit for all major state changes.
- [ ] `--debug-scheduler` exposes the Diagnostics screen.

---

## 11. Effort estimate (rough day-by-day)

Total: ~5–6 working days.

| Day | Focus |
|---|---|
| 1 | `Scheduler` primitive + `ScheduledNotification` model + permission flow + `resyncOnLaunch`. Tests for Scheduler in isolation. |
| 2 | `RecurrenceTemplate` model + `RecurrenceService` (cadence math, range resolution, `materializeDraft`). Cadence + range tests. |
| 3 | `RecurringRulesView` + InvoiceGenerator toggle + Invoices tab "Recurring" segment + Catch-up banner. |
| 4 | `ReminderConfig` + `InvoiceReminderSchedule` models + `ReminderService` + `Invoice.markSent`/`markPaid` hooks. ReminderService tests. |
| 5 | `PaymentRemindersView` (Settings) + ClientEditor per-client override + InvoiceDetailView reminder banner + Mail composer prefill. |
| 6 | UI test, edge-case shake-down, `--debug-scheduler` screen, polish, copy review, signposting. Buffer for sync-resync test scenarios. |

---

## 12. Files added / modified (forward-looking inventory)

### Added — `Packages/BillableCore/Sources/BillableCore/`
- `Scheduling/Scheduler.swift`
- `Scheduling/SchedulerPayload.swift`
- `Models/ScheduledNotification.swift`
- `Models/RecurrenceTemplate.swift`
- `Models/ReminderConfig.swift`
- `Models/InvoiceReminderSchedule.swift`
- `Recurrence/RecurrenceService.swift`
- `Recurrence/RecurrenceCadence.swift`
- `Recurrence/RangeRule.swift`
- `Reminders/ReminderService.swift`
- `Reminders/ReminderTemplateRenderer.swift`
- `Routing/NotificationRouter.swift`

### Added — `App/Sources/`
- `App/AppDelegate.swift` (new, minimal)
- `Features/Recurrence/RecurringRulesView.swift`
- `Features/Recurrence/RecurrenceEditorView.swift`
- `Features/Recurrence/CatchUpBanner.swift`
- `Features/Settings/PaymentRemindersView.swift`
- `Features/Settings/DiagnosticsView.swift` (gated by `--debug-scheduler`)

### Modified — `Packages/BillableCore/Sources/BillableCore/`
- `Models/Client.swift` — add `reminderOffsets: [Int]?`
- `Models/Invoice.swift` — add `reminderSchedule: InvoiceReminderSchedule?` + lifecycle hooks in `markSent`/`markPaid`
- `Persistence/ModelContainer+Billable.swift` — register the four new models, configure `ScheduledNotification` as local-only

### Modified — `App/Sources/`
- `App/BillableApp.swift` — add `@UIApplicationDelegateAdaptor`, inject `NotificationRouter` into environment
- `App/RootView.swift` — observe `NotificationRouter` and apply navigation
- `Features/Invoicing/InvoiceGeneratorView.swift` — add "Make recurring" toggle + new controls
- `Features/Invoicing/InvoicesView.swift` — add "Recurring" segment
- `Features/Invoicing/InvoiceDetailView.swift` — reminder banner + CTA wiring
- `Features/Clients/ClientEditorView.swift` — Reminders section
- `Features/Settings/SettingsView.swift` — add "Payment reminders" row

### Modified — `Packages/BillableCore/Tests/BillableCoreTests/`
- New: `SchedulingTests.swift`

---

## 13. Open questions

None at design time. All design decisions are locked. New questions discovered during implementation should be raised in the plan or against this spec.

---

## 14. Glossary

- **Recurrence template** — user-defined rule that, on a schedule, generates a draft invoice from tracked time.
- **Reminder schedule** — per-invoice list of fire dates derived from the user's offset config at the moment of `markSent`.
- **Scheduler** — internal primitive that bridges SwiftData + `UNUserNotificationCenter`, with cold-launch reconciliation.
- **Catch-up banner** — Today-screen banner shown when one or more recurrences fired but the user never opened the app to materialize them.
- **Materialize** — turn a scheduled recurrence into a concrete Draft `Invoice` by running `InvoiceBuilder`.
- **Local-first** — the principle that Cadence never finalizes invoices or sends emails on the user's behalf in the background; the user is always in the loop.
