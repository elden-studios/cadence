# Cadence v1.2 — Payment Links via Stripe Connect

**Status:** Design approved · ready for implementation plan
**Date:** 2026-05-24
**Phase:** v1.2 (of the post-v1 four-phase roadmap)
**Estimated scope:** ~12 working days (~2 weeks)
**Spec author session:** brainstorming flow (superpowers:brainstorming)
**Predecessor:** [v1.1 — Recurring + Overdue Reminders](2026-05-23-recurring-invoices-and-overdue-reminders-design.md) (shipped)

---

## 1. Summary

Cadence v1.2 adds an automatic **"Pay now"** affordance to every invoice the user sends, by integrating Stripe Connect Express. Three user-visible changes drive the entire phase:

1. A new **Settings → Payment links** screen lets the user connect their own Stripe account via Stripe's hosted onboarding form.
2. Once connected, every Invoice the user marks Sent gets a **Stripe Payment Link** generated automatically. The link is embedded as a clickable "Pay now" CTA in the rendered PDF + made available via a `{paymentLink}` merge field in reminder email templates.
3. When the client clicks the link and pays, Cadence **auto-marks the invoice Paid** in seconds — via Apple Push Notification service → background fetch → state reconciliation — without the user having to open the app.

Architecturally, v1.2 introduces Cadence's **first backend infrastructure**: a small Cloudflare Worker (~500 LOC) that holds Stripe's secret key, signs APNs JWTs, and dispatches silent push notifications when Stripe webhooks fire. The Worker stores no PII — only a tiny `stripe_acct_id → APNs device token` mapping in Cloudflare KV. All invoice and client data continues to live in the user's iCloud Private Database; Cadence still operates no server-of-record.

**Locked architectural decisions (from brainstorming):**
- **Gateway scope: Stripe Connect only** for v1.2. Covers US/EU/UK/CA/AU markets — the original Cadence persona. Multi-gateway abstraction deferred to v1.3+ if regional demand emerges.
- **Connect flavor: Express.** Stripe handles all KYC, compliance, dispute UI, and payout dashboard. Cadence builds zero compliance UI.
- **Platform fee: 0%.** Payment links are a Pro-subscription feature; Cadence takes no application_fee_amount on top of Stripe's processing fee.
- **Backend host: Cloudflare Workers.** Free tier covers v1.2 scale; near-zero cold start; global edge.
- **Sync model: APNs silent push + scenePhase polling fallback.** Primary path is push-driven; polling is the safety net.

---

## 2. Goals & non-goals

### Goals
- Cadence Pro users get **"invoice sent → client paid → marked Paid automatically"** as a near-zero-friction loop.
- Stripe handles all regulatory + compliance scope; Cadence doesn't build KYC, dispute, or payout UI.
- The Worker is genuinely tiny (~500 LOC). No server-of-record. No PII at rest server-side.
- Ship in ~2 weeks. Keep the iOS dependency surface unchanged (no Stripe iOS SDK).
- Lay the architecture so v1.3+ could add a second gateway behind an abstraction without rewriting the iOS state-sync model.

### Non-goals (deferred)
- **Refunds and disputes** — Stripe Dashboard is authority; Cadence's local Paid status doesn't auto-revert on refund. v1.2.1 candidate.
- **Partial / split / deposit payments** — Stripe Payment Links pay full amount in one shot. Deposit invoicing is a separate feature in the post-v1 portfolio.
- **Multi-account per user** — One Stripe account per Cadence install. Multiple businesses on one iCloud account: defer.
- **Stripe iOS SDK** — Not added. Saves ~5MB binary; everything goes through the Worker.
- **App Attest device attestation** — HMAC + Stripe rate limits are sufficient for v1.2. App Attest is a v1.2.1 hardening item.
- **Payouts UI inside Cadence** — "Manage on Stripe" deep link to Express Dashboard handles this.
- **Stripe Tax integration** — Cadence's existing `BusinessProfile.taxRate` snapshot is the source of truth for tax line items.
- **Auto-deactivate Payment Link on first successful payment** — leaves the double-pay edge case open (§7.4). v1.2.1 candidate.
- **Non-Stripe gateways** (Moyasar, Tap, HyperPay, PayTabs, Razorpay, PayPal) — locked out for v1.2.

### Forward references to v1.3+
- Expenses + receipt photo (v1.3) — unrelated to payments
- Quarterly tax estimate (v1.4) — will read `Invoice.status == .paid` and `stripeChargeID` for sourcing data
- Multi-gateway abstraction (v1.3 if needed) — `WorkerClient` and `PaymentLinkService` are the natural place to add a strategy/adapter layer

---

## 3. Architecture

Five components total; only **two** are new code (the Worker + the iOS Stripe integration). The rest is existing or third-party.

```
┌─────────────────────────────────────────────────────────────────────┐
│  Cadence iOS app                                                    │
│  ┌────────────────────┐  ┌───────────────────┐  ┌───────────────┐  │
│  │ StripeConnect      │  │ PaymentLinksView  │  │ Existing      │  │
│  │ Service            │  │ (Settings)        │  │ InvoiceDetail │  │
│  │ - connectAccount   │  │ - onboarding btn  │  │ - "Pay now"   │  │
│  │ - refreshStatus    │  │ - status pill     │  │   share link  │  │
│  │ - registerDevice   │  │ - manage button   │  │ - Paid badge  │  │
│  └─────────┬──────────┘  └─────────┬─────────┘  └───────┬───────┘  │
│            │                       │                    │           │
│  ┌─────────▼───────────────────────▼────────────────────▼────────┐  │
│  │ ConnectedStripeAccount @Model (mirrored)                      │  │
│  │   acct_id, payouts_enabled, charges_enabled, country, ...     │  │
│  │ Invoice.paymentLinkURL: URL? (new, mirrored)                  │  │
│  │ Invoice.stripePaymentLinkID: String? (new, mirrored)          │  │
│  │ Invoice.stripeChargeID: String? (new, mirrored)               │  │
│  └───────────────────────────────────────────────────────────────┘  │
└───────────────┬──────────────────────────────────────┬──────────────┘
                │                                      │
                │ URLSession → Worker (HMAC-signed)    │ APNs (silent push,
                │                                      │  background fetch)
                ▼                                      ▼
┌──────────────────────────┐         ┌──────────────────────────────────┐
│ Cadence Webhook Worker   │         │ Apple Push Notification Service   │
│ (Cloudflare, ~500 LOC)   │         │                                   │
│ ┌──────────────────────┐ │         │                                   │
│ │ 6 endpoints           │ │         │                                  │
│ │ (called by iOS app):  │ │         │                                  │
│ │ /connect/create-     │ │         │                                   │
│ │   account-link       │ │         │                                   │
│ │ /connect/create-     │ │         │                                   │
│ │   login-link         │ │         │                                   │
│ │ /connect/account-    │ │         │                                   │
│ │   status             │ │         │                                   │
│ │ /payment-links/create│ │         │                                   │
│ │ /payment-links/      │ │         │                                   │
│ │   status-check       │ │         │                                   │
│ │ /devices/register    │ │         │                                   │
│ │                      │ │         │                                   │
│ │ + /stripe/webhook    │ │         │                                   │
│ └──────────────────────┘ │         │                                   │
│ ┌──────────────────────┐ │         │                                   │
│ │ Cloudflare KV:       │ │         │                                   │
│ │  device_tokens       │ │         │                                   │
│ │  key=acct_id         │ │         │                                   │
│ │  val={apns_token,    │ │         │                                   │
│ │       env}           │ │         │                                   │
│ └──────────────────────┘ │         │                                   │
└──────────────┬───────────┘         └──────────────────────────────────┘
               │                                      ▲
               │ Stripe API (Connect Express,         │ APNs HTTP/2 (push w/ JWT auth)
               │ Payment Links, webhooks)             │
               ▼                                      │
┌──────────────────────────────────────────────────────────────────────┐
│ Stripe API (3rd party)                                               │
└──────────────────────────────────────────────────────────────────────┘
```

