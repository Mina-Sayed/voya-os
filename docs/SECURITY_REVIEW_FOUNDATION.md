# Foundation Slice Security Review

**Review date:** 2026-07-21
**Scope:** Next.js application shell, fixture dashboard, domain primitives, package configuration, and browser smoke coverage.
**Out of scope:** Supabase/Auth/database implementation, financial records, approvals, AI tools, notifications, external providers, and production edge/Vercel configuration.

## Executive summary

The current foundation slice is read-only and fixture-backed. The review found no application secrets, user-controlled HTML rendering, direct DOM injection, code execution, browser token storage, redirects, network requests, route handlers, server actions, database calls, or externally loaded scripts. Baseline response headers are now centrally configured and browser-tested.

Two issues remain before any authenticated or user-generated production workflow can launch: a nonce-based CSP must be designed with the Next.js request path, and the inherited moderate PostCSS advisory needs upstream dependency monitoring. These are not bypassed by the current fixture scope.

## Remediated controls

- `next.config.ts:4-22` sets `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy: strict-origin-when-cross-origin`, and a restrictive `Permissions-Policy` on every route.
- `e2e/dashboard.spec.ts:4-8` asserts the first three headers in Chromium against the actual HTTP response.
- `src/features/dashboard/operations-dashboard.tsx` renders fixture labels through React JSX; it contains no raw HTML sink or user-controlled URL.
- `.gitignore:33-34` excludes `.env*`; the source scan found no project secret or `NEXT_PUBLIC_*` use. The lone `process.env.CI` reference in `playwright.config.ts:20` only controls local test-server reuse.
- `package-lock.json` is committed as the reproducible install artifact. CI must use `npm ci` rather than `npm install`.

## Findings

### SR-001 — CSP is not yet configured

- **Rule ID:** NEXT-CSP-001 / REACT-CSP-001
- **Severity:** Medium now; High before rendering user-generated content or enabling third-party scripts.
- **Location:** `next.config.ts:3-23`
- **Evidence:** The configured global headers do not include `Content-Security-Policy`.
- **Impact:** A future rendering or dependency mistake has a larger XSS blast radius than it would under a nonce-based CSP.
- **Required fix before live tenant data:** Implement a request-aware nonce CSP using the installed Next.js 16 content-security-policy guidance; include `frame-ancestors 'none'` in CSP and preserve the existing `X-Frame-Options: DENY` fallback. Do not use `unsafe-inline` or `unsafe-eval` as a shortcut.
- **Mitigation:** Current UI uses React’s escaping-by-default path, has no user-controlled data, no raw HTML rendering, and no external scripts.
- **False-positive note:** Vercel/CDN may add a CSP later, but none is visible in this repository and runtime response headers must be verified after deployment.

### SR-002 — Dependency audit has inherited moderate PostCSS advisories

- **Rule ID:** REACT-SUPPLY-001 / NEXT-SUPPLY-001
- **Severity:** Medium
- **Location:** `package-lock.json` via `next@16.2.10` dependency tree
- **Evidence:** `npm audit --omit=dev --audit-level=high` reports two moderate `postcss <8.5.10` findings under Next.js.
- **Impact:** A known vulnerable transitive package remains in the dependency graph and must be tracked for a safe upstream patch.
- **Required fix:** Monitor the Next.js release/advisory path, upgrade to the first compatible patched Next.js version, then rerun full lint/unit/E2E/build and audit gates.
- **Mitigation:** There are no high/critical audit findings. Do not run `npm audit fix --force`: its proposed result is a destructive downgrade to Next 9.3.3.
- **False-positive note:** The advisory applies to a bundled transitive PostCSS package; its exploitability must be reassessed against the affected Next.js release when an upstream patch is available.

## Required controls for the next implementation slice

- Supabase client/server adapters must keep the service-role key in server-only modules and never in `NEXT_PUBLIC_*` values.
- Every protected command must derive membership and `organization_id` server-side, validate input at runtime, and be covered by RLS integration tests.
- Auth cookies must be `HttpOnly`, `SameSite`, and `Secure` in production; cookie-authenticated mutations need CSRF/origin protection.
- Tenant-specific responses must not use shared static/cache paths; sensitive routes must be private/no-store as appropriate.
- PostgreSQL must enforce confirmed-booking overlap, financial/audit immutability, tenant foreign-key consistency, and approval single-use semantics.
- Add GitHub CI using `npm ci`, lint, unit, E2E, build, Snyk, Trivy filesystem/config scan, secret scanning, and migration/RLS tests once Supabase migration tooling is introduced.

## Scanner execution record

- `npm audit --omit=dev --audit-level=high`: completed; no high/critical issue, two moderate transitive PostCSS findings recorded in SR-002.
- `npx snyk test --file=package-lock.json --package-manager=npm`: executed but could not scan because this environment has no provisioned Snyk credential (`SNYK-0005`, HTTP 401). Configure `SNYK_TOKEN` as a protected GitHub/Vercel secret for CI; never commit it.
- `trivy fs --scanners vuln,secret,misconfig --severity HIGH,CRITICAL --exit-code 1 .`: cannot execute locally because Trivy is not installed. An attempted npm package invocation returned registry `404` because Trivy is distributed as its own CLI/container, not an npm package. Install/pin the official Trivy binary or action in CI before the first merge/deploy gate.
