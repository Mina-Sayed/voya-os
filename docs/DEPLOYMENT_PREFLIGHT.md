# Deployment preflight

Production builds fail closed when the public authentication configuration is missing or unsafe. Configure these values in the deployment provider, never in Git:

```text
NEXT_PUBLIC_SUPABASE_URL=https://<project>.supabase.co
NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=<publishable-key>
VOYA_APP_URL=https://<application-origin>
AUTH_RATE_LIMIT_HMAC_SECRET=<server-only-random-value>
```

`AUTH_RATE_LIMIT_HMAC_SECRET` is required at runtime for pre-auth bucket
derivation. Keep it server-only and never log or expose its value. Rotating it
starts fresh rate-limit counters.

`VOYA_APP_URL` must be an HTTPS root origin without credentials, path, query, or fragment. The only HTTP exception is the disposable loopback authenticated-browser harness, which uses `127.0.0.1:3102` and never production credentials.

Run a production build with the deployment environment loaded:

```bash
npm run build
npm run test:production
# After deployment, this must return HTTP 200 with {"status":"ok"}.
curl -fsS https://<application-origin>/api/health
```

`/api/health` is non-cacheable and returns HTTP 503 with a generic `not_ready` body when a production runtime is missing its public configuration. It does not expose provider URLs, keys, database details, or exception text; database, worker, and provider health require separate monitored checks.

Before a managed database release, inspect migration parity without mutating the project:

```bash
npx supabase migration list --linked
npx supabase db push --linked --dry-run --include-all
```

Applying migrations, configuring Supabase Auth Site URL/redirects/SMTP, and deploying the application require an approved release window. Keep outbound WhatsApp, notification, and AI workers disabled until their provider contracts, retry/dead-letter policy, secrets, monitoring, and rollback plan are approved.
