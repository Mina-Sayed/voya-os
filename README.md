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

`test:e2e` starts/reuses a local development server and runs the Arabic dashboard smoke test in Chromium.

## Design direction

The interface is built around the morning handoff of a furnished-rental operations manager. Its signature element is the **stay ribbon**: a legible, semantic list that makes check-in/check-out edges and review states visible at a glance. The palette uses night harbor, sea glass, tide, limestone, and a single coral signal for attention. Arabic RTL is the default; dates/IDs use an isolated LTR utility for reliable mixed-direction rendering.

## Security and production boundary

- No Supabase credentials, service-role keys, API keys, payment data, or external providers are included.
- The local conflict helper improves future UX only. The authoritative confirmed-booking overlap control is now a tested PostgreSQL exclusion constraint; no booking command is exposed yet.
- Tenant-qualified foreign keys, forced read-only RLS, and an active-membership database check are now migration-tested. Financial/audit immutability, approvals, audit writes, and AI tool governance remain unimplemented.
- Dependency audit currently reports two moderate PostCSS issues inherited through the installed Next.js dependency tree. There are no high/critical findings; `npm audit fix --force` proposes a destructive downgrade to Next 9.3.3 and must not be used as remediation.

See the evidence-backed [foundation security review](docs/SECURITY_REVIEW_FOUNDATION.md) for current findings and the controls required before live tenant data.

## Next implementation slice

Implement Supabase Auth and a server-side organization bootstrap/command boundary. Do not connect the dashboard to live data or grant booking writes before authorization, approval, audit, idempotency, and availability-block concurrency controls have integration tests.
