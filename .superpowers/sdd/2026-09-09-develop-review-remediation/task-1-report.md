# Task 1 report — booking integrity

Date: 2026-09-09
Base: `063e134b28cd5b5f548cdf6a5acdf0e8de507968`
Branch: `codex/review-remediation-sep09`
Implementation commit: `a932b3a9f4ab4c18cdd07c14722d749919d14936`

## Files changed

- `supabase/migrations/20260905040002_booking_commercial_integrity.sql`
  adds the forward-only booking integrity migration.
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
3. `complete_booking_commercial_snapshot` now accepts only `draft` bookings.
   The existing idempotency ledger gains a payload hash so identical retries
   return success without duplicate evidence while reuse with different terms
   raises `23505`.
4. Legacy `request_booking_approval` and `confirm_booking` call
   `require_workspace_aal2_v1()` before membership or booking work. Their public
   signatures, role and tenant checks, snapshot checks, and authenticated grants
   remain unchanged.
5. Legacy approval requests now build the current snapshot and hash before
   returning an active request. An unexpired pending or approved request with a
   stale snapshot is cancelled, and a fresh request is created in the same
   transaction. Matching retries retain one actionable request.
6. The memory update keeps checkout and managed state separate and documents the
   canonical `checked_in`/`checked_out` path versus the legacy completion path.

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

Review findings were addressed in commit `b4b1998e2f2d3041c65231e4573fa22782291a32`:

- The migration now backfills `payload_hash` for legacy
  `booking.commercial.complete` bindings using a tenant-qualified booking join.
  Any legacy binding that cannot be reconstructed remains NULL and is rejected
  with SQLSTATE `55000` rather than being compared with mutable current terms.
  `booking_integrity_upgrade.sql` exercises K1/100 across the migration boundary,
  changes the draft through K2/200, verifies a K1 retry returns without mutation,
  and proves unrecoverable NULL hashes fail closed.
- The stay-event trigger now takes `FOR UPDATE` on the tenant-qualified booking
  row during commercial validation. `runBookingStayEventUpdateRace` runs two
  real psql sessions and requires the ordinary booking update to wait behind the
  one-second direct event transaction; it is wired into
  `scripts/test-database-foundation.mjs`.
- `complete_booking_commercial_snapshot` now calls
  `require_workspace_aal2_v1()` before actor or booking work. The focused suite
  asserts missing and AAL1 denial messages and an AAL2 success path.

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
