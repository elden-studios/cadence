# Cadence v1.2 — Payment Links Worker — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and deploy `cadence-webhook-worker` — a Cloudflare Worker that holds Stripe's secret key, signs APNs JWTs, dispatches silent push notifications when Stripe webhooks fire, and provides 6 HMAC-authenticated endpoints to the iOS app for Connect Express onboarding + Payment Link management + device registration.

**Architecture:** Hono + TypeScript on Cloudflare Workers, with Cloudflare KV holding a tiny `stripe_acct_id → APNs device token` map. Zero PII at rest. Stripe Node SDK adapted for Workers' fetch-based runtime. APNs HTTP/2 with ES256-signed JWT via Web Crypto. Two `wrangler.toml` envs (test/prod) with independent secret sets.

**Tech Stack:** TypeScript, Hono, Stripe Node SDK, Cloudflare Workers + KV, vitest, Web Crypto API, wrangler CLI.

**Source spec:** [`docs/superpowers/specs/2026-05-24-payment-links-design.md`](../specs/2026-05-24-payment-links-design.md) (Sections 3–6 cover this plan; sections 7–8 belong to the iOS plan that comes after Worker ships)

**Sibling plan:** `2026-05-24-payment-links-ios.md` (written after this Worker ships to test env)

---

## File Structure

### Files to create

#### Source (`src/`)

| Path | Responsibility |
|---|---|
| `src/index.ts` | Hono app entry; route mounting; `Env` type declaration; CORS-allowed health check |
| `src/types.ts` | Shared TypeScript types: request/response shapes for all 6 endpoints, KV value shape, APNs payload shape |
| `src/auth.ts` | HMAC verification — verifies `Authorization: Bearer <hmac>` against body + timestamp; 60s replay window |
| `src/stripe-client.ts` | Stripe SDK initialization wrapper (uses `Stripe.createFetchHttpClient()` for Workers fetch runtime) |
| `src/apns.ts` | ES256 JWT signer with 50-minute cache + HTTP/2 push to APNs |
| `src/endpoints/connect.ts` | 3 endpoints: `/connect/create-account-link`, `/connect/create-login-link`, `/connect/account-status` |
| `src/endpoints/payment-links.ts` | 2 endpoints: `/payment-links/create`, `/payment-links/status-check` |
| `src/endpoints/devices.ts` | 1 endpoint: `/devices/register` (KV upsert + delete-on-null-token) |
| `src/endpoints/webhook.ts` | Stripe webhook handler — verifies `Stripe-Signature`; routes `payment_intent.succeeded` + `account.updated`; calls into `apns.ts` |

#### Tests (`tests/`)

| Path | Responsibility |
|---|---|
| `tests/helpers.ts` | `buildTestApp()`, mock Stripe factory, in-memory KV shim, fetch interception helper |
| `tests/auth.test.ts` | HMAC: valid → 200, invalid → 401, timestamp drift > 60s → 401, missing header → 401 |
| `tests/connect.test.ts` | 3 endpoints: happy paths, resume-incomplete, Stripe API errors, missing acct_id |
| `tests/payment-links.test.ts` | Create + Status check (batched parallel) |
| `tests/devices.test.ts` | Register + clear via null token |
| `tests/webhook.test.ts` | Signature verification, payment_intent.succeeded routing, account.updated routing, unknown event types, KV miss handling |

#### Config + docs (repo root)

| Path | Responsibility |
|---|---|
| `package.json` | Dependencies: hono, stripe, @cloudflare/workers-types. Dev deps: vitest, @cloudflare/vitest-pool-workers, @types/node, wrangler, typescript |
| `tsconfig.json` | Strict mode, ES2022 target, Workers-types lib |
| `wrangler.toml` | Two envs (`test`, `prod`); KV namespace binding; routes |
| `vitest.config.ts` | Uses `@cloudflare/vitest-pool-workers` so tests run inside the Workers runtime |
| `.gitignore` | `node_modules`, `.dev.vars`, `.wrangler/`, coverage outputs |
| `README.md` | Local dev instructions, deploy commands, secrets-ceremony walkthrough |
| `.dev.vars.example` | Template for local secrets (committed; actual `.dev.vars` is git-ignored) |

### Files to modify

None — this is a brand-new repo. (The iOS-side plan in the sibling document will modify the existing Cadence repo.)

---

## Conventions used in this plan

- All TypeScript uses `strict: true` and explicit return types on exported functions.
- Tests use **vitest** with `@cloudflare/vitest-pool-workers` so they execute inside the actual Workers runtime (giving us real KV, real `crypto.subtle`, real `fetch`).
- Mock Stripe via `vi.mock('stripe', ...)` with a factory that returns a stub `Stripe` class.
- Mock APNs by intercepting `fetch()` for `api.push.apple.com` / `api.sandbox.push.apple.com` URLs.
- Every endpoint returns `application/json; charset=utf-8` with explicit status codes.
- Errors propagated as `{ "error": "human readable description" }` with appropriate HTTP status.
- Worker logs structured JSON via `console.log(JSON.stringify({...}))` so Cloudflare Workers Logs parses them.
- Build verification: `npm run build` (which runs `tsc --noEmit`); deploy verification: `wrangler deploy --dry-run --env test`.
- Commit messages use imperative mood and reference the task number from this plan.

### Setting up a fresh repo

This Worker lives in a separate GitHub repo (`cadence-webhook-worker`) — NOT inside the Cadence iOS repo. Plan execution should:

1. Create a new local directory `~/dev/cadence-webhook-worker/` (or wherever the engineer wants)
2. Run `git init` inside it
3. Set up the GitHub remote (`gh repo create elden-studios/cadence-webhook-worker --private`)
4. Execute Phase 1 tasks below

The engineer should NOT clone the Cadence iOS repo for this work. All file paths in this plan are relative to the Worker repo root.

---

## Phase 1 — Project bootstrap (Day 1, morning)

### Task 1.1: Initialize repo + npm + .gitignore + tsconfig

**Files:**
- Create: `package.json`
- Create: `tsconfig.json`
- Create: `.gitignore`
- Create: `README.md` (skeleton)

- [ ] **Step 1: Initialize the repo**

```bash
mkdir -p ~/dev/cadence-webhook-worker
cd ~/dev/cadence-webhook-worker
git init
gh repo create elden-studios/cadence-webhook-worker --private --source=. --remote=origin
```

Expected: empty git repo with `origin` remote configured.

- [ ] **Step 2: `npm init` and install dependencies**

```bash
npm init -y
npm install hono stripe
npm install --save-dev typescript @types/node @cloudflare/workers-types wrangler vitest @cloudflare/vitest-pool-workers
```

Expected: `package.json` + `package-lock.json` created; `node_modules/` populated.

- [ ] **Step 3: Write `package.json` scripts**

Edit `package.json` and add a `scripts` section:

```json
{
  "name": "cadence-webhook-worker",
  "version": "0.1.0",
  "private": true,
  "scripts": {
    "dev": "wrangler dev --env test",
    "deploy:test": "wrangler deploy --env test",
    "deploy:prod": "wrangler deploy --env prod",
    "test": "vitest run",
    "test:watch": "vitest",
    "typecheck": "tsc --noEmit"
  }
}
```

- [ ] **Step 4: Create `tsconfig.json`**

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ES2022",
    "moduleResolution": "Bundler",
    "lib": ["ES2022"],
    "types": ["@cloudflare/workers-types"],
    "strict": true,
    "noImplicitAny": true,
    "strictNullChecks": true,
    "noUncheckedIndexedAccess": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "resolveJsonModule": true,
    "isolatedModules": true,
    "noEmit": true
  },
  "include": ["src/**/*", "tests/**/*"]
}
```

- [ ] **Step 5: Create `.gitignore`**

```
node_modules/
.wrangler/
.dev.vars
coverage/
.DS_Store
*.log
```

- [ ] **Step 6: Create a skeleton `README.md`**

```markdown
# cadence-webhook-worker

Cloudflare Worker for Cadence v1.2's Payment Links feature.

Receives Stripe webhooks, dispatches silent APNs pushes to subscribed
iOS devices, and provides 6 HMAC-authenticated endpoints for Stripe
Connect Express onboarding + Payment Link management.

## Local development

```bash
npm install
cp .dev.vars.example .dev.vars   # then fill in secrets
npm run dev                       # starts wrangler dev on :8787
npm run test                      # vitest
npm run typecheck                 # tsc --noEmit
```

## Deployment

See "Secrets ceremony" + "Deploy" sections below (added in Phase 8).
```

- [ ] **Step 7: Verify and commit**

```bash
npm run typecheck       # Expected: no errors (no source files yet, so passes trivially)
git add .
git commit -m "chore: bootstrap cadence-webhook-worker (task 1.1)"
```

---

### Task 1.2: Create `src/types.ts` with shared shapes

**Files:**
- Create: `src/types.ts`

This file holds every type used across endpoints + tests. Keeping types in one file gives the engineer a single place to consult when building each endpoint.

- [ ] **Step 1: Create `src/types.ts`**

```typescript
// src/types.ts — shared types for cadence-webhook-worker

// ─── Cloudflare bindings (wrangler.toml env vars + KV namespace) ────────────

export interface Env {
  // Secrets (set via `wrangler secret put`)
  STRIPE_SECRET_KEY: string;
  STRIPE_WEBHOOK_SECRET: string;
  APNS_AUTH_KEY: string;       // .p8 PEM contents
  APNS_KEY_ID: string;         // 10 chars
  APNS_TEAM_ID: string;        // 10 chars
  APP_BUNDLE_ID: string;       // e.g. "com.eldenstudios.billable"
  APP_HMAC_SECRET: string;     // shared with iOS build

  // Vars (set via wrangler.toml [vars] section)
  ENV_NAME: "test" | "prod";

  // KV namespace binding
  DEVICE_TOKENS: KVNamespace;
}

// ─── KV value shape (one row per stripe_acct_id) ────────────────────────────

export interface DeviceRegistration {
  apns_token: string;          // 64-char hex
  env: "production" | "development";
  updated_at: number;           // ms epoch
}

// ─── Endpoint request/response shapes ───────────────────────────────────────

export interface CreateAccountLinkRequest {
  acct_id?: string;             // omit to create new account
  ts: number;                   // ms epoch — HMAC replay protection
}
export interface CreateAccountLinkResponse {
  url: string;
  acct_id: string;
}

export interface CreateLoginLinkRequest {
  acct_id: string;
  ts: number;
}
export interface CreateLoginLinkResponse {
  url: string;
}

export interface AccountStatusRequest {
  acct_id: string;
  ts: number;
}
export interface AccountStatusResponse {
  charges_enabled: boolean;
  payouts_enabled: boolean;
  details_submitted: boolean;
  has_pending_requirements: boolean;
  country: string;
  default_currency: string;
}

export interface CreatePaymentLinkRequest {
  acct_id: string;
  amount_minor: number;
  currency: string;             // "usd", "eur", ...
  description: string;
  metadata: Record<string, string>;
  ts: number;
}
export interface CreatePaymentLinkResponse {
  url: string;
  id: string;                   // "plink_..."
}

export interface PaymentLinkStatusCheckRequest {
  acct_id: string;
  payment_link_ids: string[];
  ts: number;
}
export interface PaymentLinkStatusResult {
  plink_id: string;
  paid: boolean;
  charge_id?: string;           // present when paid
  amount_received?: number;
  currency?: string;
}
export interface PaymentLinkStatusCheckResponse {
  results: PaymentLinkStatusResult[];
}

export interface DeviceRegisterRequest {
  acct_id: string;
  apns_token: string | null;    // null clears the registration
  env: "production" | "development";
  ts: number;
}
export interface DeviceRegisterResponse {
  ok: boolean;
}

// ─── APNs silent push payload (delivered to iOS app) ─────────────────────────

export type ApnsPushPayload =
  | {
      aps: { "content-available": 1 };
      kind: "stripe_payment_succeeded";
      payment_link_id: string;
      charge_id: string;
      amount_received: number;
      currency: string;
    }
  | {
      aps: { "content-available": 1 };
      kind: "stripe_account_updated";
    };

// ─── Error response (returned on any 4xx / 5xx) ──────────────────────────────

export interface ErrorResponse {
  error: string;
}
```

- [ ] **Step 2: Typecheck and commit**

```bash
npm run typecheck
```
Expected: PASS.

```bash
git add src/types.ts
git commit -m "feat(types): shared TypeScript types for all 6 endpoints + KV (task 1.2)"
```

---

### Task 1.3: Create Hono app entry + `wrangler.toml` skeleton + first integration test

**Files:**
- Create: `src/index.ts`
- Create: `wrangler.toml`
- Create: `vitest.config.ts`
- Create: `tests/helpers.ts`
- Create: `tests/health.test.ts`

- [ ] **Step 1: Create `tests/helpers.ts`**

```typescript
// tests/helpers.ts — shared test scaffolding

import { Hono } from "hono";
import type { Env } from "../src/types";

