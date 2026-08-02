# Release Readiness Completion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete the remaining honest-UI, trusted-redirect, authenticated-local-test, coverage, dependency, scanner, and browser-QA gates without inventing product policy or weakening the verified reliability boundary.

**Architecture:** Keep the Next.js/Supabase modular monolith and the existing server-owned authorization boundary. Represent unimplemented dashboard actions as disabled UI, add a small client-only mobile navigation island, centralize trusted application-origin parsing, and obtain authenticated browser evidence from an isolated local Supabase stack rather than a test-only application backdoor. Supply-chain remediation remains declarative and must prove compatibility with the full production artifact.

**Tech Stack:** Next.js 16.2+, React 19, TypeScript, Supabase SSR/local CLI/PostgreSQL 17, Vitest/Testing Library, Playwright Chromium, npm audit, Trivy.

## Global Constraints

- Preserve every unrelated dirty-tree change; stage and commit only task-owned files.
- Do not deploy, use managed Supabase, access production credentials, or enable notification delivery.
- Do not implement notification, account, approval, finance, settings, retry, retention, or provider behavior whose policy is unresolved.
- Never use `npm audit fix --force`, downgrade Next.js, or claim an unavailable scanner passed.
- Use red-green-refactor for behavior changes and fresh evidence before completion claims.
- Test fixtures contain synthetic data only and expose no test-only application route in a production build.
- Logs and test output must not expose tokens, cookies, emails, service-role keys, or raw provider/database errors.

## Execution status — 2026-08-02

- Tasks 1–3 are implemented and verified: honest dashboard/mobile/404 behavior, trusted auth origin handling, and the isolated authenticated Supabase browser fixture.
- Task 4 has focused behavioral coverage for callback token fallback, OTP failures, password-provider status handling, Supabase rate-limit-code handling, magic-link provider cooldown, role-aware navigation, mobile navigation, runtime health configuration, task/transport command failures, AI/WhatsApp command boundaries, strict timestamp parsing, development CSP behavior, and safe operational cause-code logging. The current suite is 54 files/253 tests with 94.62% statement coverage and 79.83% branch coverage; aggregate branch coverage remains below the project aspiration because preview/dashboard UI branches are not all exercised. Changed auth/redirect and command modules are above 90% statement and branch coverage except for intentionally unexecuted server-only configuration paths.
- Task 5 is complete for the current dependency graph: `npm audit --omit=dev --audit-level=high` reports zero vulnerabilities and the production build/E2E gates pass.
- Task 6 is implemented: Trivy passes locally; Snyk is explicitly `BLOCKED` without an authenticated binary and remains a CI release gate.
- Task 7 automated and visual evidence is recorded in `docs/TEST_PLAN.md` and `output/playwright/release-readiness/` (desktop/mobile transport screenshots reviewed on 2026-08-02). The ten pending migrations plus a booking-approval lint cleanup were applied to the linked Supabase project on 2026-08-02, verified by a matching migration list, and passed linked schema lint with no errors. The independent final security sign-off, managed Preview/production browser run, worker/provider runtime, Snyk CI evidence, backup/restore drill, and unresolved product policies remain open by design.

---

### Task 1: Honest dashboard controls, mobile navigation, and Arabic 404

**Files:**
- Create: `src/features/dashboard/mobile-navigation.tsx`
- Create: `src/app/not-found.tsx`
- Modify: `src/features/dashboard/operations-dashboard.tsx`
- Modify: `src/features/dashboard/operations-dashboard.test.tsx`
- Create: `src/app/not-found.test.tsx`
- Modify: `e2e/dashboard.spec.ts`

**Interfaces:**
- Produces: `MobileNavigation({ items }: { items: readonly DashboardNavigationItem[] })`
- Produces: exported `DashboardNavigationItem` with `{ label: string; href?: string; disabledReason?: string }`
- Consumes: the existing public dashboard navigation destinations only.

- [ ] **Step 1: Write failing dashboard behavior tests**

Add assertions that the four unimplemented action controls and settings are disabled, visible as “قريبًا”, and not exposed as active links; add a mobile-navigation test that opens the menu with its labelled button, exposes overview/bookings/properties/clients, closes on Escape, and retains disabled finance/settings states.

