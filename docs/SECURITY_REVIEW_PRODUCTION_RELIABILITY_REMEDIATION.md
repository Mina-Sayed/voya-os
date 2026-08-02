# Security Review: Production Reliability Remediation

## Scope

Request-time rendering, Supabase session refresh, workspace organization selection, shared operational error reporting, command idempotency rotation, and expired outbox-lease recovery.

## Controls verified by design and tests

- The proxy refreshes authentication only and does not authorize organizations or roles.
- `voya-organization-id` is `httpOnly`, `sameSite=lax`, secure in production, and validated against current active memberships before use.
- Multiple memberships require explicit selection; foreign, removed, suspended, and stale selections fail closed.
- Database RPCs continue deriving identity from `auth.uid()` and enforcing tenant and role internally.
- All app routes are rendered dynamically so nonce-bearing framework scripts cannot be served from static HTML. Protected routes are rejected by the production test if present in the prerender manifest or returned with shared-cache markers.
- The authentication boundary uses a hashed-email database rate limiter, strict Server Action origin allowlisting, nonce CSP, and server-owned sign-out.
- Operational logs contain only a safe operation name, generated request ID, fixed safe code, and outcome. Causes are never serialized.
- Idempotency keys remain stable during retries and rotate only after a successful result.
- `authenticated` cannot execute outbox claims. `voya_outbox_worker` has no direct outbox table read or update privilege and can execute only the claim, completion, failure, and bounded purge functions.
- Expired leases can be reclaimed through `FOR UPDATE SKIP LOCKED`; active leases cannot be stolen, completed, or failed by stale workers.
- Retry failures accept short safe error codes, release the lease, schedule a bounded retry, and transition to `dead_letter` at the configured maximum attempt.
- Terminal retention is explicit and batched; only completed/dead-letter rows are eligible for purge.

## Residual risk and release restrictions

1. **High — provider/runtime delivery is not enabled.** Provider adapters, dead-letter alert routing, metrics, and deployment ownership still require an explicit worker-runtime decision. Do not enable external delivery from the browser or an unreviewed job.
2. **High — authenticated production fixture not present.** The production cache test proves request-time rendering; Preview verification remains mandatory for the managed environment.
3. **High — database integration evidence is local-only.** Do not apply the outbox migration remotely until the SQL suite, migration dry-run, rollback/forward plan, and managed Supabase review pass.
4. **Moderate — Snyk evidence is environment-blocked.** Local Trivy passed with zero findings; Snyk authentication/binary must pass in CI before release.

## Required production signals

- auth refresh failure count and rate;
- workspace context failures by safe code;
- protected-route cache-header canary;
- organization-selection denial anomalies;
- oldest pending and expired outbox lease age;
- outbox claim rate, active leases, and repeated reclamations.