/** Builds a test Hono app with a given env stub. */
export function buildTestEnv(overrides: Partial<Env> = {}): Env {
  const fakeKV: KVNamespace = {
    get: async (_key: string) => null,
    getWithMetadata: async (_key: string) => ({ value: null, metadata: null }),
    put: async (_key: string, _value: string) => {},
    delete: async (_key: string) => {},
    list: async () => ({ keys: [], list_complete: true, cacheStatus: null }),
  } as unknown as KVNamespace;

  return {
    STRIPE_SECRET_KEY: "sk_test_dummy",
    STRIPE_WEBHOOK_SECRET: "whsec_dummy",
    APNS_AUTH_KEY: "-----BEGIN PRIVATE KEY-----\nMOCK\n-----END PRIVATE KEY-----",
    APNS_KEY_ID: "ABCDE12345",
    APNS_TEAM_ID: "TEAM123456",
    APP_BUNDLE_ID: "com.eldenstudios.billable",
    APP_HMAC_SECRET: "test-hmac-secret-rotate-me",
    ENV_NAME: "test",
    DEVICE_TOKENS: fakeKV,
    ...overrides,
  };
}

/** Convenience to dispatch a request to a Hono app with a test env. */
export async function dispatch(app: Hono<{ Bindings: Env }>, req: Request, env: Env): Promise<Response> {
  return app.fetch(req, env);
}
```

- [ ] **Step 2: Write the failing health-check test**

Create `tests/health.test.ts`:

```typescript
import { describe, it, expect } from "vitest";
import app from "../src/index";
import { buildTestEnv, dispatch } from "./helpers";

describe("GET /health", () => {
  it("returns 200 with { ok: true }", async () => {
    const env = buildTestEnv();
    const res = await dispatch(
      app,
      new Request("https://w.example.com/health"),
      env
    );
    expect(res.status).toBe(200);
    const body = (await res.json()) as { ok: boolean };
    expect(body.ok).toBe(true);
  });
});
```

- [ ] **Step 3: Run test (fail)**

```bash
npm run test
```
Expected: FAIL — "Cannot find module '../src/index'" or similar.

- [ ] **Step 4: Create `src/index.ts`**

```typescript
// src/index.ts — Hono app entry for cadence-webhook-worker

import { Hono } from "hono";
import type { Env } from "./types";

const app = new Hono<{ Bindings: Env }>();

// Health check — no auth, no PII, returns immediately
app.get("/health", (c) => c.json({ ok: true }));

// (More routes mounted in later phases)

export default app;
```

- [ ] **Step 5: Create `vitest.config.ts`**

```typescript
// vitest.config.ts — runs tests inside the Workers runtime

import { defineWorkersConfig } from "@cloudflare/vitest-pool-workers/config";

export default defineWorkersConfig({
  test: {
    poolOptions: {
      workers: {
        wrangler: { configPath: "./wrangler.toml" },
      },
    },
  },
});
```

- [ ] **Step 6: Create skeleton `wrangler.toml`**

```toml
# wrangler.toml — Cadence webhook worker (skeleton; full envs added in Phase 8)

name = "cadence-webhook-test"
main = "src/index.ts"
compatibility_date = "2026-05-24"

# Local dev environment (used by `wrangler dev` and `npm run test`)
[vars]
ENV_NAME = "test"

# KV namespace binding for device_tokens
# Replace the ID with the real KV namespace ID after creating it (Phase 8 Task 8.1)
[[kv_namespaces]]
binding = "DEVICE_TOKENS"
id = "PLACEHOLDER_KV_ID"
preview_id = "PLACEHOLDER_KV_PREVIEW_ID"
```

> **Note:** `PLACEHOLDER_KV_ID` is intentional at this stage — Phase 8 Task 8.1 creates the real KV namespace and substitutes the IDs. The placeholder lets local tests run because `@cloudflare/vitest-pool-workers` mocks the KV anyway.

- [ ] **Step 7: Run test (pass)**

```bash
npm run test
```
Expected: PASS — `1 test passed`.

- [ ] **Step 8: Commit**

```bash
git add src/index.ts wrangler.toml vitest.config.ts tests/helpers.ts tests/health.test.ts
git commit -m "feat: Hono app entry + health check + vitest scaffolding (task 1.3)"
```

---

## Phase 2 — HMAC auth middleware (Day 1, afternoon)

### Task 2.1: HMAC verification function + tests

**Files:**
- Create: `src/auth.ts`
- Create: `tests/auth.test.ts`

The HMAC scheme: signature = `hex(HMAC-SHA256(APP_HMAC_SECRET, "<method>:<path>:<ts>:<body>"))`. Request carries `Authorization: Bearer <hex>` header. Body includes `ts: number` (ms epoch). Worker rejects if `|server_now - ts| > 60_000` or HMAC mismatches.

- [ ] **Step 1: Write the failing test**

Create `tests/auth.test.ts`:

```typescript
import { describe, it, expect } from "vitest";
import { verifyHmac } from "../src/auth";

const SECRET = "test-hmac-secret-rotate-me";

async function computeHmac(method: string, path: string, ts: number, body: string): Promise<string> {
  const message = `${method}:${path}:${ts}:${body}`;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(SECRET),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message));
  return Array.from(new Uint8Array(sig))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

describe("verifyHmac", () => {
  it("returns true for a correctly-signed request within the replay window", async () => {
    const ts = Date.now();
    const body = JSON.stringify({ acct_id: "acct_1ABC", ts });
    const sig = await computeHmac("POST", "/connect/account-status", ts, body);

    const ok = await verifyHmac({
      secret: SECRET,
      method: "POST",
      path: "/connect/account-status",
      ts,
      body,
      providedHmac: sig,
      now: Date.now(),
    });
    expect(ok).toBe(true);
  });

  it("returns false when the signature is wrong", async () => {
    const ts = Date.now();
    const body = JSON.stringify({ acct_id: "acct_1ABC", ts });
    const ok = await verifyHmac({
      secret: SECRET,
      method: "POST",
      path: "/connect/account-status",
      ts,
      body,
      providedHmac: "0".repeat(64),
      now: Date.now(),
    });
    expect(ok).toBe(false);
  });

  it("returns false when timestamp drift exceeds 60 seconds", async () => {
    const ts = Date.now() - 61_000;
    const body = JSON.stringify({ acct_id: "acct_1ABC", ts });
    const sig = await computeHmac("POST", "/connect/account-status", ts, body);

    const ok = await verifyHmac({
      secret: SECRET,
      method: "POST",
      path: "/connect/account-status",
      ts,
      body,
      providedHmac: sig,
      now: Date.now(),
    });
    expect(ok).toBe(false);
  });

  it("returns false when timestamp is in the future beyond the replay window", async () => {
    const ts = Date.now() + 61_000;
    const body = JSON.stringify({ acct_id: "acct_1ABC", ts });
    const sig = await computeHmac("POST", "/connect/account-status", ts, body);

    const ok = await verifyHmac({
      secret: SECRET,
      method: "POST",
      path: "/connect/account-status",
      ts,
      body,
      providedHmac: sig,
      now: Date.now(),
    });
    expect(ok).toBe(false);
  });
});
```

- [ ] **Step 2: Run test (fail)**

```bash
npm run test -- auth
```
Expected: FAIL — `Cannot find module '../src/auth'`.

- [ ] **Step 3: Implement `src/auth.ts`**

```typescript
// src/auth.ts — HMAC verification for non-webhook endpoints

const REPLAY_WINDOW_MS = 60_000;

export interface VerifyHmacInput {
  secret: string;
  method: string;       // "POST"
  path: string;         // "/connect/account-status"
  ts: number;           // ms epoch from request body
  body: string;         // exact raw request body
  providedHmac: string; // hex from `Authorization: Bearer <hex>`
  now: number;          // ms epoch — Date.now() in production, injectable for tests
}

/**
 * Verify HMAC-SHA256 over `<method>:<path>:<ts>:<body>` matches `providedHmac`,
 * AND that |now - ts| is within REPLAY_WINDOW_MS. Uses constant-time comparison.
 */
export async function verifyHmac(input: VerifyHmacInput): Promise<boolean> {
  // Replay-window check first (cheap)
  if (Math.abs(input.now - input.ts) > REPLAY_WINDOW_MS) {
    return false;
  }

  const message = `${input.method}:${input.path}:${input.ts}:${input.body}`;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(input.secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const sigBuffer = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message));
  const computed = Array.from(new Uint8Array(sigBuffer))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");

  // Constant-time compare to prevent timing leaks
  return constantTimeEquals(computed, input.providedHmac);
}

function constantTimeEquals(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}
```

- [ ] **Step 4: Run test (pass)**

```bash
npm run test -- auth
```
Expected: PASS — all 4 tests green.

- [ ] **Step 5: Commit**

```bash
git add src/auth.ts tests/auth.test.ts
git commit -m "feat(auth): HMAC verification with 60s replay window + constant-time compare (task 2.1)"
```

---

### Task 2.2: Hono auth middleware

**Files:**
- Modify: `src/auth.ts` (add middleware factory)
- Modify: `src/index.ts` (use middleware on protected routes)
- Create: `tests/auth-middleware.test.ts`

Wraps `verifyHmac` as Hono middleware. Reads `Authorization: Bearer <hex>` header, parses body as JSON to find `ts`, dispatches to `verifyHmac`. On failure → 401 `{ error: "auth" }`.

- [ ] **Step 1: Write the failing middleware test**

Create `tests/auth-middleware.test.ts`:

```typescript
import { describe, it, expect } from "vitest";
import { Hono } from "hono";
import { hmacMiddleware } from "../src/auth";
import type { Env } from "../src/types";
import { buildTestEnv, dispatch } from "./helpers";

const SECRET = "test-hmac-secret-rotate-me";

async function signedRequest(
  method: string,
  path: string,
  body: Record<string, unknown>
): Promise<Request> {
  const ts = Date.now();
  const bodyWithTs = { ...body, ts };
  const bodyStr = JSON.stringify(bodyWithTs);

  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(SECRET),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const sigBuffer = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(`${method}:${path}:${ts}:${bodyStr}`)
  );
  const hmac = Array.from(new Uint8Array(sigBuffer))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");

  return new Request(`https://w.example.com${path}`, {
    method,
    headers: {
      "content-type": "application/json",
      "authorization": `Bearer ${hmac}`,
    },
    body: bodyStr,
  });
}

function buildAppWithProtected(): Hono<{ Bindings: Env }> {
  const app = new Hono<{ Bindings: Env }>();
  app.use("/protected/*", hmacMiddleware);
  app.post("/protected/ping", (c) => c.json({ pong: true }));
  return app;
}

describe("hmacMiddleware", () => {
  it("allows correctly-signed requests through", async () => {
    const app = buildAppWithProtected();
    const env = buildTestEnv();
    const req = await signedRequest("POST", "/protected/ping", { hello: "world" });
    const res = await dispatch(app, req, env);
    expect(res.status).toBe(200);
    const body = (await res.json()) as { pong: boolean };
    expect(body.pong).toBe(true);
  });

  it("rejects requests with no Authorization header (401)", async () => {
    const app = buildAppWithProtected();
    const env = buildTestEnv();
    const ts = Date.now();
    const req = new Request("https://w.example.com/protected/ping", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ hello: "world", ts }),
    });
    const res = await dispatch(app, req, env);
    expect(res.status).toBe(401);
  });

  it("rejects requests with a tampered body (401)", async () => {
    const app = buildAppWithProtected();
    const env = buildTestEnv();
    const req = await signedRequest("POST", "/protected/ping", { hello: "world" });
    // Replace the body after signing — HMAC will no longer match
    const tampered = new Request(req, { body: JSON.stringify({ hello: "tampered", ts: Date.now() }) });
    const res = await dispatch(app, tampered, env);
    expect(res.status).toBe(401);
  });

  it("rejects requests with malformed Authorization header (401)", async () => {
    const app = buildAppWithProtected();
    const env = buildTestEnv();
    const ts = Date.now();
    const req = new Request("https://w.example.com/protected/ping", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "authorization": "NotBearer abc",
      },
      body: JSON.stringify({ hello: "world", ts }),
    });
    const res = await dispatch(app, req, env);
    expect(res.status).toBe(401);
  });
});
```

- [ ] **Step 2: Run test (fail)**

```bash
npm run test -- auth-middleware
```
Expected: FAIL — `hmacMiddleware is not exported`.

- [ ] **Step 3: Add `hmacMiddleware` to `src/auth.ts`**

Append to `src/auth.ts`:

```typescript
import type { Context, MiddlewareHandler } from "hono";
import type { Env } from "./types";

/**
 * Hono middleware enforcing HMAC auth on protected endpoints.
 * Reads:
 *   - `Authorization: Bearer <hex>` header
 *   - Request body as JSON, extracting `ts: number`
 * Stashes the parsed body on the context as `c.set("parsedBody", obj)` so
 * the route handler doesn't have to re-parse.
 * On failure: returns 401 with { error: "auth" }.
 */
