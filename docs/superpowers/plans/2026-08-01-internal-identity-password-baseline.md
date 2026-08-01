# Internal Identity and Password Login Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Establish the Slice 0 baseline and add secure email/password sign-in for existing, server-provisioned Voya memberships while preserving magic-link access and tenant boundaries.

**Architecture:** Keep Supabase Auth as the identity provider and the existing Next.js Server Action as the mutation boundary. Password authentication creates a session only; the existing workspace-context service remains responsible for active membership, organization selection, and access-pending outcomes. No browser table writes, public organization bootstrap, or new production provider behavior is introduced in this slice.

**Tech Stack:** Next.js 16 App Router, React 19, TypeScript, Supabase SSR/Auth, Vitest/Testing Library, PostgreSQL integration tests, Playwright.

## Global Constraints

- Read the relevant Next.js 16 guide under `node_modules/next/dist/docs/` before changing Next.js code.
- Preserve the server-owned modular monolith, RLS, tenant-qualified relations, audit/outbox evidence, and idempotency.
- Do not implement public self-service organization creation; that remains Slice 6 in the approved program design.
- Never expose password, session, refresh token, service-role key, Supabase error payload, or membership existence across tenants.
- Every behavior change has focused unit/component coverage, an integration or route-boundary check, and a security review note.
- Preserve all unrelated dirty-tree changes and stage only files owned by this slice.

---

### Task 1: Record the Slice 0 baseline

**Files:**
- Modify: `docs/superpowers/plans/2026-07-26-release-readiness-completion.md` only if evidence status is stale
- Modify: `docs/TEST_PLAN.md` only for an exact password-auth case
- Create: `docs/SECURITY_REVIEW_PASSWORD_AUTH.md`

**Interfaces:**
- Consumes: current `npm` scripts and existing auth/context contracts.
- Produces: dated evidence and security scope for the password-auth boundary.

- [x] **Step 1: Run the baseline gates**

Run `npm test`, `npm run lint`, and `npm run test:production:unit`. Record the exact results without claiming database, browser, scanner, or production deployment evidence that was not run.

- [x] **Step 2: Inspect the existing auth boundary**

Confirm the current sign-in action only calls `signInWithOtp`, the callback exchanges a one-time code, and workspace context derives active memberships. Do not alter these files in this task.

- [x] **Step 3: Write the password-auth security review**

Document the threat boundary, generic failure behavior, session-cookie ownership, membership authorization handoff, rate-limit dependency, and residual gaps. Include reproduction commands for invalid credentials and a failing-test reference from Task 2.

---

### Task 2: Add a pure password-auth contract

**Files:**
- Create: `src/features/auth/password-sign-in.ts`
- Create: `src/features/auth/password-sign-in.test.ts`

**Interfaces:**
- Produces `PasswordSignInGateway` with `signInWithPassword(input: { email: string; password: string }): Promise<void>`.
- Produces `PasswordSignInResult` with `status: "signed_in" | "invalid_credentials" | "rate_limited" | "retry"`.
- Produces `requestPasswordSignIn(input: { email: string; password: string; gateway: PasswordSignInGateway }): Promise<PasswordSignInResult>`.

- [x] **Step 1: Write the failing tests**

```ts
test("normalizes email and forwards credentials without returning secrets", async () => {
  const calls: Array<{ email: string; password: string }> = [];
  const result = await requestPasswordSignIn({
    email: "  MINA@example.com ",
    password: "correct horse battery staple",
    gateway: { signInWithPassword: async (input) => { calls.push(input); } },
  });

  expect(result).toEqual({ status: "signed_in" });
  expect(calls).toEqual([{ email: "mina@example.com", password: "correct horse battery staple" }]);
  expect(JSON.stringify(result)).not.toContain("correct horse");
});

test("maps invalid credentials and rate limits to safe statuses", async () => {
  const invalid = await requestPasswordSignIn({
    email: "mina@example.com", password: "wrong",
    gateway: { signInWithPassword: async () => { throw Object.assign(new Error("bad"), { status: 400 }); } },
  });
  const limited = await requestPasswordSignIn({
    email: "mina@example.com", password: "wrong",
    gateway: { signInWithPassword: async () => { throw Object.assign(new Error("slow"), { status: 429 }); } },
  });

  expect(invalid).toEqual({ status: "invalid_credentials" });
  expect(limited).toEqual({ status: "rate_limited" });
});
```

