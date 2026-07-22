# Security Review: Booking Draft Command

Date: 2026-07-22

## Scope

`create_booking_draft` is the only browser-callable booking mutation added in
this slice. It creates a `draft` proposal only; it cannot confirm, cancel,
amend, or complete a booking and has no financial effect.

## Controls verified

- The command is `SECURITY DEFINER`, has a fixed `pg_catalog` search path, and
  is executable only by `authenticated`; direct table inserts remain denied.
- It derives identity from `auth.uid()`, resolves an active membership in the
  supplied organization, and allows only `owner`, `manager`, `sales_agent`, or
  `operations`.
- It uses the existing tenant-qualified foreign keys for property and client.
- Repeated identical idempotency keys return the original draft; mismatched
  reuse fails rather than silently applying a different request.
- Draft creation and a minimal, attributable `booking.draft_created` audit
  event occur in one database transaction.
- Database integration tests prove authorized owner/sales creation, suspended
  user denial, no direct browser insert privilege, idempotency, and audit.

## Explicit non-goals

This command does not decide approval requirements or execute approval,
confirmation, availability reservation, cancellation, prices, notifications,
or finance. A future confirmation command must re-check the approved snapshot,
version, tenant/role, property state, occupancy ledger, and idempotency in one
transaction.