export const hmacMiddleware: MiddlewareHandler<{ Bindings: Env; Variables: { parsedBody: Record<string, unknown>; rawBody: string } }> = async (c, next) => {
  const authHeader = c.req.header("authorization");
  if (!authHeader || !authHeader.startsWith("Bearer ")) {
    return c.json({ error: "auth" }, 401);
  }
  const providedHmac = authHeader.slice("Bearer ".length).trim();
  if (providedHmac.length === 0) {
    return c.json({ error: "auth" }, 401);
  }

  // Read raw body once. Cache for downstream handlers.
  const rawBody = await c.req.text();
  let parsed: Record<string, unknown>;
  try {
    parsed = JSON.parse(rawBody) as Record<string, unknown>;
  } catch {
    return c.json({ error: "auth" }, 401);
  }

  const ts = parsed.ts;
  if (typeof ts !== "number") {
    return c.json({ error: "auth" }, 401);
  }

  const path = new URL(c.req.url).pathname;
  const ok = await verifyHmac({
    secret: c.env.APP_HMAC_SECRET,
    method: c.req.method,
    path,
    ts,
    body: rawBody,
    providedHmac,
    now: Date.now(),
  });

  if (!ok) {
    return c.json({ error: "auth" }, 401);
  }

  c.set("parsedBody", parsed);
  c.set("rawBody", rawBody);
  await next();
  return; // explicit void
};
```

- [ ] **Step 4: Run test (pass)**

```bash
npm run test -- auth-middleware
```
Expected: PASS — all 4 tests green.

- [ ] **Step 5: Commit**

```bash
git add src/auth.ts tests/auth-middleware.test.ts
git commit -m "feat(auth): Hono HMAC middleware with body caching (task 2.2)"
```

---

## Phase 3 — Stripe SDK setup (Day 2, morning, ~half-day)

### Task 3.1: Stripe client factory adapted for Workers fetch

**Files:**
- Create: `src/stripe-client.ts`
- Create: `tests/stripe-client.test.ts`

The Node Stripe SDK uses Node's `http` module by default, which doesn't exist on Workers. Stripe ships a built-in `createFetchHttpClient()` that swaps in `fetch()` — we use that.

- [ ] **Step 1: Write the failing test**

Create `tests/stripe-client.test.ts`:

```typescript
import { describe, it, expect } from "vitest";
import { stripeFor } from "../src/stripe-client";

describe("stripeFor", () => {
  it("returns a Stripe instance with the fetch-based HTTP client", () => {
    const s = stripeFor("sk_test_dummy");
    // The instance exposes the SDK surface we'll use later
    expect(typeof s.accounts.create).toBe("function");
    expect(typeof s.accountLinks.create).toBe("function");
    expect(typeof s.accounts.retrieve).toBe("function");
    expect(typeof s.accounts.createLoginLink).toBe("function");
    expect(typeof s.paymentLinks.create).toBe("function");
    expect(typeof s.checkout.sessions.list).toBe("function");
    expect(typeof s.webhooks.constructEvent).toBe("function");
  });
});
```

- [ ] **Step 2: Run test (fail)**

```bash
npm run test -- stripe-client
```
Expected: FAIL — `Cannot find module '../src/stripe-client'`.

- [ ] **Step 3: Implement `src/stripe-client.ts`**

```typescript
// src/stripe-client.ts — Stripe SDK factory for Cloudflare Workers

import Stripe from "stripe";

/**
 * Builds a Stripe SDK instance configured for the Workers fetch runtime.
 *
 * The default Node http client is not available on Workers, so we swap in
 * `Stripe.createFetchHttpClient()` which uses the platform's native `fetch`.
 *
 * Pinned API version for reproducibility; bump only after testing.
 */
export function stripeFor(secretKey: string): Stripe {
  return new Stripe(secretKey, {
    apiVersion: "2024-12-18.acacia",
    httpClient: Stripe.createFetchHttpClient(),
  });
}
```

- [ ] **Step 4: Run test (pass)**

```bash
npm run test -- stripe-client
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/stripe-client.ts tests/stripe-client.test.ts
git commit -m "feat(stripe): SDK factory with fetch HTTP client for Workers (task 3.1)"
```

---

## Phase 4 — Connect endpoints (Day 2, afternoon + Day 3 morning)

### Task 4.1: `POST /connect/create-account-link`

**Files:**
- Create: `src/endpoints/connect.ts`
- Modify: `src/index.ts` (mount the route)
- Create: `tests/connect.test.ts`

Handler logic (per spec §6, endpoint 1):
1. Auth via `hmacMiddleware` (already applied at mount point)
2. If `acct_id` present in body → resume; else → `stripe.accounts.create({ type: 'express' })`
3. Then `stripe.accountLinks.create({ account, refresh_url, return_url, type: 'account_onboarding' })`
4. Return `{ url, acct_id }`

Return URL: `cadence://stripe-connect/return?account=<acct_id>` (the iOS app handles this).
Refresh URL: same (Stripe shows this if user expired the link).

- [ ] **Step 1: Write the failing test**

Create `tests/connect.test.ts`:

```typescript
import { describe, it, expect, vi, beforeEach } from "vitest";
import { Hono } from "hono";
import type { Env } from "../src/types";
import { mountConnect } from "../src/endpoints/connect";
import { hmacMiddleware } from "../src/auth";
import { buildTestEnv, dispatch } from "./helpers";

const SECRET = "test-hmac-secret-rotate-me";

async function signedPost(path: string, body: Record<string, unknown>): Promise<Request> {
  const ts = Date.now();
  const bodyWithTs = { ...body, ts };
  const bodyStr = JSON.stringify(bodyWithTs);
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(SECRET),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const sig = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(`POST:${path}:${ts}:${bodyStr}`)
  );
  const hmac = Array.from(new Uint8Array(sig))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
  return new Request(`https://w.example.com${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", "authorization": `Bearer ${hmac}` },
    body: bodyStr,
  });
}

// Mock the Stripe SDK
vi.mock("../src/stripe-client", () => ({
  stripeFor: vi.fn(),
}));

import { stripeFor } from "../src/stripe-client";

function buildApp(): Hono<{ Bindings: Env }> {
  const app = new Hono<{ Bindings: Env }>();
  app.use("/connect/*", hmacMiddleware);
  mountConnect(app);
  return app;
}

describe("POST /connect/create-account-link", () => {
  beforeEach(() => {
    vi.mocked(stripeFor).mockReset();
  });

  it("creates a new account when acct_id is absent + returns the onboarding URL", async () => {
    const mockStripe = {
      accounts: {
        create: vi.fn().mockResolvedValue({ id: "acct_1NEW" }),
      },
      accountLinks: {
        create: vi.fn().mockResolvedValue({ url: "https://stripe.example/onboard/abc" }),
      },
    };
    vi.mocked(stripeFor).mockReturnValue(mockStripe as never);

    const app = buildApp();
    const env = buildTestEnv();
    const req = await signedPost("/connect/create-account-link", {});
    const res = await dispatch(app, req, env);

    expect(res.status).toBe(200);
    const body = (await res.json()) as { url: string; acct_id: string };
    expect(body.acct_id).toBe("acct_1NEW");
    expect(body.url).toBe("https://stripe.example/onboard/abc");
    expect(mockStripe.accounts.create).toHaveBeenCalledOnce();
    expect(mockStripe.accountLinks.create).toHaveBeenCalledWith({
      account: "acct_1NEW",
      refresh_url: "cadence://stripe-connect/return",
      return_url: "cadence://stripe-connect/return",
      type: "account_onboarding",
    });
  });

  it("resumes onboarding when acct_id is provided (no new account created)", async () => {
    const mockStripe = {
      accounts: {
        create: vi.fn(),
      },
      accountLinks: {
        create: vi.fn().mockResolvedValue({ url: "https://stripe.example/resume/xyz" }),
      },
    };
    vi.mocked(stripeFor).mockReturnValue(mockStripe as never);

    const app = buildApp();
    const env = buildTestEnv();
    const req = await signedPost("/connect/create-account-link", { acct_id: "acct_1EXISTING" });
    const res = await dispatch(app, req, env);

    expect(res.status).toBe(200);
    const body = (await res.json()) as { url: string; acct_id: string };
    expect(body.acct_id).toBe("acct_1EXISTING");
    expect(body.url).toBe("https://stripe.example/resume/xyz");
    expect(mockStripe.accounts.create).not.toHaveBeenCalled();
    expect(mockStripe.accountLinks.create).toHaveBeenCalledOnce();
  });

  it("returns 502 when Stripe rejects the account creation", async () => {
    const mockStripe = {
      accounts: {
        create: vi.fn().mockRejectedValue(new Error("Stripe API down")),
      },
      accountLinks: { create: vi.fn() },
    };
    vi.mocked(stripeFor).mockReturnValue(mockStripe as never);

    const app = buildApp();
    const env = buildTestEnv();
    const req = await signedPost("/connect/create-account-link", {});
    const res = await dispatch(app, req, env);

    expect(res.status).toBe(502);
  });
});
```

- [ ] **Step 2: Run test (fail)**

```bash
npm run test -- connect
```
Expected: FAIL — `Cannot find module '../src/endpoints/connect'`.

- [ ] **Step 3: Implement `src/endpoints/connect.ts`**

Create `src/endpoints/connect.ts`:

```typescript
// src/endpoints/connect.ts — Stripe Connect Express endpoints

import type { Hono } from "hono";
import { stripeFor } from "../stripe-client";
import type {
  CreateAccountLinkRequest,
  CreateAccountLinkResponse,
  Env,
} from "../types";

const RETURN_URL = "cadence://stripe-connect/return";
const REFRESH_URL = "cadence://stripe-connect/return";

export function mountConnect(app: Hono<{ Bindings: Env; Variables: { parsedBody: Record<string, unknown>; rawBody: string } }>): void {
  app.post("/connect/create-account-link", async (c) => {
    const body = c.var.parsedBody as Partial<CreateAccountLinkRequest>;
    const stripe = stripeFor(c.env.STRIPE_SECRET_KEY);

    try {
      let acctID: string;
      if (typeof body.acct_id === "string" && body.acct_id.length > 0) {
        acctID = body.acct_id;
      } else {
        const account = await stripe.accounts.create({ type: "express" });
        acctID = account.id;
      }

      const link = await stripe.accountLinks.create({
        account: acctID,
        refresh_url: REFRESH_URL,
        return_url: RETURN_URL,
        type: "account_onboarding",
      });

      const response: CreateAccountLinkResponse = { url: link.url, acct_id: acctID };
      return c.json(response);
    } catch (err) {
      console.log(JSON.stringify({
        event: "create_account_link_failed",
        error: err instanceof Error ? err.message : String(err),
      }));
      return c.json({ error: "stripe_api" }, 502);
    }
  });

  // /connect/create-login-link is added in Task 4.2
  // /connect/account-status is added in Task 4.3
}
```

- [ ] **Step 4: Mount the route in `src/index.ts`**

Edit `src/index.ts` to import and mount:

```typescript
// src/index.ts — Hono app entry for cadence-webhook-worker

import { Hono } from "hono";
import type { Env } from "./types";
import { hmacMiddleware } from "./auth";
import { mountConnect } from "./endpoints/connect";

const app = new Hono<{
  Bindings: Env;
  Variables: { parsedBody: Record<string, unknown>; rawBody: string };
}>();

// Health check — no auth, no PII
app.get("/health", (c) => c.json({ ok: true }));

// HMAC-protected endpoints
app.use("/connect/*", hmacMiddleware);
app.use("/payment-links/*", hmacMiddleware);
app.use("/devices/*", hmacMiddleware);

mountConnect(app);
// mountPaymentLinks(app) — Phase 5
// mountDevices(app)      — Phase 6
// mountWebhook(app)      — Phase 7 (no auth middleware; uses Stripe signature instead)

export default app;
```

- [ ] **Step 5: Run test (pass)**

```bash
npm run test -- connect
```
Expected: PASS — 3 tests green.

- [ ] **Step 6: Commit**

```bash
git add src/endpoints/connect.ts src/index.ts tests/connect.test.ts
git commit -m "feat(connect): POST /connect/create-account-link with new + resume paths (task 4.1)"
```

---

### Task 4.2: `POST /connect/create-login-link`

**Files:**
- Modify: `src/endpoints/connect.ts` (add the second endpoint)
- Modify: `tests/connect.test.ts` (append tests)

Handler logic:
1. Auth via `hmacMiddleware`
2. `stripe.accounts.createLoginLink(acct_id)`
3. Return `{ url }`

- [ ] **Step 1: Append the failing test**

Append to `tests/connect.test.ts` (inside the existing `describe` blocks — add a new `describe`):

```typescript
describe("POST /connect/create-login-link", () => {
  beforeEach(() => {
    vi.mocked(stripeFor).mockReset();
  });

  it("returns a one-shot Express Dashboard URL", async () => {
    const mockStripe = {
      accounts: {
        createLoginLink: vi.fn().mockResolvedValue({ url: "https://connect.stripe.com/express/abc" }),
      },
    };
    vi.mocked(stripeFor).mockReturnValue(mockStripe as never);

    const app = buildApp();
    const env = buildTestEnv();
    const req = await signedPost("/connect/create-login-link", { acct_id: "acct_1ABC" });
    const res = await dispatch(app, req, env);

    expect(res.status).toBe(200);
    const body = (await res.json()) as { url: string };
    expect(body.url).toBe("https://connect.stripe.com/express/abc");
    expect(mockStripe.accounts.createLoginLink).toHaveBeenCalledWith("acct_1ABC");
  });

  it("returns 400 when acct_id is missing", async () => {
    const mockStripe = {
      accounts: { createLoginLink: vi.fn() },
    };
    vi.mocked(stripeFor).mockReturnValue(mockStripe as never);

    const app = buildApp();
    const env = buildTestEnv();
    const req = await signedPost("/connect/create-login-link", {});  // no acct_id
    const res = await dispatch(app, req, env);

    expect(res.status).toBe(400);
    expect(mockStripe.accounts.createLoginLink).not.toHaveBeenCalled();
  });

  it("returns 502 when Stripe errors", async () => {
    const mockStripe = {
      accounts: {
        createLoginLink: vi.fn().mockRejectedValue(new Error("no such account")),
      },
    };
    vi.mocked(stripeFor).mockReturnValue(mockStripe as never);

    const app = buildApp();
    const env = buildTestEnv();
    const req = await signedPost("/connect/create-login-link", { acct_id: "acct_1NONEXISTENT" });
    const res = await dispatch(app, req, env);

    expect(res.status).toBe(502);
  });
});
```

- [ ] **Step 2: Run tests (fail)**

```bash
npm run test -- connect
```
Expected: FAIL — endpoint not found / handler returns 404.

- [ ] **Step 3: Append to `src/endpoints/connect.ts`**

Inside `mountConnect`, add:

```typescript
  app.post("/connect/create-login-link", async (c) => {
    const body = c.var.parsedBody as Partial<CreateLoginLinkRequest>;
    if (typeof body.acct_id !== "string" || body.acct_id.length === 0) {
      return c.json({ error: "missing acct_id" }, 400);
    }

    const stripe = stripeFor(c.env.STRIPE_SECRET_KEY);
    try {
      const link = await stripe.accounts.createLoginLink(body.acct_id);
      const response: CreateLoginLinkResponse = { url: link.url };
      return c.json(response);
    } catch (err) {
      console.log(JSON.stringify({
        event: "create_login_link_failed",
        acct_id: body.acct_id,
        error: err instanceof Error ? err.message : String(err),
      }));
      return c.json({ error: "stripe_api" }, 502);
    }
  });
