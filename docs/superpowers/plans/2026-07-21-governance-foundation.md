# Governance Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add database-enforced append-only audit events and generic approval records without inventing financial thresholds or exposing any browser writes.

**Architecture:** A forward-only Supabase migration extends the tenant foundation with tenant-qualified approval and audit tables. PostgreSQL triggers enforce append-only facts and maker-checker separation. RLS remains forced and no `authenticated` write grants are introduced.

**Tech Stack:** PostgreSQL 17/Supabase SQL, psql integration assertions, Next.js/TypeScript test runner, GitHub Actions.

## Global Constraints

- Multi-tenant records use non-null `organization_id` and tenant-qualified foreign keys.
- Financial policy, threshold, payment, booking confirmation, and AI mutation semantics remain unimplemented.
- Browser roles receive no direct booking, approval, audit, or finance writes.
- All database behavior is verified first against a disposable local `*_test` database.

---

### Task 1: Extend migration runner and write governance integration assertions

**Files:**
- Modify: `scripts/test-database-foundation.mjs`
- Create: `supabase/tests/governance_foundation.sql`

- [x] Write assertions for append-only audit records, same-tenant approval references, self-approval rejection, and absence of browser-role writes.
- [x] Run `VOYA_DB_TEST=1 DATABASE_URL=... npm run test:db`; expect failure because the governance migration/tables do not exist.
- [x] Change the runner to apply every SQL file in `supabase/migrations` in lexical order, then rerun the existing foundation test before the governance assertion file.

### Task 2: Add approval and audit migration

**Files:**
- Create: `supabase/migrations/20260721000200_governance_foundation.sql`

- [x] Add tenant-qualified membership uniqueness needed by approval foreign keys.
- [x] Add `approval_requests`, `approval_decisions`, and `audit_events` with safe lifecycle/status checks and canonical snapshot hash fields.
- [x] Add immutable trigger functions: audit rows reject update/delete; approval decisions reject update/delete; a maker cannot decide their own request.
- [x] Force RLS, retain deny-by-default writes, and grant only the narrow future read capability approved by policy (none in this initial table slice).
- [x] Run `npm run test:db`; expect all existing and governance assertions to pass.

### Task 3: Documentation and full verification

**Files:**
- Modify: `docs/DATABASE_FOUNDATION.md`
- Create: `docs/SECURITY_REVIEW_GOVERNANCE_FOUNDATION.md`

- [x] Document exact invariants, intentionally absent command execution, and open policy decisions.
- [x] Run lint, coverage, database integration, E2E, build, audit, and available scanner checks.
- [ ] Commit only after `git diff --check` is clean and all available tests pass.
