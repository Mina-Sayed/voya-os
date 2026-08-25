# Booking System Hardening Design

## Goal
Make the Voya OS commercial booking flow the single production write path, preserve immutable approved commercial snapshots, expose the full booking lifecycle to staff, and keep money, approvals, idempotency, and role behavior consistent from database to UI.

## Canonical command surface
The commercial V1 RPCs are the only authenticated booking write API. Legacy `create_booking_draft`, `request_booking_approval`, `confirm_booking`, and `record_booking_stay_event` remain in the schema only for migration/history compatibility but lose `authenticated` execute permission.

Commercial completion is only for legacy rows with `commercial_completion_status = 'needs_completion'`. Once a booking has a complete commercial snapshot, any commercial/date/property/client change must go through amendment approval.

## Money contract
PostgreSQL continues to store `bigint` minor units. Browser forms accept human-readable major-unit decimal strings. A shared TypeScript money helper converts major units to integer minor units and formats minor units back to locale-aware amounts. EGP defaults to two fraction digits through `Intl.NumberFormat` currency metadata, while the helper supports zero/three-decimal currencies without floating-point arithmetic.

## Lifecycle
The workspace supports:
- draft creation and direct draft cancellation;
- confirmation approval and independent owner/manager execution;
- amendments for confirmed or checked-in bookings, including stay extension while checked in;
- cancellation approval for confirmed and checked-in bookings;
- check-in and check-out with strict idempotency payload matching;
- legacy commercial completion only when the snapshot is incomplete.

A checked-in amendment may change only checkout date and agreed amount/currency; property, client, and check-in are frozen after arrival. Any new checkout must remain later than check-in and occupancy constraints remain authoritative in PostgreSQL.

## Approval review
`list_approval_requests` returns redacted but decision-sufficient booking details: requester label, property/client labels, dates, amount/currency, proposal reason, and before/after values appropriate to confirm/amend/cancel. Expired pending records are surfaced as expired, and creating a new request expires stale pending requests for the same booking/action. The UI allows owner/manager decisions for confirm, amend, and cancel rather than confirm only.

## RBAC
Booking page read roles match the database read model and navigation: owner, manager, sales_agent, operations, accountant, viewer. Mutation controls render only for roles that can execute the corresponding RPC. Viewers/accountants never receive create/mutation controls.

## Queue
The booking queue RPC uses bounded pagination (`p_limit`, `p_offset`) with a maximum page size of 100. The initial workspace page requests the latest 50 records; no unbounded booking read remains.

## Testing
Add SQL regression tests for legacy RPC revocation, immutable commercial completion, strict stay-event idempotency, approval expiry/deduplication, checked-in amendment/extension, and cancellation while checked in. Add Vitest tests for major/minor money conversion and UI rendering/controls. Extend authenticated Playwright coverage for amendment/cancellation when practical. GitHub Actions `verify` is the authoritative runner when local npm registry access is unavailable.