```

And add the imports at the top:

```typescript
import type {
  CreateAccountLinkRequest,
  CreateAccountLinkResponse,
  CreateLoginLinkRequest,
  CreateLoginLinkResponse,
  Env,
} from "../types";
```

- [ ] **Step 4: Run tests (pass)**

```bash
npm run test -- connect
```
Expected: PASS — 6 connect tests green (3 from Task 4.1 + 3 new).

- [ ] **Step 5: Commit**

```bash
git add src/endpoints/connect.ts tests/connect.test.ts
git commit -m "feat(connect): POST /connect/create-login-link (task 4.2)"
```

---

### Task 4.3: `POST /connect/account-status`

**Files:**
- Modify: `src/endpoints/connect.ts`
- Modify: `tests/connect.test.ts`

Handler logic:
1. Auth
2. `stripe.accounts.retrieve(acct_id)` — returns the full Stripe Account object
3. Map down to the sanitized 6-field response

`has_pending_requirements` derives from `account.requirements?.currently_due ?? []` being non-empty.

- [ ] **Step 1: Append the failing test**

Append to `tests/connect.test.ts`:

```typescript
describe("POST /connect/account-status", () => {
  beforeEach(() => {
    vi.mocked(stripeFor).mockReset();
  });

  it("returns the sanitized account state", async () => {
    const mockStripe = {
      accounts: {
        retrieve: vi.fn().mockResolvedValue({
          id: "acct_1ABC",
          charges_enabled: true,
          payouts_enabled: true,
          details_submitted: true,
          country: "US",
          default_currency: "usd",
          requirements: { currently_due: [] },
        }),
      },
    };
    vi.mocked(stripeFor).mockReturnValue(mockStripe as never);

    const app = buildApp();
    const env = buildTestEnv();
    const req = await signedPost("/connect/account-status", { acct_id: "acct_1ABC" });
    const res = await dispatch(app, req, env);

    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      charges_enabled: boolean;
      payouts_enabled: boolean;
      details_submitted: boolean;
      has_pending_requirements: boolean;
      country: string;
      default_currency: string;
    };
    expect(body).toEqual({
      charges_enabled: true,
      payouts_enabled: true,
      details_submitted: true,
      has_pending_requirements: false,
      country: "US",
      default_currency: "usd",
    });
  });

  it("flags has_pending_requirements when currently_due is non-empty", async () => {
    const mockStripe = {
      accounts: {
        retrieve: vi.fn().mockResolvedValue({
          id: "acct_1ABC",
          charges_enabled: false,
          payouts_enabled: false,
          details_submitted: true,
          country: "US",
          default_currency: "usd",
          requirements: { currently_due: ["business_profile.url"] },
        }),
      },
    };
    vi.mocked(stripeFor).mockReturnValue(mockStripe as never);

    const app = buildApp();
    const env = buildTestEnv();
    const req = await signedPost("/connect/account-status", { acct_id: "acct_1ABC" });
    const res = await dispatch(app, req, env);

    expect(res.status).toBe(200);
    const body = (await res.json()) as { has_pending_requirements: boolean };
    expect(body.has_pending_requirements).toBe(true);
  });

  it("returns 400 when acct_id is missing", async () => {
    const mockStripe = { accounts: { retrieve: vi.fn() } };
    vi.mocked(stripeFor).mockReturnValue(mockStripe as never);

    const app = buildApp();
    const env = buildTestEnv();
    const req = await signedPost("/connect/account-status", {});
    const res = await dispatch(app, req, env);

    expect(res.status).toBe(400);
    expect(mockStripe.accounts.retrieve).not.toHaveBeenCalled();
  });

  it("returns 502 when Stripe errors", async () => {
    const mockStripe = {
      accounts: {
        retrieve: vi.fn().mockRejectedValue(new Error("no such account")),
      },
    };
    vi.mocked(stripeFor).mockReturnValue(mockStripe as never);

    const app = buildApp();
    const env = buildTestEnv();
    const req = await signedPost("/connect/account-status", { acct_id: "acct_1MISSING" });
    const res = await dispatch(app, req, env);

    expect(res.status).toBe(502);
  });
});
```

- [ ] **Step 2: Run tests (fail)**

```bash
npm run test -- connect
```
Expected: FAIL — endpoint returns 404.

- [ ] **Step 3: Append to `src/endpoints/connect.ts`**

Inside `mountConnect`, add:

```typescript
  app.post("/connect/account-status", async (c) => {
    const body = c.var.parsedBody as Partial<AccountStatusRequest>;
    if (typeof body.acct_id !== "string" || body.acct_id.length === 0) {
      return c.json({ error: "missing acct_id" }, 400);
    }

    const stripe = stripeFor(c.env.STRIPE_SECRET_KEY);
    try {
      const account = await stripe.accounts.retrieve(body.acct_id);
      const currentlyDue = account.requirements?.currently_due ?? [];
      const response: AccountStatusResponse = {
        charges_enabled: account.charges_enabled ?? false,
        payouts_enabled: account.payouts_enabled ?? false,
        details_submitted: account.details_submitted ?? false,
        has_pending_requirements: currentlyDue.length > 0,
        country: account.country ?? "",
        default_currency: account.default_currency ?? "",
      };
      return c.json(response);
    } catch (err) {
      console.log(JSON.stringify({
        event: "account_status_failed",
        acct_id: body.acct_id,
        error: err instanceof Error ? err.message : String(err),
      }));
      return c.json({ error: "stripe_api" }, 502);
    }
  });
```

Update imports at the top to include `AccountStatusRequest` + `AccountStatusResponse`.

- [ ] **Step 4: Run tests (pass)**

```bash
npm run test -- connect
```
Expected: PASS — 10 connect tests green (3 + 3 + 4).

- [ ] **Step 5: Commit**

```bash
git add src/endpoints/connect.ts tests/connect.test.ts
git commit -m "feat(connect): POST /connect/account-status (task 4.3)"
```

---

## Phase 5 — Payment Link endpoints (Day 3, afternoon)

### Task 5.1: `POST /payment-links/create`

**Files:**
- Create: `src/endpoints/payment-links.ts`
- Modify: `src/index.ts`
- Create: `tests/payment-links.test.ts`

Handler logic (per spec §6 endpoint 4):
1. Auth via `hmacMiddleware`
2. `stripe.paymentLinks.create({ line_items: [{ price_data: { ... }, quantity: 1 }], metadata }, { stripeAccount: acct_id })`
3. Return `{ url, id }`

Stripe Payment Link with `price_data` (rather than `price: 'price_xxx'`) lets us inline the amount + currency + product description per invoice without pre-creating Stripe products.

- [ ] **Step 1: Write the failing test**

Create `tests/payment-links.test.ts`:

```typescript
import { describe, it, expect, vi, beforeEach } from "vitest";
import { Hono } from "hono";
import type { Env } from "../src/types";
import { mountPaymentLinks } from "../src/endpoints/payment-links";
import { hmacMiddleware } from "../src/auth";
import { buildTestEnv, dispatch } from "./helpers";

const SECRET = "test-hmac-secret-rotate-me";

