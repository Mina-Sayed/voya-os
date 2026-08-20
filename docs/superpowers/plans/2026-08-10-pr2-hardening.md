# PR #2 Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the self-service authentication, tenancy bootstrap, PostgreSQL migrations, idempotent commands, and release checks safe and reproducible before PR #2 can merge.

**Architecture:** Keep browser authentication on the publishable Supabase client, but move the application-owned rate-limit RPC behind a server-only service-role client and bind its bucket to a trusted request address plus normalized email. Enforce MFA at the request proxy and provide a browser TOTP challenge page. Add forward-only SQL hardening for existing production functions, while making fresh restores and local CI deterministic.

**Tech Stack:** Next.js App Router 16, React 19, Supabase SSR/JS, PostgreSQL migrations, Vitest, Playwright, GitHub Actions.

## Global Constraints

- Do not expose `SUPABASE_SERVICE_ROLE_KEY` to browser bundles or Playwright page processes.
- Do not modify or rewrite migrations that may already be applied remotely; add forward-only migrations for production schema/function corrections.
- Bootstrap only authenticated users with a confirmed email and no prior membership of any status.
- An enrolled MFA user must reach AAL2 before any protected workspace route is rendered.
- Every behavioral fix must have a regression test written and observed failing before its implementation.
- Do not commit, push, merge, deploy, or post GitHub comments in this execution.

---

### Task 1: Protect the server-owned authentication limiter

**Files:**
- Modify: `src/lib/supabase/server-auth.ts`
- Modify: `src/app/sign-in/page.tsx`
- Modify: `src/features/auth/password-sign-in.ts`
- Modify: `src/features/auth/password-sign-in-form.tsx`
- Modify: `src/features/auth/sign-in-form.tsx`
- Test: `src/lib/supabase/server-auth.test.ts`
- Test: `src/features/auth/password-sign-in.test.ts`
- Test: `src/features/auth/password-sign-in-form.test.tsx`
- Test: `src/features/auth/sign-in-form.test.tsx`

**Interfaces:**
- The server limiter accepts `scope`, normalized email, and a trusted request address; it calls `consume_auth_rate_limit` through a client created with `SUPABASE_SERVICE_ROLE_KEY`.
- Password outcomes include `access_pending` in addition to the existing safe statuses.

- [x] Write tests proving the limiter uses the server-only client, includes the request address in the digest, and does not use the cookie-bound publishable client for the RPC.
- [x] Write tests for suspended access, post-authentication dependency failure cleanup, rejected form promises, and the 900-second retry contract.
- [x] Run the focused tests and confirm the new assertions fail against the current implementation.
- [x] Implement the smallest server-only limiter and safe outcome handling.
- [x] Align UI cooldown with the database policy and restore submitting state in `finally`/rejection paths.
- [x] Run the focused tests again, then the auth test group.

### Task 2: Enforce MFA and prevent suspended-user bootstrap

**Files:**
- Modify: `src/lib/supabase/proxy-client.ts`
- Modify: `src/proxy.ts`
- Create: `src/lib/supabase/browser-client.ts`
- Create: `src/features/auth/mfa-challenge.tsx`
- Create: `src/features/auth/mfa-challenge.test.tsx`
- Create: `src/app/mfa/page.tsx`
- Modify: `src/features/auth/workspace-context.ts`
- Modify: `src/app/auth/callback/route.ts`
- Modify: `src/lib/supabase/server-auth.ts`
- Test: `src/lib/supabase/server-auth.test.ts`
- Test: `src/lib/supabase/proxy-client.test.ts`
- Test: `src/features/auth/workspace-context.test.ts`
- Test: `src/app/auth/callback/route.test.ts`

**Interfaces:**
- Protected requests with `currentLevel !== "aal2"` and `nextLevel === "aal2"` redirect to `/mfa`; `/mfa` remains public to the session but is outside the protected matcher branch.
- Membership bootstrap checks all memberships, not only active memberships, and returns `access_pending` for an existing suspended/pending user.

