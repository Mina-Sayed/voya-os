# ADR-008: Booking Approval and Stay Lifecycle Commands

**Status:** Accepted for internal preview
**Date:** 2026-08-01

## Context

The booking screen previously created drafts but had no server-owned path for maker-checker approval, confirmation, or operational check-in/check-out. Browser writes must remain denied, tenant predicates must be enforced in PostgreSQL, and unresolved pricing, payment, cancellation, and commission policy must not be inferred.

## Decision

Add a private `booking_stay_events` append-only table and five tenant-scoped RPC boundaries:

- `list_booking_work_queue`
- `request_booking_approval`
- `decide_booking_approval`
- `confirm_booking`
- `record_booking_stay_event`

Approval snapshots are immutable evidence. The requester cannot approve their own booking. Confirmation requires an approved, unexpired request and an active property. Check-out requires a prior check-in and marks the booking `completed`. Each successful transition appends audit and outbox evidence in the same transaction. Idempotency keys make approval requests and stay events safe to retry.

## Alternatives considered

1. Client-side status changes — rejected because clients can forge role, tenant, or state.
2. A generic workflow table with dynamic transitions — deferred because it would hide the explicit booking invariant and complicate review.
3. Provider/payment integration in the same command — rejected until business and provider contracts are approved.

## Consequences

Operations receives a real, reviewable internal stay workflow. The slice does not claim pricing, deposits, refunds, commissions, cancellation, or external notifications. Those remain separate policy-gated commands.

## Verification

`supabase/tests/booking_lifecycle.sql` covers grants, role denial, duplicate requests, maker-checker approval, confirmation idempotency, check-in prerequisite, stay-event idempotency, completion, and audit evidence.
