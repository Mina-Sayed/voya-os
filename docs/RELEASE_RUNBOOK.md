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

The build must fail when any public production variable is missing or unsafe. Never use a service-role key in a browser or build argument.

## 2. Managed Supabase gate

Before a migration window, review the linked project and take a managed backup:

```bash
npx supabase migration list --linked
npx supabase db push --linked --dry-run --include-all
```

Apply migrations only during an approved window. Verify the migration history, RLS/grants, auth rate limiting, outbox lease lifecycle, and representative tenant queries immediately afterward. Keep a forward-fix and restore procedure ready; do not use an ad-hoc destructive reset.

## 3. Auth and Preview smoke

Configure Supabase Auth Site URL, exact callback URL, PKCE email template, SMTP/provider limits, and password policy. Run the authenticated browser suite against the deployed Preview with synthetic users, then verify sign-in, callback, multi-membership selection, sign-out, and token refresh.

## 4. Go / no-go

Do not enable WhatsApp, notification, or AI delivery until a durable worker, provider contract, retry/dead-letter policy, secrets, ownership, metrics, alerts, and kill switch are approved. A blocked Snyk scan, missing migration, failed Preview smoke, unresolved backup/restore drill, or missing policy owner is a **NO-GO**.