- [x] **Step 2: Run the focused test to verify RED**

Run: `npm test -- src/features/auth/password-sign-in.test.ts`

Expected: FAIL because the password-auth module does not exist.

- [x] **Step 3: Implement the pure contract**

Normalize and validate the email with the existing auth convention. Reject empty credentials as `invalid_credentials`; map Supabase status `400` to `invalid_credentials`, `429` to `rate_limited`, and all other failures to `retry`. Never include the password or provider error in the result.

- [x] **Step 4: Run the focused test to verify GREEN**

Run: `npm test -- src/features/auth/password-sign-in.test.ts`.

Expected: all password contract tests pass.

---

### Task 3: Add the server-owned password sign-in action

**Files:**
- Modify: `src/lib/supabase/server-auth.ts`
- Modify: `src/app/sign-in/actions.ts`
- Create: `src/app/sign-in/actions.test.ts`

**Interfaces:**
- Produces `createServerPasswordGateway(): Promise<PasswordSignInGateway>`.
- Produces `signInWithPasswordAction(email: string, password: string): Promise<PasswordSignInResult | { status: "unavailable" }>`.
- Consumes the existing `createServerSupabaseClient()` cookie adapter and `requestPasswordSignIn()`.

- [x] **Step 1: Write the failing action tests**

Mock the gateway and configuration boundary. Prove normalized credentials reach `auth.signInWithPassword`, invalid credentials return a generic status, configuration failure returns `unavailable`, and the action never serializes an Auth error or password.

- [x] **Step 2: Run the focused action test to verify RED**

Run: `npm test -- src/app/sign-in/actions.test.ts`.

Expected: FAIL because the password gateway/action does not exist.

- [x] **Step 3: Implement the gateway and action**

Use `client.auth.signInWithPassword({ email, password })`. Keep cookie writes in the existing Server Action-compatible Supabase adapter. Catch configuration errors separately and map all provider failures through the pure contract. Do not query or return organization data from the sign-in form; `/workspace` remains the authorization and selection boundary.

- [x] **Step 4: Run focused auth tests**

Run:

```bash
npm test -- src/features/auth/password-sign-in.test.ts src/app/sign-in/actions.test.ts src/features/auth/sign-in-form.test.tsx src/app/auth/callback/route.test.ts
```

Expected: all focused auth tests pass.

---

### Task 4: Add the password UI while preserving magic links

**Files:**
- Create: `src/features/auth/password-sign-in-form.tsx`
- Create: `src/features/auth/password-sign-in-form.test.tsx`
- Modify: `src/app/sign-in/page.tsx`

**Interfaces:**
- Produces `PasswordSignInForm({ configured, onSignIn })` with accessible email/password fields, pending state, generic Arabic feedback, and a link to the existing magic-link form.
- Consumes `signInWithPasswordAction` and redirects to `/workspace` only after the Server Action succeeds.

- [x] **Step 1: Write failing component tests**

Cover required email/password fields, password masking, disabled submit while pending, generic invalid-credential feedback, rate-limit feedback, and that the magic-link option remains discoverable.

- [x] **Step 2: Run component tests to verify RED**

Run: `npm test -- src/features/auth/password-sign-in-form.test.tsx`.

Expected: FAIL because the component does not exist.

- [x] **Step 3: Implement the component and page composition**

Keep the existing Design C visual language and Arabic RTL. Use `autoComplete="email"` and `autoComplete="current-password"`; never echo or log the password. Use a client-side `window.location.assign("/workspace")` only after the server action returns `signed_in`, allowing the workspace context to select one membership or show the organization selector. Keep magic-link sign-in as a secondary route for recovery and environments where password sign-in is disabled.

