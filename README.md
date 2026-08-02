# Voya OS

Arabic-first operating software for furnished apartment rentals.

## Current implementation slice

This repository contains a foundation slice, not a production-ready rental platform yet:

- An Arabic RTL responsive operations dashboard, verified at desktop and 360px mobile widths.
- A distinctive stay-ribbon interface for upcoming apartment stays, arrivals, and pending decisions.
- Typed, test-driven domain primitives for organization IDs, date-only stay ranges, and in-memory confirmed-booking conflict checks.
- A protected workspace with reviewed, tenant-scoped foundation commands for properties, owners, availability blocks, clients, leads, and booking drafts. These commands are not a production booking, finance, approval, AI, or notification system.

The approved product architecture and policy documentation lives in [`docs/`](docs). Before implementing live workflows, resolve the listed finance, approval, compliance, and provider decisions.

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

Organizations are platform-provisioned in the current slice. No self-service tenant/owner bootstrap is enabled. The `/auth/callback` exchange and membership-gated workspace redirect remain the next authentication security boundary.

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

## Next implementation slice

The database outbox lifecycle now supports ownership-checked completion, bounded retry/dead-letter transitions, and terminal retention. Keep external delivery disabled until a reviewed worker runtime, provider adapter, alerting/metrics, and the remaining release gates are deployed. Resolve the canonical ADR registry, pagination/query budgets, MFA/CSP/rate-limit policy, and the remaining finance, approval, retention, and provider decisions before adding sensitive workflows.
