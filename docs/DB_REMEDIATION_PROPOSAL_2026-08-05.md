# Managed database remediation proposal — 2026-08-05

**Status:** Planned; not approved for execution  
**Scope:** Managed Supabase only; no application, migration, or database change was executed by this proposal.  
**Evidence basis:** Read-only managed-environment evidence supplied and recorded in `docs/memory/CURRENT_STATE.md`.

## Objective

Reconcile the managed Supabase state with an approved checkout and explicit
product policy without rewriting applied migration history or widening access.
The work has three independent tracks:

1. remove or revoke the legacy four-argument auth rate-limit surface;
2. reconcile managed migration history with the checkout; and
3. decide and align the self-service workspace bootstrap boundary.

No track should be treated as complete because another track succeeded.

## Current evidence to preserve

| Plane | Evidence |
|---|---|
| Checkout | Branch `codex/production-security-remediation`, `HEAD` `5459c61`, 34 migration files in the working tree, and application code calling the two-argument rate-limit RPC |
| Managed Supabase | 36 recorded migrations, both `consume_auth_rate_limit` overloads present as `SECURITY DEFINER` and executable by `anon`, and `bootstrap_personal_workspace(uuid)` present as `SECURITY DEFINER` with `authenticated` `EXECUTE` |
| Product/policy | ADR-013 approves the database-owned rate-limit target and gates rollout; platform-provisioned organizations remain the current checkout policy; bootstrap alignment is not approved by this pass |

## Track 1 — legacy rate-limit overload

### Read-only preflight

- Capture the live signatures, `pg_proc` security mode, function definitions,
  and explicit/default privileges for both overloads.
- Confirm whether any currently deployed application artifact still calls the
  four-argument signature. The current checkout calls only the two-argument
  signature, but deployed artifact state must be checked separately.
- Establish the intended fixed policy values from the approved ADR/migration
  contract without accepting caller-provided values as policy authority.

### Proposed forward remediation

- If no deployed caller remains, issue a reviewed forward migration that
  revokes `anon` execution immediately and removes the legacy overload after
  compatibility is confirmed.
- If a rolling deployment still requires the signature, first move the
  deployed application to the two-argument contract, then revoke/remove the
  overload in a subsequent approved migration. Do not leave the legacy
  signature public as a permanent compatibility path.
- Preserve the two-argument pre-auth path only with the intended fixed policy,
  narrow grants, locked `search_path`, and `SECURITY DEFINER` review.

### Proof before closing

- `to_regprocedure` shows the intended final signature set.
- `has_function_privilege('anon', legacy_signature, 'EXECUTE')` is false (or
  the legacy function no longer exists).
- The two-argument function has the approved security mode and grant posture.
- Negative SQL tests prove caller-supplied limit/window parameters cannot
  select policy, and auth unit/integration tests use the narrow RPC.

## Track 2 — migration parity reconciliation

### Read-only inventory

- Capture managed `supabase migration list --linked` output and the complete
  local migration inventory without printing credentials.
- Map all 36 managed versions against the 34 checkout files by version and
  SQL intent. Pay special attention to the differently timestamped production
  security, grant-revocation, and advisor-hardening migrations.
- Compare live catalog objects, grants, policies, constraints, and function
  definitions against the candidate migration chain.

### Proposed reconciliation

- Decide which already-applied managed versions correspond to which checkout
  intent before adding any file; do not create duplicate migrations merely
  because timestamps differ.
- Preserve managed history. Use a reviewed forward migration for any missing
  invariant or a documented checkout migration-history reconciliation for an
  intentional rename/split.
- Run the disposable upgrade/preflight suite and a clean database test before
  requesting an approved managed apply window.

### Proof before closing

- The approved checkout migration history and managed history have an explicit
  one-to-one reconciliation record.
- Preflight reports zero tenant/grant/constraint violations.
- Backup/restore and lock/statement-timeout rehearsal evidence exists.
- Post-apply live catalog and privilege checks match the approved result.

## Track 3 — self-service workspace bootstrap alignment

### Policy decision required first

Product and security owners must explicitly choose one of these directions:

- retain self-service bootstrap as an approved product boundary; or
- keep organizations platform-provisioned and retire the managed function.

The current checkout does not expose the flow, and this proposal does not
choose the product policy.

### Read-only technical review

- Inspect the live function body, dependencies, `SECURITY DEFINER` settings,
  `search_path`, grants, and audit behavior.
- Verify the authenticated/verified-email assumptions, idempotency and race
  behavior, organization naming/slug collision behavior, and abuse controls.
- Verify whether any deployed Vercel artifact calls the function; Supabase
  presence alone is insufficient.

### Proposed alignment

- If retained, add the approved behavior to the current checkout through the
  normal migration/application/test/ADR process, then deploy in a controlled
  order with explicit tenant and abuse-control evidence.
- If retired, revoke `authenticated` execution and remove the function only
  through an approved forward migration after confirming no deployed caller or
  recovery path depends on it.
- In either case, update the product/policy record and managed verification
  separately; do not turn managed presence into implicit product approval.

## Approval and execution gates

Execution requires explicit user approval plus a reviewed window covering:

1. security and product/policy sign-off;
2. read-only preflight and migration mapping;
3. disposable database, unit/integration, grant, and authenticated-browser
   evidence as applicable;
4. approved backup and restore/rollback posture; and
5. post-change live verification of migration history, functions, grants,
   provider artifact, and audit evidence.

Until those gates are approved, do not run `supabase db push`, dashboard SQL,
`DROP FUNCTION`, `REVOKE`, or any other managed mutation.
