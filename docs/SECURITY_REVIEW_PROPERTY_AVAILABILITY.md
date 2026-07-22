# Property and Availability Foundation Security Review

**Review date:** 2026-07-22
**Scope:** property owner, ownership period, and availability block migrations with PostgreSQL integration tests.

## Controls added

- Tenant-qualified composite foreign keys prevent a period/block in one organization from referencing a property owner or property in another.
- GiST exclusion protects concurrent historical ownership-period overlap for the same property under half-open date semantics.
- RLS is enabled and forced on all new tables; no browser `INSERT`, `UPDATE`, or `DELETE` grant exists.
- Historical ownership facts are not hard-deleted by product paths; source tables have no direct browser mutation capability.

## Verified evidence

The database integration suite passes on PostgreSQL 17 and exercises null tenant rejection, cross-tenant references, adjacent/overlapping ownership periods, invalid availability ranges, and direct authenticated write denial.

## Blocking findings before live commands

1. **High — cross-table occupancy.** A block can conflict with a booking because each table has an independent invariant. Enable confirmation/block mutations only after a single shared advisory-lock or unified-occupancy design is implemented and concurrency-tested.
2. **High — no server commands yet.** RLS denies browser writes, but an approved server application service must still validate role, state, idempotency, audit/outbox, and approvals before any write is made possible.
3. **Medium — sensitive owner data intentionally absent.** Do not add contact, payout, document, or tax data until field-level policy, encryption/retention, and audit rules are implemented.
