# ADR-009: Database-backed auth rate limiting and nonce CSP

## Status

Accepted — 2026-08-02

## Context

The authentication boundary accepts cookie-authenticated Server Actions and renders a Next.js application behind a request proxy. Provider email limits alone do not protect password attempts or provide a deterministic application-side control. Next.js nonce CSP support requires dynamic rendering; a static sign-in page would receive a CSP nonce without nonce-bearing framework scripts and fail closed in the browser.

## Decision

- Store only a scoped SHA-256 key in `auth_rate_limit_buckets`; never persist the submitted email.
- Consume limits through a `SECURITY DEFINER` RPC with narrow `anon`/`authenticated` execute grants and no table grants. Password sign-in allows 10 attempts per 15 minutes; magic links allow 5.
- Fail closed when the limiter dependency is unavailable and return generic UI outcomes.
- Generate a per-request nonce in `src/proxy.ts`, forward the CSP to Next.js, and keep the root layout dynamic so framework scripts receive the nonce. Production CSP forbids `unsafe-inline` and `unsafe-eval`.
- Restrict Server Action origins to the configured `VOYA_APP_URL` host and keep sign-out server-owned.

## Consequences

The auth path adds one database RPC before provider calls and requires the migration to be applied in every environment. Dynamic rendering increases origin work and prevents static HTML caching for the app shell. Provider/domain configuration, MFA policy, and Snyk credentials remain deployment decisions and are not inferred by this ADR.

## Verification

`npm test`, `npm run test:production`, `npm run test:e2e`, `VOYA_AUTH_E2E_DISPOSABLE=1 npm run test:e2e:auth-local`, and the guarded disposable `npm run test:db` suite pass on the isolated branch.