### Trust boundary

The Worker holds **only** the `acct_id ↔ device_token` mapping (in KV) and short-lived secret keys (Stripe secret, APNs key, HMAC secret) as env vars. It stores **no invoice data, no customer data, no amounts, no PII**. Cadence's v1 "no server we operate stores user data" property is preserved — the Worker is a pure dispatcher.

If the Worker is ever compromised, the attacker gets only the ability to spam silent pushes to user devices (which the app validates safely against Stripe's API) and the ability to see which Cadence users have connected Stripe. No payment, invoice, or client data is exposed.

### Module responsibilities

**`StripeConnectService`** (BillableCore, `@MainActor @Observable` singleton, ~250 LOC) — owns the `ConnectedStripeAccount` @Model, kicks off onboarding via Worker call → opens Stripe-hosted form in SFSafariViewController, handles return callback, registers APNs token with Worker, reconciles invoice state on silent push, refreshes account status on scenePhase changes.

**`PaymentLinkService`** (BillableCore, static helpers, ~100 LOC) — called from `Invoice.didMarkSentHook` after Sent transition. Creates a Stripe Payment Link via Worker, persists `paymentLinkURL` + `stripePaymentLinkID` on the Invoice. Also handles deactivation on Invoice deletion.

**`WorkerClient`** (BillableCore, URLSession wrapper, ~150 LOC) — HMAC-signs every request, holds the deployed Worker URL (test vs prod baked at compile time), provides Codable models for the 6 endpoints. Single point of network failure handling and retry policy.

**`Cadence Webhook Worker`** (separate repo `cadence-webhook-worker`, ~500 LOC) — Hono router + 6 endpoints + Stripe webhook handler + APNs JWT signer. Two `wrangler.toml` envs (`test`, `prod`) with independent secret sets.

### App-target footprint

- One new `AppDelegate` method (`didReceiveRemoteNotification:fetchCompletionHandler:`) for silent push handling
- One new SwiftUI view (`PaymentLinksView`)
- Three modifications to existing files (`SettingsView`, `InvoiceDetailView`, `PaymentRemindersView`)
- New `cadence://stripe-connect/return` URL scheme handler via SwiftUI's `.onOpenURL`
- New `UIBackgroundModes: remote-notification` entitlement in Info.plist (via `project.yml`)

No other app-target changes.

---

## 4. Data model

One new mirrored `@Model`, three new optional fields on `Invoice`. No changes to `Client`, `Project`, `TimeEntry`, `BusinessProfile`, `RecurrenceTemplate`, `ReminderConfig`, `InvoiceReminderSchedule`, or `ScheduledNotification`.

### New `@Model`: `ConnectedStripeAccount`

```swift
import Foundation
import SwiftData

/// Mirrored singleton @Model. Represents the user's connected Stripe Express
/// account. Exactly one per user (Cadence v1.2 supports a single Stripe
/// account; multi-account / per-business-profile is deferred to v1.3+).
///
/// Lives in `mirroredTypes` so the account state propagates to all of the
/// user's iCloud-linked devices.
@Model
public final class ConnectedStripeAccount {
    /// Stripe's account ID, e.g. "acct_1ABC...". Source of truth for identifying
    /// this account at Stripe's API.
    @Attribute(.unique) public var acctID: String

    /// `true` once Stripe has verified the connected account can accept charges.
    /// Set to `false` if Stripe requires additional info post-onboarding
    /// (e.g., tax form review, identity re-verification).
    public var chargesEnabled: Bool

    /// `true` once the connected account can receive payouts to its bank.
    /// Independent of `chargesEnabled` — Stripe sometimes flips one before
    /// the other.
    public var payoutsEnabled: Bool

    /// `true` once the user has completed the Stripe-hosted onboarding form.
    /// Used to distinguish "never started" from "started but Stripe wants more."
    public var detailsSubmitted: Bool

    /// `true` if the Stripe `requirements.currently_due` array is non-empty.
    /// Drives the "Continue onboarding" CTA on PaymentLinksView. We don't
    /// store the requirement details — the user resolves them in Stripe's
    /// hosted form, not in Cadence.
    public var hasPendingRequirements: Bool

    /// ISO 3166-1 alpha-2 country code, e.g. "US", "GB", "CA". Determines
    /// which currencies are available + which Stripe features are accessible.
    /// Set once at onboarding, doesn't change.
    public var country: String

    /// Stripe's default currency for this account, e.g. "usd", "gbp". Three-letter
    /// lowercase per Stripe convention.
    public var defaultCurrency: String

    /// When the user first completed onboarding.
    public var connectedAt: Date

    /// When `StripeConnectService.refreshAccountStatus()` last ran successfully.
    public var lastRefreshedAt: Date

    public init(
        acctID: String,
        chargesEnabled: Bool = false,
        payoutsEnabled: Bool = false,
        detailsSubmitted: Bool = false,
        hasPendingRequirements: Bool = false,
        country: String,
        defaultCurrency: String,
        connectedAt: Date = .now,
        lastRefreshedAt: Date = .now
    ) {
        self.acctID = acctID
        self.chargesEnabled = chargesEnabled
        self.payoutsEnabled = payoutsEnabled
        self.detailsSubmitted = detailsSubmitted
        self.hasPendingRequirements = hasPendingRequirements
        self.country = country
        self.defaultCurrency = defaultCurrency
        self.connectedAt = connectedAt
        self.lastRefreshedAt = lastRefreshedAt
    }

    /// Convenience: ready to accept payments end-to-end (charges + payouts both enabled).
    public var isReadyForPayments: Bool {
        chargesEnabled && payoutsEnabled && !hasPendingRequirements
    }
}
```

Add `ConnectedStripeAccount.self` to `mirroredTypes` in `BillableModelContainer`. One-line edit — same pattern as v1.1's Phase 2 model additions.

### New optional fields on `Invoice`

```swift
// — added to existing @Model Invoice —

/// Stripe Payment Link URL for this invoice, e.g. "https://buy.stripe.com/...".
/// Created when the invoice transitions Draft → Sent (if the user has a
/// connected Stripe account). Embedded as the "Pay now" CTA in the rendered
/// PDF and available as the `{paymentLink}` merge field in reminder email
/// templates.
///
/// Nullable: invoices created before v1.2, invoices for users without a
/// connected Stripe account, and invoices where Payment Link creation
/// failed all have `paymentLinkURL = nil`.
public var paymentLinkURL: URL?

/// Stripe Payment Link ID, e.g. "plink_1ABC...". Used to deactivate the
/// link when the invoice is deleted or manually marked Paid.
public var stripePaymentLinkID: String?

/// Stripe Charge ID, e.g. "ch_3ABC...", set by the silent push handler path
/// when `payment_intent.succeeded` fires. The presence of a non-nil value is
/// Cadence's proof that the invoice was paid via Stripe. Manual mark-as-paid
/// (user got cash and updates Cadence) leaves this nil.
public var stripeChargeID: String?
```

Add to `Invoice.init` with default `nil` values. Migration-safe: existing v1.1 rows get all three as `nil`.

### CloudKit mirroring

| Model | Mirrored to iCloud? | Reason |
|---|---|---|
| `ConnectedStripeAccount` | ✅ | Account state must be consistent across user's devices |
| `Invoice.paymentLinkURL` | ✅ | Already-mirrored model |
| `Invoice.stripePaymentLinkID` | ✅ | Already-mirrored model |
| `Invoice.stripeChargeID` | ✅ | Already-mirrored model |

### What's NOT being added

- `Invoice.refundedAt: Date?` / `refundAmount: Decimal?` — refunds out of scope
- `PaymentEvent` audit log @Model — Stripe Dashboard is the audit log
- Partial-payment fields — single-shot Payment Links only
- Multi-account fields — one `ConnectedStripeAccount` per user

### Schema migration impact

Same pattern as v1.1's `RecurrenceTemplate` and `ReminderConfig` additions:
- Adding `ConnectedStripeAccount.self` to `mirroredTypes` is a one-line edit; the table is created on next launch.
- Adding optional fields to `Invoice` is migration-safe by SwiftData convention; existing rows get `nil`.
- CloudKit Mirror picks up the new schema; no destructive migration; no risk to v1.1-era data.
- The manual "CloudKit reinstall smoke test" procedure documented in `TESTING.md` (v1.1.1 R2) applies to v1.2's schema changes too.

---

## 5. Stripe Connect Express onboarding flow

The Connect Express onboarding never lives inside Cadence — Stripe owns the hosted form (KYC, identity verification, bank account collection) so we don't take on legal/compliance scope. The iOS app kicks off and finishes the flow; everything in between is Stripe's responsibility.

### First-time onboarding (happy path)

1. User opens Settings → Payment links → taps "Connect with Stripe"
2. App calls `POST /connect/create-account-link` on Worker (no acct_id yet)
3. Worker calls Stripe `POST /v1/accounts` (type=express) → gets `acct_1ABC...`
4. Worker calls Stripe `POST /v1/account_links` (return_url=`cadence://stripe-connect/return`) → gets hosted onboarding URL
5. Worker responds to iOS with `{ url, acct_id }`
6. App persists `acct_id` provisionally + opens `url` in `SFSafariViewController`
7. User completes Stripe-hosted KYC form (~3-5 minutes: legal name, address, DOB, SSN-or-equivalent, bank account)
8. Stripe redirects to `cadence://stripe-connect/return?account=acct_1ABC...`
9. SwiftUI's `.onOpenURL` fires; `StripeConnectService.handleReturnCallback(url:)` runs
10. App calls Worker `POST /connect/account-status` → Worker calls Stripe `GET /v1/accounts/acct_xxx` → returns sanitized state (charges_enabled, payouts_enabled, etc.)
11. App persists `ConnectedStripeAccount` @Model with the returned state
12. App requests APNs permission (just-in-time, same pattern as v1.1's notification permission for recurring/reminders), gets device token
13. App calls Worker `POST /devices/register` with `{ acct_id, apns_token, env }`
14. PaymentLinksView UI flips to "Connected" state

Roughly 6 round-trips, all happening on a single screen with progress UI.

### Resume-incomplete onboarding

If `charges_enabled: false` on first check (user bailed mid-form or Stripe needs more info), `PaymentLinksView` shows "Continue onboarding." Tap re-runs `POST /connect/create-account-link` with the existing `acct_id` and reopens Stripe's hosted form. Stripe Account Links resume cleanly by design.

### Manage on Stripe (post-onboarding)

`PaymentLinksView` shows "Manage on Stripe" when connected. Tap calls Worker `POST /connect/create-login-link` → Worker calls Stripe `POST /v1/accounts/acct_xxx/login_links` → returns one-shot Express Dashboard URL → iOS opens in SFSafariViewController. User sees payouts, edits bank account, updates tax forms, sees disputes. Cadence never builds any of this UI.

### Custom URL scheme

`cadence://stripe-connect/return` — registered in `Info.plist` via `CFBundleURLTypes` (set in `project.yml`):

```yaml
CFBundleURLTypes:
  - CFBundleURLName: com.eldenstudios.billable.stripe
    CFBundleURLSchemes:
      - cadence
```

The `BillableApp.WindowGroup`'s `.onOpenURL { url in ... }` modifier dispatches to `StripeConnectService.handleReturnCallback(url:)`.

### Test mode vs. live mode

Two Worker deployments via `wrangler.toml` envs:
- `cadence-webhook-test.<your-cf-subdomain>.workers.dev` — `sk_test_*` Stripe keys
- `cadence-webhook.cadence.app` — `sk_live_*` Stripe keys

The iOS app's build config picks the Worker URL at compile time. Debug builds → test Worker → Stripe test mode. App Store builds → live Worker → Stripe live mode.

**App Store Review:** v1.2 first release goes through live Worker but reviewers can verify the UI for the "not connected" state and the "Connect with Stripe" button without completing onboarding. If a reviewer demands a working flow, ship a separate TestFlight build pointed at the test Worker with a sandbox Stripe account.

---

## 6. The Cloudflare Worker

### Repo layout

Lives in its own GitHub repo (`cadence-webhook-worker`), not as a subdirectory of the iOS repo. Different deployment pipelines (wrangler vs xcodebuild), different secret stores, different commit cadences.

### Tech stack

| Layer | Choice |
|---|---|
| Framework | **Hono** (TypeScript, ~20kB, edge-runtime-first) |
| Stripe SDK | `stripe@latest` with `Stripe.createFetchHttpClient()` for Workers compatibility |
| KV | One namespace: `device_tokens` |
| APNs | Raw HTTP/2 + ES256-signed JWT via Web Crypto (~80 LOC, no npm SDK) |
| Deploy | `wrangler` CLI, two envs from same `wrangler.toml` |
| Tests | vitest with mocked Stripe / KV / fetch |

### Endpoint specifications

#### 1. `POST /connect/create-account-link`
**Body:** `{ "acct_id"?: string }` (omit to create new account)
**Logic:** Verify HMAC. If acct_id absent → `stripe.accounts.create({ type: 'express' })`. Then `stripe.accountLinks.create({ account, return_url, type: 'account_onboarding' })`.
**Response:** `{ url, acct_id }`

#### 2. `POST /connect/create-login-link`
**Body:** `{ "acct_id": string }`
**Logic:** Verify HMAC. `stripe.accounts.createLoginLink(acct_id)`.
**Response:** `{ url }` (one-shot Express Dashboard URL, ~30s validity)

#### 3. `POST /connect/account-status`
**Body:** `{ "acct_id": string }`
**Logic:** Verify HMAC. `stripe.accounts.retrieve(acct_id)`.
**Response:** Sanitized subset: `{ charges_enabled, payouts_enabled, details_submitted, has_pending_requirements, country, default_currency }`

#### 4. `POST /payment-links/create`
**Body:** `{ "acct_id": string, "amount_minor": number, "currency": string, "description": string, "metadata": object }`
**Logic:** Verify HMAC. `stripe.paymentLinks.create({ line_items: [...] }, { stripeAccount: acct_id })`.
**Response:** `{ url, id }`

#### 5. `POST /payment-links/status-check`
**Body:** `{ "acct_id": string, "payment_link_ids": string[] }`
**Logic:** Verify HMAC. For each plink_id in parallel via `Promise.all`: `stripe.checkout.sessions.list({ payment_link: id, limit: 1 })`.
**Response:**
```json
{
  "results": [
    { "plink_id": "plink_1A", "paid": true, "charge_id": "ch_3ZZ",
      "amount_received": 120000, "currency": "usd" },
    { "plink_id": "plink_1B", "paid": false }
  ]
}
```

#### 6. `POST /devices/register`
**Body:** `{ "acct_id": string, "apns_token": string | null, "env": "production" | "development" }`
**Logic:** Verify HMAC. If `apns_token == null` → `KV.delete(acct_id)`. Else → `KV.put(acct_id, JSON.stringify({ apns_token, env, updated_at }))`.
**Response:** `{ ok: true }`

#### 7. `POST /stripe/webhook`
**Body:** Raw event from Stripe.
**Logic:** Verify `Stripe-Signature` header via `stripe.webhooks.constructEvent`. Switch on `event.type`:
- `payment_intent.succeeded` → extract `event.account` → `KV.get(acct_id)` → if present, send silent APNs push with `{ kind: "stripe_payment_succeeded", payment_link_id, charge_id, amount_received, currency }`
- `account.updated` → `KV.get(acct_id)` → send silent APNs push with `{ kind: "stripe_account_updated" }`
- Other event types → 200 OK, log + ignore

**Response:** `200 OK` after successful signature verification (Stripe retries on non-200).

### KV schema

Single namespace `device_tokens`:
```
key:   stripe_acct_id ("acct_1ABC...")
value: { apns_token: string, env: "production" | "development", updated_at: number }
```

Cloudflare KV free tier (100k reads/day, 1k writes/day, 1 GB) is effectively unlimited for v1.2 scale.

### Secrets (via `wrangler secret put`)

| Secret | Purpose |
|---|---|
| `STRIPE_SECRET_KEY` | `sk_test_*` for test env, `sk_live_*` for prod |
| `STRIPE_WEBHOOK_SECRET` | `whsec_*` — verifies webhook signatures |
| `APNS_AUTH_KEY` | `.p8` private key contents (Apple-issued ES256 key) |
| `APNS_KEY_ID` | 10-char Apple-issued Key ID |
| `APNS_TEAM_ID` | 10-char Apple Developer Team ID |
| `APP_BUNDLE_ID` | `com.eldenstudios.billable` — APNs topic |
| `APP_HMAC_SECRET` | Shared with the iOS build — JWT signing |

### APNs HTTP/2 + ES256-signed JWT

The Worker signs an ES256 JWT once per ~50 minutes (cached; APNs allows up to 60). Web Crypto handles the signing natively:

```typescript
// Pseudocode — actual implementation ~80 lines
async function sendSilentPush(token: string, env: "production" | "development", payload: object) {
  const jwt = await getCachedAPNsJWT();
  const host = env === "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com";

  await fetch(`https://${host}/3/device/${token}`, {
    method: "POST",
    headers: {
      "authorization": `bearer ${jwt}`,
      "apns-topic": APP_BUNDLE_ID,
      "apns-push-type": "background",
      "apns-priority": "5",
      "content-type": "application/json"
    },
    body: JSON.stringify({
      aps: { "content-available": 1 },
      ...payload
    })
  });
}
```

`content-available: 1` + `apns-push-type: background` means **no user-visible banner**. The app wakes in the background, fetches state, updates Cadence's local store + badge count.

### HMAC auth on non-webhook endpoints

iOS requests carry:
- `Authorization: Bearer <hmac>` header
- Body includes `ts: number` (ms epoch)
- HMAC: `hex(HMAC-SHA256(APP_HMAC_SECRET, "<method>:<path>:<ts>:<body>"))`

Worker rejects if:
- `|server_now - ts| > 60000` (60s replay window)
- HMAC mismatch

The HMAC secret is compiled into the iOS app binary and rotates per build. If extracted, attacker can hit the 6 endpoints but every endpoint already has tight Stripe-side rate limits (account creation, payment link creation) and KV operations are non-PII.

### Local development

`wrangler dev` runs the Worker locally with KV. Stripe CLI (`stripe listen --forward-to localhost:8787/stripe/webhook`) proxies real test events into the local Worker. No ngrok needed. APNs testing uses sandbox endpoint with development tokens.

### Effort estimate (Worker alone)

| Task | Days |
|---|---|
| Hono boilerplate + routing + HMAC middleware | 0.5 |
| Stripe SDK adaptation + 3 `/connect/*` endpoints | 1 |
| `/payment-links/*` + `/devices/register` | 0.5 |
| Webhook handler + signature verification | 0.5 |
| APNs JWT + HTTP/2 push (Web Crypto ES256) | 1 |
| `wrangler.toml` dual-env setup + secrets ceremony | 0.25 |
| vitest suites (~20 tests) | 1 |
| **Total** | **~4 working days** |

---

## 7. iOS-side flow

### New services in `BillableCore`

Two new services that mirror v1's `SubscriptionManager` / `ReminderService` patterns:

**`StripeConnectService`** (`@MainActor @Observable` singleton)
- `start(modelContext:)` — called once at app launch
- `beginOnboarding() async throws -> URL` — kicks off Connect Express; returns the Account Link URL
- `openManagementDashboard() async throws -> URL` — Login Link URL for Express Dashboard
- `handleReturnCallback(url: URL) async` — `onOpenURL` hook
- `refreshAccountStatus() async` — fetches latest from Stripe via Worker
- `reconcileInvoicePaid(paymentLinkID:, chargeID:, amountMinor:, currency:) async` — called by silent push handler
- `reconcilePendingInvoices() async` — batched status check on scenePhase.active
- `disconnect() async` — clears local model + de-registers device

**`PaymentLinkService`** (static helpers)
- `createForInvoice(_ invoice: Invoice, in context: ModelContext) async` — called from `Invoice.didMarkSentHook`
- `deactivateForInvoice(_ invoice: Invoice) async` — called from Invoice delete path

**`WorkerClient`** — HMAC-signing URLSession wrapper with Codable request/response models for all 6 Worker endpoints the iOS app calls (the 7th, `/stripe/webhook`, is called by Stripe and uses its own signature scheme, not HMAC).

### Silent push handling

`AppDelegate` (introduced in v1.1 Phase 3) gains one new method:

```swift
func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
) {
    Task { @MainActor in
        defer { completionHandler(.newData) }
        guard let kind = userInfo["kind"] as? String else { return }
        switch kind {
        case "stripe_payment_succeeded":
            guard let plinkID = userInfo["payment_link_id"] as? String,
                  let chargeID = userInfo["charge_id"] as? String,
                  let amount = userInfo["amount_received"] as? Int,
                  let currency = userInfo["currency"] as? String else { return }
            await StripeConnectService.shared.reconcileInvoicePaid(
                paymentLinkID: plinkID, chargeID: chargeID,
                amountMinor: amount, currency: currency
            )
        case "stripe_account_updated":
            await StripeConnectService.shared.refreshAccountStatus()
        default:
            break  // unknown kind; ignore safely
        }
    }
}
```

`UIBackgroundModes: remote-notification` must be in `Info.plist` (via `project.yml`).

### The `reconcileInvoicePaid` flow

```
StripeConnectService.reconcileInvoicePaid(paymentLinkID, chargeID, amountMinor, currency)
  │
  ├── Fetch Invoice from SwiftData WHERE stripePaymentLinkID == paymentLinkID
  │
  ├── Defensive checks:
  │   • Invoice exists (else: log + drop)
  │   • Invoice.status == .sent (else: see §7.3 manual-paid-race handling)
  │   • amountMinor / 100 ≈ Invoice.total (±1 cent; if mismatch, log warning + still mark Paid)
  │   • currency matches Invoice.currencyCodeSnapshot (else: log warning)
  │
  ├── Mutate:
  │   • Invoice.stripeChargeID = chargeID
  │   • Invoice.markPaid(at: .now)  ← existing v1 state-machine transition
  │   • modelContext.save()
  │
  └── SwiftUI views observing the @Query auto-refresh.
```

**The Worker never writes to Cadence's local store directly.** The app is always the authority for SwiftData writes, even when triggered by a backend event.

### Fallback polling — scenePhase.active

`RootView.task(id: scenePhase)` (from v1.1 Phase 6) gains a Stripe reconcile pass:

```swift
.task(id: scenePhase) {
    if scenePhase == .active {
        // ... existing v1.1 logic ...
        if StripeConnectService.shared.connectedAccount != nil {
            await StripeConnectService.shared.refreshAccountStatus()
            await StripeConnectService.shared.reconcilePendingInvoices()
        }
    }
}
```

`reconcilePendingInvoices` does a single batched Worker call to `/payment-links/status-check` with the IDs of all locally-Sent invoices that have a `paymentLinkURL`. Idempotent via the same `Invoice.status == .sent` guard.

### Failure handling

| Failure | Behavior | User-visible |
|---|---|---|
| Worker unreachable | Stripe-touching operations fail silently | Sent button works (creates invoice locally); PDF lacks "Pay now" CTA |
| Stripe API 429 | Worker returns 429; iOS retries with exponential backoff (3 attempts) | Tiny progress spinner |
| APNs push delivery fails | Next scenePhase.active polling catches up | Up to a few seconds of delay |
| Onboarding incomplete | `detailsSubmitted = false` or `hasPendingRequirements = true` | "Continue onboarding" pill |
| Offline silent push fails to land | Same as APNs delivery fail | Polling catches up |
| Webhook signature verification fails | Worker returns 400; KV untouched | None |

### Effort estimate (iOS side)

| Task | Days |
|---|---|
| `WorkerClient` (HMAC + Codable models) | 0.5 |
| `StripeConnectService` + `ConnectedStripeAccount` @Model | 1.5 |
| `PaymentLinkService` + `Invoice.markSent` hook | 0.5 |
| `PaymentLinksView` (Settings screen) | 1 |
| SFSafariViewController wrapper + `onOpenURL` handler | 0.5 |
| Silent push handler in AppDelegate | 0.5 |
| `reconcilePendingInvoices` + `RootView` wiring | 0.5 |
| Pay link UI on `InvoiceDetailView` + PDF embedding | 1 |
| `{paymentLink}` merge field + hint chip | 0.25 |
| Swift Testing suites (~15 tests) | 1 |
| Bug-fix slack | 1 |
| **Total** | **~8 working days** |

---

## 8. UI changes

Five surfaces touched. None requires new screens beyond `PaymentLinksView` (which mirrors `PaymentRemindersView`'s pattern from v1.1).

### `PaymentLinksView` — Settings → Payment links

Five visual states:

| State | When | UI |
|---|---|---|
| **Not connected** | No `ConnectedStripeAccount` row | Hero card explaining the feature; big "Connect with Stripe" button; disclaimer "Stripe handles payments. Cadence never sees your bank info." |
| **Onboarding incomplete** | `detailsSubmitted == false` | Yellow status pill "Continue onboarding"; big "Continue with Stripe" button |
| **Pending requirements** | `detailsSubmitted == true && hasPendingRequirements == true` | Yellow banner: "Stripe needs more info to keep your payments active"; "Update on Stripe" button |
| **Connected & ready** ✅ | `isReadyForPayments == true` | Green status pill; masked acct_id (`acct_1...XYZ`) + country; "Manage on Stripe" + "Disconnect" buttons |
| **Disabled** | `detailsSubmitted == true && chargesEnabled == false` | Red banner "Stripe disabled this account"; "Open Stripe" + "Disconnect" buttons |

### `SettingsView` — one new row

```
Subscription
  • Cadence Pro · Active                          [Manage subscription]
  • Restore purchases

Reminders
  • Payment reminders                                                ›

[NEW] Payments
  • Payment links · Connected ✓                                      ›
  // OR · Connect Stripe to get paid faster
  // OR · Continue onboarding

About
  • Version 0.2.0 (1)
```

### `InvoiceDetailView` — Pay link row when `paymentLinkURL != nil`

Below the existing status banner, above the PDF preview:

```
┌─────────────────────────────────────────────────────┐
│  Pay link                                           │
│  https://buy.stripe.com/abc123xyz... [Copy] [Share] │
└─────────────────────────────────────────────────────┘
```

- **Copy** → UIPasteboard + brief "Copied" toast
- **Share** → iOS share sheet with `[paymentLinkURL]`

Row hides when `paymentLinkURL == nil` (backward-compatible).

### PDF rendering — clickable "Pay now" CTA at the bottom

`InvoiceTemplate.swift` gains a conditional block between Notes and the "Thank you" footer:

```
┌───────────────────────────────────────────────────────┐
│              ┌─────────────────────────┐              │
│              │       Pay this now      │              │
│              │   ⚡ Secure via Stripe   │              │
│              └─────────────────────────┘              │
│         buy.stripe.com/abc123xyz                      │
└───────────────────────────────────────────────────────┘
```

`InvoicePDFRenderer.swift` adds a post-render pass that overlays a `PDFAnnotation(.link)` rectangle at the CTA's position, with `annotation.url = paymentLinkURL`. The annotation makes the rectangle clickable in any PDF viewer.

When `paymentLinkURL == nil`, the block is omitted; the PDF looks exactly like v1.

### `{paymentLink}` merge field in reminder templates

`ReminderTemplateRenderer.render(...)` gains one substitution:
```swift
.replacingOccurrences(of: "{paymentLink}", with: invoice.paymentLinkURL?.absoluteString ?? "")
```

`PaymentRemindersView`'s body template hint chips gains an 8th chip: `{paymentLink}`.

Default body template stays unchanged. Users opt in by adding `{paymentLink}` to their template manually. The live preview (v1.1.1 F5) automatically picks up the new merge field.

### Not changing in v1.2

- **Today screen, Reports, Clients tab, Invoices list rows** — no Stripe-specific indicators
- **Onboarding flow (first-launch wizard)** — Stripe connect deliberately NOT added; user completes BusinessProfile + Client + Project first, decides later about Stripe from Settings

### Accessibility + localization

- Pay link row uses `accessibilityLabel("Stripe payment link, tap to copy or share")` so VoiceOver reads it as a unit
- PDF Pay-now CTA's clickable rectangle has `PDFAnnotation.contents = "Pay this invoice via Stripe"` for screen readers parsing the PDF
- Status pills use both color AND text label
- All new strings extracted to `Localizable.strings`; merge field tokens (`{paymentLink}`) stay literal across locales

---

## 9. Edge cases

### 9.1 Idempotency — the architectural invariant

Every "mark invoice paid" path checks `Invoice.status == .sent` BEFORE mutating. If already `.paid`, no-op. Three paths trigger:

1. Silent APNs push handler (`reconcileInvoicePaid`)
2. Fallback polling (`reconcilePendingInvoices` on scenePhase.active)
3. User manually taps "Mark as paid" in InvoiceDetailView (existing v1 path)

Wrap `try? invoice.markPaid(...)` and log on the `paid → paid` no-op path.

### 9.2 Currency mismatch — Stripe is authority

If `invoice.currencyCodeSnapshot.lowercased() != connectedAccount.defaultCurrency`, `PaymentLinkService.createForInvoice` either:
- Attempts creation if Stripe likely accepts (US accounts support multi-currency)
- For impossible mismatches (e.g., Saudi account billing in CAD), surfaces an inline error on the InvoiceGenerator Preview: *"This invoice's currency (EUR) isn't supported by your Stripe account (USD only). Either change the currency, or skip the pay link for this invoice."*

The user can finalize-and-send anyway with `paymentLinkURL = nil`. PDF renders without "Pay now" CTA; `{paymentLink}` merge field resolves to empty. No data loss.

### 9.3 Manual mark-as-paid races a Stripe payment

If user marks Paid at 10:00am while Stripe payment fired at 9:59:50am, the webhook → silent push → `reconcileInvoicePaid` finds `Invoice.status == .paid` and:
- Logs "Invoice already marked paid manually; backfilling stripeChargeID"
- Sets `Invoice.stripeChargeID = chargeID`, saves (no `markPaid` call, no `paidAt` change)

User's manual action is preserved as the moment-of-payment authority; Cadence still records that Stripe confirmed.

### 9.4 Payment Link clicked twice (double charge)

First `payment_intent.succeeded` → marks Paid, sets `stripeChargeID = ch_3AAA`. Second `payment_intent.succeeded` → finds `Invoice.status == .paid` → logs "double charge detected: existing=ch_3AAA, incoming=ch_3BBB" → no mutation.

Double charge is visible in Stripe Dashboard; v1.2 does NOT auto-refund. v1.2.1 candidate: auto-deactivate Payment Link via `stripe.paymentLinks.update(id, { active: false })` on first successful payment.

### 9.5 Invoice deleted while pay link is live

`PaymentLinkService.deactivateForInvoice(invoice)` runs in the deletion path: Worker call `/payment-links/deactivate` → `stripe.paymentLinks.update(id, { active: false })`.

If deactivation fails (network drop), we log and proceed with the delete. The link stays active in Stripe but pointing at a deleted invoice. If a client pays it, the webhook fires, the silent push arrives, `reconcileInvoicePaid` finds no matching Invoice locally → logs "received payment for unknown payment_link_id; doing nothing" → user sees the payment in Stripe Dashboard but not in Cadence.

### 9.6 App reinstall

`ConnectedStripeAccount` survives via CloudKit Mirror. APNs device token does NOT survive. On first foreground after reinstall:
1. `StripeConnectService.start()` notices `connectedAccount != nil`
2. Requests notification permission if needed
3. Gets fresh APNs device token
4. Calls `POST /devices/register` with new token + acct_id
5. Worker KV.put overwrites the stale entry

Until step 4-5 completes, silent pushes go to a stale token and fail at APNs. Fallback polling on `scenePhase.active` catches any payments missed in this gap.

### 9.7 User switches iCloud accounts

Edge case. v1.2 documented behavior: "If you switch iCloud accounts, disconnect Stripe in Settings → Payment links first, on the previous account." If users hit this in practice, v1.2.1 adds a KV TTL (e.g., 30 days of no device check-in expires the entry).

### 9.8 Refunds and disputes — explicitly out of scope

Worker only switches on `payment_intent.succeeded` and `account.updated`. `charge.refunded` is logged + ignored. Cadence's local Invoice stays `.paid` after a Stripe refund; user sees the refund in Stripe Dashboard. v1.2 has no UI for marking an invoice refunded.

### 9.9 Security architecture summary

| Asset | Where it lives | Protection |
|---|---|---|
| Stripe **secret key** (`sk_live_*`) | CF Worker env var only | Set via `wrangler secret`; never in app or repo |
| Stripe **webhook secret** | CF Worker env var only | Verifies `Stripe-Signature` on every webhook |
| APNs **auth key** (`.p8`) | CF Worker env var only | Used to sign ES256 JWTs |
| **HMAC secret** for Worker auth | iOS app binary AND CF Worker env var | Rotated per build |
| **Stripe Account ID** (`acct_*`) | iOS SwiftData + CF KV | Not sensitive on its own |
| Invoice / Client / Payment **data** | iOS SwiftData + iCloud Private Database | Never on Worker; never on any server we operate |

HMAC replay window: 60s. Webhook signature verification via official `stripe.webhooks.constructEvent`. No TLS pinning in v1.2.

---

## 10. Testing strategy

### Worker tests (vitest)

| Suite | Coverage |
|---|---|
| HMAC auth | Valid → 200. Invalid → 401. Drift > 60s → 401. Missing header → 401. |
| Stripe webhook signature | Valid → 200. Tampered body → 400. Wrong secret → 400. |
| `/connect/create-account-link` | New account path; resume path; Stripe API error → 502. |
| `/connect/create-login-link` | Returns login URL; nonexistent acct → 404. |
| `/connect/account-status` | Returns sanitized fields; pending requirements detected. |
| `/payment-links/create` | Happy path; currency mismatch returns Stripe's error; metadata propagates. |
| `/payment-links/status-check` | Batched lookup; partial results when some IDs are invalid. |
| `/devices/register` | KV write; null token deletes the entry; env value preserved. |
| Webhook `payment_intent.succeeded` | Looks up KV; sends APNs push; logs on KV miss. |
| Webhook `account.updated` | Same flow. |
| Webhook other event types | Returns 200; logs; does not push. |

**Target: ~20 Worker tests.** Mock Stripe SDK via `vi.mock`; mock KV via miniflare or in-memory shim; mock APNs by stubbing fetch.

### iOS tests (Swift Testing)

| Suite | Coverage |
|---|---|
| `WorkerClient` | HMAC signing matches Worker expectations; round-trip Codable models; retry on 502 |
| `StripeConnectService` | Onboarding state transitions; `handleReturnCallback` parses URL correctly; `reconcileInvoicePaid` idempotency; currency mismatch → no link, no crash |
| `PaymentLinkService` | `createForInvoice` writes back paymentLinkURL + ID; failure path leaves nil; deactivateForInvoice triggers Worker call |
| `ReminderTemplateRenderer` | `{paymentLink}` resolves correctly; nil → empty string |
| `InvoicePDFRenderer` | PDF contains clickable annotation when paymentLinkURL is set; omits when nil |
| `Invoice.markSent` hook | After Sent transition, paymentLinkURL is populated (via mocked PaymentLinkService) |

**Target: ~15 new tests.** BillableCore total goes from 121 → ~136.

### Manual end-to-end test (required before TestFlight)

Documented in `TESTING.md` under a new "Stripe Connect end-to-end" section:

1. Worker deployed to test env with `sk_test_*`
2. iOS debug build on physical device with development APNs token
3. "Connect with Stripe" → test data → confirm `ConnectedStripeAccount` row + flags
4. Send Invoice → confirm `paymentLinkURL` populated; PDF shows "Pay now" CTA
5. Open pay link in browser; pay with Stripe test card `4242 4242 4242 4242`
6. Background Cadence; trigger webhook via Stripe Dashboard or `stripe trigger payment_intent.succeeded`
7. Confirm silent push received (Console.app: `[StripeConnect] reconcileInvoicePaid: ...`)
8. Foreground Cadence; verify Invoice is Paid + stripeChargeID set
9. Repeat with manual mark-as-paid + Stripe pay racing in opposite orders (§9.3 idempotency)
10. Force-quit between push and foreground; confirm fallback polling catches up (§9.4)

### Observability

- **Worker:** structured JSON logs to Cloudflare Workers Logs. Key events: webhook received (event.type, event.account, event.id), KV miss, APNs success/failure, HMAC failure, Stripe API failure.
- **iOS:** new `OSLog` categories `"StripeConnect"`, `"PaymentLink"` under `com.eldenstudios.billable`. Key events: onboarding start/complete, silent push received (kind + payment_link_id), reconcileInvoicePaid result, status mismatch detected.
- **Diagnostics screen** (gated by `--debug-scheduler` from v1.1 Phase 6) gets a "Stripe" section: `acctID`, `chargesEnabled`, `lastRefreshedAt`, count of invoices with paymentLinkURL, last APNs push timestamp.

---

## 11. Acceptance criteria

A v1.2 build is shippable when:

### Functional
- [ ] User can complete Stripe-hosted Connect Express onboarding from Settings → Payment links and see "Connected" status within 2 seconds of returning from Stripe.
- [ ] "Manage on Stripe" opens Express Dashboard via SFSafariViewController.
- [ ] "Disconnect" removes the local `ConnectedStripeAccount`, clears the Worker KV entry, and removes pay links from subsequent invoices.
- [ ] Marking an Invoice Sent (when Stripe is connected) populates `paymentLinkURL` within 1 second; PDF renders with clickable "Pay now" CTA; `{paymentLink}` merge field resolves correctly.
- [ ] Client paying via Stripe link triggers silent push → background fetch → Paid status visible in Cadence within ≤30 seconds (with APNs delivery).
- [ ] If silent push fails, the next `scenePhase.active` polling catches up within ≤500ms.
- [ ] Manual "Mark as paid" races a Stripe payment cleanly: whichever fires first wins `paidAt`; the other fills `stripeChargeID`.
- [ ] Double payment on same link is detected, logged, no second `markPaid` mutation.
- [ ] Invoice deletion deactivates the Payment Link.
- [ ] Currency mismatch surfaces inline on Preview screen with a "skip pay link" option.
- [ ] InvoiceDetailView shows the Pay link row with Copy + Share when `paymentLinkURL != nil`.

### Permissions
- [ ] First-time Stripe connect prompts for notification permission JIT.
- [ ] Denial reverts the connect flow with a soft block + deep link to Settings.
- [ ] Permission revoked later → silent pushes fail silently → fallback polling continues → app shows permission banner on PaymentLinksView.

### Robustness
- [ ] Force-quit + relaunch: `StripeConnectService.start()` re-registers the APNs token.
- [ ] App reinstall: `ConnectedStripeAccount` round-trips through CloudKit; APNs token re-registers on first foreground.
- [ ] Worker downtime: all Stripe-touching operations fail gracefully; user can still send invoices without pay links.
- [ ] HMAC replay attack (timestamp drift > 60s) returns 401.
- [ ] Webhook with tampered body or wrong signature returns 400.
- [ ] App Store Review build shows correct UI for "not connected" state.

### Testing
- [ ] Worker has ≥20 vitest tests covering all 6 endpoints + webhook handler + HMAC + APNs (mocked).
- [ ] iOS has ≥15 new Swift Testing tests in `PaymentsTests.swift`. BillableCore total: 121 → ~136. All pass under default parallelism.
- [ ] Full end-to-end manual test in `TESTING.md` executed against the test Worker + Stripe test mode before TestFlight.

### Observability
- [ ] Worker logs structured events for every webhook, KV miss, APNs success/failure, HMAC failure.
- [ ] iOS logs via `OSLog` under `StripeConnect` / `PaymentLink` categories at key events.
- [ ] Diagnostics screen has Stripe section with acct_id, charges_enabled, lastRefreshedAt, count of pending pay links, last push received timestamp.

---

## 12. Effort estimate

Total: **~12 working days** (~2.5 weeks calendar).

| Day | Focus |
|---|---|
| 1 | Worker: Hono router + wrangler.toml dual-env + KV + Stripe SDK + HMAC middleware |
| 2 | Worker: 3 `/connect/*` endpoints + vitest scaffold |
| 3 | Worker: `/payment-links/*` + `/devices/register` + `/stripe/webhook` + APNs JWT/HTTP/2 |
| 4 | Worker: tests (20+). iOS: `WorkerClient` + `ConnectedStripeAccount` @Model + AppDelegate silent push skeleton |
| 5 | iOS: `StripeConnectService` (start, beginOnboarding, handleReturnCallback, disconnect) |
| 6 | iOS: `PaymentLinksView` (all 5 states) + Settings row + SFSafariViewController wrapper |
| 7 | iOS: `PaymentLinkService` + `Invoice.markSent` hook + Invoice field migrations |
| 8 | iOS: `InvoiceDetailView` Pay link row + `InvoiceTemplate` Pay-now block + `InvoicePDFRenderer` PDFAnnotation |
| 9 | iOS: `refreshAccountStatus` + `reconcileInvoicePaid` + `reconcilePendingInvoices` + RootView wiring |
| 10 | iOS: `{paymentLink}` merge field + PaymentRemindersView hint chip + `PaymentsTests.swift` suite |
| 11 | End-to-end manual testing + bug fixes + Diagnostics screen Stripe section |
| 12 | App Store / TestFlight ceremony: Stripe Dashboard webhook URL registration; TestFlight build; App Store Connect metadata |

---

## 13. Files added / modified inventory

**New repo:** `cadence-webhook-worker` (separate GitHub repo)
- `src/index.ts`, `src/auth.ts`, `src/stripe-client.ts`, `src/apns.ts`
- `src/endpoints/{connect,devices,payment-links,webhook}.ts`
- `wrangler.toml`, `package.json`, `vitest.config.ts`
- `tests/{auth,connect,devices,payment-links,webhook}.test.ts`
- `README.md`

**iOS — new files in `Packages/BillableCore/Sources/BillableCore/`:**
- `Models/ConnectedStripeAccount.swift`
- `Payments/StripeConnectService.swift`
- `Payments/PaymentLinkService.swift`
- `Payments/WorkerClient.swift`
- `Payments/WorkerRequests.swift`

**iOS — new files in `App/Sources/`:**
- `Features/Settings/PaymentLinksView.swift`
- `Features/Payments/StripeOnboardingPresenter.swift`

**iOS — modified files:**
- `App/Sources/App/BillableApp.swift`
- `App/Sources/App/AppDelegate.swift`
- `App/Sources/App/RootView.swift`
- `App/Sources/Features/Settings/SettingsView.swift`
- `App/Sources/Features/Settings/PaymentRemindersView.swift`
- `App/Sources/Features/Invoicing/InvoiceDetailView.swift`
- `Packages/BillableCore/Sources/BillableCore/Models/Invoice.swift`
- `Packages/BillableCore/Sources/BillableCore/Models/InvoiceStatusMachine.swift`
- `Packages/BillableCore/Sources/BillableCore/Persistence/ModelContainer+Billable.swift`
- `Packages/BillableCore/Sources/BillableCore/Reminders/ReminderTemplateRenderer.swift`
- `Packages/BillableCore/Sources/BillableCore/Invoicing/InvoicePDFRenderer.swift`
- `Packages/BillableCore/Sources/BillableCore/Invoicing/InvoiceTemplate.swift`
- `project.yml`
- `TESTING.md`

**iOS — new tests:**
- `Packages/BillableCore/Tests/BillableCoreTests/PaymentsTests.swift`

---

## 14. Out of scope

Same list as §2's non-goals, restated here for plan visibility:

| Item | Defer to |
|---|---|
| Refunds / disputes auto-handling in Cadence | v1.2.1 |
| Partial / split / deposit payments | v1.x feature cluster "Money flowing faster" |
| Multi-account per user | v1.3+ if real demand |
| Stripe iOS SDK integration | v1.x if Apple Pay sheet becomes a requirement |
| TLS pinning on Worker requests | v1.x hardening |
| App Attest device attestation | v1.2.1 hardening |
| Push notification banner on payment | Not planned |
| Payouts dashboard inside Cadence | Not planned — "Manage on Stripe" deep link covers |
| Stripe Tax integration | v1.x if needed |
| Auto-deactivate Payment Link on first payment | v1.2.1 |
| Customer storage in Stripe (repeat-pay) | Not planned |
| Non-Stripe gateways (Moyasar, Tap, HyperPay, PayTabs, Razorpay, PayPal) | v1.3+ if regional demand emerges; v1.2 abstraction shape supports adding via `WorkerClient` strategy/adapter |

---

## 15. Open questions

None. All design decisions are locked. New questions discovered during implementation should be raised in the plan or against this spec.

---

## 16. Glossary

- **Stripe Connect Express** — Stripe's hosted onboarding + payout model for platforms (Cadence is the platform; user is the connected account)
- **Account Link** — short-lived URL Stripe issues for hosting the onboarding form
- **Login Link** — short-lived URL for the connected account's Express Dashboard
- **Payment Link** — Stripe's hosted checkout page URL; one-shot per invoice in v1.2
- **`acct_*`** — Stripe Account ID format
- **`plink_*`** — Stripe Payment Link ID format
- **`pi_*`** — Stripe PaymentIntent ID format
- **`ch_*`** — Stripe Charge ID format
- **APNs** — Apple Push Notification service; HTTP/2 endpoint at `api.push.apple.com` (prod) / `api.sandbox.push.apple.com` (dev)
- **ES256 JWT** — JSON Web Token signed with ECDSA + SHA-256; APNs auth format
- **Worker** — Cloudflare Workers deployed JavaScript runtime; ~50ms cold-start, global edge
- **KV** — Cloudflare's key-value store, eventually-consistent globally
- **HMAC** — Hash-based Message Authentication Code; Cadence-to-Worker auth mechanism
- **CAS** — Compare-and-swap; idempotency invariant for `reconcileInvoicePaid` paths