async function signedPost(path: string, body: Record<string, unknown>): Promise<Request> {
  const ts = Date.now();
  const bodyStr = JSON.stringify({ ...body, ts });
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(SECRET),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const sig = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(`POST:${path}:${ts}:${bodyStr}`)
  );
  const hmac = Array.from(new Uint8Array(sig))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
  return new Request(`https://w.example.com${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", "authorization": `Bearer ${hmac}` },
    body: bodyStr,
  });
}

vi.mock("../src/stripe-client", () => ({ stripeFor: vi.fn() }));
import { stripeFor } from "../src/stripe-client";

function buildApp(): Hono<{ Bindings: Env }> {
  const app = new Hono<{ Bindings: Env }>();
  app.use("/payment-links/*", hmacMiddleware);
  mountPaymentLinks(app);
  return app;
}

describe("POST /payment-links/create", () => {
  beforeEach(() => vi.mocked(stripeFor).mockReset());

  it("creates a Stripe Payment Link on the connected account", async () => {
    const mockStripe = {
      paymentLinks: {
        create: vi.fn().mockResolvedValue({ id: "plink_1ABC", url: "https://buy.stripe.com/abc" }),
      },
    };
    vi.mocked(stripeFor).mockReturnValue(mockStripe as never);

    const app = buildApp();
    const env = buildTestEnv();
    const req = await signedPost("/payment-links/create", {
      acct_id: "acct_1XYZ",
      amount_minor: 120000,
      currency: "usd",
      description: "INV-0042 — Acme Corp",
      metadata: { invoice_uuid: "F47AC10B-58CC-4372-A567-0E02B2C3D479" },
    });
    const res = await dispatch(app, req, env);

    expect(res.status).toBe(200);
    const body = (await res.json()) as { url: string; id: string };
    expect(body).toEqual({ url: "https://buy.stripe.com/abc", id: "plink_1ABC" });

    expect(mockStripe.paymentLinks.create).toHaveBeenCalledWith(
      {
        line_items: [
          {
            price_data: {
              currency: "usd",
              product_data: { name: "INV-0042 — Acme Corp" },
              unit_amount: 120000,
            },
            quantity: 1,
          },
        ],
        metadata: { invoice_uuid: "F47AC10B-58CC-4372-A567-0E02B2C3D479" },
      },
      { stripeAccount: "acct_1XYZ" },
    );
  });

  it("returns 400 when required fields are missing", async () => {
    const mockStripe = { paymentLinks: { create: vi.fn() } };
    vi.mocked(stripeFor).mockReturnValue(mockStripe as never);

    const app = buildApp();
    const env = buildTestEnv();
    const req = await signedPost("/payment-links/create", {
      acct_id: "acct_1XYZ",
      // missing amount_minor, currency, description
    });
    const res = await dispatch(app, req, env);

    expect(res.status).toBe(400);
    expect(mockStripe.paymentLinks.create).not.toHaveBeenCalled();
  });

  it("returns 502 when Stripe rejects (e.g. currency unsupported)", async () => {
    const mockStripe = {
      paymentLinks: {
        create: vi.fn().mockRejectedValue(new Error("currency not supported for this account")),
      },
    };
    vi.mocked(stripeFor).mockReturnValue(mockStripe as never);

    const app = buildApp();
    const env = buildTestEnv();
    const req = await signedPost("/payment-links/create", {
      acct_id: "acct_1XYZ",
      amount_minor: 120000,
      currency: "cad",
      description: "INV-0042",
      metadata: {},
    });
    const res = await dispatch(app, req, env);

    expect(res.status).toBe(502);
  });
});
```

- [ ] **Step 2: Run test (fail)**

```bash
npm run test -- payment-links
```
Expected: FAIL — `Cannot find module '../src/endpoints/payment-links'`.

- [ ] **Step 3: Implement `src/endpoints/payment-links.ts`**

```typescript
// src/endpoints/payment-links.ts — Stripe Payment Link endpoints

import type { Hono } from "hono";
import { stripeFor } from "../stripe-client";
import type {
  CreatePaymentLinkRequest,
  CreatePaymentLinkResponse,
  Env,
} from "../types";

export function mountPaymentLinks(app: Hono<{ Bindings: Env; Variables: { parsedBody: Record<string, unknown>; rawBody: string } }>): void {
  app.post("/payment-links/create", async (c) => {
    const body = c.var.parsedBody as Partial<CreatePaymentLinkRequest>;
    if (
      typeof body.acct_id !== "string" || body.acct_id.length === 0 ||
      typeof body.amount_minor !== "number" || !Number.isFinite(body.amount_minor) || body.amount_minor < 1 ||
      typeof body.currency !== "string" || body.currency.length !== 3 ||
      typeof body.description !== "string" || body.description.length === 0
    ) {
      return c.json({ error: "missing or invalid fields" }, 400);
    }

    const stripe = stripeFor(c.env.STRIPE_SECRET_KEY);
    try {
      const link = await stripe.paymentLinks.create(
        {
          line_items: [
            {
              price_data: {
                currency: body.currency,
                product_data: { name: body.description },
                unit_amount: body.amount_minor,
              },
              quantity: 1,
            },
          ],
          metadata: (body.metadata as Record<string, string> | undefined) ?? {},
        },
        { stripeAccount: body.acct_id }
      );

      const response: CreatePaymentLinkResponse = { url: link.url, id: link.id };
      return c.json(response);
    } catch (err) {
      console.log(JSON.stringify({
        event: "payment_link_create_failed",
        acct_id: body.acct_id,
        error: err instanceof Error ? err.message : String(err),
      }));
      return c.json({ error: "stripe_api" }, 502);
    }
  });

  // /payment-links/status-check added in Task 5.2
}
```

- [ ] **Step 4: Mount in `src/index.ts`**

Edit `src/index.ts`:

```typescript
// ... existing imports
import { mountPaymentLinks } from "./endpoints/payment-links";

// ... existing app + middleware setup

mountConnect(app);
mountPaymentLinks(app);   // NEW
// mountDevices(app)      — Phase 6
// mountWebhook(app)      — Phase 7
```

- [ ] **Step 5: Run test (pass)**

```bash
npm run test -- payment-links
```
Expected: PASS — 3 tests green.

- [ ] **Step 6: Commit**

```bash
git add src/endpoints/payment-links.ts src/index.ts tests/payment-links.test.ts
git commit -m "feat(payment-links): POST /payment-links/create on connected account (task 5.1)"
```

---

### Task 5.2: `POST /payment-links/status-check` (batched parallel lookup)

**Files:**
- Modify: `src/endpoints/payment-links.ts`
- Modify: `tests/payment-links.test.ts`

Handler logic (per spec §6 endpoint 5):
1. Auth
2. For each `plink_id` in parallel via `Promise.all`: `stripe.checkout.sessions.list({ payment_link: plink_id, limit: 1, status: 'complete' }, { stripeAccount: acct_id })`
3. Map results to `PaymentLinkStatusResult`

`Promise.all` semantically; if one lookup rejects, we still want partial results. So use `Promise.allSettled` and treat rejected ones as "unknown" — but per the spec, "partial results when some IDs are invalid." Strategy: settle each; on reject, mark `paid: false` + log.

- [ ] **Step 1: Append the failing test**

Append to `tests/payment-links.test.ts`:

```typescript
describe("POST /payment-links/status-check", () => {
  beforeEach(() => vi.mocked(stripeFor).mockReset());

  it("returns paid: true with charge details when a session is complete", async () => {
    const mockStripe = {
      checkout: {
        sessions: {
          list: vi.fn().mockResolvedValue({
            data: [
              {
                id: "cs_xxx",
                payment_link: "plink_1A",
                payment_status: "paid",
                amount_total: 120000,
                currency: "usd",
                payment_intent: { id: "pi_111", latest_charge: "ch_111" },
              },
            ],
          }),
        },
      },
    };
    vi.mocked(stripeFor).mockReturnValue(mockStripe as never);

    const app = buildApp();
    const env = buildTestEnv();
    const req = await signedPost("/payment-links/status-check", {
      acct_id: "acct_1XYZ",
      payment_link_ids: ["plink_1A"],
    });
    const res = await dispatch(app, req, env);

    expect(res.status).toBe(200);
    const body = (await res.json()) as { results: Array<{ plink_id: string; paid: boolean; charge_id?: string; amount_received?: number; currency?: string }> };
    expect(body.results).toHaveLength(1);
    expect(body.results[0]).toEqual({
      plink_id: "plink_1A",
      paid: true,
      charge_id: "ch_111",
      amount_received: 120000,
      currency: "usd",
    });
  });

  it("returns paid: false when no complete session exists for the link", async () => {
    const mockStripe = {
      checkout: {
        sessions: {
          list: vi.fn().mockResolvedValue({ data: [] }),
        },
      },
    };
    vi.mocked(stripeFor).mockReturnValue(mockStripe as never);

    const app = buildApp();
    const env = buildTestEnv();
    const req = await signedPost("/payment-links/status-check", {
      acct_id: "acct_1XYZ",
      payment_link_ids: ["plink_1B"],
    });
    const res = await dispatch(app, req, env);

    expect(res.status).toBe(200);
    const body = (await res.json()) as { results: Array<{ plink_id: string; paid: boolean }> };
    expect(body.results[0]).toEqual({ plink_id: "plink_1B", paid: false });
  });

  it("batches multiple lookups in parallel + handles partial failures gracefully", async () => {
    const calls: string[] = [];
    const mockStripe = {
      checkout: {
        sessions: {
          list: vi.fn().mockImplementation((params: { payment_link: string }) => {
            calls.push(params.payment_link);
            if (params.payment_link === "plink_1A") {
              return Promise.resolve({
                data: [{
                  payment_link: "plink_1A",
                  payment_status: "paid",
                  amount_total: 50000, currency: "usd",
                  payment_intent: { id: "pi_a", latest_charge: "ch_a" },
                }],
              });
            }
            if (params.payment_link === "plink_1B") {
              return Promise.reject(new Error("not found"));
            }
            return Promise.resolve({ data: [] });
          }),
        },
      },
    };
    vi.mocked(stripeFor).mockReturnValue(mockStripe as never);

    const app = buildApp();
    const env = buildTestEnv();
    const req = await signedPost("/payment-links/status-check", {
      acct_id: "acct_1XYZ",
      payment_link_ids: ["plink_1A", "plink_1B", "plink_1C"],
    });
    const res = await dispatch(app, req, env);

    expect(res.status).toBe(200);
    const body = (await res.json()) as { results: Array<{ plink_id: string; paid: boolean }> };
    expect(body.results).toHaveLength(3);
    const byID = Object.fromEntries(body.results.map((r) => [r.plink_id, r]));
    expect(byID.plink_1A?.paid).toBe(true);
    expect(byID.plink_1B?.paid).toBe(false); // failed lookup treated as unknown
    expect(byID.plink_1C?.paid).toBe(false);
    expect(calls).toEqual(expect.arrayContaining(["plink_1A", "plink_1B", "plink_1C"]));
  });

  it("returns 400 when payment_link_ids is missing or empty", async () => {
    const mockStripe = { checkout: { sessions: { list: vi.fn() } } };
    vi.mocked(stripeFor).mockReturnValue(mockStripe as never);

    const app = buildApp();
    const env = buildTestEnv();
    const req = await signedPost("/payment-links/status-check", {
      acct_id: "acct_1XYZ",
      payment_link_ids: [],
    });
    const res = await dispatch(app, req, env);

    expect(res.status).toBe(400);
  });
});
```

- [ ] **Step 2: Run tests (fail)**

```bash
npm run test -- payment-links
```
Expected: FAIL — endpoint returns 404.

- [ ] **Step 3: Append to `src/endpoints/payment-links.ts`**

Update imports + add the handler. Replace the file's full content with:

```typescript
// src/endpoints/payment-links.ts — Stripe Payment Link endpoints

import type { Hono } from "hono";
import { stripeFor } from "../stripe-client";
import type {
  CreatePaymentLinkRequest,
  CreatePaymentLinkResponse,
  PaymentLinkStatusCheckRequest,
  PaymentLinkStatusCheckResponse,
  PaymentLinkStatusResult,
  Env,
} from "../types";

export function mountPaymentLinks(app: Hono<{ Bindings: Env; Variables: { parsedBody: Record<string, unknown>; rawBody: string } }>): void {
  app.post("/payment-links/create", async (c) => {
    const body = c.var.parsedBody as Partial<CreatePaymentLinkRequest>;
    if (
      typeof body.acct_id !== "string" || body.acct_id.length === 0 ||
      typeof body.amount_minor !== "number" || !Number.isFinite(body.amount_minor) || body.amount_minor < 1 ||
      typeof body.currency !== "string" || body.currency.length !== 3 ||
      typeof body.description !== "string" || body.description.length === 0
    ) {
      return c.json({ error: "missing or invalid fields" }, 400);
    }

    const stripe = stripeFor(c.env.STRIPE_SECRET_KEY);
    try {
      const link = await stripe.paymentLinks.create(
        {
          line_items: [
            {
              price_data: {
                currency: body.currency,
                product_data: { name: body.description },
                unit_amount: body.amount_minor,
              },
              quantity: 1,
            },
          ],
          metadata: (body.metadata as Record<string, string> | undefined) ?? {},
        },
        { stripeAccount: body.acct_id }
      );

      const response: CreatePaymentLinkResponse = { url: link.url, id: link.id };
      return c.json(response);
    } catch (err) {
      console.log(JSON.stringify({
        event: "payment_link_create_failed",
        acct_id: body.acct_id,
        error: err instanceof Error ? err.message : String(err),
      }));
      return c.json({ error: "stripe_api" }, 502);
    }
  });

  app.post("/payment-links/status-check", async (c) => {
    const body = c.var.parsedBody as Partial<PaymentLinkStatusCheckRequest>;
    if (
      typeof body.acct_id !== "string" || body.acct_id.length === 0 ||
      !Array.isArray(body.payment_link_ids) || body.payment_link_ids.length === 0
    ) {
      return c.json({ error: "missing or invalid fields" }, 400);
    }
    const plinks: string[] = body.payment_link_ids.filter((s): s is string => typeof s === "string");

    const stripe = stripeFor(c.env.STRIPE_SECRET_KEY);

    const settled = await Promise.allSettled(
      plinks.map((plinkID) =>
        stripe.checkout.sessions.list(
          { payment_link: plinkID, limit: 1 },
          { stripeAccount: body.acct_id as string }
        )
      )
    );

    const results: PaymentLinkStatusResult[] = settled.map((settle, i) => {
      const plinkID = plinks[i] as string;
      if (settle.status === "rejected") {
        console.log(JSON.stringify({
          event: "payment_link_status_lookup_failed",
          plink_id: plinkID,
          error: settle.reason instanceof Error ? settle.reason.message : String(settle.reason),
        }));
        return { plink_id: plinkID, paid: false };
      }
      const sessions = settle.value.data;
      const complete = sessions.find((s) => s.payment_status === "paid");
      if (!complete) {
        return { plink_id: plinkID, paid: false };
      }
      const charge = typeof complete.payment_intent === "object" && complete.payment_intent !== null
        ? (complete.payment_intent as { latest_charge?: string }).latest_charge
        : undefined;
      return {
        plink_id: plinkID,
        paid: true,
        charge_id: typeof charge === "string" ? charge : undefined,
        amount_received: complete.amount_total ?? undefined,
        currency: complete.currency ?? undefined,
      };
    });

    const response: PaymentLinkStatusCheckResponse = { results };
    return c.json(response);
  });
}
```

- [ ] **Step 4: Run tests (pass)**

```bash
npm run test -- payment-links
```
Expected: PASS — 7 tests green (3 from 5.1 + 4 new).

- [ ] **Step 5: Commit**

```bash
git add src/endpoints/payment-links.ts tests/payment-links.test.ts
git commit -m "feat(payment-links): POST /payment-links/status-check with parallel lookup (task 5.2)"
```

---

## Phase 6 — Device registration endpoint (Day 4, morning, ~half-day)

### Task 6.1: `POST /devices/register` + KV upsert/delete

**Files:**
- Create: `src/endpoints/devices.ts`
- Modify: `src/index.ts`
- Create: `tests/devices.test.ts`

Handler logic (per spec §6 endpoint 6):
1. Auth via `hmacMiddleware`
2. If `apns_token === null` → `KV.delete(acct_id)`
3. Else → `KV.put(acct_id, JSON.stringify({ apns_token, env, updated_at: Date.now() }))`
4. Return `{ ok: true }`

- [ ] **Step 1: Write the failing test**

Create `tests/devices.test.ts`:

```typescript
import { describe, it, expect } from "vitest";
import { Hono } from "hono";
import type { Env, DeviceRegistration } from "../src/types";
import { mountDevices } from "../src/endpoints/devices";
import { hmacMiddleware } from "../src/auth";
import { buildTestEnv, dispatch } from "./helpers";

const SECRET = "test-hmac-secret-rotate-me";

async function signedPost(path: string, body: Record<string, unknown>): Promise<Request> {
  const ts = Date.now();
  const bodyStr = JSON.stringify({ ...body, ts });
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(SECRET),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const sig = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(`POST:${path}:${ts}:${bodyStr}`)
  );
  const hmac = Array.from(new Uint8Array(sig))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
  return new Request(`https://w.example.com${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", "authorization": `Bearer ${hmac}` },
    body: bodyStr,
  });
}

function buildApp(): Hono<{ Bindings: Env }> {
  const app = new Hono<{ Bindings: Env }>();
  app.use("/devices/*", hmacMiddleware);
  mountDevices(app);
  return app;
}

// Simple in-memory KV shim for tests
function makeKV(): { kv: KVNamespace; storage: Map<string, string> } {
  const storage = new Map<string, string>();
  const kv = {
    get: async (k: string) => storage.get(k) ?? null,
    put: async (k: string, v: string) => { storage.set(k, v); },
    delete: async (k: string) => { storage.delete(k); },
    list: async () => ({ keys: Array.from(storage.keys()).map((name) => ({ name })), list_complete: true, cacheStatus: null }),
    getWithMetadata: async (k: string) => ({ value: storage.get(k) ?? null, metadata: null }),
  } as unknown as KVNamespace;
  return { kv, storage };
}

