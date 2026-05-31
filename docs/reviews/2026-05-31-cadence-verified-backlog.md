# Cadence — Verified Implementation Backlog

_Reviewed against real main (origin/main = `2c9acde`). Method: 6-lens panel → adversarial code-verification → re-baselined onto main. Priorities preserved verbatim (not re-graded)._

## Summary

- **Canonical items:** 61

- Carried unchanged on main: 17 · re-verified still valid: 17 · partially valid: 10 · fresh on main: 30

- Removed: 7 (fixed-on-main / false-positive / out-of-scope) · Borderline: 1


## High priority


### #1 — Invoice is finalized (number consumed, entries marked invoiced, Draft→Sent) BEFORE delivery is confirmed, with no revert path
- **Status:** Carried (unchanged on main) · **Lenses:** UI/UX & interaction logic; Product logic — coherence/consistency · **IDs:** F1, F19
- **Evidence:** InvoicePreviewView.finalizeAndEmail (~364-379) and finalizeAndShare (~522-537) call InvoiceBuilder.createDraft + finalizeAndSend immediately on tap, then present MailComposerView/ShareSheet; onDismiss always calls dismiss()+onDone() regardless of send. InvoiceStatusMachine is one-way Draft→Sent→Paid and InvoiceDetailView exposes no reopen/void — a cancelled send strands a phantom 'Sent' invoice and silently consumes the uninvoiced balance shown on Today/Reports/ProjectDetail.
- **Fix:** Reorder so finalizeAndSend runs only in the composer/share success callback (mirror the composeReminder pattern that gates recordFired on presentMail's return). At minimum relabel buttons to 'Send & email'/'Send & share' and add a destructive 'Reopen to draft' action in InvoiceDetailView's ⋯ menu for .sent invoices (re-marks entries uninvoiced) so a never-delivered invoice has an exit.


### #2 — Watermark gate is hand-stamped at 6 finalize/render sites + a re-typed literal; bypass-by-omission risk and twin finalize/render functions already drifting
- **Status:** Carried (unchanged on main) · **Lenses:** Engineering & code · **IDs:** F10, F11
- **Evidence:** InvoiceTemplateData.from(_:) leaves watermark nil (Pro state), so 6 callers each repeat `data.watermark = subscriptions.canRemoveWatermark ? nil : "Sent with Cadence"` (InvoicePreviewView.swift:90/384/543, InvoiceDetailView.swift:291/458/664) and InvoiceDetailView.cacheIsStale:682 hard-codes the same literal as the renderer/cache contract. finalizeAndEmail (346-468) and finalizeAndShare (511-564) are copy-pasted create+finalize+render+cache blocks; ensurePDFData (447-474) has a `!cached.isEmpty` guard that ensurePDFOnDisk (656-676) lacks — a 0-byte render can be written to disk and shared.
- **Fix:** Centralize entitlement→watermark in one BillableCore helper (e.g. `InvoiceTemplateData.from(_:watermarked:)` + `static let watermarkText`) and have cacheIsStale reference the constant. Extract one `ensureCachedPDF(for:watermarked:)->Data` (0-byte guard in the single path) and one `deliver(invoice:channel:)`, collapsing the four twins to thin call sites.


### #3 — No upgrade nudge on the SENT-invoice detail screen — the most-revisited watermark exposure never converts
- **Status:** Carried (unchanged on main) · **Lenses:** Conversion · **IDs:** F28
- **Evidence:** InvoicePreviewView.swift:109-131 renders the orange 'Remove watermark with Pro' banner, but InvoiceDetailView has watermark logic only inside PDF rendering (291/458/664) and zero PaywallView references. The detail screen is the surface a freelancer revisits on every re-share/email/chase, i.e. the most-repeated watermark exposure, yet it never prompts upgrade. In the watermark-based model the watermark IS the free→paid wedge, so this is the single biggest leak.
- **Fix:** Reuse the InvoicePreviewView watermark banner verbatim on InvoiceDetailView (show when subscriptions.canRemoveWatermark == false and the invoice is non-draft), wired to the existing PaywallView(trigger: .removeWatermark) sheet. Move/duplicate of an existing control to a higher-traffic surface.


### #4 — Free-tier gates the spec advertises (≤2 clients, invoicing is Pro, paywall-before-generator) are never enforced in code
- **Status:** Re-verified on main · **Lenses:** Product logic — coherence/consistency · **IDs:** F18
- **Evidence:** InvoiceGeneratorView.canPreview (73-76) gates only on client/project/profile/non-empty lineItems + canSendInvoice (business-name-only, no isPro). ClientEditorView.save() (146-171) inserts with zero gating/count check. PaywallView.Trigger has only .reports/.settings/.removeWatermark (15-43); exactly 3 call sites exist (RootView:127, SettingsView:170, InvoicePreviewView:236) — no createInvoice/extraClient triggers. FEATURES.md §10 still advertises 'Up to 2 active clients' (:297), 'Create + send invoices —|✅' (:299), §6 'Paywall fires if the user is not Pro' (:133) — none enforced.
- **Fix:** Reconcile spec and code: either enforce the advertised gates (add createInvoice/extraClient PaywallView.Trigger cases at ClientEditorView.save / InvoiceGeneratorView.canPreview), or correct FEATURES.md §10/§6 to the actual watermark-only model. Pick one source of truth; do not ship a spec the app contradicts.


### #5 — Project's client is permanently fixed — no reassignment anywhere, despite Project.client being mutable
- **Status:** Carried (unchanged on main) · **Lenses:** Flexibility of use · **IDs:** F37
- **Evidence:** ProjectEditorView takes `let client: Client` (non-optional, ProjectEditorView.swift:11) and renders NO UI for it; save() only sets project fields, never client (93-98). ClientDetailView/ProjectDetailView/WorkView offer no reassignment. Project.client is `Client?` and freely mutable, so this is a UI gap not a model limit — a wrong-client or restructured-client choice forces delete+recreate, losing tracked time and invoice history.
- **Fix:** Add a client picker row to ProjectEditorView's existing 'Project' section, populated from the non-archived clients @Query already used elsewhere, defaulting to the current client, wired to the already-mutable Project.client (picker pattern already exists in ManualEntrySheet/InvoiceGenerator).


### #6 — Per-client consolidated invoice impossible — only per-project Preview or N separate drafts, contradicting the two Project-section controls
- **Status:** Re-verified on main · **Lenses:** Flexibility of use · **IDs:** F38
- **Evidence:** canPreview requires selectedProject != nil (InvoiceGeneratorView.swift:74); InvoicePreviewView is built with a single project + pre-scoped lineItems (308-317; init takes `project: Project?`). The only multi-project affordance, 'Invoice all projects (separate drafts)' (116-118), loops creating one draft each (invoiceAllProjects 449-471). No consolidated single-invoice-per-client path exists, despite InvoiceBuilder.eligibleEntries(for: client) already fetching across all the client's billable projects (InvoiceBuilder.swift:40-64).
- **Fix:** Add an 'All projects (one invoice)' option to the Project Picker that builds a single InvoicePreviewView over InvoiceBuilder.eligibleEntries(for: client) (already aggregates across the client's billable projects), so a freelancer billing one client for several projects gets one invoice. Reuses existing builder + preview.


### #7 — Client whose only active projects are non-billable hits false 'This client has no active projects.' dead-end
- **Status:** Re-verified on main · **Lenses:** Flexibility of use · **IDs:** F36
- **Evidence:** refreshProjectsAndActive() computes `activeProjects = $0.projects.filter { !$0.isArchived && $0.isBillable }` (InvoiceGeneratorView.swift:419), dropping non-billable projects from the count; the UI branches on `activeProjects.isEmpty` (108) and renders 'This client has no active projects.' (109). For a client with only active non-billable projects the message is literally false and dead-ends the user.
- **Fix:** Distinguish 'no projects at all' from 'no billable projects' — when the client has active projects but none billable, show an accurate message (e.g. 'This client's active projects are all non-billable') instead of 'no active projects', and/or don't exclude non-billable from activeProjects for the empty-state test. Relabel/condition existing logic.


### #8 — 'UNINVOICED' headline silently switches scope (all-projects on Today vs one-project on ProjectDetail) and 'Outstanding' collides; widget all-time figure unlabeled next to today figure
- **Status:** Re-verified on main · **Lenses:** Product logic — coherence/consistency; Value clarity · **IDs:** F20, F47
- **Evidence:** TodayView.UninvoicedTile shows all-time/all-project money under bare 'UNINVOICED' caption 'Hours you've tracked but haven't invoiced yet.' (TodayView.swift:388/393); ProjectDetailView.uninvoicedTile shows one-project money under the SAME bare 'UNINVOICED' label (:188). InvoicesView.Filter.outstanding renders 'Outstanding' but maps to status==.sent (15, 131-132). TodaySummaryWidget places entry.uninvoicedAmount (all-time) top-right with NO label (TodaySummaryWidget.swift:152), beside today-scoped 'EARNED' (166-171) under a 'Today' header (148) — two horizons adjacent, one labeled. (ReportsView 'uninvoiced' callout is gone after the PR #12 overhaul — that prong is moot.)
- **Fix:** Add explicit scope qualifiers so the same word never silently changes meaning: 'UNINVOICED · all projects' on Today, 'UNINVOICED · this project' on ProjectDetail, and a label on the widget's all-time figure (or remove the today/all-time adjacency). Add a range/all-time word to the Today caption. (Rename 'Outstanding'→'Unpaid' is tracked under the Overdue-filter item.)


### #9 — Established user has no live-timer start path on Today — '+' leads with past-entry logging; empty JumpBackIn renders nothing
- **Status:** Re-verified on main · **Lenses:** Value clarity · **IDs:** F45
- **Evidence:** Today's '+' opens ManualEntrySheet not a live timer (TodayView.swift:43-50, 59-60); StartTimerSheet is wired only from ProjectDetailView.swift:98. First-run is now handled by GetStartedSection's 'Start a timer now' (GetStartedSection.swift:115-136), but once firstSetupCompletedAt is stamped GetStartedSection disappears (TodayView.swift:93/107); the only remaining Today start-paths are JumpBackIn per-project play buttons (280-300), which render nothing when no recent projects in the 60-day window (233-251).
- **Fix:** (1) Repoint Today's '+' to the existing StartTimerSheet (used by ProjectDetailView.swift:98), demoting 'Add past entry' to a secondary slot/menu. (2) For the established user whose JumpBackIn is empty (233-251), surface a single Start-timer affordance opening StartTimerSheet instead of rendering nothing. First-run already covered by GetStartedSection.


### #10 — UninvoicedTile on Today is non-interactive — the hero 'what am I owed' metric never on-ramps into the invoice flow
- **Status:** Re-verified on main · **Lenses:** Value clarity · **IDs:** F46
- **Evidence:** UninvoicedTile (TodayView.swift:382-401) is a plain VStack — no NavigationLink/onTap/invoice route; TodayView has zero InvoiceGeneratorView references. The only generator entry points are ProjectDetailView.swift:95, InvoicesView.swift:65, RecurrenceEditorView. So the track→invoice loop is never demonstrated from Today. The reusable target exists: InvoiceGeneratorView has init(defaultClient:defaultProject:) (37) and the global variant at InvoicesView.swift:65.
- **Fix:** Make UninvoicedTile a tappable control that, when amount > 0, routes into the existing InvoiceGeneratorView() (global multi-client variant as at InvoicesView.swift:65), turning the hero metric into the on-ramp to the payoff.


### #11 — Tap/long-press/'Edit' on a timeline block do nothing — selectedEntry is a dead-end; running-block drag animates then snaps back
- **Status:** Carried (unchanged on main) · **Lenses:** UI/UX & interaction logic; Product logic — coherence/consistency · **IDs:** F2, F16, F22
- **Evidence:** DayTimelineView onTap/onLongPress (~172-173) and context-menu 'Edit' (~190) all just set selectedEntry; the only consumer is the selection-border read (~184). No .sheet(item:)/navigationDestination observes it, so 'Edit' is indistinguishable from a tap. Dragging a running entry visibly moves then snaps back (commitActiveDrag early-returns on endedAt==nil, ~237). ManualEntrySheet(editing:) exists and TodayView even declares an unused editingEntry sheet for exactly this.
- **Fix:** Wire `.sheet(item: $selectedEntry) { ManualEntrySheet(editing: $0) }` so tap/'Edit' opens the editor the rest of the app uses. If editing-from-timeline is out of scope, remove the 'Edit' menu item and stop setting selectedEntry. For running blocks, suppress the drag gesture (or show 'Stop the timer to edit') instead of animating a revert.


### #12 — Recurrence save failure is a silent dead-end — rollback + OSLog + bare return, spinner just stops
- **Status:** New on main · **Lenses:** Engineering & code · **IDs:** NEW-S6-1
- **Evidence:** saveRecurrence() catch block (InvoiceGeneratorView.swift:519-531) calls modelContext.rollback(), sets permissionDeniedAlert=false, logs via Logger and `return`s with no UI feedback — the comment admits 'for v1.1 we just log via OSLog and bail without dismissing.' Success dismisses (536); failure looks identical to a no-op tap. Recurring is the newly-expanded section.
- **Fix:** Surface the failure via the alert mechanism already in this view — wire a state-driven error alert mirroring permissionDeniedAlert (325-334) so a save failure shows e.g. 'Couldn't save schedule, try again' instead of silently bailing.


### #13 — Recurring schedule ignores the selected Period and its eligible-entries preview — saved cadence derives its own range
- **Status:** New on main · **Lenses:** Product logic — coherence/consistency · **IDs:** NEW-S6-2
- **Evidence:** While 'Make this recurring' is on, the Period picker and eligible-entries preview stay visible/editable, but saveRecurrence() builds RecurrenceTemplate passing only cadence/grouping/notesTemplate/nextFireDate/endDate (InvoiceGeneratorView.swift:510-517) — never a rangeRule — so the model falls back to RangeRule.implied(from: cadence) (RecurrenceTemplate.swift:60). The preset/resolvedRange state and the 'Line items' eligible-entries block (145-165) become decorative once recurring is toggled.
- **Fix:** When makeRecurring is on, hide/disable the Period section and eligible-entries preview (they don't apply), or add a caption in the Recurring section stating the billing period is derived from the cadence (e.g. 'Each invoice covers the previous period automatically').


### #14 — Write/finalize/destructive paths fail silently — no user-facing error channel for PDF render, mark-paid, recurrence save, timer mutations
- **Status:** Re-verified on main · **Lenses:** Engineering & code · **IDs:** F12
- **Evidence:** Still silent: TimerActions.start/switchTo/takeBreak/resume/stop (try?/empty catch, TimerActions.swift:16/39/45/53/60); ManualEntrySheet create `_ = try? logCompletedEntry` (151); InvoiceDetailView.markPaid `try? markPaid()` (396); InvoicePreviewView.finalizeAndEmail/Share `catch {}` ('error toasts as future work', 465-467/561-563); InvoiceGeneratorView.saveRecurrence (519-531); RunningTimerCard.adjustStart `catch {}` (275-278). PARTIALLY FIXED: ReportsView.exportCSV now sets exportError→.alert (425, 89-95); a new ModelContext+SaveOrLog logs save failures to OSLog (no user signal).
- **Fix:** CSV-export site is done (mirror its pattern). Add one shared error-surface primitive (@Observable presenter hosted by a single .alert/toast on RootView) and route the still-silent non-save failures through it: InvoicePreviewView finalizeAndEmail/finalizeAndShare, InvoiceDetailView.markPaid, InvoiceGeneratorView.saveRecurrence, TimerActions/ManualEntrySheet-create. saveOrLog already gives the developer breadcrumb; the missing piece is the user channel.


## Medium priority


### Duplicate delivery actions on InvoiceDetail (loud body + ⋯ menu) while time-sensitive 'Send reminder email' is buried menu-only
- **Status:** Carried (unchanged on main) · **IDs:** F3
- **Evidence:** actionButtons (InvoiceDetailView.swift ~322-355) renders 'Share PDF' (always) and 'Email invoice' (non-draft) as bordered buttons, and the toolbar Menu (~69-99) renders the identical pair plus the menu-only 'Send reminder email' (sent-only). reminderBanner surfaces 'Send reminder' only when a fire date is past-due, so a sent-but-not-yet-overdue invoice's only reminder entry point is the buried menu.
- **Fix:** Keep delivery actions in ONE place: make 'Mark as paid' the loud body button on a sent invoice and demote 'Share PDF'/'Email invoice' to the ⋯ menu (or vice-versa) — not both in both. Promote 'Send reminder email' to parity with Email invoice in whichever single location is chosen.


### Editing an entry's times silently zeroes banked breaks, force-converts tracked→manual, and allows future-dated sessions
- **Status:** Carried (unchanged on main) · **IDs:** F9, F24, F40
- **Evidence:** ManualEntrySheet.save() editing branch (~135-149): if start/end changed it sets accumulatedSeconds=0 and activeSegmentStartedAt=nil (dropping break accounting) and unconditionally sets isManual=true — a timer entry with a 20-min break, opened to fix a typo'd end, loses the break (billable duration jumps) and is reclassified manual, with no alert. The Start DatePicker (~49) has no upper bound (rangeIsValid only checks endDate>startDate, ~38), so a wholly-future session is saveable; invalid range shows bare '—' (~123) with no reason.
- **Fix:** Show a confirmationDialog (existing pattern) before flattening when accumulatedSeconds>0 or isManual==false and times changed ('Editing times recalculates from start/end and clears recorded breaks'); preserve isManual when only notes/project changed. Cap the Start DatePicker at .now (like AdjustStartTimePickerSheet). Replace the bare '—' with 'End must be after start'.


### ManualEntrySheet bypasses TimerActions side-effects — no widget reload / Live Activity reconcile / intent donation after a manual edit
- **Status:** Carried (unchanged on main) · **IDs:** F13
- **Evidence:** ManualEntrySheet.save (ManualEntrySheet.swift:137-143) mutates SwiftData directly (or calls TimerService.logCompletedEntry) and never calls WidgetCenter.shared.reloadAllTimelines() or any TimerActions side effect, unlike every live-timer mutation ('ManualEntrySheet bypasses this entirely, skipping all side effects'). Today/Work tiles and widgets can show stale numbers after a manual edit. (Distinct from the break-data semantics item — this is the side-effect path.)
- **Fix:** Route ManualEntrySheet.save through a TimerActions.logCompleted/editEntry wrapper that saves then reloads widgets (and reconciles Live Activity if the edited entry is the running one), so manual and live-timer edits share one side-effect path.


### InvoiceGenerator exposes conflicting commit controls + silent makeRecurring/scope traps
- **Status:** Re-verified on main · **IDs:** F7
- **Evidence:** 'Invoice all projects (separate drafts)' (InvoiceGeneratorView.swift:115-119) renders whenever !projectsWithEligible.isEmpty, independent of the single-project Picker (111-114) — per-project Preview and N-draft batch both reachable at once. The toolbar trailing button silently swaps Preview↔'Save schedule' on makeRecurring (286-304) with the label as the only cue; makeRecurring (28) is never reset in the onChange(selectedClient/selectedProject) handlers (259-266). Batch path hardcodes scopeOfWork: nil (466).
- **Fix:** Make commit actions mutually exclusive and labelled by state; reset makeRecurring when client/project changes; resolve the batch vs single-Preview coexistence (see the recurring-mode and consolidated-invoice items). Relabel/condition existing controls — no new capability.


### Batch 'Invoice all projects' silently discards the typed Scope of work
- **Status:** Re-verified on main · **IDs:** F39
- **Evidence:** invoiceAllProjects() hardcodes `scopeOfWork: nil` in createDraft (InvoiceGeneratorView.swift:467) while the single-invoice Preview path passes trimmedScope (314). The 'Drafts created' alert says 'Open each from Invoices to add a scope' (323) but no on-form caption warns the Scope-of-work Section (126-129) is dropped for the batch path.
- **Fix:** Either caption the Scope-of-work section that it's ignored for the batch path, or carry the typed scope into each batch draft (pass scopeOfWork through invoiceAllProjects). Clarify/wire existing data.


### Recurring schedule silently drops the selected Project (template is client-wide) while the project picker stays visible
- **Status:** New on main · **IDs:** NEW-S6-3
- **Evidence:** A user can select a Project and toggle 'Make this recurring'; the picker stays visible, implying per-project scope. But saveRecurrence() uses only selectedClient (477) and builds RecurrenceTemplate with `client:` and no project (510-517) — RecurrenceTemplate has no project relationship (client-only, RecurrenceTemplate.swift:15). The selection is silently discarded. Distinct from F38 (consolidated one-off Preview).
- **Fix:** When makeRecurring is on, clarify scope inline (caption 'Recurring invoices cover all billable projects for this client') or de-emphasize/disable the Project picker so users don't expect per-project recurrence.


### Batch 'Invoice all projects' stays active in recurring mode — a second, conflicting immediate commit with no confirmation
- **Status:** New on main · **IDs:** NEW-S6-4
- **Evidence:** With makeRecurring on (toolbar reads 'Save schedule'), the inline 'Invoice all projects (separate drafts)' button is gated only by !projectsWithEligible.isEmpty (InvoiceGeneratorView.swift:115) — NOT !makeRecurring — so it remains tappable and immediately creates N one-off drafts + dismisses (287-298), contradicting the recurring intent with no confirmation. Two conflicting commit actions exposed at once.
- **Fix:** Wrap the batch button block (115-119) in `if !makeRecurring` so recurring mode offers a single, unambiguous commit action.


### 'Overdue' is a first-class status (red pill, banner) but has no filter; 'Outstanding' silently mixes overdue + not-yet-due
- **Status:** Carried (unchanged on main) · **IDs:** F21
- **Evidence:** InvoicesView.StatusPill and InvoiceDetailView.statusBanner render a distinct 'OVERDUE' label/color (InvoicesView.swift:244, InvoiceDetailView.swift:183) via isOverdue(). But Filter has only outstanding/paid/drafts/recurring, and .outstanding == status==.sent (131-132), folding overdue into Outstanding with no dedicated view. A freelancer chasing late payers cannot list just the late ones.
- **Fix:** Make the filter set match the status vocabulary: add an 'Overdue' segment (reusing isOverdue()), or rename 'Outstanding'→'Unpaid'/'Sent' and sort/emphasize overdue rows to the top so the label honestly describes contents. (The 'Outstanding' rename here also resolves the vocabulary collision in the UNINVOICED item.)


### Recoverable Archive fires instantly (no confirm) while less-frequent Delete is dialog-gated — proportionality inverted
- **Status:** Carried (unchanged on main) · **IDs:** F5
- **Evidence:** ClientsListContent.listContent (~171-185): trailing swipe has 'Delete' (role .destructive → confirmationDialog) AND 'Archive' (executes isArchived=true + save immediately, no confirm/undo). Archived clients then render with no NavigationLink (~191-208) — an accidentally-archived active client becomes a non-interactive dimmed row whose only recovery is a second swipe→Restore.
- **Fix:** Keep confirmation weight proportional to reversibility: give Archive the same lightweight confirmation Delete has, or reorder so the recoverable Archive is the default/leading swipe and Delete requires the deliberate full-swipe + dialog.


### 'Seed demo' toolbar button is unguarded in production, shown in the brand-new-user empty state
- **Status:** Re-verified on main · **IDs:** F23, F34, F50
- **Evidence:** TodayView.swift:51-57 renders `if allClients.isEmpty { ToolbarItem(.topBarTrailing){ Button("Seed demo"){ SampleData.seedDemo(in: modelContext) } } }` with NO #if DEBUG, against the live modelContext. The other two seedDemo sites ARE gated (RootView.swift:142 in #Preview; BillableApp.swift:26 behind --seed-demo). For a real new user the toolbar shows '+' and 'Seed demo' side by side at first contact, making the home look like a dev build. (F34's 'empty Today = dead air' half is FIXED — GetStartedSection now occupies the empty-state slot.)
- **Fix:** Gate the 'Seed demo' button (TodayView.swift:51-57) behind #if DEBUG (or the --seed-demo launch-arg pattern). Drop the 'add a first-track nudge' half — GetStartedSection already covers it.


### Just-completed (archived) billable project loses its only path to bill outstanding uninvoiced time; Complete copy never mentions uninvoiced
- **Status:** Re-verified on main · **IDs:** F25, F41
- **Evidence:** ProjectDetailView.swift:121 gates BOTH uninvoicedTile and 'Create invoice' on `project.isBillable && !project.isArchived`; completeProject() sets isArchived=true and dismiss()es (293-299). Complete confirmation copy (:108) says only 'Logged time stays on past invoices and reports.' — nothing about UN-invoiced time. Cross-screen incoherence: TodayView.swift:335-337 computes Uninvoiced over ALL entries with invoiceID==nil and NO isArchived filter, so Today shows money owed that ProjectDetail won't display or let you bill. Recovery ('Restore project') is buried in ⋯ (75-77) and restoreProject() doesn't dismiss (asymmetric).
- **Fix:** Split the gate so uninvoicedTile (and ideally 'Create invoice') drops only `!isArchived` when stats.uninvoicedAmount > 0, OR amend the Complete confirmation (:108) to add 'You can still invoice tracked time after completing by tapping Restore project.' and surface the outstanding $ in that dialog. Guard/copy change.


### Identical 'Xh YYm' duration formatter reimplemented at 8 view-layer sites — no shared helper
- **Status:** Re-verified on main · **IDs:** F14, NEW-S5-3
- **Evidence:** Same `"\(h)h \(String(format: "%02d", m))m"` literal at 8 sites: TodayView.formatHours (354-359), ProjectDetailView.hoursString (310-312), ManualEntrySheet.durationLabel (~123-127), ProjectSessionsView.hoursLabel (50-53, NEW from PR #13), WorkView.statsLine inlined (301-305), InvoiceGeneratorView.formatHours (388-393), ReportsView.formatHours (440-445, takes Decimal HOURS), Widgets/TodaySummaryWidget.swift:108-112. No shared DurationFormatting helper exists. EXCLUDE InvoiceTemplate.formatHours (349-350) — it intentionally renders decimal hours ('3.5'), a different format.
- **Fix:** Add DurationFormatting.hoursMinutes(seconds:) plus an hoursMinutes(decimalHours:) overload (for ReportsView) to BillableCore and replace all 8; the widget target already links BillableCore. Do NOT fold InvoiceTemplate.formatHours in.


### Per-second TimelineView re-runs unbounded fetch-all + all-time uninvoiced reduction on Today and in the widget
- **Status:** Re-verified on main · **IDs:** F15
- **Evidence:** TodaySummarySection @Query(entriesDescriptor) is FetchDescriptor<TimeEntry>() with no predicate (TodayView.swift:308-315); body is TimelineView(.periodic by:1) that re-filters today AND re-reduces the all-time invoiceID==nil uninvoiced EVERY SECOND (318-337). TodaySummaryWidget.fetchEntry is also fetch-all then in-memory filter (TodaySummaryWidget.swift:48-68). ClientsListContent.deleteClient fetches ALL RecurrenceTemplate, filters in-memory on the synchronous swipe path (ClientsView.swift:136-140). (ReportsView 'recomputed every body eval' is now FALSE — snapshot is @State gated via recompute(); only its fetch-all @Query remains, lower priority.)
- **Fix:** Give TodaySummarySection a today-only predicate for the live tiles and a separate invoiceID==nil descriptor, and lift the all-time uninvoiced reduction out of the 1Hz closure (can't change per second). Bound the TodaySummaryWidget fetch (today + 30/60-day window). Move deleteClient's in-memory filter off the synchronous swipe path. Drop the ReportsView body-eval rationale.


### Settings 'Upgrade to Pro' mimics a NavigationLink push but presents a sheet; 'Restore purchases' shows even for Pro users
- **Status:** Re-verified on main · **IDs:** F32
- **Evidence:** SettingsView.swift:78-88 builds 'Upgrade to Pro' as an HStack with a trailing chevron.right (push affordance) but the action sets showingPaywall=true presenting a .sheet (79, 169-171). Separately the 'Restore purchases' Button (90-95) renders unconditionally, outside the `if subscriptions.isPro / else` branch (closes at 89), so a Pro user sees 'Cadence Pro · Active' + 'Manage subscription' + 'Restore purchases' stacked.
- **Fix:** Drop the chevron from the upgrade row (sheets don't push) or convert it to a real push; move 'Restore purchases' inside the non-Pro branch (or hide it when isPro).


### Restore purchases is a silent no-op on failed/empty restore — paying user on a new device taps Restore and gets nothing
- **Status:** Re-verified on main · **IDs:** F31
- **Evidence:** PaywallView.restore() (PaywallView.swift:766-771) dismisses only when isPro; on a failed/empty restore it does nothing — SubscriptionManager.restore() swallows the error and returns false with the TODO intact (SubscriptionManager.swift:247-258). runPurchase() success also just dismiss()es with no confirmation (756). No 'No purchases found'-style copy exists anywhere; Settings' restore row discards the result too (`_ = await subscriptions.restore()`, SettingsView.swift:91). The error @State + .alert infra exists (PaywallView.swift:53, 116-122).
- **Fix:** On a failed/empty restore, surface a message via the existing error @State + .alert (e.g. 'No purchases found to restore'); on success show a brief confirmation before dismiss. Reuse the alert infra already in PaywallView.


### Paywall value copy is inconsistent across Trigger cases and can read as if invoicing itself is gated
- **Status:** Re-verified on main · **IDs:** F48
- **Evidence:** The only invoice-side Pro lever is canRemoveWatermark (SubscriptionManager.swift:66) — a free user fully creates/finalizes/shares invoices, just watermarked (InvoicePreviewView.swift:90, 109-130). Yet the paywall lead bullet is 'Watermark-free PDF invoices … without Sent with Cadence' (PaywallView.swift:330-331); the .removeWatermark subhead says 'Pro removes Sent with Cadence … and unlocks Reports + CSV export' (31) while its headline names only 'Remove the watermark.' (24) — across the three Trigger cases the actual Pro line is stated inconsistently and the bullet can read as if invoicing is gated. FEATURES.md §10 compounds it ('Create + send invoices' as Pro-only, :299).
- **Fix:** State one consistent Pro value line across all three Trigger cases (watermark-free PDFs + Reports + CSV) and reword the lead bullet so it can't read as 'invoicing is Pro'. Align FEATURES.md §10. (Coordinate with the spec-gating reconciliation item.)


### Paywall close button stays tappable during an in-flight purchase/restore (swipe is blocked, X isn't)
- **Status:** New on main · **IDs:** NEW-S1-1
- **Evidence:** interactiveDismissDisabled(isProcessing) blocks the swipe (PaywallView.swift:124) but the topBarTrailing close Button (92-95, rendered when !isEmbedded) has no .disabled(isProcessing). A user can tap X during `await manager.purchase`/restore, dismissing the sheet while the StoreKit await is outstanding; the success-side metrics (purchaseSuccess/trialStart) and dismiss() in runPurchase then fire against a gone view — an avoidable inconsistency at the moment money changes hands.
- **Fix:** Add .disabled(isProcessing) to the toolbar close Button (and/or hide it while processing) so both dismissal paths honor the same guard as interactiveDismissDisabled.


### lifetimeOwnedView funnel metric races async entitlement resolution — owned re-opens undercounted
- **Status:** New on main · **IDs:** NEW-S1-2
- **Evidence:** onAppear records PaywallMetrics.lifetimeOwnedView only when manager.ownsLifetime is true (PaywallView.swift:108-111). ownsLifetime is set by async refreshEntitlements() (SubscriptionManager.swift:299-321), kicked off from .task→start() (PaywallView.swift:98), both after onAppear. On a cold present, onAppear reads default ownsLifetime=false and the owned-view event never fires for a Lifetime owner, even though body's !ownsLifetime guard (75) later collapses the purchase UI. paywallView impression is recorded unconditionally, skewing the owned-vs-impression ratio.
- **Fix:** Record lifetimeOwnedView reactively once entitlement settles — add .onChange(of: manager.ownsLifetime) that emits when it flips true (guard against double-count on the same presentation).


### GetStartedSection lingers a full session after the checklist is completed in-app (latch only stamped on launch/foreground)
- **Status:** New on main · **IDs:** NEW-S3-1
- **Evidence:** TodayView.guidanceElement reads `profile?.firstSetupCompletedAt != nil` (TodayView.swift:93) and renders GetStartedSection when nil (107). The ONLY writer is BusinessProfileStore.stampFirstSetupIfReached (51-59), invoked solely via BusinessProfileMaintenance.run at RootView.swift:93 (scenePhase active) and BillableApp.swift:117 (startup). GetStartedSection never stamps it (GetStartedSection.swift:9-10) yet its doc claims 'The block disappears on its own once stampFirstSetupIfReached latches' — false within a session: after adding a client AND a client-linked project in-session, the fully-checked card persists until background/foreground or relaunch.
- **Fix:** Call the existing BusinessProfileMaintenance.run(in: modelContext) (or stampFirstSetupIfReached) from GetStartedSection in the onDismiss of the showingAddClient/showingNewProject sheets, so the latch is evaluated as soon as both pieces coexist and the block self-dismisses in-session. Pure wiring of an idempotent call.


### GetStartedSection 'Timer running' header tells users who already have a client to 'Add a client'
- **Status:** New on main · **IDs:** NEW-S3-2
- **Evidence:** header (GetStartedSection.swift:100-111) switches only on isTimerRunning: `Text(isTimerRunning ? "Add a client to invoice this time." : ...)`. It never consults hasClient (49), even though that boolean drives the checklist row's green checkmark (62-67) and the 'Create a project' enablement/hint (69-74). The block shows precisely while first-setup is unreached, which includes the common 'has a client, still needs a project' state — so the header contradicts the checkmark two rows below.
- **Fix:** Make the running-state subtitle depend on hasClient: when a client exists, point at the remaining step ('Create a project for this client to invoice this time.'); show 'Add a client to invoice this time.' only when hasClient==false. Reuses the already-computed hasClient.


### Reports AR 'GET PAID' card is as-of-today and unaffected by the range picker, sitting among range-scoped tiles — reads as a bug when switching ranges
- **Status:** New on main · **IDs:** NEW-S4-1
- **Evidence:** ReportsAggregator.arSummary computes current/overdue/aging from ALL sent invoices using `now` (ReportsAggregator.swift:244-254), while avgDaysToPay in the same struct IS range-scoped to bounds (256), and MoneySummary is fully range-scoped (160-166). The AR card sits directly below the range picker beside the range-scoped Tracked/Invoiced/Collected lenses (ReportsView.swift rangePicker→moneyLenses→arCard). Switching Week→Month→Year changes the tiles and '~N days to pay' but leaves the big outstanding headline + aging bar frozen, explained only by a small tertiary 'as of today' caption (158).
- **Fix:** Make the temporal split unmissable: relabel the AR header (e.g. 'OUTSTANDING (all time)') or promote the 'as of today' caption next to the headline figure, and/or move the AR card above the range picker so the picker visually governs only what it filters.


### Reports 'All paid up' contradicts a range-scoped $0 Collected tile in the same viewport
- **Status:** New on main · **IDs:** NEW-S4-2
- **Evidence:** The 'All paid up' branch fires on as-of-now state (ar.outstanding==0 && hasAnyBilledInvoice, ReportsView.swift:163-181) but its supporting line shows RANGE-SCOPED money.collected and is hidden when that is 0 (177-181). Collected (ReportsAggregator.swift:163-165) counts only invoices PAID within the range. So for 'Week' with an invoice paid last month: Collected tile=$0, AR card='All paid up' with no number — adjacent elements telling opposite stories.
- **Fix:** Tie the 'All paid up' sub-line to the same as-of-now framing as the headline (always show lifetime collected, or drop the conditional figure); alternatively suppress 'All paid up' wording when nothing was collected in-range and fall back to a neutral as-of-today phrasing.


### Reports CSV export ignores the selected range — always dumps all-time TimeEntries
- **Status:** New on main · **IDs:** NEW-S4-3
- **Evidence:** exportCSV() builds rows from `allEntries` (the unbounded @Query), never passing range/bounds (ReportsView.swift:414-417). Every other element on the screen is range-filtered (18, 98-100 drive recompute), so a user viewing 'Week' and tapping Export reasonably expects this week and silently gets an all-time dump. CSVExporter.rows just maps whatever it's given (CSVExporter.swift:87-91) — the caller hands it the wrong set.
- **Fix:** Filter the entries passed to CSVExporter.rows by the active range's bounds (the same bounds ReportsAggregator derives) so the CSV matches what the user is looking at. Reuse existing range selection.


### ProjectDetail/ProjectSessionsView session rows are inert — no way to edit or delete a listed entry from the project screens
- **Status:** New on main · **IDs:** NEW-S5-1
- **Evidence:** The detail 'Sessions' preview and the whole ProjectSessionsView list every session as a non-interactive SessionRow — no tap/swipe/context menu (ProjectSessionsView.swift:26-48; used read-only at ProjectDetailView.swift:266-269 and ProjectSessionsView.swift:81). The same TimeEntry objects ARE editable/deletable elsewhere: TodayView.swift:63 ManualEntrySheet(editing:), DayTimelineView.swift:172 selectedEntry / :309 delete. A user looking at a wrong/duplicate session on a screen titled 'Sessions' has no path to fix it from there.
- **Fix:** Wire ManualEntrySheet(editing:) into SessionRow (wrap in a Button/onTapGesture setting @State selectedEntry, present ManualEntrySheet(editing:)), and/or add a destructive .swipeActions delete mirroring DayTimelineView.delete(_:) (309-312). Reuses existing editor + delete.


### Work/NewProject empty states have no action — 'No projects yet' and 'No clients yet' dead-end the user
- **Status:** Re-verified on main · **IDs:** F4
- **Evidence:** WorkView.swift:138-143 — the 'No projects yet' ContentUnavailableView has NO action button (only Label + 'Add a client and a project to start tracking.'), while the sibling Clients empty state (ClientsView.swift:75-87) DOES provide a borderedProminent 'Add Client'. NewProjectSheet.swift:193-198 shows 'No clients yet' with only a 'Cancel' toolbar button (WorkView.swift:217-219) — tapping + → New project before any client exists dead-ends. The + menu (WorkView.swift:67-80) already has 'New project'/'New client'.
- **Fix:** Add an inline CTA to the Work 'No projects yet' state (surface the existing 'New client'/'New project' menu actions), and give NewProjectSheet's 'No clients yet' an 'Add client' action instead of forcing a back-out. Move existing controls into the empty states.


### Payment reminders: master ON with zero day-offsets selected is a silent no-op
- **Status:** New on main · **IDs:** NEW-S7-1
- **Evidence:** masterSection (PaymentRemindersView.swift:56-75) and offsetsSection (77-91) are independent: all four offset Toggles can be off while masterEnabled is true. config.enabledOffsets becomes [] (84) and the scheduler has no fire dates, so the user believes reminders are on but the client never receives one. No empty-set guard or hint anywhere.
- **Fix:** When masterEnabled is true and enabledSet.isEmpty, show an inline caption in offsetsSection ('Pick at least one timing or no reminders will send'), reusing the caption styling at 65-67.


## Low priority


### PaymentReminders live Preview signs off as hardcoded 'Studio Lina' while real sends use the profile name
- **Status:** Re-verified on main · **IDs:** F26
- **Evidence:** PaymentRemindersView.swift:149 and :155 pass `senderName: "Studio Lina"` into both ReminderTemplateRenderer.render calls for the live Preview; the default body ends with {senderName} (ReminderConfig.swift:63), substituted verbatim (ReminderTemplateRenderer.swift:54). Real send paths use the profile name: InvoiceDetailView.swift:426, InvoicePreviewView.swift:413. So every user's preview signs 'Studio Lina' while the sent email uses their real name. `profiles` is already @Query'd here (10) and used for currencyCode (13).
- **Fix:** Replace the two 'Studio Lina' literals (149, 155) with `profiles.first?.name`, falling back to a neutral placeholder like 'Your business' only when blank. One-line fix using data already in scope.


### ProjectDetail hero: 'Create invoice' is visually quieter than Start timer; session rows lack time-of-day
- **Status:** Re-verified on main · **IDs:** F8
- **Evidence:** 'Create invoice' is .buttonStyle(.bordered) (ProjectDetailView.swift:129) while Start/Switch is .borderedProminent (242) — the monetizing action reads quieter than Start timer. SessionRow shows NO time-of-day: it renders entry.startedAt.formatted(.dateTime.weekday().day()) (ProjectSessionsView.swift:34) though TimeEntry.startedAt/endedAt exist. (The 'See all N sessions / Show less' sub-claim is FIXED by PR #13 — it's now a NavigationLink + prefix(5) cap; the lifecycle action moved to ⋯, so the tie-with-destructive framing is stale.)
- **Fix:** Promote 'Create invoice' to .borderedProminent (distinguish from lifecycle actions) so it reads primary on billable projects; add start time-of-day (or start–end) to SessionRow (ProjectSessionsView.swift:34) since both the detail preview and full history reuse this one row.


### RecurringRules empty-state names a non-existent screen; 'Ended' templates still offer Pause/Resume
- **Status:** Carried (unchanged on main) · **IDs:** F27
- **Evidence:** RecurringRulesView empty state (~23) reads 'Set up monthly billing... from the New Invoice screen' but the actual screen is titled 'New invoice' (InvoiceGeneratorView), reached via the Invoices '+'. Swipe actions (~35-39) always offer Pause/Resume even when statusPill shows 'Ended' (isEnded(), ~122-124); resuming an ended template is contradictory, and PendingMaterializationsView can surface an ended template whose only error is 'This template has ended' with no in-place fix.
- **Fix:** Update empty-state copy to the real entry point ('from the Invoices tab, tap + and turn on Make this recurring'). For ended templates, hide Pause/Resume (leave only Delete) so the offered action matches state. Copy/visibility edits.


### Monthly plan caption is bare ('Billed every month') while Yearly's is informative — lopsided at-a-glance compare
- **Status:** Re-verified on main · **IDs:** F33
- **Evidence:** pricePicker renders a single shared ProgressView during .idle/.loading and only both planRow cards in .ready (PaywallView.swift:363-385), and refreshProducts sets monthly AND yearly before flipping .ready (SubscriptionManager.swift:156-165) — so the original 'price-less card + spinner' mechanism is dead. What remains is copy asymmetry: Yearly's caption is 'Just $X per month, billed yearly' (561-570) while Monthly's is the bare 'Billed every month' (571-572).
- **Fix:** Wording only — give Monthly a symmetric, equally-informative caption (e.g. restate '$3.99 billed monthly') so both rows carry the same level of detail. (Drop the price-slot/loading framing — now fixed.)


### CurrencyPicker has no search / common-currency fast-path and silently side-creates a profile
- **Status:** Re-verified on main · **IDs:** F43
- **Evidence:** CurrencyPickerView.swift:19-25 renders a single Picker over CurrencyCatalog.allCodes (= Locale.commonISOCurrencyCodes.sorted(), CurrencyCatalog.swift:11) with .pickerStyle(.navigationLink), NO .searchable and no fast-path — the user scrolls the full ISO list. save(_:) runs on every onChange(of: selection) (30) with no Save/Cancel, and when no profile exists it silently side-creates one via BusinessProfile.defaultForCurrentLocale() (42-46), so opening BusinessProfileEditorView afterward finds a pre-created profile.
- **Fix:** Add .searchable to the currency list (note .pickerStyle(.navigationLink) puts options on a system-pushed screen; to control the search bar, render the list as explicit NavigationLink rows). Separately, defer profile creation until an explicit save or reuse the existing 'Set up your business' copy.


### WorkView builds/labels/sorts a 'No client' project group that no creation path can produce
- **Status:** Re-verified on main · **IDs:** F44
- **Evidence:** WorkView.swift:107-124 builds, labels ('No client', 111) and sorts-last (117-123, nil-id bucket) a client-less project group. But every creation path supplies a client: ProjectEditorView requires non-optional `let client: Client` (ProjectEditorView.swift:11), NewProjectSheet forces client selection before the editor (WorkView.swift:200-225), and Client.projects is .cascade (Client.swift:23) so deleting a client deletes its projects. Project.client is Client? only for model flexibility. The 'No client' grouping is unreachable for normal data and contradicts the rest of the app.
- **Fix:** Remove the 'No client' grouping/label/sort branch (or guard it behind a real data condition), since no UI path creates a client-less project under the normal model. Restructure existing view code — no behavior loss.


### EntityType.showsTaxByDefault policy is dead code; tax-section gating re-encodes the rule as a literal
- **Status:** New on main · **IDs:** NEW-S2-1
- **Evidence:** EntityType.swift:11 declares `showsTaxByDefault: Bool { self == .organization }` and its doc + EntityType+Presentation.swift:5 frame it as the driver of default tax-section visibility, but it's referenced only in its own def, one doc comment, and one test (EntityTypeTests.swift:21-22) — never in app code. BusinessProfileEditorView.swift:93 makes the actual decision with literal `if entityType == .organization { taxFields } else { DisclosureGroup(...) }`, re-encoding the same rule. A future entity case could silently diverge.
- **Fix:** Replace the literal at BusinessProfileEditorView.swift:93 with `if entityType.showsTaxByDefault` so the policy property is the single source of truth (or delete the property + test if genuinely unwanted). Wiring an existing property into the place that already implies it — no behavior change.


### EntityType default diverges: model defaults to .organization, both UIs to .freelancer
- **Status:** New on main · **IDs:** NEW-S2-2
- **Evidence:** BusinessProfile.swift:65 sets entityTypeRaw = .organization (echoed in init :110, getter fallback :68). OnboardingView.swift:15 pre-selects .freelancer, BusinessProfileEditorView.swift:46 also defaults @State to .freelancer. finish() overwrites with the user's pick (OnboardingView.swift:270), masking it in the normal flow — but `--seed-onboarding-needs-setup` fixture BusinessProfile(name:"Test Co") (BillableApp.swift:68) and defaultForCurrentLocale() (BusinessProfile.swift:218-225) both yield .organization (Business-name labels + always-visible tax) for a freelancer-first product.
- **Fix:** Pick one default and make the three sites agree — align the model default to .freelancer (and update the seed fixture expectation), or document why the persisted fallback stays .organization while the UIs start at .freelancer. Reconcile an existing default.


### Entity-type control mismatch: onboarding teaches with descriptive cards, the Settings editor it points to shows a bare segmented Picker
- **Status:** New on main · **IDs:** NEW-S2-3
- **Evidence:** OnboardingView.swift:106-110 renders entityCard per case with cardTitle + cardSubtitle (e.g. 'Just me — I bill for my own time.', EntityType+Presentation.swift:55-60) and promises Settings as the change-point (101). But BusinessProfileEditorView.swift:53-58 builds a .segmented Picker tagging each option with only Text(type.cardTitle) — the subtitle is dropped. The editor's section footer (73) re-explains in prose, but the control itself loses the richer affordance.
- **Fix:** Make the two surfaces consistent — keep the editor's footer text aligned with onboarding's subtitle wording, or reuse the same labeled affordance. Reuse of existing copy/controls.


### Onboarding identity step: @FocusState nameFocused is bound but never driven (inert wiring)
- **Status:** New on main · **IDs:** NEW-S2-4
- **Evidence:** OnboardingView.swift:18 declares `@FocusState private var nameFocused` and :119 applies .focused($nameFocused), but no assignment to nameFocused exists in the file. The omission is intentional and documented (248-249: not auto-focusing so the keyboard can't hide the entity cards), but the result is a declared FocusState that drives nothing.
- **Fix:** Remove the unused @FocusState/.focused pair (it does nothing), or, if a one-tap-faster finish is wanted, set nameFocused=true after the identity step appears (short post-transition delay). Pure cleanup.


### Paywall savings-badge currency code can disagree with the price it annotates
- **Status:** New on main · **IDs:** NEW-S1-3
- **Evidence:** savingsPill computes AnnualSavings from manager.monthly?.price and manager.yearly?.price (PaywallView.swift:542-543) but formats it with yearlyCurrencyCode, which reads only manager.yearly?.priceFormatStyle.locale.currency (544, 555-559). PricingDisplay.annualSavings (PricingDisplay.swift:14-29) assumes both prices share a currency before subtracting, with no guard. Fine in the single-storefront case, but it mixes a both-products computation with a single-product currency label.
- **Fix:** Assert/guard that monthly and yearly currency codes match before showing the badge, or derive the badge currency from the same product whose price dominates the figure, so the symbol always matches the math.


### Owned-Lifetime paywall still shows a no-op 'Restore purchases' and irrelevant auto-renew fine print
- **Status:** New on main · **IDs:** NEW-S1-4
- **Evidence:** Body always renders lifetimeAffordance + secondaryActions + finePrint; only picker/CTA are hidden by the !ownsLifetime guard (PaywallView.swift:75-83). For an owner, secondaryActions still shows 'Restore purchases' (701-705) whose restore() returns true-but-already-pro with the only effect being dismiss() (766-771), and the auto-renew finePrint (716-721) is irrelevant to a one-time Lifetime owner — two now-meaningless affordances on the owned screen.
- **Fix:** In the ownsLifetime branch, drop the auto-renew finePrint and the Restore action (or collapse secondaryActions to just Terms/Privacy), reusing the existing ownsLifetime guard already in body.


### CSV export silently drops client-less ('General') time, diverging from the on-screen project breakdown
- **Status:** New on main · **IDs:** NEW-S4-4
- **Evidence:** CSVExporter.rows guards `guard let project = entry.project, let client = project.client else { return nil }` (CSVExporter.swift:91-93 — confirmed at :92), dropping client-less rows. But ReportsAggregator.groupings emits projectHours for client-less projects too (ReportsAggregator.swift:215-228, `project.client?.name ?? ""`), and onboarding's quickStart creates clientless 'General' entries (ActivationMetrics.swift:16-20, 67-70). So the screen total and CSV total diverge for a first-run-typical user.
- **Fix:** Emit client-less entries in the CSV with an empty or 'General' client column instead of dropping them, so the export reconciles with the on-screen project breakdown.


### Reports paywall impression counter over-counts on re-appear (embedded tab), understating conversion rate
- **Status:** New on main · **IDs:** NEW-S4-5
- **Evidence:** ReportsConversionMetrics.recordImpression() is called unconditionally in PaywallView.onAppear (99-102) and .onAppear re-fires on Reports-tab revisits (the embedded paywall stays mounted, RootView.swift:120-128). Conversion is recorded exactly once on purchase success (755), so the numerator is honest while the denominator drifts up — the DEBUG 'N seen · M converted' readout (ActivationMetricsView.swift:40-41) reads worse than reality.
- **Fix:** Guard the impression increment with a one-shot @State flag (record only on first appear per presentation) so the impression count tracks distinct presentations, matching the once-only conversion counter.


### ProjectDetail recomputes full lifetime ProjectStats every second while a timer runs
- **Status:** New on main · **IDs:** NEW-S5-2
- **Evidence:** content(asOf:) is called inside the per-second TimelineView (ProjectDetailView.swift:60-61) and calls `ProjectStats.compute(for: project, asOf:)` (114), which reduces over ALL project.entries (ProjectStats.swift:29-36) once per second for the whole history while any timer for this project runs. Only the running entry's contribution changes per tick. PR #13 already hoisted the sort + month-grouping out of this closure (46-51) and pinned completed rows to a stable date (266-267) — but the most expensive O(n) reduce was left inside. WorkView.swift:302 has the same pattern per visible row.
- **Fix:** Compute the static portion of ProjectStats once outside the TimelineView (like the sort/group already are) and add only the running entry's live delta per tick, or memoize compute() keyed on entry count + running entry id. Pure perf refactor, output unchanged.


### ProjectDetail hero: low-contrast white text over the bright-orange gradient
- **Status:** New on main · **IDs:** NEW-S5-4
- **Evidence:** The hero renders the big lifetime-hours value in solid white (ProjectDetailView.swift:140-141) and the session/value subline in .white.opacity(0.9) (150) over a LinearGradient [.timerAccent, .timerAccent.opacity(0.85)] (155). .timerAccent is bright orange (~#FA7D21, RunningTimerCard.swift:9); white on that lightness is borderline for WCAG and the 90%-opacity subline on the lighter gradient end is weaker still, on the project's headline screen carrying real info.
- **Fix:** Deepen the gradient (darker orange end) so white clears contrast, or drop the .opacity(0.9) on the subline to solid white, and verify against dynamic-type/contrast accessibility settings. Pure styling change.


### ProjectSessionsView shows a running session frozen (asOf: .now, no live tick)
- **Status:** New on main · **IDs:** NEW-S5-5
- **Evidence:** ProjectSessionsView renders every session with asOf: .now and has no TimelineView (ProjectSessionsView.swift:67-68 sorts all project.entries incl. the running one; :81 SessionRow(entry:, asOf: .now)). A user who taps 'See all sessions' mid-session sees a non-updating value for the active session, contradicting the live behavior on the detail card, Today, and WorkView. The justifying comment (56-59) assumes the running entry is only on the detail screen.
- **Fix:** Either exclude the running entry from this history list (already shown live on the detail screen), or wrap the running row in the same TimerTickSchedule TimelineView the detail screen uses so it ticks. Latter reuses existing machinery.


### 'Save schedule' enables with zero billable projects — a recurring schedule that can never produce a non-empty invoice
- **Status:** New on main · **IDs:** NEW-S6-5
- **Evidence:** saveDisabled checks only `selectedClient == nil || profile == nil || savingRecurrence` (InvoiceGeneratorView.swift:95-97 — confirmed), ignoring activeProjects/projectsWithEligible. Meanwhile the Project section may show 'This client has no active projects.' (109) and Line items 'No billable... entries' (155). The enablement logic and the on-screen eligibility signals disagree.
- **Fix:** Gate saveDisabled additionally on the client having at least one billable project (activeProjects non-empty), reusing data already computed in refreshProjectsAndActive() (418-420). Tighten existing disable logic.


### PaymentReminders live Preview keeps updating even when reminders are disabled
- **Status:** New on main · **IDs:** NEW-S7-2
- **Evidence:** templatesSection disables the Subject/Body fields when reminders are off (PaymentRemindersView.swift:100, 107), but previewSection (144-181) is rendered unconditionally and recomputes from subject/bodyText regardless of masterEnabled. The screen simultaneously says 'this is off' (greyed editor) and 'here is exactly what will be sent' (live preview).
- **Fix:** Gate or visually de-emphasize the preview when !masterEnabled (wrap previewSection in `if masterEnabled` or apply the same dimming) so the disabled state reads consistently.


### Switching entity type to Freelancer hides a freshly-entered tax rate behind a collapsed DisclosureGroup
- **Status:** New on main · **IDs:** NEW-S7-3
- **Evidence:** The tax Section branches on entityType at render: Organization shows taxFields inline, Freelancer shows them inside DisclosureGroup(isExpanded: $taxExpanded) (BusinessProfileEditorView.swift:92-99). taxExpanded is set from saved data only in loadIfNeeded (267) on first mount; switching entityType live doesn't re-evaluate it, so a freshly-entered Organization rate disappears from view when toggled to Freelancer.
- **Fix:** On entityType change to .freelancer, set `taxExpanded = (taxRatePercent != 0)` (mirroring loadIfNeeded at 267) via .onChange(of: entityType), so a non-zero rate is never hidden. Reuses existing state.


### Business-profile 'Incomplete' badge hinges on optional bank details, nagging users who invoice without a bank
- **Status:** New on main · **IDs:** NEW-S7-5
- **Evidence:** isProfileEnriched is `!address.isEmpty && hasBankDetails` (BusinessProfile.swift:78-80) and SettingsView.swift:41-47 renders the orange 'Incomplete' badge whenever !isProfileEnriched. Yet the Bank details section footer says bank info is optional ('Leave blank to hide.', BusinessProfileEditorView.swift:181). The two surfaces disagree about whether bank details are required, so the persistent flag misrepresents a valid, intentionally-minimal profile.
- **Fix:** Reword the badge to be advisory ('Add bank details to show payment info on invoices') rather than a deficiency, or base isProfileEnriched only on fields actually required to send a valid invoice, so an intentionally bank-less profile isn't labeled incomplete.


## Borderline — fix may add a new capability (needs your decision)


- **Today widget empty state ('Add a client to start tracking.') has no tap target / deep link** [Medium] {NEW-S3-3}
  - Constraint-borderline: the populated widget tiles are interactive via StartTimerIntent (TodaySummaryWidget.swift:184-204) but the empty branch is a bare Text with no widgetURL/Link (176-181; grep finds zero widgetURL/Link in the file), so a new user who adds the widget first taps a dead instruction. The fix reuses an existing in-app destination + the standard widget deep-link mechanism, but it delivers a widget→app deep-link routing capability the app does not have today (no widgetURL handling exists), so it crosses from pure relabel/wire into adding a new behavior. User decides whether to add deep-link routing.


## Removed — not silently dropped


- **Onboarding forces a running timer with no skip** — _Already fixed on main_ {F6}
  - OnboardingView was rewritten to a 2-step flow (enum Step { case welcome, identity }, :20). finish() (258-286) inserts ONLY a BusinessProfile and explicitly 'creates no Client/Project/TimeEntry'; TimerActions/.start( appear nowhere in the file. Final CTA is 'Finish setup' landing on Today — nothing is started, so there is nothing to skip.

- **Onboarding forced timer + always-enabled final CTA (conversion)** — _Already fixed on main_ {F30}
  - finish() never calls TimerActions.start (only mutates name/entityType + stamps onboardingCompletedAt); primaryEnabled for the .identity step now requires a non-blank name (235-240) with .disabled(!primaryEnabled) + 0.4 opacity (224-225). The old always-true displayProjectName fallback is deleted. Completion needs a name and lands on Today with no running timer.

- **Onboarding forces a client + rate; no try-tracking path** — _Already fixed on main_ {F42}
  - The rewritten flow no longer asks for client or rate (no clientName/hourlyRate/displayProjectName, no rate=100, no gate). finish() (258-286) creates no Client/Project/TimeEntry and starts no timer; Today's TodayGuidance.resolve surfaces a non-blocking .getStarted nudge (GetStartedSection) instead of forcing billable setup. The non-billable/try-tracking path now exists by construction.

- **ReportsLockedView has no Restore path + hardcoded feature claims** — _Already fixed on main_ {F35}
  - ReportsLockedView was deleted (commit 1e20d0d 'render Reports paywall in place; retire ReportsLockedView'). RootView.swift:118-129 now renders the locked tab via PaywallView(trigger: .reports, isEmbedded: true), which has a 'Restore purchases' button (699-714) and outcome copy (22-33), and shares ReportsSampleData with ReportsView so teaser numbers can't drift. Both concerns resolved.

- **ReportsLockedView hardcoded brittle feature enumeration ('8-week earnings trend' etc.)** — _Already fixed on main_ {F49}
  - The exact target string ('Hours by client, billable vs. non-billable, 8-week earnings trend, plus CSV export') no longer exists (grep finds zero '8-week'/'earnings trend'/'billable vs.'); retired in commit 1e20d0d. The locked tab now shows PaywallView with outcome-oriented, enumeration-free copy (22-33, 328-336), and the dashboard is range-aware (ReportsAggregator.swift:12-27) so a fixed-window claim would be wrong anyway. What F49 recommended is essentially what shipped.

- **Deleting a project can orphan a project-scoped RecurrenceTemplate / misroute its notification** — _False positive_ {F17}
  - The premise is false against the model. RecurrenceTemplate.swift:15 declares only `client: Client?` and has NO project relationship (header: recurrence is client-scoped; cancel-then-delete lives in ClientsView.deleteClient by design). Deleting a project (ClientDetailView.swift:123-126) cannot dangle a template. The only project-linked record is Invoice.project (Invoice.swift:76), a plain Project? SwiftData nullifies on delete; the invoice keeps its frozen projectNameSnapshot and its reminders (cascaded from Invoice, not Project). The deleteClient-vs-deleteProject asymmetry is intentional.

- **Paywall mock-screenshot prices wrong + Lifetime not purchasable** — _Out of scope (now doc-only)_ {F29}
  - Both code defects are FIXED on main: mockPlanRow renders '$39.99'/'$3.99' (PaywallView.swift:359-360) matching Billable.storekit, and Lifetime IS purchasable (Plan.lifetime :64, lifetimeAffordance sets selection :665-697, selectedProduct returns manager.lifetime :725-731, purchase handled :599-609/733-764). The only residual is FEATURES.md §10 drift (still lists Monthly $5.99/Yearly $34.99, no $99.99 Lifetime, :304-305) — a doc-only edit, out of the engineering backlog. The CRO-conversion engineering risk is resolved.
