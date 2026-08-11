# Voya OS Release Runbook

This runbook is the final gate for promoting a reviewed build. It does not authorize a production change by itself.

## 1. Candidate preflight

Run from the release commit and keep credentials in the deployment provider:

```bash
npm ci
npm run lint
npm test -- --run
npm run test:coverage
npm audit --omit=dev --audit-level=high
env NEXT_PUBLIC_SUPABASE_URL=<https-root> \
  NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=<publishable-key> \
  VOYA_APP_URL=<https-app-root> npm run build
npm run test:production
```

Run the browser gates against the candidate before any managed release:

```bash
npm run test:e2e
VOYA_AUTH_E2E_DISPOSABLE=1 npm run test:e2e:auth-local
npm run scan:security
```

`npm run scan:security` must exit successfully. A local `BLOCKED` Snyk result is not a pass; provide authenticated CI evidence instead. The disposable database suite must also run with an explicit loopback `*_test` database:

```bash
VOYA_DB_TEST=1 DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:55322/voya_os_lifecycle_test npm run test:db
```

The build must fail when any public production variable is missing or unsafe. Never use a service-role key in a browser or build argument.

## 2. Managed Supabase gate

Before a migration window, review the linked project and take a managed backup:

```bash
npx supabase migration list --linked
npx supabase db push --linked --dry-run --include-all
```

For migration `20260803085546` and its follow-up grant hardening migrations, run the reviewed read-only data check before the dry run using a migration-owner connection supplied outside source control:

```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
  -f supabase/tests/production_security_migration_preflight.sql
```

It must report zero cross-tenant references and zero overlapping active vehicle/driver allocations. It opens a read-only transaction, reports no row contents, and rolls back. A failure requires an investigated, approved data-repair plan; do not weaken or bypass the migration constraints. Rehearse lock duration on production-shaped data because the new unique and GiST exclusion constraints scan and lock affected tables. The migration itself fails after five seconds of lock contention rather than waiting indefinitely.

Apply migrations only during an approved window. Verify the migration history, RLS/grants (including deny-by-default PostgREST table access), auth rate limiting, outbox lease lifecycle, extension schemas, and representative tenant queries immediately afterward. Keep a forward-fix and restore procedure ready; do not use an ad-hoc destructive reset.

## 3. Auth and Preview smoke

Configure Supabase Auth Site URL, exact callback URL, PKCE email template, SMTP/provider limits, and password policy. Run the authenticated browser suite against the deployed Preview with synthetic users, then verify sign-in, callback, multi-membership selection, sign-out, and token refresh.

## 4. Go / no-go

Do not enable WhatsApp, notification, or AI delivery until a durable worker, provider contract, retry/dead-letter policy, secrets, ownership, metrics, alerts, and kill switch are approved. A blocked Snyk scan, missing migration, failed Preview smoke, unresolved backup/restore drill, or missing policy owner is a **NO-GO**.