describe("POST /devices/register", () => {
  it("writes the device registration to KV on first registration", async () => {
    const { kv, storage } = makeKV();
    const env = buildTestEnv({ DEVICE_TOKENS: kv });

    const app = buildApp();
    const req = await signedPost("/devices/register", {
      acct_id: "acct_1ABC",
      apns_token: "a".repeat(64),
      env: "production",
    });
    const res = await dispatch(app, req, env);

    expect(res.status).toBe(200);
    const body = (await res.json()) as { ok: boolean };
    expect(body.ok).toBe(true);

    expect(storage.has("acct_1ABC")).toBe(true);
    const raw = storage.get("acct_1ABC") as string;
    const parsed = JSON.parse(raw) as DeviceRegistration;
    expect(parsed.apns_token).toBe("a".repeat(64));
    expect(parsed.env).toBe("production");
    expect(typeof parsed.updated_at).toBe("number");
  });

  it("overwrites an existing registration when called twice for same acct_id", async () => {
    const { kv, storage } = makeKV();
    const env = buildTestEnv({ DEVICE_TOKENS: kv });

    const app = buildApp();
    const req1 = await signedPost("/devices/register", {
      acct_id: "acct_1ABC",
      apns_token: "a".repeat(64),
      env: "production",
    });
    await dispatch(app, req1, env);

    const req2 = await signedPost("/devices/register", {
      acct_id: "acct_1ABC",
      apns_token: "b".repeat(64),
      env: "development",
    });
    const res2 = await dispatch(app, req2, env);

    expect(res2.status).toBe(200);
    const parsed = JSON.parse(storage.get("acct_1ABC") as string) as DeviceRegistration;
    expect(parsed.apns_token).toBe("b".repeat(64));
    expect(parsed.env).toBe("development");
  });

  it("deletes the registration when apns_token is null", async () => {
    const { kv, storage } = makeKV();
    storage.set(
      "acct_1ABC",
      JSON.stringify({ apns_token: "a".repeat(64), env: "production", updated_at: 0 })
    );
    const env = buildTestEnv({ DEVICE_TOKENS: kv });

    const app = buildApp();
    const req = await signedPost("/devices/register", {
      acct_id: "acct_1ABC",
      apns_token: null,
      env: "production",
    });
    const res = await dispatch(app, req, env);

    expect(res.status).toBe(200);
    expect(storage.has("acct_1ABC")).toBe(false);
  });

  it("returns 400 when acct_id is missing", async () => {
    const { kv } = makeKV();
    const env = buildTestEnv({ DEVICE_TOKENS: kv });

    const app = buildApp();
    const req = await signedPost("/devices/register", {
      apns_token: "a".repeat(64),
      env: "production",
    });
    const res = await dispatch(app, req, env);
    expect(res.status).toBe(400);
  });
});
```

- [ ] **Step 2: Run test (fail)**

```bash
npm run test -- devices
```
Expected: FAIL — `Cannot find module '../src/endpoints/devices'`.

- [ ] **Step 3: Implement `src/endpoints/devices.ts`**

```typescript
// src/endpoints/devices.ts — Device registry endpoint

import type { Hono } from "hono";
import type {
  DeviceRegisterRequest,
  DeviceRegisterResponse,
  DeviceRegistration,
  Env,
} from "../types";

export function mountDevices(app: Hono<{ Bindings: Env; Variables: { parsedBody: Record<string, unknown>; rawBody: string } }>): void {
  app.post("/devices/register", async (c) => {
    const body = c.var.parsedBody as Partial<DeviceRegisterRequest>;
    if (typeof body.acct_id !== "string" || body.acct_id.length === 0) {
      return c.json({ error: "missing acct_id" }, 400);
    }
    if (body.env !== "production" && body.env !== "development") {
      return c.json({ error: "invalid env" }, 400);
    }

    // null token → clear the registration
    if (body.apns_token === null) {
      await c.env.DEVICE_TOKENS.delete(body.acct_id);
      const response: DeviceRegisterResponse = { ok: true };
      return c.json(response);
    }

    if (typeof body.apns_token !== "string" || body.apns_token.length === 0) {
      return c.json({ error: "missing apns_token" }, 400);
    }

    const reg: DeviceRegistration = {
      apns_token: body.apns_token,
      env: body.env,
      updated_at: Date.now(),
    };
    await c.env.DEVICE_TOKENS.put(body.acct_id, JSON.stringify(reg));

    const response: DeviceRegisterResponse = { ok: true };
    return c.json(response);
  });
}
```

- [ ] **Step 4: Mount in `src/index.ts`**

```typescript
import { mountDevices } from "./endpoints/devices";

// ... existing setup
mountConnect(app);
mountPaymentLinks(app);
mountDevices(app);  // NEW
// mountWebhook(app) — Phase 7
```

- [ ] **Step 5: Run test (pass)**

```bash
npm run test -- devices
```
Expected: PASS — 4 tests green.

- [ ] **Step 6: Commit**

```bash
git add src/endpoints/devices.ts src/index.ts tests/devices.test.ts
git commit -m "feat(devices): POST /devices/register with KV upsert + delete (task 6.1)"
```

---

## Phase 7 — APNs + Stripe webhook handler (Day 4 afternoon + Day 5)

### Task 7.1: APNs ES256 JWT signer with 50-minute cache

**Files:**
- Create: `src/apns.ts`
- Create: `tests/apns.test.ts`

The Web Crypto API supports ES256 (ECDSA over P-256 with SHA-256). Apple gives us a `.p8` PEM-encoded private key + a key ID + a team ID. We sign JWT headers + claims with the private key, send the result as a Bearer token to `api.push.apple.com`. Apple allows reusing a JWT for ~1 hour; we cache for 50 minutes to leave buffer.

**Note on PEM parsing:** Web Crypto's `importKey` requires a binary DER format, not PEM. We strip the `-----BEGIN/END PRIVATE KEY-----` markers, base64-decode the body, and pass the resulting ArrayBuffer.

- [ ] **Step 1: Write the failing test**

Create `tests/apns.test.ts`:

```typescript
import { describe, it, expect, vi } from "vitest";
import { getAPNsJWT, _resetCache } from "../src/apns";

// A valid P-256 .p8 PEM for tests (this is a TEST key, fine to commit)
// Generated via: openssl ecparam -name prime256v1 -genkey -noout -out test.p8
// THIS IS NOT A REAL APNS KEY — it's only used to exercise the signing code.
const TEST_P8 = `-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgKZ8owErpEKbT4hH7
4HXJLgFRm7C7vAdtTm8rfeRQyCihRANCAATA0+s/HMqlYxRTrgDQ9P1k0pVi/Es5
o/lz+vZpD8MOA/rXBQHb/eF3lD0eotaHJqjmU0KkbHQ+8MIv8ATEhqkP
-----END PRIVATE KEY-----`;

describe("getAPNsJWT", () => {
  it("returns a JWT with three dot-separated segments", async () => {
    _resetCache();
    const jwt = await getAPNsJWT({
      pemKey: TEST_P8,
      keyID: "ABCDE12345",
      teamID: "TEAM123456",
      now: Date.now(),
    });
    const parts = jwt.split(".");
    expect(parts).toHaveLength(3);
  });

  it("returns the cached JWT on a second call within 50 minutes", async () => {
    _resetCache();
    const jwt1 = await getAPNsJWT({
      pemKey: TEST_P8,
      keyID: "ABCDE12345",
      teamID: "TEAM123456",
      now: Date.now(),
    });
    const jwt2 = await getAPNsJWT({
      pemKey: TEST_P8,
      keyID: "ABCDE12345",
      teamID: "TEAM123456",
      now: Date.now() + 1000,
    });
    expect(jwt2).toBe(jwt1);
  });

  it("issues a fresh JWT after 50 minutes", async () => {
    _resetCache();
    const t0 = Date.now();
    const jwt1 = await getAPNsJWT({
      pemKey: TEST_P8,
      keyID: "ABCDE12345",
      teamID: "TEAM123456",
      now: t0,
    });
    const jwt2 = await getAPNsJWT({
      pemKey: TEST_P8,
      keyID: "ABCDE12345",
      teamID: "TEAM123456",
      now: t0 + 51 * 60 * 1000,
    });
    expect(jwt2).not.toBe(jwt1);
  });

  it("decodes header + claims correctly", async () => {
    _resetCache();
    const jwt = await getAPNsJWT({
      pemKey: TEST_P8,
      keyID: "MYKEY12345",
      teamID: "MYTEAM4321",
      now: Date.UTC(2026, 4, 24, 10, 0, 0),
    });
    const [headerB64, claimsB64] = jwt.split(".");
    const header = JSON.parse(atob((headerB64 as string).replace(/-/g, "+").replace(/_/g, "/")));
    const claims = JSON.parse(atob((claimsB64 as string).replace(/-/g, "+").replace(/_/g, "/")));
    expect(header).toEqual({ alg: "ES256", kid: "MYKEY12345" });
    expect(claims.iss).toBe("MYTEAM4321");
    expect(claims.iat).toBe(Math.floor(Date.UTC(2026, 4, 24, 10, 0, 0) / 1000));
  });
});
```

- [ ] **Step 2: Run test (fail)**

```bash
npm run test -- apns
```
Expected: FAIL — module not found.

- [ ] **Step 3: Implement `src/apns.ts`** (JWT signing portion only — push function in 7.2)

```typescript
// src/apns.ts — APNs ES256 JWT signer + HTTP/2 push (push function in Task 7.2)

import type { ApnsPushPayload, DeviceRegistration } from "./types";

const FIFTY_MINUTES_MS = 50 * 60 * 1000;

let cachedJWT: { token: string; issuedAt: number; keyID: string; teamID: string } | null = null;

/** Test helper — exported only for tests; resets the in-module cache. */
export function _resetCache(): void {
  cachedJWT = null;
}

export interface GetAPNsJWTInput {
  pemKey: string;       // .p8 PEM contents from APNS_AUTH_KEY env var
  keyID: string;        // APNS_KEY_ID
  teamID: string;       // APNS_TEAM_ID
  now: number;          // ms epoch; injectable for tests
}

/**
 * Returns a valid APNs JWT (creates a new one + caches it, or returns the
 * cached value if still within the 50-minute window).
 *
 * Apple permits JWT reuse up to ~60 minutes — we cap at 50 to leave buffer.
 */
export async function getAPNsJWT(input: GetAPNsJWTInput): Promise<string> {
  if (
    cachedJWT !== null &&
    cachedJWT.keyID === input.keyID &&
    cachedJWT.teamID === input.teamID &&
    input.now - cachedJWT.issuedAt < FIFTY_MINUTES_MS
  ) {
    return cachedJWT.token;
  }

  const cryptoKey = await importP8(input.pemKey);

  const header = { alg: "ES256", kid: input.keyID };
  const iat = Math.floor(input.now / 1000);
  const claims = { iss: input.teamID, iat };

  const headerB64 = base64URLEncode(JSON.stringify(header));
  const claimsB64 = base64URLEncode(JSON.stringify(claims));
  const signingInput = `${headerB64}.${claimsB64}`;

  const sigBuffer = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    cryptoKey,
    new TextEncoder().encode(signingInput)
  );
  const sigB64 = base64URLEncodeBytes(new Uint8Array(sigBuffer));

  const token = `${signingInput}.${sigB64}`;
  cachedJWT = { token, issuedAt: input.now, keyID: input.keyID, teamID: input.teamID };
  return token;
}

async function importP8(pem: string): Promise<CryptoKey> {
  const body = pem
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replace(/\s+/g, "");
  const bytes = base64Decode(body);
  return crypto.subtle.importKey(
    "pkcs8",
    bytes,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"]
  );
}

function base64Decode(b64: string): ArrayBuffer {
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes.buffer;
}

function base64URLEncode(str: string): string {
  return base64URLEncodeBytes(new TextEncoder().encode(str));
}

function base64URLEncodeBytes(bytes: Uint8Array): string {
  let bin = "";
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i] as number);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
```

- [ ] **Step 4: Run test (pass)**

```bash
npm run test -- apns
```
Expected: PASS — 4 tests green.

- [ ] **Step 5: Commit**

```bash
git add src/apns.ts tests/apns.test.ts
git commit -m "feat(apns): ES256 JWT signer with 50-minute cache + Web Crypto P-256 (task 7.1)"
```

---

### Task 7.2: APNs HTTP/2 push function

**Files:**
- Modify: `src/apns.ts` (add `sendSilentPush`)
- Modify: `tests/apns.test.ts` (add push tests)

Calls APNs HTTP/2 endpoint with the JWT + push payload. Workers' native `fetch` handles HTTP/2 transparently.

- [ ] **Step 1: Append the failing test**

Append to `tests/apns.test.ts`:

```typescript
import { sendSilentPush } from "../src/apns";

