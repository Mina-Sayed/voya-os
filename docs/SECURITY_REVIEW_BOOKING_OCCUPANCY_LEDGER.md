# Security Review: Booking Occupancy Ledger

Date: 2026-07-22

## Scope

`20260722000400_booking_occupancy_commands.sql` adds a private,
database-enforced occupancy ledger maintained by booking and availability-block
triggers. It does not create a public RPC, browser write grant, finance rule, or
approval policy.

## Security properties verified

- `property_occupancies` has forced RLS and no privileges for `authenticated`.
- The ledger has tenant-qualified property, booking, and block foreign keys;
  one ledger row cannot point across organizations.
- `num_nonnulls` requires exactly one source record per occupancy row.
- The GiST exclusion constraint uses `[start_date, end_date)` and rejects both
  confirmed-booking conflicts and booking/block conflicts.
- `AFTER` triggers roll back the source mutation if the ledger write conflicts.
- The integration harness starts two independent `psql` transactions. Exactly
  one conflicting writer can commit; the committed ledger count is asserted.

## Residual risks and required controls

- Applying the migration to a database that already contains conflicting
  confirmed bookings and availability blocks will fail during ledger backfill.
  Run a reviewed preflight query and resolve every conflict before production
  application; do not weaken or skip the constraint.
- Database owners can disable triggers or constraints. Restrict migration and
  service-role credentials, use GitHub review protections, and audit every
  production schema change.
- A future command must map PostgreSQL `23P01` to a neutral availability
  response without exposing another tenant's reservation details.
- This invariant is not approval policy. Booking confirmation remains blocked
  from browser writes until a server-owned command verifies actor role,
  approved proposal snapshot, idempotency, optimistic version, audit event, and
  transactional outbox.
- Trivy passed locally from the pinned `aquasec/trivy:0.67.2` image with no
  high/critical dependency, secret, or misconfiguration findings. Snyk is not
  installed or authenticated locally. The repository CI workflow remains the
  required place for an authenticated Snyk scan; a release must not be approved
  without successful CI evidence.

## Local evidence

| Check | Result |
| --- | --- |
| PostgreSQL integration and two-session race | Passed |
| Unit coverage | Passed: 22 tests, 94.02% statements |
| Playwright browser suite | Passed: 3 tests |
| Lint and production build | Passed |
| `npm audit --omit=dev --audit-level=high` | Passed; 2 moderate PostCSS advisories remain, with no safe automated fix |
| Trivy filesystem scan | Passed: 0 high/critical findings |

## Production migration gate

1. Rotate any previously exposed Supabase keys and verify the linked project.
2. Restore privileged migration access without placing credentials in source.
3. Run `supabase db push --dry-run` against the intended project.
4. Run a reviewed, tenant-scoped conflict preflight and retain its output as a
   deployment artifact.
5. Apply through the reviewed declarative migration workflow only after CI
   (including Trivy and Snyk) is green. Verify the new constraint and triggers
   before enabling server confirmation commands.
