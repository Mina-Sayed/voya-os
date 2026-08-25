# Booking System Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make commercial booking the only authenticated booking write path and complete the production lifecycle with correct money, approvals, idempotency, RBAC, and pagination.

**Architecture:** Keep the existing Next.js + Supabase modular monolith. Add one forward-only hardening migration that replaces affected RPC definitions/revokes legacy grants, then wire existing server-action/UI patterns to those RPCs. Money conversion lives in a pure TypeScript helper so the browser uses major units while PostgreSQL continues to store integer minor units.

**Tech Stack:** Next.js 16, React 19, TypeScript, Supabase/PostgreSQL PL/pgSQL, Vitest, Playwright.

**Spec:** `docs/superpowers/specs/2026-08-25-booking-system-hardening-design.md`

## Global Constraints
- Do not rewrite old migrations; add a new forward migration.
- PostgreSQL minor-unit bigint is canonical for monetary storage.
- Commercial V1 RPCs are the only authenticated booking write commands.
- Maker-checker remains independent: requester cannot approve/execute their own protected change.
- Database occupancy constraints remain the final conflict authority.
- No finance/payments/ledger scope is added.

---

### Task 1: Add failing database regressions for security and integrity

**Files:**
- Modify: `supabase/tests/commercial_booking_v1.sql`

**Interfaces:**
- Consumes: existing commercial/legacy booking RPCs.
- Produces: regression assertions for revoked legacy writes, immutable commercial completion, strict idempotency, checked-in amendment/cancellation, and approval expiry behavior.

- [ ] Add assertions that `authenticated` has no EXECUTE privilege on legacy booking write RPCs.
- [ ] Add a test proving commercial completion rejects already-complete bookings.
- [ ] Add a test proving a reused stay-event idempotency key with different booking/event/notes raises `23505`.
- [ ] Add a checked-in extension amendment test and verify property/client/check-in cannot change after arrival.
- [ ] Add checked-in cancellation request/execution coverage.
- [ ] Add stale approval renewal coverage that leaves only one actionable pending request.
- [ ] Run `npm run test:db` and confirm the new assertions fail before the migration exists. If the local runner is unavailable, push this test-only commit and confirm GitHub Actions `verify` fails for the expected assertions.

### Task 2: Harden the database command surface

**Files:**
- Create: `supabase/migrations/20260825180000_booking_system_hardening.sql`

**Interfaces:**
- Produces: revised `complete_booking_commercial_snapshot`, `list_commercial_booking_work_queue`, `list_approval_requests`, `request_commercial_booking_approval`, `request_booking_amendment`, `execute_booking_amendment`, `request_booking_cancellation`, `execute_booking_cancellation`, and `record_commercial_booking_stay_event` behavior; revoked legacy grants.

- [ ] Revoke `authenticated` EXECUTE from `create_booking_draft`, `request_booking_approval`, `confirm_booking`, and `record_booking_stay_event` signatures.
- [ ] Restrict commercial completion to `needs_completion` rows and make idempotency payload-specific.
- [ ] Add bounded `p_limit`/`p_offset` to the commercial queue.
- [ ] Replace approval read RPC with decision-sufficient booking snapshot fields and computed expired status.
- [ ] Expire stale pending approval records before inserting a replacement for the same booking/action.
- [ ] Allow amendment/cancellation for `confirmed` and `checked_in`; for checked-in amendment freeze property/client/check-in and allow checkout/amount/currency changes only.
- [ ] Restore strict stay-event idempotency matching.
- [ ] Run database tests and confirm Task 1 regressions pass.

### Task 3: Add failing money-contract tests

**Files:**
- Create: `src/domain/money/minor-units.test.ts`
- Create: `src/domain/money/minor-units.ts`

**Interfaces:**
- Produces: `parseMajorToMinor(value, currency): string` and `formatMinorUnits(value, currency, locale?): string`.

- [ ] Write tests for EGP `25000` -> `2500000`, EGP `25000.50` -> `2500050`, invalid precision rejection, zero-decimal currency, and formatting.
- [ ] Confirm tests fail before implementation.
- [ ] Implement string-based decimal conversion with `Intl.NumberFormat(...).resolvedOptions().maximumFractionDigits`; never use floating-point multiplication.
- [ ] Confirm tests pass.