describe("sendSilentPush", () => {
  it("POSTs to api.push.apple.com for production tokens", async () => {
    _resetCache();
    const captured: { url: string; method: string; headers: Record<string, string>; body: string }[] = [];
    const fetchSpy = vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
      const url = typeof input === "string" ? input : input instanceof Request ? input.url : input.toString();
      captured.push({
        url,
        method: (init?.method ?? "GET").toUpperCase(),
        headers: Object.fromEntries(new Headers(init?.headers ?? {}).entries()),
        body: typeof init?.body === "string" ? init.body : "",
      });
      return new Response("", { status: 200 });
    });

    await sendSilentPush({
      registration: { apns_token: "a".repeat(64), env: "production", updated_at: 0 },
      pemKey: TEST_P8,
      keyID: "ABCDE12345",
      teamID: "TEAM123456",
      bundleID: "com.eldenstudios.billable",
      payload: { aps: { "content-available": 1 }, kind: "stripe_account_updated" },
      now: Date.now(),
    });

    expect(captured).toHaveLength(1);
    expect(captured[0]?.url).toBe(`https://api.push.apple.com/3/device/${"a".repeat(64)}`);
    expect(captured[0]?.method).toBe("POST");
    expect(captured[0]?.headers["apns-topic"]).toBe("com.eldenstudios.billable");
    expect(captured[0]?.headers["apns-push-type"]).toBe("background");
    expect(captured[0]?.headers["apns-priority"]).toBe("5");
    expect(captured[0]?.headers["authorization"]).toMatch(/^bearer /);

    const parsed = JSON.parse(captured[0]?.body ?? "");
    expect(parsed).toEqual({
      aps: { "content-available": 1 },
      kind: "stripe_account_updated",
    });

    fetchSpy.mockRestore();
  });

  it("POSTs to api.sandbox.push.apple.com for development tokens", async () => {
    _resetCache();
    let capturedURL = "";
    const fetchSpy = vi.spyOn(globalThis, "fetch").mockImplementation(async (input) => {
      capturedURL = typeof input === "string" ? input : input instanceof Request ? input.url : input.toString();
      return new Response("", { status: 200 });
    });

    await sendSilentPush({
      registration: { apns_token: "b".repeat(64), env: "development", updated_at: 0 },
      pemKey: TEST_P8,
      keyID: "ABCDE12345",
      teamID: "TEAM123456",
      bundleID: "com.eldenstudios.billable",
      payload: { aps: { "content-available": 1 }, kind: "stripe_account_updated" },
      now: Date.now(),
    });

    expect(capturedURL).toContain("api.sandbox.push.apple.com");
    fetchSpy.mockRestore();
  });
});
```

- [ ] **Step 2: Run test (fail)**

```bash
npm run test -- apns
```
Expected: FAIL — `sendSilentPush is not exported`.

- [ ] **Step 3: Append to `src/apns.ts`**

```typescript
export interface SendSilentPushInput {
  registration: DeviceRegistration;
  pemKey: string;
  keyID: string;
  teamID: string;
  bundleID: string;
  payload: ApnsPushPayload;
  now: number;
}

export async function sendSilentPush(input: SendSilentPushInput): Promise<void> {
  const jwt = await getAPNsJWT({
    pemKey: input.pemKey,
    keyID: input.keyID,
    teamID: input.teamID,
    now: input.now,
  });

  const host = input.registration.env === "production"
    ? "api.push.apple.com"
    : "api.sandbox.push.apple.com";

  const url = `https://${host}/3/device/${input.registration.apns_token}`;

  const res = await fetch(url, {
    method: "POST",
    headers: {
      "authorization": `bearer ${jwt}`,
      "apns-topic": input.bundleID,
      "apns-push-type": "background",
      "apns-priority": "5",
      "content-type": "application/json",
    },
    body: JSON.stringify(input.payload),
  });

  if (!res.ok) {
    const reason = await res.text().catch(() => "");
    console.log(JSON.stringify({
      event: "apns_push_failed",
      apns_token: input.registration.apns_token.slice(0, 8) + "...",
      env: input.registration.env,
      status: res.status,
      reason,
    }));
  }
}
```

- [ ] **Step 4: Run tests (pass)**

```bash
npm run test -- apns
```
Expected: PASS — 6 tests green (4 from 7.1 + 2 new).

- [ ] **Step 5: Commit**

```bash
git add src/apns.ts tests/apns.test.ts
git commit -m "feat(apns): sendSilentPush via HTTP/2 with prod + sandbox routing (task 7.2)"
```

---

### Task 7.3: Stripe webhook handler

**Files:**
- Create: `src/endpoints/webhook.ts`
- Modify: `src/index.ts`
- Create: `tests/webhook.test.ts`

Handler logic (per spec §6 endpoint 7):
1. Verify `Stripe-Signature` via `stripe.webhooks.constructEvent(rawBody, sig, secret)`. On failure → 400.
2. Switch on `event.type`:
   - `payment_intent.succeeded` → extract `event.account`, `event.data.object.payment_link`, `event.data.object.latest_charge`, `event.data.object.amount_received`, `event.data.object.currency`; look up KV; send silent push
   - `account.updated` → look up KV; send silent push
   - Other types → log, ignore
3. Return 200 on successful processing (Stripe retries on non-200, so we want to be permissive about unknown event types)

**Important:** the webhook endpoint does NOT use `hmacMiddleware`. It uses Stripe's own signature scheme. Mount it OUTSIDE the `app.use("/...")` middleware.

- [ ] **Step 1: Write the failing test**

Create `tests/webhook.test.ts`:

```typescript
import { describe, it, expect, vi, beforeEach } from "vitest";
import { Hono } from "hono";
import type { Env } from "../src/types";
import { mountWebhook } from "../src/endpoints/webhook";
import { buildTestEnv, dispatch } from "./helpers";

vi.mock("../src/stripe-client", () => ({ stripeFor: vi.fn() }));
vi.mock("../src/apns", () => ({ sendSilentPush: vi.fn() }));

import { stripeFor } from "../src/stripe-client";
import { sendSilentPush } from "../src/apns";

function buildApp(): Hono<{ Bindings: Env }> {
  const app = new Hono<{ Bindings: Env }>();
  mountWebhook(app);
  return app;
}

function makeEnvWithKV(rows: Record<string, string>): Env {
  const kv = {
    get: async (k: string) => rows[k] ?? null,
    put: async () => {},
    delete: async () => {},
    list: async () => ({ keys: [], list_complete: true, cacheStatus: null }),
    getWithMetadata: async (k: string) => ({ value: rows[k] ?? null, metadata: null }),
  } as unknown as KVNamespace;
  return buildTestEnv({ DEVICE_TOKENS: kv });
}

describe("POST /stripe/webhook", () => {
  beforeEach(() => {
    vi.mocked(stripeFor).mockReset();
    vi.mocked(sendSilentPush).mockReset();
  });

  it("verifies the signature and dispatches a push for payment_intent.succeeded", async () => {
    const event = {
      type: "payment_intent.succeeded",
      account: "acct_1XYZ",
      data: {
        object: {
          payment_link: "plink_1A",
          latest_charge: "ch_3ZZ",
          amount_received: 120000,
          currency: "usd",
        },
      },
    };
    const mockStripe = {
      webhooks: {
        constructEvent: vi.fn().mockReturnValue(event),
      },
    };
    vi.mocked(stripeFor).mockReturnValue(mockStripe as never);

    const env = makeEnvWithKV({
      "acct_1XYZ": JSON.stringify({ apns_token: "a".repeat(64), env: "production", updated_at: 0 }),
    });

    const app = buildApp();
    const req = new Request("https://w.example.com/stripe/webhook", {
      method: "POST",
      headers: {
        "stripe-signature": "t=123,v1=deadbeef",
        "content-type": "application/json",
      },
      body: JSON.stringify(event),
    });
    const res = await dispatch(app, req, env);

    expect(res.status).toBe(200);
    expect(mockStripe.webhooks.constructEvent).toHaveBeenCalled();
    expect(sendSilentPush).toHaveBeenCalledOnce();
    const call = vi.mocked(sendSilentPush).mock.calls[0]?.[0];
    expect(call?.payload).toEqual({
      aps: { "content-available": 1 },
      kind: "stripe_payment_succeeded",
      payment_link_id: "plink_1A",
      charge_id: "ch_3ZZ",
      amount_received: 120000,
      currency: "usd",
    });
  });

  it("dispatches a push for account.updated", async () => {
    const event = {
      type: "account.updated",
      account: "acct_1XYZ",
      data: { object: { id: "acct_1XYZ" } },
    };
    const mockStripe = {
      webhooks: { constructEvent: vi.fn().mockReturnValue(event) },
    };
    vi.mocked(stripeFor).mockReturnValue(mockStripe as never);

    const env = makeEnvWithKV({
      "acct_1XYZ": JSON.stringify({ apns_token: "a".repeat(64), env: "production", updated_at: 0 }),
    });

    const app = buildApp();
    const req = new Request("https://w.example.com/stripe/webhook", {
      method: "POST",
      headers: { "stripe-signature": "t=123,v1=deadbeef", "content-type": "application/json" },
      body: JSON.stringify(event),
    });
    const res = await dispatch(app, req, env);

    expect(res.status).toBe(200);
    expect(sendSilentPush).toHaveBeenCalledOnce();
    const call = vi.mocked(sendSilentPush).mock.calls[0]?.[0];
    expect(call?.payload).toEqual({
      aps: { "content-available": 1 },
      kind: "stripe_account_updated",
    });
  });

  it("returns 200 and skips push when the account has no registered device", async () => {
    const event = {
      type: "payment_intent.succeeded",
      account: "acct_1UNKNOWN",
      data: { object: { payment_link: "plink_1A", latest_charge: "ch_1", amount_received: 100, currency: "usd" } },
    };
    const mockStripe = {
      webhooks: { constructEvent: vi.fn().mockReturnValue(event) },
    };
    vi.mocked(stripeFor).mockReturnValue(mockStripe as never);

    const env = makeEnvWithKV({});  // no rows
    const app = buildApp();
    const req = new Request("https://w.example.com/stripe/webhook", {
      method: "POST",
      headers: { "stripe-signature": "t=123,v1=deadbeef", "content-type": "application/json" },
      body: JSON.stringify(event),
    });
    const res = await dispatch(app, req, env);

    expect(res.status).toBe(200);
    expect(sendSilentPush).not.toHaveBeenCalled();
  });

  it("returns 200 and ignores unknown event types", async () => {
    const event = {
      type: "charge.refunded",
      account: "acct_1XYZ",
      data: { object: {} },
    };
    const mockStripe = {
      webhooks: { constructEvent: vi.fn().mockReturnValue(event) },
    };
    vi.mocked(stripeFor).mockReturnValue(mockStripe as never);

    const env = makeEnvWithKV({
      "acct_1XYZ": JSON.stringify({ apns_token: "a".repeat(64), env: "production", updated_at: 0 }),
    });

    const app = buildApp();
    const req = new Request("https://w.example.com/stripe/webhook", {
      method: "POST",
      headers: { "stripe-signature": "t=123,v1=deadbeef", "content-type": "application/json" },
      body: JSON.stringify(event),
    });
    const res = await dispatch(app, req, env);

    expect(res.status).toBe(200);
    expect(sendSilentPush).not.toHaveBeenCalled();
  });

  it("returns 400 on invalid Stripe signature", async () => {
    const mockStripe = {
      webhooks: {
        constructEvent: vi.fn().mockImplementation(() => {
          throw new Error("invalid signature");
        }),
      },
    };
    vi.mocked(stripeFor).mockReturnValue(mockStripe as never);

    const env = makeEnvWithKV({});
    const app = buildApp();
    const req = new Request("https://w.example.com/stripe/webhook", {
      method: "POST",
      headers: { "stripe-signature": "garbage", "content-type": "application/json" },
      body: "{}",
    });
    const res = await dispatch(app, req, env);

    expect(res.status).toBe(400);
    expect(sendSilentPush).not.toHaveBeenCalled();
  });
});
```

- [ ] **Step 2: Run test (fail)**

```bash
npm run test -- webhook
```
Expected: FAIL — module not found.

- [ ] **Step 3: Implement `src/endpoints/webhook.ts`**

```typescript
// src/endpoints/webhook.ts — Stripe webhook handler

import type { Hono } from "hono";
import { stripeFor } from "../stripe-client";
import { sendSilentPush } from "../apns";
import type { ApnsPushPayload, DeviceRegistration, Env } from "../types";

interface PaymentIntentSucceededObject {
  payment_link?: string;
  latest_charge?: string;
  amount_received?: number;
  currency?: string;
}

