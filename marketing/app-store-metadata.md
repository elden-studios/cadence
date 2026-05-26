# Cadence — App Store Connect Metadata (v1.3)

Copy-paste-ready content for App Store Connect submission. Char counts shown for fields with strict limits.

---

## App Name — 30 chars

**Recommended:** `Cadence: Time Tracker` *(21 chars)*

> Brand-led with a high-SEO descriptor. Apple's strongest ranking signal; getting "Time Tracker" into the App Name beats burying it in keywords.

Alternative options if you prefer brand-pure:
- `Cadence` *(7 chars)* — pure brand
- `Cadence — Freelance Timer` *(25 chars)* — audience-led

---

## Subtitle — 30 chars

**Recommended:** `Time tracker for freelancers` *(28 chars)*

> Reinforces both the audience (freelancers) and the category (time tracker). High SEO weight after the name.

Alternatives:
- `Track hours, send invoices` *(26 chars)* — value-prop-led
- `Hours + invoices for billing` *(28 chars)* — invoicing-led

---

## Keywords — 100 chars (comma-separated, no spaces after commas)

**Recommended:** `billable,hours,timer,timesheet,billing,hourly,consultant,pdf,client,contractor,self employed,agency` *(99 chars)*

> Notes:
> - Excludes words already in App Name + Subtitle ("time tracker", "freelance", "invoices") — Apple ranks those automatically from the name fields.
> - Apple auto-indexes plurals (timer → timers), so the singular form is enough.
> - "self employed" intentionally has a space (single keyword for the phrase).

If you want broader audience reach, drop `pdf` and add `lawyer,coach`:
`billable,hours,timer,timesheet,billing,hourly,consultant,client,contractor,self employed,lawyer,coach`

---

## Promotional Text — 170 chars (editable post-launch without resubmission)

**Recommended:**
> `New: Start 7 days free. Watermark-free invoices, full Reports, CSV exports. Track time and bill clients without the bloat.` *(132 chars)*

> Use this field for limited-time announcements; you can update it without resubmitting the build.

---

## Description — 4000 chars

```
Cadence is the time tracker and invoice generator built for freelancers, consultants, and independent professionals. Track every billable minute. Send polished, branded PDFs to clients. Skip the bloat of team-focused tools.

WHAT YOU CAN DO

• Start a timer in one tap. Switch between projects without losing context.
• Resume the timer you just stopped with a single tap — perfect for short interruptions.
• See today at a glance: hours, earnings, and uninvoiced time.
• Build invoices from your tracked hours in seconds.
• Generate beautifully formatted PDF invoices with your business details, line items, tax, and notes.
• Track recurring invoices for monthly retainers.
• Set automatic payment reminders so you never have to nag a client again.
• Organize work by client and project with your own color system.
• Choose from 150+ currencies — USD, EUR, GBP, JPY, SAR, AED, INR, and more.
• Sync seamlessly across iPhone via iCloud.
• Live Activities, Lock Screen widgets, and Siri Shortcuts integrated.

CADENCE PRO — START 7 DAYS FREE

Unlock everything for $5.99/month or $34.99/year:

• Watermark-free PDF invoices — send polished documents without "Sent with Cadence" in the footer.
• Reports & insights — hours by client, billable vs. non-billable, 8-week earnings trend.
• CSV export — clean exports your accountant will actually want.

Cancel anytime from your App Store account settings. The 7-day trial is free; if you cancel before it ends, you won't be charged.

PRIVATE BY DESIGN

Your data lives in your iCloud account. No third-party servers. No tracking analytics. No teams to set up. No account or login required to use the app.

MADE FOR

Designers, developers, writers, lawyers, accountants, photographers, tutors, contractors, copywriters, consultants, coaches, agencies of one — anyone who bills by the hour.

YOU'LL LOVE IT IF

• You spend more time tracking time than doing the work
• Your invoices look like they were made in a hurry
• You forget to follow up on unpaid invoices
• You want to know how much you actually earned this month
• You'd rather not pay $10+/month for a tool you barely use
• You want something that respects your time and your data

START YOUR 7-DAY FREE TRIAL TODAY

Download Cadence. Track your first hour. Send your first invoice. See where your time really goes.

Questions or feedback? Tap Settings → support — we read everything.
```

**Char count:** ~2,100 chars. Well under 4000.

---

## What's New (Release Notes) — for v1.3

```
v1.3 — Resume, polish, and quality-of-life

NEW
• Resume Last — tap to pick up the timer you just stopped, perfect for short interruptions (coffee, calls, bathroom breaks)
• Full ISO 4217 currency catalog — 150+ currencies including SAR, AED, EGP, ILS, CNY, KRW, TRY, ARS, and many more

IMPROVED
• Today screen: simpler empty-state logic, faster rendering
• Save failures now surface via OSLog instead of being silent
• Launch tagline regression coverage added
• Cleaner internal architecture (28-site persistence-call sweep)
• 165 unit tests passing, all green

INVOICE PREVIEW
• Watermark cache now refreshes correctly after a Pro upgrade

If you find Cadence useful, please leave a review — it makes a real difference for an indie app.
```

**Char count:** ~700 chars.

---

## Required URLs

| Field | Value | Status |
|---|---|---|
| Support URL | `https://elden-studios.github.io/cadence/support` | ⚠️ Needs GitHub Pages page |
| Marketing URL (optional) | `https://elden-studios.github.io/cadence/` | ⚠️ Needs landing page |
| Privacy Policy URL | `https://elden-studios.github.io/cadence/legal/privacy` | ⚠️ Needs real privacy policy |
| Terms of Use (EULA) URL | `https://elden-studios.github.io/cadence/legal/terms` | ⚠️ Needs real terms |

GitHub Pages and the legal pages were scaffolded in v1.2 Task 7. You still need to (a) enable GitHub Pages on the repo, (b) author real legal copy in `docs/legal/`.

---

## App Categories

| Field | Value |
|---|---|
| Primary | **Business** |
| Secondary | **Productivity** |

> Business has lower competition than Productivity. Cadence's audience (freelancers, consultants) is more likely to search the Business charts.

---

## Age Rating

**4+** — no objectionable content. The standard questionnaire answers will all be "None."

---

## Privacy "Data Used to Track You" / "Data Linked to You" (App Privacy section)

Cadence collects:
- **No data** from your activity to track you across other apps or websites.
- **No data** sent to third parties.

For the App Store Connect privacy questionnaire, declare:
- "Data Not Collected" for almost every category
- Exception: **Purchases** — declared as "Linked to Identity" (because Apple's StoreKit handles subscription receipts, which are user-identifiable on their side; this is the standard pattern for any IAP-using app)
- CloudKit data is stored in **the user's own iCloud** which Apple treats as "not collected" from the developer's perspective

---

## Sandbox testing checklist before submission

- [ ] Create sandbox tester in App Store Connect → Users and Access → Sandbox Testers
- [ ] Sign into the simulator/device with the sandbox tester Apple ID (Settings → App Store → Sandbox Account)
- [ ] Verify products load on the paywall (not "Pricing unavailable")
- [ ] Verify subscribe flow → entitlement updates to `.trial` → watermark disappears → Reports populates
- [ ] Verify restore purchases → entitlement re-derives
- [ ] Verify "What's New" copy renders correctly post-update