```tsx
render(<OperationsDashboard data={dashboardData} />);
expect(screen.getByRole("button", { name: "التنبيهات — قريبًا" })).toBeDisabled();
expect(screen.getByRole("button", { name: "فتح التنقل" })).toHaveAttribute("aria-expanded", "false");
await user.click(screen.getByRole("button", { name: "فتح التنقل" }));
expect(screen.getByRole("navigation", { name: "التنقل على الهاتف" })).toBeVisible();
await user.keyboard("{Escape}");
expect(screen.queryByRole("navigation", { name: "التنقل على الهاتف" })).not.toBeInTheDocument();
```

- [ ] **Step 2: Run the focused dashboard test and verify RED**

Run: `npm test -- src/features/dashboard/operations-dashboard.test.tsx`

Expected: FAIL because the current controls are enabled, settings is a dead anchor, and no mobile navigation exists.

- [ ] **Step 3: Write the failing Arabic 404 test**

```tsx
render(<NotFound />);
expect(screen.getByRole("heading", { name: "الصفحة غير موجودة" })).toBeVisible();
expect(screen.getByRole("link", { name: "العودة إلى لوحة العمليات" })).toHaveAttribute("href", "/");
```

Run: `npm test -- src/app/not-found.test.tsx`

Expected: FAIL because `src/app/not-found.tsx` does not exist.

- [ ] **Step 4: Implement the smallest honest UI**

Create a client-only `MobileNavigation` that owns only `open` state, listens for Escape while open, renders a labelled dialog-like menu without trapping focus, and closes after a destination link is selected. Export the navigation item data from the dashboard module or a small adjacent data file so desktop and mobile consume the same list.

Replace nonfunctional buttons with disabled buttons:

```tsx
<button
  aria-label="التنبيهات — قريبًا"
  className="cursor-not-allowed opacity-55"
  disabled
  title="قريبًا"
  type="button"
>
  <Bell aria-hidden="true" />
</button>
```

Render settings like the existing disabled finance item rather than `href="#الإعدادات"`. Add the Arabic not-found page with a fixed `/` link and no requested-path echo.

- [ ] **Step 5: Verify focused tests GREEN**

Run:

```bash
npm test -- src/features/dashboard/operations-dashboard.test.tsx src/app/not-found.test.tsx
npm run lint -- src/features/dashboard src/app/not-found.tsx
```

Expected: all focused tests and lint pass.

- [ ] **Step 6: Add browser assertions**

Extend `e2e/dashboard.spec.ts` to prove the desktop disabled states, open/close mobile navigation at `390×844`, protected destination redirect, Arabic 404, and absence of horizontal overflow.

- [ ] **Step 7: Commit the task-owned files**

```bash
git add src/features/dashboard/mobile-navigation.tsx src/features/dashboard/operations-dashboard.tsx \
  src/features/dashboard/operations-dashboard.test.tsx src/app/not-found.tsx \
  src/app/not-found.test.tsx e2e/dashboard.spec.ts
git commit -m "fix: make dashboard preview controls honest"
```

---

### Task 2: Trusted application origin for sign-in and callback redirects

**Files:**
- Create: `src/features/auth/application-origin.ts`
- Create: `src/features/auth/application-origin.test.ts`
- Modify: `src/app/sign-in/actions.ts`
- Modify: `src/app/auth/callback/route.ts`
- Modify: `src/app/auth/callback/route.test.ts`

**Interfaces:**
- Produces: `resolveApplicationOrigin(input: { environment: PublicEnvironment; requestUrl: string }): URL`
- Produces: `internalApplicationUrl(origin: URL, path: "/auth/callback" | "/workspace" | "/access-pending"): URL`
- Consumes: `VOYA_APP_URL`, `NODE_ENV`, and the request URL; never forwarded host or browser redirect input.

- [ ] **Step 1: Write origin-parser tests**

Cover a valid production HTTPS root origin, rejection of HTTP in production, credentials, fragments, queries, and non-root pathnames, local request-origin fallback in non-production, and missing/invalid production configuration.

```ts
expect(resolveApplicationOrigin({
  environment: { NODE_ENV: "production", VOYA_APP_URL: "https://app.voya.example" },
  requestUrl: "http://internal:3000/auth/callback",
}).origin).toBe("https://app.voya.example");
```

- [ ] **Step 2: Verify the parser test RED**

Run: `npm test -- src/features/auth/application-origin.test.ts`