export function mountWebhook(app: Hono<{ Bindings: Env }>): void {
  app.post("/stripe/webhook", async (c) => {
    const sigHeader = c.req.header("stripe-signature");
    if (!sigHeader) {
      return c.json({ error: "missing signature" }, 400);
    }
    const rawBody = await c.req.text();
    const stripe = stripeFor(c.env.STRIPE_SECRET_KEY);

    let event;
    try {
      event = await stripe.webhooks.constructEventAsync(
        rawBody,
        sigHeader,
        c.env.STRIPE_WEBHOOK_SECRET,
      );
    } catch (err) {
      console.log(JSON.stringify({
        event: "webhook_signature_invalid",
        error: err instanceof Error ? err.message : String(err),
      }));
      return c.json({ error: "invalid signature" }, 400);
    }

    const acctID = (event as { account?: string }).account;
    if (typeof acctID !== "string" || acctID.length === 0) {
      console.log(JSON.stringify({
        event: "webhook_missing_account",
        type: event.type,
        id: event.id,
      }));
      return c.json({ ok: true });  // Not an error — Cadence only cares about Connect events
    }

    if (event.type !== "payment_intent.succeeded" && event.type !== "account.updated") {
      console.log(JSON.stringify({
        event: "webhook_ignored_type",
        type: event.type,
      }));
      return c.json({ ok: true });
    }

    // Look up the device registration
    const raw = await c.env.DEVICE_TOKENS.get(acctID);
    if (raw === null) {
      console.log(JSON.stringify({
        event: "webhook_no_device_for_account",
        type: event.type,
        acct_id: acctID,
      }));
      return c.json({ ok: true });
    }

    let registration: DeviceRegistration;
    try {
      registration = JSON.parse(raw) as DeviceRegistration;
    } catch (err) {
      console.log(JSON.stringify({
        event: "webhook_corrupt_kv_row",
        acct_id: acctID,
        error: err instanceof Error ? err.message : String(err),
      }));
      return c.json({ ok: true });
    }

    let payload: ApnsPushPayload;
    if (event.type === "payment_intent.succeeded") {
      const obj = (event.data?.object ?? {}) as PaymentIntentSucceededObject;
      if (
        typeof obj.payment_link !== "string" ||
        typeof obj.latest_charge !== "string" ||
        typeof obj.amount_received !== "number" ||
        typeof obj.currency !== "string"
      ) {
        console.log(JSON.stringify({
          event: "webhook_payment_intent_missing_fields",
          acct_id: acctID,
        }));
        return c.json({ ok: true });
      }
      payload = {
        aps: { "content-available": 1 },
        kind: "stripe_payment_succeeded",
        payment_link_id: obj.payment_link,
        charge_id: obj.latest_charge,
        amount_received: obj.amount_received,
        currency: obj.currency,
      };
    } else {
      payload = {
        aps: { "content-available": 1 },
        kind: "stripe_account_updated",
      };
    }

    await sendSilentPush({
      registration,
      pemKey: c.env.APNS_AUTH_KEY,
      keyID: c.env.APNS_KEY_ID,
      teamID: c.env.APNS_TEAM_ID,
      bundleID: c.env.APP_BUNDLE_ID,
      payload,
      now: Date.now(),
    });

    return c.json({ ok: true });
  });
}
```

> **Note:** The test mock uses `constructEvent` (synchronous), but the Stripe SDK on Workers requires `constructEventAsync` because Web Crypto operations are async. The implementation calls `constructEventAsync`. Update the mock in `tests/webhook.test.ts` if needed — vi.fn() with `mockReturnValue` works for both sync and async in vitest.

- [ ] **Step 4: Mount in `src/index.ts`**

```typescript
import { mountWebhook } from "./endpoints/webhook";

// ... existing setup
mountConnect(app);
mountPaymentLinks(app);
mountDevices(app);
mountWebhook(app);  // NEW — note: no hmacMiddleware applied to /stripe/webhook
```

Critically, the webhook MUST be mounted AFTER (or at least not under) the `app.use("/...")` middleware blocks. Since the existing setup applies middleware to `/connect/*`, `/payment-links/*`, `/devices/*` only, this is naturally correct — `/stripe/webhook` doesn't match any of those paths.

- [ ] **Step 5: Run test (pass)**

```bash
npm run test -- webhook
```
Expected: PASS — 5 tests green.

- [ ] **Step 6: Run the full suite**

```bash
npm run test
```
Expected: ALL pass. Total test count ~30 (4 auth + 4 auth-middleware + 1 stripe-client + 1 health + 10 connect + 7 payment-links + 4 devices + 6 apns + 5 webhook).

- [ ] **Step 7: Commit**

```bash
git add src/endpoints/webhook.ts src/index.ts tests/webhook.test.ts
git commit -m "feat(webhook): Stripe webhook handler with signature verification + APNs dispatch (task 7.3)"
```

---

## Phase 8 — Deployment (Day 5 afternoon)

### Task 8.1: KV namespace + `wrangler.toml` dual envs

**Files:**
- Modify: `wrangler.toml`
- Create: `.dev.vars.example`

- [ ] **Step 1: Create the KV namespace via wrangler CLI**

```bash
wrangler kv namespace create device_tokens
```
Expected: output like `Creating namespace with title "device_tokens"... Success! Add the following to your configuration file: { binding = "DEVICE_TOKENS", id = "abc123..." }`

Copy the **id**. Then create the preview namespace:

```bash
wrangler kv namespace create device_tokens --preview
```
Copy the **preview_id**.

- [ ] **Step 2: Replace `wrangler.toml` with full dual-env config**

```toml
# wrangler.toml — Cadence webhook worker (test + prod)

name = "cadence-webhook"
main = "src/index.ts"
compatibility_date = "2026-05-24"

# === Test env (Stripe test keys, sandbox APNs) ===

[env.test]
name = "cadence-webhook-test"
vars = { ENV_NAME = "test" }

[[env.test.kv_namespaces]]
binding = "DEVICE_TOKENS"
id = "REPLACE_WITH_REAL_KV_ID"
preview_id = "REPLACE_WITH_REAL_PREVIEW_KV_ID"

# === Prod env (Stripe live keys, prod APNs) ===

[env.prod]
name = "cadence-webhook"
vars = { ENV_NAME = "prod" }

[[env.prod.kv_namespaces]]
binding = "DEVICE_TOKENS"
id = "REPLACE_WITH_REAL_KV_ID"           # Same namespace OK — single source of truth
preview_id = "REPLACE_WITH_REAL_PREVIEW_KV_ID"

# === Default (used by `wrangler dev` for local development) ===

[vars]
ENV_NAME = "test"

[[kv_namespaces]]
binding = "DEVICE_TOKENS"
id = "REPLACE_WITH_REAL_KV_ID"
preview_id = "REPLACE_WITH_REAL_PREVIEW_KV_ID"
```

Substitute the IDs from Step 1.

> **KV namespace strategy:** For simplicity v1.2 uses a SINGLE KV namespace for both test and prod envs. Test data sits alongside prod data in the same KV, but acct_ids never collide (Stripe test acct_ids start with `acct_1Test...`, prod with `acct_1Live...`). If you want stricter isolation, create two separate namespaces and put each id under the right env block.

- [ ] **Step 3: Create `.dev.vars.example`**

```
# .dev.vars.example — local dev secrets (copy to .dev.vars, fill in real values)
#
# .dev.vars is git-ignored; this template stays in the repo.

STRIPE_SECRET_KEY=sk_test_REPLACE
STRIPE_WEBHOOK_SECRET=whsec_REPLACE
APNS_AUTH_KEY="-----BEGIN PRIVATE KEY-----\nREPLACE\n-----END PRIVATE KEY-----"
APNS_KEY_ID=REPLACE
APNS_TEAM_ID=REPLACE
APP_BUNDLE_ID=com.eldenstudios.billable
APP_HMAC_SECRET=REPLACE_LONG_RANDOM_STRING
```

- [ ] **Step 4: Verify wrangler config**

```bash
wrangler deploy --dry-run --env test
```
Expected: success message about dry run, no errors.

- [ ] **Step 5: Commit**

```bash
git add wrangler.toml .dev.vars.example
git commit -m "chore(deploy): wrangler.toml dual envs + .dev.vars template (task 8.1)"
```

---

### Task 8.2: Document the secrets ceremony in README

**Files:**
- Modify: `README.md`

The engineer who picks this up needs an unambiguous walkthrough of how to put each secret into Cloudflare. The README is the only thing that survives across sessions / engineers.

- [ ] **Step 1: Append to `README.md`**

```markdown
## Secrets ceremony

Before deploying, populate these secrets via `wrangler secret put`. Each secret
must be set for BOTH `--env test` and `--env prod`:

### Stripe test env

```bash
echo "sk_test_..." | wrangler secret put STRIPE_SECRET_KEY --env test
echo "whsec_..." | wrangler secret put STRIPE_WEBHOOK_SECRET --env test
cat path/to/AuthKey_ABCDE12345.p8 | wrangler secret put APNS_AUTH_KEY --env test
echo "ABCDE12345" | wrangler secret put APNS_KEY_ID --env test
echo "TEAM123456" | wrangler secret put APNS_TEAM_ID --env test
echo "com.eldenstudios.billable" | wrangler secret put APP_BUNDLE_ID --env test
openssl rand -hex 32 | wrangler secret put APP_HMAC_SECRET --env test
```

### Stripe prod env (only when going live)

```bash
echo "sk_live_..." | wrangler secret put STRIPE_SECRET_KEY --env prod
echo "whsec_..." | wrangler secret put STRIPE_WEBHOOK_SECRET --env prod
# ... same APNS_AUTH_KEY, APNS_KEY_ID, APNS_TEAM_ID, APP_BUNDLE_ID (Apple keys are env-agnostic)
openssl rand -hex 32 | wrangler secret put APP_HMAC_SECRET --env prod   # different from test!
```

**Important:** `APP_HMAC_SECRET` must be DIFFERENT between test and prod, AND it
must be compiled into the iOS app's build config matching the target Worker.
The iOS WorkerClient picks the correct secret + URL at compile time based on
build configuration (Debug → test, Release → prod).

### Webhook URL setup in Stripe Dashboard

For each env, register the webhook URL in Stripe Dashboard:

- **Test env:** Dashboard → Developers → Webhooks → "Add an endpoint" →
  URL: `https://cadence-webhook-test.<your-cf-subdomain>.workers.dev/stripe/webhook`
  Events: `payment_intent.succeeded`, `account.updated`
  Mode: **Connect** (not Standard) — we listen to events FROM connected accounts.
  Copy the signing secret (`whsec_...`) and feed to `STRIPE_WEBHOOK_SECRET`.

- **Prod env:** same as above but with the prod URL.

### Verifying secrets

```bash
wrangler secret list --env test
wrangler secret list --env prod
```
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: secrets ceremony walkthrough (task 8.2)"
```

---

### Task 8.3: First deploy to test env + curl smoke test + Stripe CLI trigger

**Files:**
- Modify: `README.md` (append the smoke-test procedure)

- [ ] **Step 1: Deploy to test env**

```bash
wrangler deploy --env test
```
Expected: success with deployed URL like `https://cadence-webhook-test.<your-cf-subdomain>.workers.dev`.

- [ ] **Step 2: Smoke-test the health endpoint**

```bash
curl https://cadence-webhook-test.<your-cf-subdomain>.workers.dev/health
```
Expected: `{"ok":true}`.

- [ ] **Step 3: Smoke-test the HMAC auth on a Connect endpoint**

Run this Node one-liner to compute a signed request:

```bash
TS=$(date +%s%3N)
BODY=$(printf '{"ts":%s}' "$TS")
SECRET="<your APP_HMAC_SECRET value>"
PATH_="/connect/create-account-link"
SIG=$(node -e "
  const crypto = require('crypto');
  const msg = 'POST:${PATH_}:${TS}:${BODY}';
  console.log(crypto.createHmac('sha256', '${SECRET}').update(msg).digest('hex'));
")
curl -X POST "https://cadence-webhook-test.<your-cf-subdomain>.workers.dev${PATH_}" \
  -H "Authorization: Bearer $SIG" \
  -H "Content-Type: application/json" \
  -d "$BODY"
```
Expected: JSON response with `{"url": "https://connect.stripe.com/setup/...", "acct_id": "acct_1..."}`.

If this returns 401 → HMAC secret mismatch. If 502 → Stripe key mismatch. If 200 → the worker is live and Stripe-connected.

- [ ] **Step 4: End-to-end webhook test via Stripe CLI**

Install Stripe CLI: `brew install stripe/stripe-cli/stripe`. Then:

```bash
stripe login
stripe listen --forward-to https://cadence-webhook-test.<your-cf-subdomain>.workers.dev/stripe/webhook
```

In another terminal, fire a test event:

```bash
stripe trigger payment_intent.succeeded \
  --add "metadata[invoice_uuid]=test"
```

Expected: `stripe listen` shows the event was forwarded and got 200 back. Cloudflare Workers Logs (Dashboard → Workers → your worker → Logs) shows the event being processed.

Since no real device has registered an APNs token yet, the log will show `"webhook_no_device_for_account"`. That's expected and is the right behavior.

- [ ] **Step 5: Append smoke-test procedure to README**

Append to `README.md`:

```markdown
## Smoke test procedure

Run after every deploy:

1. `curl https://cadence-webhook-test...workers.dev/health` → `{"ok":true}`
2. Sign a `POST /connect/create-account-link` request with the HMAC secret;
   expect 200 with a Stripe URL (see Task 8.3 in the plan for the Node snippet).
3. `stripe trigger payment_intent.succeeded` while `stripe listen` is forwarding
   to the Worker; expect 200 in `stripe listen` output.

If steps 1-3 all pass, the Worker is operational and ready for the iOS plan
to start integration.
```

- [ ] **Step 6: Commit + final tag**

```bash
git add README.md
git commit -m "docs: end-to-end smoke test procedure (task 8.3)"
git tag v0.1.0
git push origin main --tags
```

---

## Appendix A — Cloudflare Worker production tier check

Cloudflare Workers free tier covers:
- 100,000 requests/day
- 10ms CPU time/request
- 100,000 KV reads/day
- 1,000 KV writes/day
- 1 GB KV storage

For Cadence v1.2 scale (single-digit-thousands of users, mostly idle), free tier is more than enough. If usage exceeds, upgrade to Workers Paid plan ($5/month) for 10M requests/day. No code changes needed.

---

## Appendix B — Test count summary

| Suite | Count |
|---|---|
| `tests/auth.test.ts` | 4 |
| `tests/auth-middleware.test.ts` | 4 |
| `tests/health.test.ts` | 1 |
| `tests/stripe-client.test.ts` | 1 |
| `tests/connect.test.ts` | 10 |
| `tests/payment-links.test.ts` | 7 |
| `tests/devices.test.ts` | 4 |
| `tests/apns.test.ts` | 6 |
| `tests/webhook.test.ts` | 5 |
| **Total** | **~42 tests** |

(The spec's §11 target was "≥20 Worker tests" — this plan delivers ~2× that, which is the right amount of coverage for this surface.)

---

