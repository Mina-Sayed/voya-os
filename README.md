# Voya OS

Arabic-first operating software for furnished apartment rentals.

## Current implementation slice

This repository contains the first walking skeleton, not a production-ready rental platform yet:

- An Arabic RTL responsive operations dashboard, verified at desktop and 360px mobile widths.
- A distinctive stay-ribbon interface for upcoming apartment stays, arrivals, and pending decisions.
- Typed, test-driven domain primitives for organization IDs, date-only stay ranges, and in-memory confirmed-booking conflict checks.
- Explicit fixture-only data marked as preview data. The interface performs no booking, finance, approval, AI, notification, or database mutation.

The approved product architecture and policy documentation remains in the parent workspace under [`../docs`](../docs). Before implementing live workflows, bring those documents into the repository and resolve the listed finance, approval, compliance, and provider decisions.

## Run locally

```bash
npm install
npm run dev
```

Open [http://localhost:3000](http://localhost:3000).

### Authentication configuration

The Arabic sign-in route is available at `/sign-in`. It is intentionally disabled until the public configuration and server-only service credential are present:

```bash
NEXT_PUBLIC_SUPABASE_URL=https://your-project.supabase.co
NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=your-publishable-key
VOYA_APP_URL=http://localhost:3000
SUPABASE_SERVICE_ROLE_KEY=your-server-only-service-role-key
```

`SUPABASE_SERVICE_ROLE_KEY` is read only by server actions and server-side auth helpers. Never expose it through `NEXT_PUBLIC_*`, client components, browser fixtures, logs, or committed files. Set each value separately per environment in Vercel/GitHub configuration; `VOYA_APP_URL` must match the exact origin used by that environment.

The fresh-restore compatibility migration `20260721000000_bootstrap_runtime_dependencies.sql` intentionally sorts before the existing migration history so the worker role exists before its first grant. When applying this branch to a linked Supabase project that already recorded later timestamps, review the migration list and use the reviewed `supabase db push --include-all` workflow so the compatibility migration is recorded; never use a linked or production reset.

The callback and password sign-in paths require a verified email and distinguish active, suspended, and missing memberships. Users with a non-active membership go to the neutral `/access-pending` page; only users with no membership can use the guarded personal-workspace bootstrap. Workspace routes also require an authenticated Supabase session at MFA assurance level AAL2.

## Quality commands

```bash
npm run test
npm run test:coverage
npm run test:db # requires an explicit local *_test PostgreSQL DATABASE_URL
npm run test:e2e
npm run lint
npm run build
npm audit --omit=dev --audit-level=high
```

`test:e2e` starts/reuses a local development server and verifies the public sign-in boundary, neutral access-pending page, and protected-route redirects in Chromium. `test:e2e:auth-local` uses a dedicated disposable Supabase stack and passes its service-role key only to the isolated Next server, never to browser page code.

## Design direction

The interface is built around the morning handoff of a furnished-rental operations manager. Its signature element is the **stay ribbon**: a legible, semantic list that makes check-in/check-out edges and review states visible at a glance. The palette uses night harbor, sea glass, tide, limestone, and a single coral signal for attention. Arabic RTL is the default; dates/IDs use an isolated LTR utility for reliable mixed-direction rendering.

## Security and production boundary

- No production Supabase credentials, service-role keys, API keys, payment data, or external providers are included. Local authenticated-browser tests obtain disposable stack credentials at runtime and keep the service-role key server-only.
- The local conflict helper improves future UX only. The authoritative confirmed-booking overlap control is now a tested PostgreSQL exclusion constraint; no booking command is exposed yet.
- Tenant-qualified foreign keys, forced read-only RLS, and an active-membership database check are now migration-tested. Financial/audit immutability, approvals, audit writes, and AI tool governance remain unimplemented.
- Dependency audit currently reports two moderate PostCSS issues inherited through the installed Next.js dependency tree. There are no high/critical findings; `npm audit fix --force` proposes a destructive downgrade to Next 9.3.3 and must not be used as remediation.

See the evidence-backed [foundation security review](docs/SECURITY_REVIEW_FOUNDATION.md) for current findings and the controls required before live tenant data.
See [authentication security review](docs/SECURITY_REVIEW_AUTH_BOUNDARY.md) for the sign-in boundary and its remaining launch blockers.

## Next implementation slice

Connect the protected workspace to live data only after the authorization, approval, audit, idempotency, and availability-block concurrency controls remain covered by integration tests. Keep Supabase Auth native rate limits/CAPTCHA enabled for public auth endpoints; the custom database limiter is an additional server-side control and is callable only by the service role.
