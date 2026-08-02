# Production Reliability Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the confirmed production authentication/cache blocker and make tenant selection, repeated commands, outbox leases, and operational failures safe and testable.

**Architecture:** Keep the Next.js/Supabase modular monolith. Add a request-time workspace-context port shared by pages and actions, maintain Supabase sessions in a Next.js 16 proxy, validate an organization-selection cookie against current memberships, and repair outbox claiming with an additive migration.

**Tech Stack:** Next.js 16.2, React 19, TypeScript, Supabase SSR/PostgreSQL, Vitest/Testing Library, Playwright, Node.js production smoke scripts.

## Global Constraints

- Preserve browser-write deny-by-default and PostgreSQL tenant/role authorization.
- Do not invent finance, approval, retention, retry-limit, or provider policy.
- Never log tokens, cookies, emails, raw provider/database messages, payloads, or customer data.
- Use test-first red-green-refactor for every behavioral change.
- Preserve unrelated working-tree changes and commit only task-owned files.

## Current execution status — 2026-08-02

The implementation steps below are the original execution script; this status is the authoritative checkpoint for the isolated release branch:

- Tasks 1–4 are implemented and verified: request-time auth/proxy, shared workspace and organization context, safe operational logging, and rotating idempotency keys.
- Task 5 is implemented and locally verified: recoverable outbox leases, narrow worker grants, SQL lifecycle assertions, and the extension-schema parity checks used by Supabase.
- Task 6 is locally complete: production rendering, unit/coverage, disposable DB, public/authenticated browser, lint, build, audit, Trivy, and visual QA evidence are recorded. The ten pending managed migrations plus the booking-approval lint cleanup were applied to the linked Supabase project on 2026-08-02 and re-listed as matching; linked schema lint now reports no errors. Snyk, verified Auth/SMTP and Preview smoke, backup/restore evidence, and provider-worker policy remain external release gates.
- Do not mark this plan's historical checkboxes as evidence of a managed release; use [`docs/RELEASE_RUNBOOK.md`](../../RELEASE_RUNBOOK.md) for the remaining go/no-go steps.

---

### Task 1: Production request-time authentication regression

**Files:**
- Create: `scripts/test-production-auth-rendering.mjs`
- Modify: `package.json`
- Create: `src/proxy.ts`
- Create: `src/lib/supabase/proxy-client.ts`
- Test: `src/lib/supabase/proxy-client.test.ts`

**Interfaces:**
- Produces: `refreshSupabaseSession(request: NextRequest): Promise<NextResponse>` and the exported Next.js `proxy` function.

- [ ] Add a production smoke script that starts `.next` on an unused port, requests `/workspace` with and without a cookie, and fails if either response contains `x-nextjs-prerender`, `x-nextjs-cache: HIT`, or shared-cache `s-maxage`.
- [ ] Run `npm run build && node scripts/test-production-auth-rendering.mjs` and verify it fails on the cached prerendered redirect.
- [ ] Add proxy-client unit tests proving refreshed cookies are copied to both the forwarded request and response, while raw errors are not returned.
- [ ] Implement the Supabase SSR refresh adapter and `src/proxy.ts` matcher excluding `_next/static`, `_next/image`, favicon, and common static files.
- [ ] Run the focused unit tests; request-time rendering becomes green after Task 2 adds `connection()`.

### Task 2: Trusted workspace and organization context

**Files:**
- Create: `src/features/auth/workspace-context.ts`
- Create: `src/features/auth/workspace-context.test.ts`
- Create: `src/lib/observability/operational-error.ts`
- Create: `src/lib/observability/operational-error.test.ts`
- Create: `src/app/workspace/actions.ts`
- Modify: `src/app/workspace/page.tsx`
- Modify: `src/app/auth/callback/route.ts`

**Interfaces:**
- Produces: `resolveWorkspaceContext(memberships, selectedOrganizationId)`, `loadWorkspaceContext()`, `WorkspaceContextResult`, `selectOrganizationAction(formData)`, and `reportOperationalError(input)`.

- [ ] Write failing pure tests for no membership, one membership, valid selected membership, multiple memberships requiring selection, suspended/foreign selection rejection, and membership-query failure propagation.
- [ ] Write failing tests proving operational logging emits only operation, request ID, safe code, and outcome.
- [ ] Implement the pure resolver, then the request-time loader using `connection()`, `auth.getUser()`, a complete active-membership query, and `voya-organization-id` cookie validation.
- [ ] Implement the secure organization-selection action and render the chooser on `/workspace`; make the callback send any active member to `/workspace`.
- [ ] Run focused tests, then `npm run build && node scripts/test-production-auth-rendering.mjs`; verify workspace responses are request-time and private/no-store.

