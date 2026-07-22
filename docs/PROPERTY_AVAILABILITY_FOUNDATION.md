# Property and Availability Foundation

The property foundation adds tenant-scoped property-owner history and availability blocks. It deliberately stops before any booking-confirmation command is introduced.

## Enforced invariants

- `property_owners`, `property_ownership_periods`, and `availability_blocks` all require `organization_id`.
- Ownership-period property and owner references are tenant-qualified; cross-tenant references fail at the database boundary.
- Ownership periods use `[start_date, end_date)` and a GiST exclusion constraint. Adjacent periods are valid; overlapping periods for a property are rejected.
- Availability blocks use the same half-open date convention and reject invalid/reversed ranges.
- RLS is enabled and forced. The `authenticated` role receives no direct write privileges for any property/availability source table.

## Critical booking-concurrency limitation

Availability blocks and bookings are separate tables. PostgreSQL exclusion constraints cannot enforce overlap across those two tables directly. Therefore this migration does **not** enable booking confirmation, block creation commands, or any override path.

Before a server command can confirm a booking or create/change an availability block, it must use the same per-property transactional advisory lock (or an approved unified occupancy table), check both sources inside the transaction, validate the booking constraint, and atomically append audit/outbox records. The integration suite for that command must include concurrent confirmation/block attempts.

## Test evidence

`npm run test:db` applies every migration against a disposable `*_test` PostgreSQL database. The property suite proves table existence, non-null tenant keys, tenant-qualified relations, ownership-range exclusion, adjacent-range acceptance, availability validation, and browser-role write denial.
