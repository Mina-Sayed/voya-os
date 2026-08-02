# Security Review: Booking Approval and Stay Lifecycle

**Date:** 2026-08-01
**Scope:** `20260801000600_booking_lifecycle_commands.sql`, booking/approval server actions and UI

## Threat boundaries reviewed

- Browser roles have no direct table update/insert privileges for booking stay events or booking source rows.
- Every RPC accepts an organization identifier but derives actor membership and role from `auth.uid()` inside `SECURITY DEFINER` functions.
- Every query and mutation includes an organization predicate; the database remains the authorization boundary.
- Approval requires owner/manager role, rejects self-approval, locks the request and booking, and consumes an approved request once.
- Stay events are append-only, unique per booking/event type, and idempotent by tenant-scoped key.

## Reproduction and regression evidence

The SQL integration test proves:

1. `anon` cannot execute confirmation and authenticated users cannot write the event table directly.
2. A duplicate approval request returns the existing pending request.
3. The requester cannot approve their own booking; an eligible separate approver can approve it.
4. Confirmation cannot bypass approval and repeated confirmation is harmless.
5. Check-out before check-in fails with the stable `22023` domain error.
6. Repeated check-in/check-out keys create one event per event type and append audit evidence.
7. A suspended membership cannot read the work queue.

## Findings

No Critical or High issue was identified in this slice. Pricing, payment, cancellation, commission, external provider delivery, and finance posting are intentionally absent; adding them without approved policy would be a product and integrity risk.

## Operational follow-up

- Run the SQL suite on an explicitly disposable database after any migration reordering.
- Add authenticated browser coverage with seeded booking fixtures before internal preview sign-off.
- Keep the final security gate blocked if Snyk is unavailable or if provider/finance policies remain unresolved.