- [x] Add failing AAL1→AAL2 proxy/context tests and a client challenge test for factor listing, challenge, verify, and retry errors.
- [x] Add failing callback/password tests for an existing suspended membership and for a confirmed-email check.
- [x] Run those tests to verify the failures are behavioral.
- [x] Implement proxy enforcement, TOTP challenge UI, all-membership lookup, and a fail-closed bootstrap response.
- [x] Run the focused auth tests and verify no protected route bypasses the central proxy.

### Task 3: Add forward-only PostgreSQL hardening

**Files:**
- Create via `supabase migration new`: `supabase/migrations/20260810000100_harden_auth_bootstrap_and_command_reliability.sql`
- Modify: `supabase/tests/bootstrap_auth.sql`
- Modify: `supabase/tests/auth_rate_limit_policy.sql`
- Modify: `supabase/tests/tenancy_booking_foundation.sql`
- Modify: `scripts/test-database-foundation.mjs`
- Test: `supabase/tests/auth_bootstrap_security.sql`
- Test: `supabase/tests/command_idempotency.sql`

**Interfaces:**
- Final limiter privileges: `service_role` only; `anon` and `authenticated` cannot execute it.
- `bootstrap_personal_workspace` rejects a missing confirmed email and any existing membership.
- Final command functions normalize idempotency keys once, use `INSERT ... ON CONFLICT DO NOTHING`, then compare/fetch the winner.
- The local migration harness invokes `psql --single-transaction` for each migration file.

- [x] Add failing SQL assertions for role creation on fresh restore, pgcrypto in `extensions`, anonymous limiter denial, unconfirmed bootstrap denial, suspended bootstrap denial, normalized retry, and concurrent idempotency winners.
- [x] Run the database suite and confirm the tests expose the current failures.
- [x] Create the forward-only migration with role/extension setup, fixed grants, bootstrap invariants, lock-order correction, and atomic idempotent command bodies.
- [x] Make the harness transactional and ensure the test shim does not pre-create the worker role.
- [ ] Run the full database foundation suite and inspect advisor output (blocked here: no `psql`, PostgreSQL service, or usable Supabase CLI environment).

### Task 4: Reconcile browser quality coverage and deployment configuration

**Files:**
- Modify: `e2e/dashboard.spec.ts`
- Modify: `e2e/sign-in.spec.ts`
- Modify: `e2e/access-pending.spec.ts`
- Modify: `scripts/test-authenticated-browser.mjs`
- Modify: `scripts/test-authenticated-browser.test.mjs`
- Modify: `README.md`
- Modify: `docs/SECURITY_REVIEW_AUTH_BOUNDARY.md`
- Modify: `.github/workflows/quality.yml` to keep every required verification command fail-closed

- [x] Update stale route/copy expectations and add an authenticated MFA checkpoint without weakening protected-route assertions.
- [x] Pass the local service key only to the isolated Next server, never to Playwright page code.
- [x] Document required Vercel server secret, Supabase native Auth limits, CAPTCHA, and per-environment `VOYA_APP_URL`.
- [x] Run the browser harness unit tests; live browser execution remains environment-blocked because Chromium is not installed.

### Task 5: Integrated verification and handoff

- [x] Run `npm test`, `npm run lint`, `npm run build`, `npm audit --omit=dev --audit-level=high`, and `git diff --check`.
- [ ] Run live `npm run test:db`, `npm run test:e2e`, and Supabase advisors (blocked by missing local PostgreSQL/`psql`, Supabase CLI environment, and Chromium; static harness and Playwright listing checks pass).
- [x] Review the complete diff, verify no production secrets/artifacts are tracked, and record environment-only prerequisites.
- [x] Report changed files, test evidence, remaining deployment steps, and that no push/merge/deploy occurred.
