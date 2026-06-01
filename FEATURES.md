# Cadence — Feature Reference (v1)

A native iOS app for freelance creatives and independent consultants who bill by the hour. One job: turn tracked time into a paid invoice, entirely on the phone.

---

## 1. Positioning

**Who it's for.** Solo professionals — designers, developers, copywriters, freelance marketers, consultants — billing roughly $40–150/hr across 2–5 active clients. They hate admin and want to look professional and send polished invoices without the laptop.

**The wedge.** Web-first competitors (Toggl, Harvest, Clockify) force users to a laptop to invoice. The other big native app (Hours) has been abandoned since 2020. Cadence is a modern, native, mobile-complete loop: **track → review → invoice**, with the timer startable from lock screen, widgets, or Siri — and the invoice generated as a polished branded PDF without ever opening a laptop.

---

## 2. The core flow

A returning user opens Cadence and within a few seconds can answer two questions: **what am I tracking** and **how much have I earned but not yet invoiced**.

```
[ Today screen ]
        │
        ├── Start timer  ─►  Pick Client → Project  ─►  Timer card live on Today, lock screen, widget, Watch
        │                                                       │
        │                                                       ▼
        │                                                  Stop / Switch
        │
        └── Open timeline  ─►  Spatial 24h day view  ─►  Drag / resize / split / merge / delete entries

[ Invoices tab ]
        │
        └── New invoice  ─►  Pick client + range  ─►  Live PDF preview  ─►  Finalize & share
                                                                                    │
                                                                                    ▼
                                                                              Mark as Paid  ─►  Review prompt
```

---

## 3. Time tracking

### Live timer
- One-tap **Start** from the Today screen's big amber button (opens project picker) or from the **Recent** row (last 3 used projects, one-tap each)
- **Switch** between projects without a gap: the previous entry ends at the same instant the new one begins (`TimerService.switchTo`)
- **Stop** from anywhere — Today card, lock-screen Live Activity, Dynamic Island
- Live earned-dollar counter ticks alongside the elapsed timer, computed against the project's hourly rate
- "Already tracking that project" detection — tapping the running project is a no-op, not a restart
- Defensive recovery: if the app is force-killed mid-session, the running `TimeEntry` survives in SwiftData and the Live Activity re-attaches on next launch

### Manual / after-the-fact entry
- "Add entry" toolbar `+` on Today opens a form: project picker, start date+time, end date+time, notes, auto-computed duration
- Validates start < end before allowing save
- Marks the entry `isManual = true` for downstream reporting

### Project picker (Start / Switch sheet)
- Searchable list
- **Recent** projects shown first (last 30 days, deduplicated by project)
- Grouped by client below
- Shows the hourly rate next to each project
- "Non-billable" badge on projects with `isBillable = false`

