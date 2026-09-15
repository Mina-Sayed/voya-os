# Develop review remediation

Base: `origin/develop` at `063e134b28cd5b5f548cdf6a5acdf0e8de507968`.

## Goal

Close the release-blocking findings found while reviewing merged PRs 30–34,
without rewriting applied migrations or weakening tenant, MFA, booking, or
provider-safety boundaries.

## Global constraints

- Add forward migrations only; do not edit deployed migration history.
- Preserve existing RPC signatures used by the application.
- Workspace browser RPCs covered here must reject missing or non-`aal2` JWTs.
- Operational booking rows and new stay events require a complete commercial
  snapshot with exact minor-unit amount and currency.
- Confirmed or later bookings cannot be repriced through the legacy completion
  command; changes must use the approved amendment flow.
- The WhatsApp worker cannot invoke an unrestricted result-application primitive.
- Add SQL regression tests and wire every new top-level test into the guarded DB
  runner. Database execution requires a disposable loopback `*_test` database.

## Task 1 — Booking integrity

Add a forward migration and regression tests that:

1. enforce commercial completeness for every write to an operational booking
   state, including `checked_out`;
2. prevent new stay events for commercially incomplete bookings through both
   legacy and canonical RPCs;
3. restrict `complete_booking_commercial_snapshot` to draft bookings;
4. refresh or replace a stale active approval rather than returning an unusable
   request;
5. require workspace AAL2 for the legacy booking request/confirm entry points.

## Task 2 — Property/availability AAL2 closure

Add forward-only guards and tests for the property-adjacent authenticated RPCs
missed by PR30: availability reads/writes, property confirmation claim/finalize,
and property-bearing indirect reads identified by the review. Preserve service
worker boundaries explicitly.

## Task 3 — WhatsApp worker safety

Remove worker/service-role execution of the unrestricted legacy AI-result
function. Keep only the safety wrapper callable and add catalog plus behavior
tests proving kill-switch and low-confidence denial cannot be bypassed.

## Task 4 — Money and timezone contracts

Replace guessed currency scales with one explicit supported-currency contract,
and align accepted organization timezones across application and database
boundaries. Preserve existing stored data through explicit validation/recovery
behavior; do not silently rescale historical amounts.

## Verification

- focused SQL suites on disposable PostgreSQL;
- `npm run typecheck`;
- `npm run lint`;
- `npm test`;
- `npm run test:memory` when durable state changes;
- final independent review of each task and the complete branch.
