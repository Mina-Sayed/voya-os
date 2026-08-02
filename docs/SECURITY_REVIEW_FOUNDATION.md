# Foundation Slice Security Review

**Review date:** 2026-07-21
**Scope:** Next.js application shell, fixture dashboard, domain primitives, package configuration, and browser smoke coverage.
**Out of scope:** Supabase/Auth/database implementation, financial records, approvals, AI tools, notifications, external providers, and production edge/Vercel configuration.

## Executive summary

The current foundation slice is read-only and fixture-backed. The review found no application secrets, user-controlled HTML rendering, direct DOM injection, code execution, browser token storage, redirects, network requests, route handlers, server actions, database calls, or externally loaded scripts. Baseline response headers are now centrally configured and browser-tested.

The earlier CSP finding is remediated in the current branch with a request-aware nonce policy and dynamic rendering. The current local dependency audit reports no high/critical vulnerabilities; managed environment configuration and authenticated provider verification remain outside this repository.

## Remediated controls

- `next.config.ts:4-22` sets `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy: strict-origin-when-cross-origin`, and a restrictive `Permissions-Policy` on every route.
- `e2e/dashboard.spec.ts:4-8` asserts the first three headers in Chromium against the actual HTTP response.
- `src/features/dashboard/operations-dashboard.tsx` renders fixture labels through React JSX; it contains no raw HTML sink or user-controlled URL.
- `.gitignore:33-34` excludes `.env*`; the source scan found no project secret or `NEXT_PUBLIC_*` use. The lone `process.env.CI` reference in `playwright.config.ts:20` only controls local test-server reuse.
- `package-lock.json` is committed as the reproducible install artifact. CI must use `npm ci` rather than `npm install`.

## Findings

### SR-001 — CSP was previously missing (remediated)

- **Rule ID:** NEXT-CSP-001 / REACT-CSP-001
- **Status:** Remediated on 2026-08-02.
- **Location:** `src/proxy.ts`, `src/lib/security/content-security-policy.ts`, `src/app/layout.tsx`.
- **Evidence:** `npm run test:production` and the public/authenticated browser suites verify nonce CSP, no unsafe inline/eval, request-time rendering, and the existing `X-Frame-Options: DENY` fallback.
- **Residual:** The managed deployment must still be checked for CDN/header rewriting.

### SR-002 — Dependency audit status

- **Rule ID:** REACT-SUPPLY-001 / NEXT-SUPPLY-001
- **Status:** The previously recorded moderate advisory is no longer present in the current lockfile audit.
- **Evidence:** `npm audit --omit=dev --audit-level=high` completed with zero vulnerabilities on 2026-08-02.
- **Required follow-up:** Keep the audit in CI and reassess after every Next.js upgrade. Do not use `npm audit fix --force`.

## Required controls for the next implementation slice

- Supabase client/server adapters must keep the service-role key in server-only modules and never in `NEXT_PUBLIC_*` values.
- Every protected command must derive membership and `organization_id` server-side, validate input at runtime, and be covered by RLS integration tests.
- Auth cookies must be `HttpOnly`, `SameSite`, and `Secure` in production; cookie-authenticated mutations need CSRF/origin protection.
- Tenant-specific responses must not use shared static/cache paths; sensitive routes must be private/no-store as appropriate.
- PostgreSQL must enforce confirmed-booking overlap, financial/audit immutability, tenant foreign-key consistency, and approval single-use semantics.
- Add GitHub CI using `npm ci`, lint, unit, E2E, build, Snyk, Trivy filesystem/config scan, secret scanning, and migration/RLS tests once Supabase migration tooling is introduced.

## Scanner execution record

- `npm audit --omit=dev --audit-level=high`: completed with zero vulnerabilities on 2026-08-02.
- `npm run scan:security`: Trivy passed with zero findings; Snyk remained `BLOCKED` because the binary/credentials are not provisioned. Configure the protected CI Snyk credential; never commit it or report the local blocked scan as clean.