### Today screen at-a-glance
- **Running timer card**: client color dot, client + project name, live HH:MM:SS counter (monospaced rounded digits), running dollar amount, Stop (destructive red) + Switch buttons
- **Idle state**: big Start timer button + Recent 3-tile row
- **Today summary**: Hours tile (today's billable + non-billable seconds, formatted as `Xh YYm`) and Earnings tile (today's billable amount in the user's currency)
- **Uninvoiced amount**: hero number — the all-time sum of tracked time that hasn't been finalized into a Sent invoice yet. The freelancer's "what am I owed" pulse.
- Both summary blocks tick live via `TimelineView(.periodic)`

---

## 4. Timeline editor (the wedge UX)

A spatial 24-hour vertical canvas — the editing experience competitors have been getting wrong for years. Reachable from the calendar icon in the Today toolbar.

### Layout
- 80 points per hour (1920 pt total height; ~5x screen) — dense enough to render 15-minute blocks at tappable size, sparse enough to grasp the day at a glance
- Hour gridlines + hour labels (`1AM`, `2AM`, etc.) in the left gutter
- **Current-time indicator**: red horizontal line + dot, only visible when viewing today
- Auto-scrolls on appear to the first entry of the day (or current hour if today, else 8 AM)

### Time blocks
- Each `TimeEntry` is a colored rounded-rect block, color from `Client.color`
- Title (project name) + subtitle (`9:00 AM – 10:30 AM` or `9:00 AM – now` for running)
- Selected state: thicker stroke + slightly brighter fill
- **Running entry**: live dashed bottom edge + a small green pulsing dot next to the title. Bottom edge tracks `Date.now` at 1 Hz via `TimelineView(.periodic)`.

### Gestures
- **Drag block body** → shifts the whole entry in time (snap to 15-min by default; configurable to 1, 5, 15, 30 via the toolbar menu)
- **Drag top edge** → resizes the start time
- **Drag bottom edge** → resizes the end time
- **Tap** → selects the entry
- **Long-press** → context menu (Edit, Split here, Duplicate, Delete)
- **Split here** → cleaves the entry at its midpoint into two contiguous entries; marks both `isManual`
- **Duplicate** → clones the entry into the slot immediately after it
- **Delete** → removes (destructive)

### Day navigation
- **Week strip** at top: 7-day chip row, current day highlighted with the accent color
- Tap a chip to jump to that day
- Horizontal swipe on the day canvas → previous/next day with animated transition
- The header title updates ("Fri, May 22", etc.)

---

## 5. Client & project management

### Clients
- Add via `+` toolbar on the Clients tab
- Form: name (required), color (10-color picker), optional contact name/email/address/notes
- **Archive** (swipe → gray "Archive"): client is hidden from active lists and pickers but data is preserved. Restorable.
- **Delete** (swipe → red "Delete"): cascades to all the client's projects and time entries, with a confirmation dialog
- Sorted alphabetically; archived clients shown in a separate section
- Color picker uses a fixed 10-color palette (slate, red, orange, amber, green, teal, blue, indigo, purple, pink) — keeps PDFs and widgets visually deterministic

### Projects
- Owned by a client; reached via the client detail screen
- Add via the "Add project" row in client detail
- Form: name, billable toggle, hourly rate (if billable), notes
- Per-project rate (so a freelancer can charge different rates to the same client for different scopes)
- Non-billable toggle for internal/admin time tracking (entries count toward total hours but contribute $0 earnings)
- Archive / Delete with the same swipe pattern as Clients

### Business profile (issuer)
- Reached via Settings → Business profile
- Form: name, address, email, phone, payment terms, default-due-after days, invoice number prefix (e.g., `INV-`), next invoice number (stepper), tax label (Tax/VAT/GST/etc.), tax rate (% input), currency (USD/EUR/GBP/CAD/AUD/JPY/CHF/SEK/NOK/DKK/NZD/SGD/HKD/INR/MXN/BRL/ZAR)
- Singleton — there's exactly one BusinessProfile per user, used as the issuer on every invoice

---

## 6. Invoice generation (the wedge)

### Free vs. Pro on invoices
Invoice creation, preview, and sending are available to **all users** — no paywall gate on invoicing. Free users' sent PDFs carry a small "Sent with Cadence" footer watermark. **Pro removes the watermark** and also unlocks the Reports tab and CSV export. Clients are unlimited on both tiers.

### Generator flow
1. **Tap** `+` on the Invoices tab
2. **Form**:
   - Client picker (Menu)
   - Range picker (segmented: This Week / Last Week / This Month / Last Month / Custom)
   - When Custom: two DatePickers for From / To
   - Grouping toggle: **Per entry** (one line per `TimeEntry`) or **Per project** (sums hours per project)
   - Live preview of eligible entry count, total hours, subtotal — updates as the user changes the range
   - Helpful warning if no eligible entries exist
   - Notes field (optional)
3. **Preview button** → opens InvoicePreviewView with the rendered SwiftUI template
4. **Finalize & share** → status transitions Draft → Sent atomically (`InvoiceBuilder.finalizeAndSend`), profile's next invoice number advances, source TimeEntries are stamped with `invoiceID`, PDF rendered and cached, iOS share sheet opens

### Eligibility rules
A `TimeEntry` lands on an invoice when **all** of the following:
- Belongs to the chosen client's project
- Project is billable
- Entry is completed (`endedAt != nil`)
- Entry hasn't been invoiced before (`invoiceID == nil`)
- Entry's `startedAt` falls within the date range

### Invoice template
A SwiftUI view rendered at US Letter (612 × 792 pt) and exported via `ImageRenderer` + Core Graphics PDF context. Vector text where possible — invoice numbers and money values stay searchable in the exported PDF.

Sections (top to bottom):
1. **Accent bar** along the top edge in the client's color
2. **Header row**: issuer block (logo if uploaded, business name, address, email) on the left; "INVOICE" wordmark + invoice number on the right (both in the accent color)
3. **Bill-to + meta row**: client snapshot (name, email, address) on the left; Issued / Due / Terms labeled rows on the right
4. **Line items table**: Description / Hours / Rate / Amount columns, with header band tinted in accent
5. **Totals block**: Subtotal, Tax row (with rate like "Tax (8.75%)"), accent rule, **Total** in bold accent color
6. **Notes** section if provided
7. **Footer**: "Thank you for your business."

### Snapshots, not references
Every value displayed on the invoice — issuer name/address/email/logo, client name/address/email/color, payment terms, tax label, tax rate, currency code — is **frozen at finalization**. Renaming a client or changing the tax rate later doesn't mutate prior invoices.

### Line items are encoded JSON
Stored on the Invoice as `lineItemsData: Data` (Codable struct array). Sidesteps SwiftData relationship merge conflicts on financial records and guarantees the customer's archived invoice always renders the same way.

### Invoice status state machine
- `Draft` → `Sent` via `markSent(at:)` (records `sentAt`)
- `Sent` → `Paid` via `markPaid(at:)` (records `paidAt`)
- Illegal transitions throw `InvoiceTransitionError.illegalTransition`
- **Overdue is derived**, not stored: `status == .sent && dueAt < now`. This way "overdue" changes with the clock without polling.

### Invoice list
- **Outstanding** / **Paid** / **Drafts** segmented filter
- Each row: invoice number, client name, total, status pill (Draft/Sent/Paid/Overdue), context-aware date label (`Paid May 23` / `Due Jun 6` / `Created May 22`)
- Tap → InvoiceDetailView

### Invoice detail
- **Status banner**: pill + total + paid/due/sent date
- **Inline PDF preview** via PDFKit (renders the cached `pdfDataCached`; falls back to a live SwiftUI render if cache is empty)
- **Mark as paid** (green prominent button, only shown when Sent)
- **Share PDF** (bordered button + toolbar menu item) → iOS share sheet with `INV-XXXX.pdf`
- **Send reminder email** (toolbar menu, only when Sent) → opens Mail composer with prefilled subject + body via `mailto:`
- **Delete draft** (toolbar menu, only when Draft) — confirmation dialog
- **Metadata block**: Client / Issued / Due / Terms / Sent timestamp

### Review prompt
- Triggers Apple's native `requestReview()` (from `@Environment(\.requestReview)`) after the user marks their **first** invoice as Paid
- Gated on `UserDefaults` flag `billable.hasPromptedReview` so it only fires once from our side. Apple's own ≤3/year rate-limiting takes over after that.

---

## 7. Reports & analytics (Pro)

Reachable via the Reports tab. Free users see a locked view that sells the upgrade; Pro users see the full report.

### Time range
Segmented control at top: **Week** / **Month** / **Year** / **All**.

### Headline tiles
- **HOURS** — total tracked time in the range, formatted `Xh YYm`
- **EARNED** — total billable earnings in the user's currency

### Billable vs. non-billable
Horizontal stacked bar (green = billable, gray = non-billable) with labeled legend underneath. Hides when there's no tracked time in range.

### Hours by client
Horizontal Swift Charts bar chart, one row per client, colored with each client's accent. Trailing annotation shows the formatted hours total. Sorted by hours descending.

### Earnings — last 8 weeks
Vertical bar chart of weekly earnings totals, regardless of the chosen range (the trend is always last-8-weeks for context). Date axis stride every 2 weeks. Green gradient fill.

### Hours by project
Itemized list, one row per project with: client color dot, project name, client name, hours total, amount (if billable). Sorted by hours.

### Uninvoiced callout
Bottom card with the all-time outstanding amount in bold rounded display type. Not scoped to the range — always shows total outstanding.

### CSV export
Toolbar share button → exports `BillableTimeEntries.csv` with one header row + one row per `TimeEntry`. Format:
```
date, client, project, start, end, duration_hours, hourly_rate, amount,
billable, invoice_number, notes
```
- RFC-4180 escaping (quoted on comma/quote/newline; embedded quotes doubled)
- POSIX number formatting (no thousand separators, `.` decimal)
- ISO-8601 timestamps
- Opens cleanly in Numbers / Excel / Google Sheets

---

## 8. Native iOS integrations

### Live Activity (lock screen + Dynamic Island)
Starts automatically when the user starts a timer; ends on stop; replaces atomically on switch.

- **Lock screen view**: client color dot + name, project name (bold), running status, live elapsed counter via `Text(timerInterval:)` (system-managed, no per-second pushes from our app)
- **Dynamic Island compact**: leading = colored dot, trailing = elapsed
- **Dynamic Island expanded**: leading = client, center = project, trailing = elapsed, bottom = "Running" + "Tap to open"
- **Dynamic Island minimal**: solid colored dot
- Defensive: if the app is killed and re-launched while a `TimeEntry` is running, the activity is re-attached or recreated

### Home-screen widgets

**CurrentTimerWidget** — small / accessory rectangular / accessory circular / accessory inline
- Running state: client color + name, project name, live elapsed counter
- Idle state: "Tap to start" prompt

**TodaySummaryWidget** — medium
- "Today" header with the uninvoiced $ on the right
- HOURS tile + EARNED tile
- Three quick-start tiles for the last-3-used projects. **Tap-to-start** wired via `Button(intent: StartTimerIntent(project:))` so a tap fires the App Intent without opening the app.

Both widgets read directly from the shared App Group SwiftData store, so no backend round-trip and no stale-data fallback needed.

### App Intents (Siri & Shortcuts)
- `StartTimerIntent(project:)` — phrases: "Start Cadence timer", "Start Cadence for [project]", "Start tracking [project] in Cadence"
- `StopTimerIntent` — phrases: "Stop Cadence timer", "Stop my Cadence"
- `SwitchTimerIntent(project:)` — phrases: "Switch Cadence to [project]"
- `LogCompletedTimeIntent(project, start, end, notes?)` — for after-the-fact entries via Shortcuts automation

Each intent returns spoken dialog feedback ("Started timer for Acme Website Redesign."). `ProjectEntity` conforms to `AppEntity` so the Shortcuts app shows a proper project picker. Intents are donated on relevant user actions so Siri can learn personal phrasing.

### Donation hooks
- `StartTimerIntent.donate()` on quick-start tap and on Start sheet selection
- `SwitchTimerIntent.donate()` on switch
- `StopTimerIntent.donate()` on stop

---

## 9. Onboarding

Three-screen first-launch flow that ships you into a running timer in well under a minute. Detected via `OnboardingFlags.shouldShow` (no clients in store + `UserDefaults` flag not set).

1. **Welcome** — Cadence wordmark + hero arc icon + "Track hours. Send invoices." + "Made for freelancers and consultants." + amber "Get started" CTA
2. **Add your first client** — Client name field, hourly rate, 10-color picker. Next is disabled until name + rate are valid.
3. **Start your first timer** — Project name field (defaults to "General"), explanation of what'll happen, amber "Start tracking" CTA

On finish: creates the BusinessProfile (empty defaults the user fills later from Settings), the Client, the Project, and starts a `TimeEntry`. Live Activity launches. Onboarding flag is persisted so it doesn't fire again.

Dark navy gradient background throughout for a premium feel that contrasts with the light main UI.

---

## 10. Subscription model

### Tiers
| | Free | Pro |
|---|---|---|
| Time tracking (any volume) | ✅ | ✅ |
| Today summary + Uninvoiced $ | ✅ | ✅ |
| Live Activity, widgets, Siri | ✅ | ✅ |
| Unlimited clients & projects | ✅ | ✅ |
| Create + send invoices | ✅ | ✅ |
| Watermark-free invoices | — | ✅ |
| Reports + charts | — | ✅ |
| CSV export | — | ✅ |

### Pricing
- **Monthly**: $3.99 (`com.eldenstudios.billable.pro.monthly`)
- **Yearly**: $39.99 with **7-day free trial** (`com.eldenstudios.billable.pro.yearly`)
- **Lifetime**: $99.99 one-time (`com.eldenstudios.billable.pro.lifetime`)

### Paywall
Contextual — the same sheet, different headline based on what the user was trying to do. The three active triggers are:
- **removeWatermark** (`Trigger.removeWatermark`): "Remove the watermark." / "Pro removes 'Sent with Cadence' from your invoice PDFs and unlocks Reports + CSV export."
- **reports** (`Trigger.reports`): "Know what you've earned — and what you're owed." / "Full Reports dashboard, watermark-free invoices, and CSV export — all in one upgrade."
- **settings** (`Trigger.settings`): "Go Pro." / "Watermark-free invoices, full Reports, CSV exports."

Sheet contents:
- Three value bullets: Clean, professional invoices · Full Reports & insights · CSV export
- Plan picker with **Yearly** selected by default (hero card, accent fill), Monthly receded below; **Lifetime** demoted affordance below the CTA
- Savings badge on Yearly showing real dollar saving vs. 12× Monthly + "about N months free"
- Per-month equivalent shown on yearly ("Just $X.XX per month, billed yearly")
- Subscribe button label adapts: "Start 7-day free trial" (yearly, first time) or "Subscribe"; Lifetime shows "Buy Lifetime — $99.99"
- Restore purchases, Terms, Privacy links
- Fine print about auto-renew + cancellation

### Settings hub
- **Active Pro pill** + "Manage subscription" row (opens Apple's `manageSubscriptionsSheet`)
- **Upgrade to Pro** row when free
- **Restore purchases** always available

### Implementation
- StoreKit 2 via `Product`, `Transaction`, `AppStore.sync()`
- `SubscriptionManager` (`@Observable` singleton): loads products, listens to `Transaction.updates` for the session lifetime, derives `isPro` from current entitlements
- StoreKit Configuration file (`App/Resources/Billable.storekit`) bound to the Xcode scheme for sandbox testing
- Dev override `--pretend-pro` launch flag for QA + screenshots

### Review-ask
Fires Apple's native review prompt after the user marks their **first** invoice as Paid. One-time gate via `UserDefaults`; Apple's annual rate-limit handles subsequent.

---

## 11. Data & privacy

### Storage
- **SwiftData** with the schema: `BusinessProfile`, `Client`, `Project`, `TimeEntry`, `Invoice`
- Stored in an **App Group container** (`group.com.eldenstudios.billable`) so the main app and the widget extension read/write the same database
- Optional **CloudKit Mirror** to the user's private iCloud database (`iCloud.com.eldenstudios.billable`) — no server we operate. All financial data stays in the user's own iCloud.
- Graceful degradation: when CloudKit entitlements aren't validated (dev runs without team), falls back to App-Group-only without data loss

### Money math
- All currency values stored as `Decimal`, never `Double`
- Two-fraction-digit display formatting only at presentation time
- Per-entry amount = duration in seconds × rate ÷ 3600
- Subtotal = sum of line item amounts; Tax = Subtotal × rate; Total = Subtotal + Tax — computed on read from the immutable line-items snapshot

### Sync semantics
- Last-writer-wins for `TimeEntry`, `Client`, `Project` edits (intentional user mutations)
- **Invoices are immutable** once their status leaves Draft — only the status field can change (Sent → Paid). Sidesteps merge conflicts on financial records.
- Invoice numbers are user-namespaced strings (e.g., `INV-0042`) generated only at finalization

### Offline-first
The app works fully offline. Tracking, invoicing, and PDF generation never require network. CloudKit sync, when available, runs in the background.

---

## 12. Platform & build

- **iOS 17.0+** (universal — iPhone + iPad, with the iPhone UI scaled on iPad in v1)
- **Swift 6** with strict concurrency
- **SwiftUI** + Observation framework (`@Observable`)
- **SwiftData** for persistence + CloudKit mirror
- **StoreKit 2** for subscriptions
- **ActivityKit** for Live Activities
- **WidgetKit** for home/lock-screen widgets
- **App Intents** for Siri & Shortcuts
- **PDFKit** + SwiftUI `ImageRenderer` for invoice PDFs
- **Swift Charts** for reports

### Project structure
```
Cadence/
├── App/                        — iOS app target (SwiftUI)
├── Widgets/                    — Widget extension (Live Activity + home-screen widgets)
├── Tools/                      — Build-time tooling (icon generator)
└── Packages/
    └── BillableCore/           — Shared Swift Package
        ├── Models              — SwiftData @Model types
        ├── Persistence         — ModelContainer factory + seeders
        ├── Invoicing           — Builder, template, PDF renderer
        ├── Timing              — TimerService
        ├── Reporting           — ReportsAggregator, CSVExporter
        ├── Subscriptions       — SubscriptionManager
        ├── Intents             — App Intents + ProjectEntity
        └── LiveActivity        — TimerActivityAttributes
```

### Tests
**52 Swift Testing tests** across 13 suites covering:
- Model invariants (duration, amount, status state machine, invoice numbering)
- Cascading deletes
- Line-item codable round-trips
- Overdue derivation
- TimerService start/stop/switch/log invariants (including clock-skew safety)
- InvoiceBuilder eligibility filtering, grouping, finalization
- PDF renderer smoke (non-empty bytes, PDFKit round-trip, searchable text)
- CSV exporter escaping + decimal formatting

---

## 13. Out of scope for v1 (intentional)

- Recurring invoices
- Estimates / quotes
- Online payment links (Stripe / Apple Pay)
- Expense tracking
- Multi-currency on a single user account
- Multiple invoice templates
- Team / collaboration / employee features
- Time-tracking screenshots or monitoring
- Payroll
- Expense-receipt scanning / OCR

These were excluded from v1 to protect the ship timeline and keep the wedge focused on the single tightest loop.

---

## 14. Planned for v1.x

- **watchOS companion** (step 4d, deferred): running-timer view + start/stop/switch + complications
- **Widget timeline auto-refresh** on timer state changes (`WidgetCenter.shared.reloadAllTimelines()`)
- **Push-driven CloudKit sync** once a paid Apple Developer team + iCloud container are provisioned
- **App Store assets**: screenshots emphasizing the Live Activity, lock-screen widget, and one-tap invoice flow
- **ASO**: title "Cadence: Time Tracker & Invoice", subtitle ~30 chars, long-tail keyword field targeting freelance / designer / consultant / hourly / billable / contractor / timesheet / self employed

---

## 15. Brand

- **Name**: Cadence — the rhythm of tracked time + the cadence of billing. Designer-aware, distinctive in productivity, isn't claimed in this category.
- **Icon**: a stopwatch sweep — bold amber arc on deep ink navy with a cream "now" pip at the leading edge. Procedurally generated (see `Tools/generate_app_icon.py`) so it can be re-rendered if the palette ever changes.
- **Tone**: calm, confident, professional tool that respects your time. Reference points: Things 3, Tally, Apple's own Reminders.
