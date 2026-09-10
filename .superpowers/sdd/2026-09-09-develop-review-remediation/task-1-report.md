# Task 1 report — booking integrity

Date: 2026-09-09
Base: `063e134b28cd5b5f548cdf6a5acdf0e8de507968`
Branch: `codex/review-remediation-sep09`
Implementation commit: `a932b3a9f4ab4c18cdd07c14722d749919d14936`

## Files changed

- `supabase/migrations/20260905040002_booking_commercial_integrity.sql`
  adds the forward-only booking integrity migration.
- `supabase/migrations/20260909000100_booking_integrity_idempotency_followup.sql`
  is the forward-only follow-up; it clears ambiguous historical hashes,
  persists approval-command result IDs, and replaces the affected RPC bodies.
- `supabase/tests/booking_integrity_remediation.sql` adds focused SQL coverage.
- `scripts/test-database-foundation.mjs` registers the new migration and test and
  updates the migration inventory assertion.
- `supabase/tests/booking_lifecycle.sql` and
  `supabase/tests/booking_legacy_guards.sql` update assertions whose expected
  behavior changed when operational rows became immutable with respect to
  commercial completeness.
- `docs/memory/DOMAIN_RULES.md` and `docs/memory/SECURITY.md` record the
  checkout semantics and database AAL2 boundary.
- `docs/superpowers/plans/2026-09-09-develop-review-remediation.md` is included
  as the task plan supplied with this worktree.

## Design decisions

1. The booking trigger now runs on every insert and update and requires
   `commercial_completion_status = 'complete'`, a non-null exact minor-unit
   amount, and a non-null currency whenever the resulting status is
   `confirmed`, `checked_in`, `checked_out`, or `completed`. This leaves
   historical incomplete rows readable while rejecting writes that touch them.
2. A `BEFORE INSERT` stay-event trigger checks the booking with the tenant pair
   `(organization_id, booking_id)`. It protects direct inserts and both legacy
   and canonical stay RPCs because both paths insert into the guarded table.
3. The forward follow-up makes `complete_booking_commercial_snapshot` hash the exact amount, currency,
   and reason payload. The idempotency lookup runs before the draft-state guard,
   so an identical retry remains idempotent after a later workflow transition;
   different terms raise `23505`. Legacy keys whose original payload cannot be
   reconstructed remain NULL and fail closed rather than being guessed from
   mutable booking terms.
4. Legacy `request_booking_approval` and `confirm_booking` call
   `require_workspace_aal2_v1()` before membership or booking work. Their public
   signatures, role and tenant checks, snapshot checks, and authenticated grants
   remain unchanged.
5. Legacy approval requests now build the current snapshot and hash before
   returning an active request. An unexpired pending or approved request with a
   stale snapshot is cancelled, and a fresh request is created in the same
   transaction. Each command idempotency key stores its resulting approval ID,
   so replaying a stale key remains bound to the original (possibly cancelled)
   result while a new key creates the replacement.
6. The memory update keeps checkout and managed state separate and documents the
   canonical `checked_in`/`checked_out` path versus the legacy completion path.
7. Approval request creation serializes on the organization advisory lock used
   by membership mutations, eliminating the active owner/manager count race.
8. The clean fixture uses a disposable pre-trigger setup boundary to model the
   historical incomplete row, and the stay-event race test uses an explicit
   advisory-lock barrier rather than process-start timing.

## Verification

- `node --check scripts/test-database-foundation.mjs` — PASS.
- `git diff --check` — PASS before and after staging.
- `npm run typecheck` — PASS (`tsc --noEmit`).
- `npm run lint` — PASS.
- `npm test -- --run` — PASS, 135 test files and 631 tests.
- `npm run test:memory` — PASS, 11 validator tests and project memory
  validation for 16 required files.
- `VOYA_DB_TEST=1 DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:5432/voya_task1_test npm run test:db` — BLOCKED before database setup because
  `psql` is unavailable (`spawnSync psql ENOENT`). The SQL migration and focused
  regressions therefore could not be executed against disposable PostgreSQL in
  this environment.

No managed database mutation or deployment was performed.

## Concerns

The database migration and SQL regression suite remain runtime-unverified until
an environment with `psql` and a disposable loopback `*_test` PostgreSQL database
is available. Static checks, application unit tests, memory validation, and
migration runner syntax validation passed locally.

## Review round 1 remediation — 2026-09-09

Review findings were addressed in commit `b4b1998e2f2d3041c65231e4573fa22782291a32`
and the follow-up working-tree changes:

- The original migration history remains unchanged. The forward follow-up clears
  all legacy completion hashes that could have been derived from mutable terms;
  they remain NULL and are rejected with SQLSTATE `55000`.
  `booking_integrity_upgrade.sql` verifies that a legacy K1 retry cannot mutate
  the row after K2/200.
- The stay-event trigger now takes `FOR UPDATE` on the tenant-qualified booking
  row during commercial validation. `runBookingStayEventUpdateRace` uses a
  separate advisory-lock observation as an explicit readiness barrier before
  starting the ordinary booking update; it remains wired into
  `scripts/test-database-foundation.mjs`.
- `complete_booking_commercial_snapshot` now calls
  `require_workspace_aal2_v1()` before actor or booking work. The focused suite
  asserts missing and AAL1 denial messages and an AAL2 success path.
- Completion retries are tested after an approval transition and reason changes
  are covered by the payload hash tests.
- Approval idempotency binds each key to its result via `result_id`, and the
  organization advisory lock serializes active owner/manager counting.
- The clean tenant fixture uses `set_config('session_replication_role', ...)`
  only around the deliberate historical setup update, leaving production
  triggers unchanged.

Additional verification after the review fixes:

- `node --check scripts/test-database-foundation.mjs` — PASS.
- `git diff --check` — PASS.
- `npm run typecheck` — PASS.
- `npm run lint` — PASS.
- `npm test -- --run` — PASS, 135 test files and 631 tests.
- `npm run test:memory` — PASS, 11 validator tests and project memory
  validation for 16 required files.
- The guarded disposable DB suite was retried with the new upgrade and
  concurrency coverage and remains BLOCKED before setup because `psql` is not
  installed (`spawnSync psql ENOENT`).

The migration has not been applied to a managed database and no deployment was
performed.

## Follow-up verification — current working tree

- `node --check scripts/test-database-foundation.mjs` — PASS.
- `git diff --check` — PASS.
- `npm run typecheck` — PASS.
- `npm run lint` — PASS.
- `npm test -- --run` — PASS, 135 test files and 631 tests.
- `npm run test:memory` — PASS, 11 validator tests and project memory
  validation for 16 required files.
- `VOYA_DB_TEST=1 DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:5432/voya_task1_test npm run test:db` — BLOCKED before database setup because
  `psql` is unavailable (`spawnSync psql ENOENT`).