- [x] **Step 4: Verify UI tests and lint**

Run:

```bash
npm test -- src/features/auth/password-sign-in-form.test.tsx src/features/auth/sign-in-form.test.tsx
npm run lint
```

Expected: focused tests and lint pass.

---

### Task 5: Exercise the real boundary and complete review evidence

**Files:**
- Modify: `e2e/sign-in.spec.ts`
- Modify: `e2e/authenticated-workspace.spec.ts` only if the existing fixture can exercise password sign-in
- Modify: `docs/TEST_PLAN.md`
- Modify: `docs/SECURITY_REVIEW_PASSWORD_AUTH.md`

**Interfaces:**
- Produces: browser evidence for valid, invalid, signed-out, and membership-pending outcomes.
- Consumes: an explicitly disposable local Supabase/Auth environment; no production credentials.

- [x] **Step 1: Add browser regression cases**

Exercise the real sign-in page with synthetic local credentials. Assert invalid credentials stay on sign-in with generic Arabic feedback, valid credentials reach `/workspace`, and a valid Auth user without an active membership reaches `/access-pending` without organization disclosure.

- [x] **Step 2: Run the browser test in a disposable environment**

Run: `npm run test:e2e:auth-local` only when the local Supabase stack is explicitly available. If it is unavailable, record `BLOCKED`; do not replace it with a test-only login route or a production account.

- [x] **Step 3: Run integration and release checks**

Run `npm run test:db`, `npm run test:e2e`, `npm run test:coverage`, `npm run build`, `npm run test:production`, `npm audit --omit=dev --audit-level=high`, and `npm run scan:security`. Report each unavailable external scanner or database environment as blocked.

- [x] **Step 4: Perform the security review**

Verify no password/token/provider error appears in logs or UI, session cookies are written only by Supabase SSR, membership enforcement remains server-side, and no browser/model organization input was added. Record reproduction, tests, residual rate-limit and email-confirmation dependencies, and rollback (disable password UI while keeping magic links).

- [ ] **Step 5: Commit only the completed slice**

```bash
git add src/features/auth/password-sign-in.ts src/features/auth/password-sign-in.test.ts \
  src/lib/supabase/server-auth.ts src/app/sign-in/actions.ts src/app/sign-in/actions.test.ts \
  src/features/auth/password-sign-in-form.tsx src/features/auth/password-sign-in-form.test.tsx \
  src/app/sign-in/page.tsx e2e/sign-in.spec.ts docs/TEST_PLAN.md \
  docs/SECURITY_REVIEW_PASSWORD_AUTH.md docs/superpowers/plans/2026-08-01-internal-identity-password-baseline.md
git commit -m "feat: add server-owned password sign-in"
```

The commit is allowed only after the required code tests, integration evidence, lint, build, scanner result, and security review are recorded.

## Verification evidence (2026-08-01)

- `npm test`: 39 files, 139 tests passed.
- `npm run test:coverage`: 87.58% statements, 80.04% branches, 97.69% functions.
- `npm run lint`, `npm run build`, `npm run test:production`, and `npm run test:production:unit`: passed; all `/workspace/*` routes remain dynamic and protected responses are request-time.
- `npm run test:e2e`: 6 passed with a sentinel configuration that cannot load `.env.local` provider values.
- `VOYA_AUTH_E2E_DISPOSABLE=1 npm run test:e2e:auth-local`: 6 passed against the disposable local Supabase/Auth stack, including real password sign-in and refresh.
- `VOYA_DB_TEST=1 DATABASE_URL=postgresql://.../voya_os_auth_e2e_test npm run test:db`: passed against a separate local PostgreSQL database after applying all migrations and concurrency/RLS assertions.
- `npm audit --omit=dev --audit-level=high`: 0 vulnerabilities.
- `npm run scan:security`: Trivy passed with zero High/Critical findings; overall status is `BLOCKED` because the required Snyk binary is unavailable.
- `git diff --check`: passed. No production deployment or remote database mutation was performed.
