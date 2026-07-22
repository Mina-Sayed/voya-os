# ADR-002: Enforce property occupancy through one protected ledger

- Status: Accepted
- Date: 2026-07-22

## Context

A confirmed booking and an availability block are stored in separate tables. The
booking GiST exclusion constraint prevents two confirmed bookings from
overlapping, but it cannot prevent a concurrent availability-block write from
committing against the same dates. Application-only checks are unsafe because
two requests can both observe availability before either commits.

The invariant is tenant-scoped: a confirmed booking must not overlap an
availability block for the same `(organization_id, property_id)`. Adjacent date
ranges are valid because stays and blocks use `[start_date, end_date)`.

## Decision

Create a protected `property_occupancies` ledger with one GiST exclusion
constraint across confirmed bookings and availability blocks. `AFTER` triggers
maintain the ledger from both source tables; the ledger rows use tenant-qualified
foreign keys to the source records. PostgreSQL's exclusion constraint is the
single final guard for every conflicting write path, including concurrent
transactions.

The ledger and triggers are private database implementation details: they are
not granted to browser roles. Existing RLS and no-write grants remain in force.
Future server-owned booking commands must still perform identity, role,
approval, expected-version, idempotency, audit, and outbox work in their own
transaction; this ADR does not define those unresolved business policies.

## Options considered

1. A unified occupancy ledger with one exclusion constraint — selected. The
   constraint is concurrency-safe by construction and covers every source-table
   mutation, not just server commands.
2. Shared advisory lock with cross-table trigger checks — rejected. Under
   read-committed statement snapshots, proving that a trigger's post-lock query
   sees a just-committed competing row is subtle; a single constraint is easier
   to reason about and test.
3. Serializable transactions only — rejected. Correctness would depend on
   every future writer using the isolation level and retrying serialization
   failures; direct or privileged SQL could bypass the convention.

## Consequences

- The guard rejects conflicts using PostgreSQL exclusion-violation semantics,
  so server code must map that error to a user-safe availability conflict.
- The migration backfills ledger rows. It fails closed if pre-existing confirmed
  bookings and blocks conflict; production rollout therefore needs a preflight
  report and a reviewed remediation before applying it.
- There is no approval threshold, financial rule, or browser write permission
  introduced by this decision.

## Verification

Database integration tests cover both write orders, adjacent ranges, and a
genuine two-session race. The race must leave exactly one conflicting occupancy
record committed.
