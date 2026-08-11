# Managed migration reconciliation — 2026-08-11

Status: **verified parity for the release candidate; no managed migration was
re-applied**.

## Evidence

- Managed Supabase project: `nseeteviretfabdfrgrc`.
- `supabase migration list --linked` from the release checkout reports every
  local and remote version aligned, including the three final records:
  `20260810182739`, `20260810182752`, and `20260810182809`.
- `supabase db push --linked --dry-run --include-all` reports:
  `Remote database is up to date.`
- `supabase db lint --linked --fail-on error` reports no schema errors.
- A read-only public-schema dump was captured outside Git at
  `/tmp/voya-managed-public-schema-20260811.sql`.

The old local compatibility migration
`20260805034227_restore_auth_rate_limit_compatibility.sql` is intentionally not
part of this release candidate because its version is absent from managed
history and the final managed auth migrations supersede it. No migration
history was rewritten and no reset was used.

## Runtime grant check

The managed database currently exposes the database-owned two-argument
`consume_auth_rate_limit(text, text)` only to `service_role`; the legacy
four-argument overload is absent. The application adapter therefore calls this
RPC through the server-only service-role client, with the HMAC key remaining
server-only.

`bootstrap_personal_workspace(uuid)` remains a managed SECURITY DEFINER
function executable by `authenticated`; this is a separate product/policy
decision and is not changed by this release.

## Remaining advisory findings

Supabase advisors still report existing INFO/WARN findings (RPC-owned tables
without row policies, SECURITY DEFINER functions intentionally exposed to
authenticated RPC callers, and two RLS init-plan warnings). They are recorded
as follow-up security/performance work, not silently treated as a clean advisor
gate.
