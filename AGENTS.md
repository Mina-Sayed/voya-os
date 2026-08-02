# Repository Guidelines

## Project Structure & Module Organization

Voya OS is an Arabic-first, multi-tenant rental operations app built with Next.js and Supabase.

- `src/app/`: App Router pages, route handlers, and Server Actions; protected routes are under `src/app/workspace/`.
- `src/features/`: feature UI and colocated tests. `src/domain/`: framework-independent tenancy, booking, localization, and AI rules.
- `src/lib/`: infrastructure adapters. `supabase/migrations/` and `supabase/tests/`: schema and SQL assertions.
- `e2e/` holds Playwright scenarios; `scripts/` holds guarded checks.

## Build, Test, and Development Commands

- `npm run dev` — start local Next.js.
- `npm run build && npm run start` — validate and serve a production build.
- `npm run lint` — run ESLint.
- `npm test`, `npm run test:watch`, `npm run test:coverage` — run Vitest once, interactively, or with coverage.
- `npm run test:e2e` — run Playwright browser tests.
- `npm run test:production` — check protected-route rendering and cache safety.
- `npm run test:db` — run migrations and SQL tests only against an explicit disposable `*_test` database with `VOYA_DB_TEST=1` and `DATABASE_URL` set.
- `npm run scan:security` — run the project security scanner.

## Coding Style & Naming Conventions

Use TypeScript, function components, 2-space indentation, and existing ESLint. Use `PascalCase` for components, `camelCase` for utilities, and colocated `*.test.ts`/`*.test.tsx` tests. Keep domain logic independent of Next.js and Supabase where practical. Arabic is the default UI: preserve RTL through `src/domain/localization/`.

## Testing Guidelines

Start behavior changes with a focused failing test. Add unit, integration/SQL, and browser coverage appropriate to the boundary. Commands need tenant-isolation, role-denial, idempotency, and error-path coverage. Run the production rendering check for protected routes. Never use shared or production databases for tests.

## Commit & Pull Request Guidelines

Use concise Conventional Commit-style messages, e.g. `feat: add protected lead registry foundation`, `fix: harden authentication origin validation`, or `docs: define …`. Keep commits scoped and do not stage unrelated dirty files. PRs state behavior/security impact, link plans or ADRs, and include test evidence, UI screenshots, migration/rollback notes, and blocked checks.

## Project Safeguards

This repository uses Next.js 16. Before changing Next.js code, read the relevant guide under `node_modules/next/dist/docs/`. Browser writes are deny-by-default: derive user, membership, and organization on the server; preserve RLS, tenant-qualified relations, audit/outbox evidence, and idempotency. Never commit or print secrets.

Use `docs/PRD.md`, `docs/USER_FLOWS.md`, `docs/PERMISSIONS.md`, `docs/DATABASE.md`, `docs/ARCHITECTURE.md`, `docs/AI_AGENTS.md`, and `docs/TEST_PLAN.md` before altering a related boundary. Record unresolved finance, approval, tax, retention, or provider policy as an open decision rather than inventing it.