Expected: FAIL because the module does not exist.

- [ ] **Step 3: Implement strict parsing**

Parse `VOYA_APP_URL`, require a root path with no credentials/search/hash, require HTTPS in production, and use `new URL(requestUrl).origin` only outside production when the configured value is absent.

- [ ] **Step 4: Write callback and sign-in integration tests**

Prove fixed internal paths use the configured production origin even when the request URL is internal, local development preserves `127.0.0.1`, and configuration failures emit only safe metadata before returning access-pending.

- [ ] **Step 5: Verify integration tests RED**

Run:

```bash
npm test -- src/features/auth/application-origin.test.ts src/app/auth/callback/route.test.ts src/features/auth/request-sign-in.test.ts
```

Expected: existing callback behavior fails the configured-origin case.

- [ ] **Step 6: Adopt the shared origin**

Use the resolver in the sign-in action’s callback URL and the auth callback’s fixed redirect helper. Do not accept a redirect destination from search parameters.

- [ ] **Step 7: Verify GREEN and production-local reproduction**

Run focused tests, then start a production server on a free loopback port with a safe local configuration and verify:

```bash
curl -sS -D - -o /dev/null http://127.0.0.1:3100/auth/callback
```

Expected: the location uses the approved application origin and the fixed `/access-pending` path.

- [ ] **Step 8: Commit task-owned files**

```bash
git add src/features/auth/application-origin.ts src/features/auth/application-origin.test.ts \
  src/app/sign-in/actions.ts src/app/auth/callback/route.ts src/app/auth/callback/route.test.ts
git commit -m "fix: validate authentication redirect origin"
```

---

### Task 3: Authenticated local Supabase browser fixture

**Files:**
- Create: `scripts/test-authenticated-browser.mjs`
- Create: `scripts/test-authenticated-browser.test.mjs`
- Create: `e2e/fixtures/local-auth.ts`
- Create: `e2e/authenticated-workspace.spec.ts`
- Modify: `playwright.config.ts`
- Modify: `package.json`
- Modify: `.gitignore` only if generated local-auth artifacts are not already ignored.

**Interfaces:**
- Produces: `npm run test:e2e:auth-local`
- Produces: Playwright fixture `authenticatedPage(fixture: "single-membership" | "multi-membership")`
- Consumes: an isolated local Supabase stack, local-only anon/service credentials obtained at runtime, and synthetic fixture IDs.

- [ ] **Step 1: Write a guarded orchestration test**

Create a Node test for the orchestration helper or expose pure guards proving it refuses non-loopback Supabase URLs and any database/project not explicitly identified as local.

```js
assert.equal(assertLocalSupabaseUrl("http://127.0.0.1:54321").hostname, "127.0.0.1");
assert.throws(() => assertLocalSupabaseUrl("https://project.supabase.co"));
```

- [ ] **Step 2: Run the guard test and verify RED**

Run: `node --test scripts/test-authenticated-browser.test.mjs`

Expected: FAIL because the guarded orchestrator does not exist.

- [ ] **Step 3: Implement the local orchestrator**

Start or reuse only the repository-local Supabase Docker project; collect local status as machine-readable output without printing secrets; apply migrations to the local stack; create synthetic auth users with the local admin API; seed two organizations, active/suspended memberships, and distinct roles; spawn Playwright with local public configuration and fixture credentials in process memory; remove synthetic users/data or stop the stack according to whether it was started by the script.

The script must reject non-loopback API/database hosts and must never invoke `supabase db push --linked`.

- [ ] **Step 4: Create Playwright authentication fixtures**

Use the real sign-in gateway or Supabase password sign-in against the local stack to obtain browser cookies. Do not add an application test-login route. Keep fixture emails/passwords synthetic and local; never write the service key to disk or test output.

- [ ] **Step 5: Add authenticated browser scenarios**

Cover:

- single membership reaches `/workspace`;
- multi-membership renders organization selection and selection persists;
- forged organization cookie fails closed;
- suspended membership cannot enter;
- forced token expiry followed by navigation refreshes the session;
- no protected response includes prerender/shared-cache markers.

- [ ] **Step 6: Run the local authenticated suite**

Run: `npm run test:e2e:auth-local`

Expected: PASS on an isolated local stack. If Docker/Supabase cannot run, record the exact environment failure; do not replace the test with mocks.

