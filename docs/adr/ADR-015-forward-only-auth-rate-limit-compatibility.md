# ADR-015: Forward-only auth rate-limit compatibility and migration reconciliation

**Status:** Accepted for local implementation; managed rollout gated
**Date:** 2026-08-05

## Context

Managed Supabase records 36 applied migrations. Five checkout candidates used
different timestamps for already-applied SQL, one historical bootstrap
migration existed only on `codex/auth-flow-fix`, and
`20260803092522_password_signup_rate_limit` existed only remotely. The latter
replaced the fixed-policy four-argument rate-limit wrapper with caller-selected
limits and a stale `ON CONFLICT (key_hash)` target after the bucket key became
`(scope, key_hash)`. The clean production artifact still calls the four-argument
signature.

Applied migration history is an immutable managed record. Cosmetic timestamp
alignment or migration repair would destroy release evidence and is not an
acceptable response to semantic drift.

## Decision

1. Represent the seven divergent managed records locally with their exact
   applied SQL and managed versions. Historical files, including the known
   password-signup regression and branch-only bootstrap function, are kept
   unchanged.
2. Add one forward migration,
   `20260805034227_restore_auth_rate_limit_compatibility.sql`, that restores the
   four-argument wrapper. It accepts only `magic_link = 5/900` and
   `password_sign_in = 10/900`, delegates to the canonical two-argument
   function, rejects `password_sign_up`, uses `SECURITY DEFINER` with
   `search_path = pg_catalog`, denies PUBLIC execution, and preserves
   `anon`/`authenticated`/`service_role` execution for the rolling window.
3. Keep the overload until a clean deployed artifact is proven to call only
   the two-argument function. Remove it in a later forward migration; never
   rewrite applied history or combine the drop with compatibility restoration.
4. Treat self-service workspace bootstrap as a separate product/security
   decision. This ADR neither adopts nor retires that flow.

## Verification

The disposable database harness applies the 36 historical migrations, proves
the managed-only `42P10` regression in a rollback, applies the repair, and
checks direct `anon`/`authenticated` calls, PUBLIC denial, fixed policy,
function security mode, ACLs, and search path. Clean install and existing
integration/concurrency suites remain required before any managed window.

## Consequences

- The checkout contains 37 migration files: the 36 managed historical records
  plus one pending repair candidate. This is semantic parity, not proof of
  managed deployment.
- Password sign-up has no canonical database-owned rate-limit policy yet.
- A production rollback to a four-argument artifact remains unsafe after the
  later overload drop unless a reviewed compatibility function is restored by
  another forward migration.
- Managed apply, Vercel deployment, provider configuration, and bootstrap
  policy remain approval-gated.
