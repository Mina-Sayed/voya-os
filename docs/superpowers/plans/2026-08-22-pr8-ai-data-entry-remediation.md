# PR #8 AI Data-Entry Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make PR #8 merge-ready by closing every still-valid Codex finding while preserving the human-confirmed AI proposal boundary.

> **Final implementation note — 2026-08-24:** Tasks 1–5 were implemented across
> the recovery, cleanup, lock-order, terminal-archival, AAL2, and atomic image
> mapping migrations, with matching Vitest/SQL/Playwright coverage. This plan is
> retained as execution history; current checkout truth is recorded in
> `docs/memory/CURRENT_STATE.md` and `docs/SECURITY_REVIEW_AI_DATA_ENTRY.md`.

**Architecture:** Keep the existing Next.js 16 modular monolith and Supabase command model. Move authoritative AI data-entry finalization behind a trusted server/service boundary, make confirmation and item writes concurrency-safe and resumable, then align worker lifecycle, upload behavior, parser recovery, and review UI with those invariants.

**Tech Stack:** Next.js 16 App Router, React, TypeScript, Supabase Auth/PostgreSQL/Storage, PL/pgSQL SECURITY DEFINER RPCs, Vitest, SQL integration tests, Playwright/GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-08-22-pr8-ai-data-entry-remediation-design.md`

## Global Constraints

- AI remains proposal-only; no autonomous source-record writes.
- Browser/session callers must not assert application success evidence.
- Tenant identity and actor/role remain server/database-derived.
- Service role remains server-only.
- Existing CRM/property commands remain source-of-record authority.
- No managed Supabase/Storage/Vercel mutation is part of this plan.
- Use failing regression tests before behavior changes where practical.

---

### Task 1: Harden database confirmation, progress, expiry, and command idempotency

**Files:**
- Modify: `supabase/migrations/20260822121522_ai_data_entry_drafts.sql`
- Modify: `supabase/migrations/20260813000200_crm_v1.sql`
- Modify: `supabase/migrations/20260813000100_property_inventory_v1.sql`
- Modify: `supabase/tests/ai_data_entry.sql`
- Modify: `scripts/test-database-foundation.mjs` only if the test registry requires a new assertion file.

**Interfaces:**
- Produces a trusted finalization RPC executable only by `service_role`/worker boundary.
- Produces serialized confirmation claim semantics so one executor owns a confirmation attempt.
- Produces concurrency-safe `create_client_v1` and `create_property_v1` behavior for equivalent idempotent retries.

- [ ] **Step 1: Add failing SQL tests** proving authenticated/anon cannot finalize progress, expiry persists, duplicate concurrent confirmation cannot create two executors, and equivalent idempotent client/property retries return one record.
- [ ] **Step 2: Run the guarded DB suite** and verify the new assertions fail on the current head.
- [ ] **Step 3: Replace authenticated progress assertion with trusted finalization.** Keep authenticated `begin_ai_data_entry_confirmation_v1` as the human claim boundary; make final progress/result recording service-only and validate the active claim/version before storing server-derived results.
- [ ] **Step 4: Fix expiry semantics** so the terminal `expired` update commits without being rolled back by a subsequent exception.
- [ ] **Step 5: Serialize confirmation execution** using persisted claim state/token so matching replays observe existing state and a conflicting executor cannot independently run item writes.
- [ ] **Step 6: Make `create_client_v1` and `create_property_v1` atomic under concurrent equivalent retries** via insert-on-conflict/read-and-validate semantics.
- [ ] **Step 7: Run DB tests** and verify all new and existing SQL assertions pass.
- [ ] **Step 8: Commit** with a focused message such as `fix(db): harden AI data-entry confirmation`.

---

### Task 2: Make data-entry worker completion atomic and parser recovery correct

**Files:**
- Modify: `supabase/functions/outbox-dispatch/index.ts`
- Modify: `supabase/migrations/20260822121522_ai_data_entry_drafts.sql`
- Modify: `supabase/tests/ai_data_entry.sql`
- Modify: `src/features/ai/ai-result-presentation.ts`
- Modify: `src/features/ai/ai-result-presentation.test.ts`
- Modify: `src/lib/ai/data-entry-worker.test.ts` or the existing worker lifecycle test covering `outbox-dispatch` contracts.

**Interfaces:**
- Produces one worker RPC that transitions `extracting -> ready_for_review` and the matching AI run to `succeeded` atomically under the current outbox lease.
- Keeps non-data-entry AI run behavior unchanged.

- [ ] **Step 1: Add failing tests** for draft/run divergence and partial-list parser field bleed.
- [ ] **Step 2: Verify tests fail** against the current ordering and greedy fallback parser.
- [ ] **Step 3: Add atomic data-entry worker finalization RPC** and change the worker to call it instead of marking the run succeeded first.
- [ ] **Step 4: Bound `extractPartialList` to the selected array** so a closed `suggestions` array cannot consume later `risks` strings.
- [ ] **Step 5: Run targeted worker/parser tests and DB tests.**
- [ ] **Step 6: Commit** as `fix(ai): make data-entry finalization atomic`.

---

### Task 3: Fix image-only intake, deterministic upload retry, cleanup error handling, and image uniqueness

**Files:**
- Modify: `src/app/api/workspace/ai/data-entry/inputs/route.ts`
- Modify: `src/app/api/workspace/ai/data-entry/inputs/route.test.ts`
- Modify: `src/app/workspace/ai/data-entry-actions.ts`
- Modify: `src/app/workspace/ai/data-entry-actions.test.ts`
- Modify: `src/domain/ai/data-entry-contract.ts`
- Modify: `src/domain/ai/data-entry-contract.test.ts`
- Modify: `src/features/ai/data-entry-intake.tsx`
- Modify: `src/features/ai/data-entry-intake.test.tsx`

**Interfaces:**
- Deterministic storage object identity derived server-side from organization, draft, and idempotency key.
- `parseEditableDataEntryPayload`/domain validation rejects one intake image appearing in multiple properties.
- Draft creation accepts empty source text; submission still requires text or at least one active image.

- [ ] **Step 1: Add failing unit/route/action tests** for image-only creation, empty submission denial, equivalent upload replay, returned Storage cleanup errors, and payload-wide image uniqueness.
- [ ] **Step 2: Verify the tests fail** on the current implementation.
- [ ] **Step 3: Derive stable upload object IDs** from a cryptographic hash of tenant + draft + idempotency key and make equivalent retries return the existing registration.
- [ ] **Step 4: Inspect Storage `{ error }` results** for rollback/reject cleanup and report failures instead of silently claiming cleanup success.
- [ ] **Step 5: Permit image-only draft creation** in the action/UI while preserving submission validation.
- [ ] **Step 6: Enforce payload-wide image uniqueness** and implement UI transfer semantics when selecting an image for a property.
- [ ] **Step 7: Run the targeted tests.**
- [ ] **Step 8: Commit** as `fix(ai): harden data-entry intake and images`.

---

### Task 4: Implement resumable partial application, human record exclusion, full draft reachability, and terminal read-only UI

**Files:**
- Modify: `src/app/workspace/ai/page.tsx`
- Modify: `src/app/workspace/ai/data-entry-actions.ts`
- Modify: `src/app/workspace/ai/data-entry-actions.test.ts`
- Modify: `src/features/ai/data-entry-review.tsx`
- Modify: `src/features/ai/data-entry-review.test.tsx`
- Modify: `src/features/ai/data-entry-intake.tsx`
- Modify: `src/features/ai/data-entry-intake.test.tsx`
- Modify domain types under `src/domain/ai/data-entry-contract.ts` only if a small explicit selection/result type is needed.

**Interfaces:**
- `DataEntryDraftReview` carries sanitized prior `applicationResult` for partial recovery.
- Applied item results are locked and skipped by retries.
- Operators can include/exclude unapplied extracted clients/properties before confirmation.

- [ ] **Step 1: Add failing UI/action tests** proving previously successful items are locked/skipped, false-positive records can be excluded, applied drafts are read-only, and review navigation does not truncate to five items.
- [ ] **Step 2: Verify the tests fail** on the current review/page/action behavior.
- [ ] **Step 3: Load and expose prior `application_result`** for `partially_applied` drafts, preserving only IDs/status/error codes needed for recovery UI.
- [ ] **Step 4: Skip already-applied items during retry** and merge new deterministic results with stored progress before trusted finalization.
- [ ] **Step 5: Add explicit include/exclude controls** for unapplied clients/properties and submit only selected items.
- [ ] **Step 6: Render terminal drafts read-only** and remove `applied` from editable review states.
- [ ] **Step 7: Remove duplicated five-item slicing** so all drafts from the bounded server query remain reachable.
- [ ] **Step 8: Run targeted React/action tests.**
- [ ] **Step 9: Commit** as `fix(ui): make AI data-entry recovery resumable`.

---

### Task 5: Update durable documentation and run full verification

**Files:**
- Modify: `docs/memory/SECURITY.md`
- Modify: `docs/memory/DOMAIN_RULES.md`
- Modify: `docs/memory/CURRENT_STATE.md`
- Modify: `docs/memory/DATA_MODEL.md` if persisted confirmation claim fields changed materially.
- Modify: `docs/SECURITY_REVIEW_AI_DATA_ENTRY.md`

**Interfaces:**
- Documentation describes checkout truth only and does not claim managed deployment.

- [ ] **Step 1: Update memory/security review** to document trusted finalization, serialized confirmation, partial recovery, image uniqueness, and verification evidence.
- [ ] **Step 2: Run targeted unit suites** for the modified AI data-entry modules.
- [ ] **Step 3: Run `npm test`.**
- [ ] **Step 4: Run `npm run lint`.**
- [ ] **Step 5: Run `npm run typecheck`.**
- [ ] **Step 6: Run `npm run test:memory`.**
- [ ] **Step 7: Run guarded `npm run test:db` when the disposable loopback DB harness is available.**
- [ ] **Step 8: Run `npm run build` and `npm run test:production` because protected workspace rendering changed.**
- [ ] **Step 9: Run the relevant authenticated data-entry E2E when the local harness is available.**
- [ ] **Step 10: Confirm GitHub Actions on the new head are green; treat unavailable security scanners as BLOCKED, not PASS.**
- [ ] **Step 11: Request a fresh `@codex review` against the new head and do not rely on resolved historical threads.**
- [ ] **Step 12: Commit documentation/evidence** as `docs: record PR 8 remediation verification`.

## Self-review

- Spec coverage: every accepted remediation section maps to Tasks 1–5.
- Placeholder scan: no TBD/TODO/"implement later" steps remain.
- Type/interface consistency: confirmation claim/finalizer is produced in Task 1 and consumed by Tasks 3–4; partial `applicationResult` is produced by page loading and consumed by review/action retry logic in Task 4.
- Scope remains limited to PR #8 AI data-entry correctness/security; no finance/booking/provider rollout expansion.