- [ ] **Step 7: Commit fixture-owned files**

```bash
git add scripts/test-authenticated-browser.mjs scripts/test-authenticated-browser.test.mjs \
  e2e/fixtures/local-auth.ts e2e/authenticated-workspace.spec.ts playwright.config.ts package.json .gitignore
git commit -m "test: add isolated authenticated browser fixture"
```

---

### Task 4: Meaningful reliability-boundary coverage

**Files:**
- Modify: `src/features/auth/workspace-context.test.ts`
- Create: `src/lib/supabase/server-auth.test.ts`
- Modify: `src/lib/supabase/proxy-client.test.ts`
- Modify: `src/app/auth/callback/route.test.ts`
- Modify: `vitest.config.ts` only if per-file thresholds can be added without hiding repository totals.

**Interfaces:**
- Consumes: the public functions already produced by the reliability remediation.
- Produces: greater than 90% statement and branch coverage for changed authentication/redirect modules, or explicit environment-only exclusions.

- [ ] **Step 1: Capture the coverage baseline**

Run:

```bash
npm run test:coverage
```

Record uncovered lines/branches for workspace context, server auth, proxy client, callback route, application origin, dashboard navigation, and Arabic 404.

- [ ] **Step 2: Add one failing behavioral test per meaningful uncovered branch**

Tests must change when production behavior changes: cookie write rejection, missing user, query failure, malformed configured origin, thrown and returned Supabase failures, multi-membership selection, and safe logging. Do not assert implementation details solely to increase line counts.

- [ ] **Step 3: Run each focused test before implementation**

Expected: each new regression fails for the intended missing behavior or exposes a genuinely unreachable branch. Remove tests that pass without exercising new behavior.

- [ ] **Step 4: Implement only behavior required by failing tests**

Do not add production branches solely for coverage. Use istanbul/v8 ignore comments only for proven runtime-generated branches and document the reason next to the line.

- [ ] **Step 5: Verify coverage**

Run: `npm run test:coverage`

Expected: changed reliability modules exceed 90% statements and branches; report the repository aggregate separately.

- [ ] **Step 6: Commit only coverage-owned tests and necessary fixes**

```bash
git add src/features/auth/workspace-context.test.ts src/lib/supabase/server-auth.test.ts \
  src/lib/supabase/proxy-client.test.ts src/app/auth/callback/route.test.ts vitest.config.ts
git commit -m "test: cover reliability boundary branches"
```

---

### Task 5: Safe PostCSS remediation

**Files:**
- Modify: `package.json`
- Modify: `package-lock.json`
- Read: `node_modules/next/dist/docs/`

**Interfaces:**
- Produces: dependency graph with no high PostCSS advisory, or an explicit blocker when no supported graph exists.
- Consumes: stable Next.js releases and npm overrides only; no forced downgrade or silent prerelease adoption.

- [ ] **Step 1: Reproduce the advisory**

Run:

```bash
npm ls next postcss --all
npm audit --omit=dev --audit-level=high
```

Expected: FAIL with the nested vulnerable PostCSS under Next 16.2.11.

- [ ] **Step 2: Check supported stable resolution**

Read the installed Next.js upgrade/deprecation documentation and current official package metadata. Prefer a stable patched Next release. Do not use a canary without a separately approved design change.

- [ ] **Step 3: Test one declarative resolution**

If a stable Next release is available, update `next` and `eslint-config-next` together. Otherwise add an exact npm override scoped to Next:

```json
{
  "overrides": {
    "next": {
      "postcss": "8.5.20"
    },
    "sharp": "0.35.3"
  }
}
```

Regenerate the lockfile with `npm install --package-lock-only` and confirm `npm ls postcss` resolves the intended copy.

- [ ] **Step 4: Verify compatibility**

Run unit/coverage, lint, build, production smoke, E2E, authenticated E2E when available, and inspect desktop/mobile CSS screenshots. If any compatibility failure occurs, revert only this task’s package/lock changes and keep the advisory as a blocker.

- [ ] **Step 5: Verify audit GREEN**

Run: `npm audit --omit=dev --audit-level=high`

Expected: exit 0 with no high advisory. Do not claim success if npm still reports the nested copy.

- [ ] **Step 6: Commit the supported dependency graph**

