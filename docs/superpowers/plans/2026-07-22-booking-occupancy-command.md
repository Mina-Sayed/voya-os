# Booking Occupancy Command Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Introduce a server-owned, concurrency-safe booking/availability command boundary and an explicit booking approval/stay lifecycle that cannot create overlapping confirmed occupancy.

**Architecture:** Use a private `property_occupancies` ledger with one tenant- and property-scoped GiST exclusion constraint. Booking and availability-block triggers maintain the ledger, so concurrent source mutations cannot create conflicting occupancy. A future server application service will own role, exact approval, expected-version, idempotency, audit, and outbox orchestration.

**Tech Stack:** PostgreSQL/Supabase migrations and RPC, TypeScript ports/adapters, Vitest, PostgreSQL concurrency integration tests, Playwright.

## Global Constraints

- No browser role receives booking/availability writes.
- A confirmed booking cannot overlap a confirmed booking or active availability block.
- Approval policy thresholds remain unresolved; commands must return/create a proposal rather than bypass approval when policy applies.
- Every successful/denied sensitive command writes audit evidence; effects use transactional outbox records.

---

### Task 1: ADR and concurrency integration test

**Files:**
- Create: `docs/adr/ADR-002-property-occupancy-lock.md`
- Create: `supabase/tests/booking_occupancy_concurrency.sql`

- [x] Document options: shared advisory lock, unified occupancy table, and serializable-only transaction; record the unified-ledger decision.
- [x] Write database tests that race confirmation vs. block creation and prove exactly one state may commit.
- [x] Run the test red before the ledger migration exists.

### Task 2: Command persistence boundary

**Files:**
- Create: `supabase/migrations/20260722000400_booking_occupancy_commands.sql`
- Create: `src/features/bookings/confirm-booking.ts`
- Create: `src/features/bookings/confirm-booking.test.ts`

- [x] Add the protected occupancy ledger, tenant-qualified source foreign keys, and trigger maintenance.
- [x] Keep browser grants denied and verify ledger authorization.
- [x] Add protected command/RPC infrastructure with idempotency validation, immutable approval snapshot, audit event, and outbox insert in one transaction.
- [x] Add the booking approval, confirmation, check-in, and check-out command path with server-side role/state checks and idempotent stay events.
- [x] Add application/UI tests for maker-checker controls and lifecycle state rendering.

### Task 3: Verification and release evidence

**Files:**
- Modify: `scripts/test-database-foundation.mjs`
- Create: `docs/SECURITY_REVIEW_BOOKING_OCCUPANCY_COMMAND.md`

- [x] Run full lint, unit coverage, database race tests, E2E, build, npm audit, and Trivy evidence. Snyk remains a required CI gate.
- [ ] Run a Supabase dry-run migration plan after this workspace is linked with reviewed, non-source credentials.
- [ ] Do not push migrations or deploy until all gates and a reviewed production plan are green.

### Task 4: Final lifecycle evidence

**Files:**
- Modify: `supabase/tests/booking_lifecycle.sql`
- Create: `docs/SECURITY_REVIEW_BOOKING_LIFECYCLE.md`

- [x] Add regression coverage for the `check-out`-before-`check-in` domain error without catching the test's own failure.
- [x] Record the security review and explicit scope exclusions.
- [ ] Rerun the complete unit, database, browser, build, lint, and security gates on the isolated branch.