### Task 4: Wire major-unit money through booking actions and forms

**Files:**
- Modify: `src/app/workspace/bookings/actions.ts`
- Modify: `src/features/bookings/booking-draft-form.tsx`
- Modify: `src/features/bookings/booking-draft-form.test.tsx`
- Modify: `src/features/bookings/bookings-page.tsx`
- Modify: `src/features/bookings/bookings-page.test.tsx`

**Interfaces:**
- Consumes: Task 3 money helpers.
- Produces: human-readable booking amount input/output while RPCs still receive minor-unit strings.

- [ ] Update component tests to expect major-unit labels/value semantics.
- [ ] Convert form `amount` to minor units server-side before RPC invocation.
- [ ] Format queue amounts from minor units with currency-aware formatting.
- [ ] Keep commercial snapshot copy explicit that the amount is not a payment.
- [ ] Run targeted Vitest tests.

### Task 5: Expose complete booking lifecycle actions

**Files:**
- Modify: `src/app/workspace/bookings/actions.ts`
- Modify: `src/app/workspace/bookings/page.tsx`
- Modify: `src/features/bookings/bookings-page.tsx`
- Modify: `src/features/bookings/bookings-page.test.tsx`

**Interfaces:**
- Produces server actions for `cancel_booking_draft`, `request_booking_amendment`, `execute_booking_amendment`, `request_booking_cancellation`, `execute_booking_cancellation`, and `complete_booking_commercial_snapshot`.

- [ ] Add tests for role-appropriate controls and states.
- [ ] Add server action validation and RPC mappings for draft cancel, amend request/execute, cancellation request/execute, and legacy commercial completion.
- [ ] Add focused inline forms/cards for amendment and cancellation, including checked-in extension.
- [ ] Hide all mutation controls from viewer/accountant.
- [ ] Ensure confirm execute only renders when approval state is actually approved.
- [ ] Run targeted tests.

### Task 6: Make approvals decision-sufficient

**Files:**
- Modify: `src/app/workspace/approvals/page.tsx`
- Modify: `src/features/approvals/approval-requests-page.tsx`
- Modify: `src/features/approvals/approval-requests-page.test.tsx`

**Interfaces:**
- Consumes: expanded `list_approval_requests` row from Task 2.
- Produces: review cards for confirm/amend/cancel with snapshot detail and decision forms for all three actions.

- [ ] Add failing component tests for property/client/dates/amount/reason/change fields and amend/cancel decision buttons.
- [ ] Map expanded RPC fields in the server page.
- [ ] Render exact proposal context and expiry.
- [ ] Permit decision forms for confirm/amend/cancel pending requests.
- [ ] Run targeted tests.

### Task 7: Align RBAC and bounded queue reads

**Files:**
- Modify: `src/app/workspace/bookings/page.tsx`
- Modify: `src/features/workspace/workspace-shell.tsx`
- Modify relevant workspace shell tests.

**Interfaces:**
- Consumes: paginated queue RPC.
- Produces: consistent navigation/page read roles and a 50-row initial booking queue.

- [ ] Add tests showing accountant/viewer read access behavior and no mutation controls.
- [ ] Make booking page and nav role sets match the canonical read model.
- [ ] Call booking queue with `p_limit: 50, p_offset: 0`.
- [ ] Run targeted tests.

### Task 8: End-to-end regression and final verification

**Files:**
- Modify when needed: `e2e/authenticated-workspace.spec.ts`
- Modify: `docs/memory/CURRENT_STATE.md` if booking behavior documented there is stale.

**Interfaces:**
- Produces: repository-level verification evidence.

- [ ] Extend E2E for approval detail and at least one amendment/cancellation path if fixture setup supports it.
- [ ] Run `npm run lint`.
- [ ] Run `npm run typecheck`.
- [ ] Run `npm test`.
- [ ] Run `npm run test:db`.
- [ ] Run authenticated E2E where environment supports it.
- [ ] Run `npm run build`.
- [ ] Push final commits, open PR to `develop`, and confirm GitHub Actions `verify` is green before calling the work complete.