### Task 3: Adopt shared context across workspace reads and commands

**Files:**
- Modify: `src/app/workspace/{activity,approvals,availability,bookings,clients,leads,notifications,properties,property-owners}/page.tsx`
- Modify: `src/app/workspace/{availability,bookings,clients,leads,notifications,properties,property-owners}/actions.ts`
- Test: existing action/page tests plus `src/features/auth/workspace-context.test.ts`

**Interfaces:**
- Consumes: `loadWorkspaceContext()` and `reportOperationalError()` from Task 2.

- [ ] Add failing tests for dependency-error distinction and selection-required behavior used by pages/actions.
- [ ] Replace duplicated `getUser`/membership queries with the shared context; map signed-out, pending, selection-required, forbidden, and unavailable outcomes consistently.
- [ ] Ensure RPC failures are logged with safe codes and request IDs while Arabic user messages remain generic.
- [ ] Run all unit tests and lint.

### Task 4: Repeatable idempotent forms

**Files:**
- Create: `src/features/shared/use-command-form.ts`
- Create: `src/features/shared/use-command-form.test.tsx`
- Modify: six create forms under `src/features/{availability,bookings,clients,leads,properties,property-owners}`
- Modify: their existing component tests.

**Interfaces:**
- Produces: `useCommandForm(state)` returning `{ formRef, idempotencyKey }`; the key rotates and the form resets only for each new success result object.

- [ ] Write failing hook/component tests proving retry/invalid results retain the key and two consecutive successful submissions use different keys.
- [ ] Implement the hook with a handled-result ref, form ref, and `crypto.randomUUID()` rotation after success.
- [ ] Adopt it in all six forms and remove one-time `useState` keys.
- [ ] Run focused tests and the complete unit suite.

### Task 5: Recoverable outbox leases and narrow worker capability

**Files:**
- Create: `supabase/migrations/20260722001900_outbox_lease_recovery.sql`
- Modify: `supabase/tests/outbox_foundation.sql`
- Modify: `scripts/test-database-foundation.mjs` only if the new test is not already executed by its glob/list.
- Create: `docs/adr/ADR-003-production-auth-context-and-outbox-recovery.md`
- Create: `docs/SECURITY_REVIEW_PRODUCTION_RELIABILITY_REMEDIATION.md`

**Interfaces:**
- Produces: replacement `public.claim_outbox_events(text, integer, integer)` and NOLOGIN role `voya_outbox_worker` with schema usage and function execution only.

- [ ] Extend SQL tests first: an expired processing lease is reclaimed exactly once, an active lease is not stolen, authenticated cannot execute, and the worker role can execute without direct table privileges.
- [ ] Run `npm run test:db` and verify the new assertions fail when a guarded local test database is available; otherwise record the explicit environment blocker.
- [ ] Add the migration using `FOR UPDATE SKIP LOCKED`, eligibility for due pending/retry rows or expired processing rows, and explicit grants/revokes.
- [ ] Re-run the database suite when available and inspect the migration with `supabase db push --dry-run` only if linked credentials are safe and the command cannot expose secrets.
- [ ] Record the architecture decision and security review, including disabled production delivery until completion/retry/dead-letter policy exists.

### Task 6: Production verification and release evidence

**Files:**
- Modify: `e2e/access-pending.spec.ts`
- Modify: `docs/TEST_PLAN.md`
- Modify: `README.md` only where it does not overlap unrelated user edits; otherwise leave it untouched and report the conflict.

**Interfaces:**
- Consumes all prior task outputs.

- [ ] Add E2E assertions for organization-selection routing where a deterministic fixture is possible; do not fake an authenticated production claim.
- [ ] Update the test plan with production-build cache/session-refresh and outbox-expiry cases.
- [ ] Run fresh gates: `npm run test:coverage`, `npm run test:db`, `npm run test:e2e`, `npm run lint`, `npm run build`, `node scripts/test-production-auth-rendering.mjs`, and `npm audit --omit=dev --audit-level=high`.
- [ ] Run Trivy/Snyk if installed; otherwise report them unavailable without claiming a clean scan.
- [ ] Review `git diff --check`, verify no unrelated files were changed, and report any blocked database/authenticated-fixture evidence precisely.
