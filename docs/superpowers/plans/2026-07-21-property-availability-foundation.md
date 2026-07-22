# Property and Availability Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add tenant-safe property-owner history and availability-block records while keeping booking confirmation and browser writes unavailable.

**Architecture:** Extend PostgreSQL with property owners, effective ownership periods, and date-range availability blocks. Tenant-qualified foreign keys and date checks protect integrity. Because blocks and confirmed bookings occupy separate tables, no confirmation path is introduced until the documented shared lock/unified occupancy decision is implemented.

**Tech Stack:** Supabase/PostgreSQL SQL migrations, psql integration tests, Node migration runner.

## Global Constraints

- Every record uses non-null `organization_id`; browser roles receive no direct writes.
- Property ownership and availability retain history; this slice does not delete or overwrite facts.
- Availability blocks use `[start_date, end_date)` and are validated within their own table only.
- A block never waives the confirmed-booking exclusion constraint, and no cross-table availability command is enabled here.

---

### Task 1: Integration assertions

**Files:**
- Create: `supabase/tests/property_availability_foundation.sql`

- [x] Write assertions for tenant-qualified property owner references, valid/non-overlapping ownership periods, valid availability ranges, cross-tenant rejection, and no authenticated writes.
- [x] Run the test against existing migrations and observe the missing-table failure.

### Task 2: Declarative property/availability migration

**Files:**
- Create: `supabase/migrations/20260721000300_property_availability_foundation.sql`
- Modify: `scripts/test-database-foundation.mjs`

- [x] Add `property_owners`, `property_ownership_periods`, and `availability_blocks`, including tenant-qualified keys and GiST exclusions for ownership periods.
- [x] Force RLS and retain deny-by-default grants; extend the test runner to apply the new assertion suite.
- [x] Run the green database integration suite.

### Task 3: Documentation and verification

**Files:**
- Create: `docs/PROPERTY_AVAILABILITY_FOUNDATION.md`
- Create: `docs/SECURITY_REVIEW_PROPERTY_AVAILABILITY.md`

- [x] Document block/booking concurrency limitation and required future lock design.
- [x] Run full quality gates and commit cleanly.