```bash
git add package.json package-lock.json
git commit -m "fix: remediate nested postcss advisory"
```

---

### Task 6: Reproducible local security scanning

**Files:**
- Create: `scripts/security-scan.sh`
- Modify: `package.json`
- Modify: `docs/TEST_PLAN.md`

**Interfaces:**
- Produces: `npm run scan:security`
- Consumes: pinned Trivy container image or existing binary; existing authenticated Snyk only.

- [ ] **Step 1: Write shell guard tests**

Use a small shell test or Bats-free script mode proving the scanner rejects an unpinned Trivy image, does not mount outside the repository, and treats missing Snyk as `BLOCKED`, not `PASS`.

- [ ] **Step 2: Verify guard RED**

Run: `bash scripts/security-scan.sh --self-test`

Expected: FAIL because the scanner does not exist.

- [ ] **Step 3: Implement the scanner**

Prefer an installed `trivy`; otherwise use an exact digest-pinned Trivy container with read-only repository mount and cache in a temporary directory. Run filesystem vulnerabilities, misconfiguration, and secret scanning without uploading source. Run `snyk test` only when both the binary and authentication are already present; otherwise emit a machine-readable blocked line and nonzero release-gate status.

- [ ] **Step 4: Document exact outcomes**

Update `docs/TEST_PLAN.md` with the local command, data boundary, pinned version/digest, blocked semantics, and CI expectation.

- [ ] **Step 5: Execute scanning**

Run:

```bash
npm run scan:security
```

Expected: Trivy completes locally; Snyk either completes with existing authentication or is explicitly `BLOCKED`. Remediate supported findings within this slice; do not suppress findings silently.

- [ ] **Step 6: Commit scanner files**

```bash
git add scripts/security-scan.sh package.json docs/TEST_PLAN.md
git commit -m "chore: add reproducible local security scan"
```

---

### Task 7: Final integrated verification and browser sign-off

**Files:**
- Modify: `docs/SECURITY_REVIEW_PRODUCTION_RELIABILITY_REMEDIATION.md`
- Modify: `docs/TEST_PLAN.md`
- Artifacts: `output/playwright/release-readiness/` (ignored/generated, not committed)

**Interfaces:**
- Consumes: Tasks 1–6.
- Produces: final PASS/FAIL/BLOCKED matrix and independent security review.

- [ ] **Step 1: Run fresh automated gates**

```bash
npm run test:coverage
npm run lint
npm run build
npm run test:production
npm run test:e2e
npm run test:e2e:auth-local
VOYA_DB_TEST=1 DATABASE_URL=<explicit-loopback-*_test-url> npm run test:db
npm audit --omit=dev --audit-level=high
npm run scan:security
git diff --check
```

Use a fresh disposable PostgreSQL 17 database. Never print its password.

- [ ] **Step 2: Perform manual Chromium functional QA**

Exercise with normal mouse/keyboard input:

- desktop and mobile navigation;
- all disabled “قريبًا” controls;
- Arabic 404 and return link;
- unauthenticated protected-route redirects;
- authenticated single- and multi-organization flows;
- forged/stale/suspended selection;
- refresh after token expiry;
- callback success and failure.

- [ ] **Step 3: Perform separate visual QA**

Inspect `1440×900` and `390×844`, initial and open-mobile-menu states, densest workspace tables/forms reachable with synthetic data, focus indicators, RTL mixed text, horizontal overflow, clipping, contrast, and console/network errors. Capture reviewed screenshots in `output/playwright/release-readiness/`.

- [ ] **Step 4: Update release evidence**

Record commands, exit codes, coverage, scanner versions/results, authenticated fixture evidence, residual policy exclusions, and exact blockers. Do not mark Snyk or Preview validation passed when unavailable.

- [ ] **Step 5: Run independent read-only security review**

Review callback origin trust, fixture isolation, tenant selection, session refresh, proxy caching, logs, dependency override, scanner data boundary, outbox leases/grants/concurrency, and unrelated dirty-tree preservation. Every finding requires severity, reproduction, and a regression-test proposal.

- [ ] **Step 6: Commit evidence only if every recorded claim matches fresh output**

```bash
git add docs/SECURITY_REVIEW_PRODUCTION_RELIABILITY_REMEDIATION.md docs/TEST_PLAN.md
git commit -m "docs: record release readiness evidence"
```
