# Voya OS

Arabic-first operating software for furnished apartment rentals.

## Release candidate status

This branch contains the reviewed Voya OS release candidate. It includes:

- An Arabic RTL responsive Design C operations workspace with role-aware navigation, live dashboard surfaces, bookings, properties, clients, leads, availability, approvals, tasks, transport, AI governance, and a WhatsApp staff inbox foundation.
- Request-time Supabase authentication with password and magic-link sign-in, token refresh, multi-organization selection, membership gating, sign-out, rate-limit handling, and protected-route cache checks.
- Tenant-qualified server commands, RLS/migration assertions, idempotency, audit/outbox records, booking lifecycle foundations, and an isolated authenticated browser harness.
- Production build, health, security-header, lint, unit, database, public-browser, and authenticated-browser gates documented in [`docs/`](docs).

This is a release candidate, not an authorization to change managed infrastructure. External delivery for WhatsApp, notifications, and AI remains disabled until provider contracts, durable workers, retry/dead-letter policy, secrets, monitoring, and rollback controls are approved. Finance, retention, MFA/session assurance, and other policy decisions are also recorded in the relevant documents and must be resolved before live tenant data is enabled.

## Run locally

```bash
npm install
npm run dev
```

Open [http://localhost:3000](http://localhost:3000).

### Authentication configuration

The Arabic sign-in route is available at `/sign-in`. It is intentionally disabled until all three nonsecret values are present:

```bash
NEXT_PUBLIC_SUPABASE_URL=https://your-project.supabase.co
NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=your-publishable-key
VOYA_APP_URL=http://localhost:3000
```

Organizations are platform-provisioned. No self-service tenant/owner bootstrap is enabled. The `/auth/callback` exchange and membership-gated workspace redirect are covered by the local authenticated E2E suite; deployed Supabase Auth/SMTP settings still require environment-specific verification.

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

`test:e2e` starts a sanitized local development server and runs public Arabic dashboard/auth-shell smoke tests in Chromium. It intentionally excludes the real authenticated workspace suite. Run `npm run test:e2e:auth-local` for that suite; it requires Docker and creates only a disposable loopback Supabase stack.

Run `npm run test:production` after a build made without local provider values to verify that protected routes remain request-time rendered and are not shared-cacheable:

```bash
env NEXT_PUBLIC_SUPABASE_URL= NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY= VOYA_APP_URL= npm run build
npm run test:production
```

### Codex development agents

The project provides four scoped Codex roles: `voya-orchestrator`, `database-worker`, `verification-worker`, and `security-reviewer`. Start a new Codex session from the repository root after pulling the configuration:

```bash
cd /home/mina/voya-os
codex
```

Then request explicit delegation, for example:

```text
Use voya-orchestrator to execute docs/superpowers/plans/2026-07-21-property-availability-foundation.md.
Delegate the migration and SQL assertions to database-worker, verification to verification-worker,
and a final read-only review to security-reviewer. Preserve uncommitted work and do not deploy.
```

Custom agent files are discovered by a new Codex session. In an already-running session, ask Codex to use the same named roles explicitly or begin a new session after the configuration is added.

## Design direction

The interface is built around the morning handoff of a furnished-rental operations manager. Its signature element is the **stay ribbon**: a legible, semantic list that makes check-in/check-out edges and review states visible at a glance. The palette uses night harbor, sea glass, tide, limestone, and a single coral signal for attention. Arabic RTL is the default; dates/IDs use an isolated LTR utility for reliable mixed-direction rendering.

## Security and production boundary

- No Supabase credentials, service-role keys, API keys, payment data, or external providers are included.
- The local conflict helper improves future UX only. The authoritative confirmed-booking overlap control is a tested PostgreSQL exclusion constraint; confirmation and cancellation policy are not implemented.
- Tenant-qualified foreign keys, forced RLS, active-membership checks, reviewed command RPCs, audit rows, idempotency, and transactional outbox writes are migration-tested. Finance posting, full approval execution, provider delivery, and AI runtime remain disabled or incomplete.
- The current dependency audit reports no high or critical findings. Do not use `npm audit fix --force`; it can propose a destructive Next.js downgrade.

See the evidence-backed [foundation security review](docs/SECURITY_REVIEW_FOUNDATION.md) for current findings and the controls required before live tenant data.
See [authentication security review](docs/SECURITY_REVIEW_AUTH_BOUNDARY.md) for the sign-in boundary and its remaining launch blockers.

## Release handoff

Follow [`docs/RELEASE_RUNBOOK.md`](docs/RELEASE_RUNBOOK.md) in order. The remaining go/no-go gates are managed Supabase migration parity, Auth Site URL/redirect/SMTP configuration, authenticated Preview smoke tests, authenticated Snyk CI evidence, backup/restore rehearsal, and approved policy/worker controls. Do not run a linked migration push or enable outbound providers without an explicit release window and rollback plan.
