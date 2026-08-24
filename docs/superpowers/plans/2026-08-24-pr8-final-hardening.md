# PR #8 Final Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close every still-valid fresh Codex/CodeRabbit finding on PR #8, preserve human-confirmed data-entry guarantees, and finish with the complete quality/security workflow green.

**Architecture:** Keep the current modular-monolith design and add forward-only database hardening rather than rewriting historical migrations. Trusted confirmation progress remains service-role-only and token-bound; browser upload retries gain stable client-side idempotency; operator UI changes remain local and deterministic; system-health observability includes data-entry recovery events.

**Tech Stack:** Next.js App Router, React, TypeScript, Vitest, Supabase/PostgreSQL, Supabase Storage, GitHub Actions, Snyk, Trivy.

**Spec:** `docs/superpowers/specs/2026-08-22-pr8-ai-data-entry-remediation-design.md`

## Global Constraints

- Do not merge PR #8 into `develop` during this work.
- Human confirmation remains mandatory before source-of-record client/property writes.
- Browser callers never receive service-role credentials.
- Trusted bookkeeping RPCs use fixed `search_path`, schema-qualified names, and narrow `EXECUTE` grants.
- Every behavior fix starts with a failing regression test and is verified green before continuing.
- Managed Supabase/Storage/Edge resources are not deployed from this plan.

---

### Task 1: Durable confirmation progress and expiry-safe execution

**Files:**
- Create: `supabase/migrations/20260824040000_finalize_ai_data_entry_recovery.sql`
- Modify: `supabase/tests/ai_data_entry_recovery.sql`
- Modify: `src/app/workspace/ai/data-entry-actions.ts`

**Interfaces:**
- Produces service-only `persist_ai_data_entry_confirmation_progress_v1(...) -> boolean`.
- Replaces heartbeat/archive/mapping/rejection implementations with consistent lock ordering and valid-token semantics.

- [ ] Add failing DB assertions proving successful per-item progress can be persisted before finalization, a valid confirmation can continue after the original draft expiry, rejection is restricted to reviewable drafts, and trusted helpers remain service-only.
- [ ] Run the database suite and confirm the new assertions fail on the old implementation.
- [ ] Add the forward migration with token-bound incremental progress, draft-first locking, expiry-safe active confirmation helpers, and strict rejection transitions.
- [ ] Update the Server Action to persist each successful client/property/image result before proceeding and to return merged IDs on every heartbeat failure path.
- [ ] Re-run targeted Vitest/DB suites and confirm green.

### Task 2: Upload retry identity and refreshed intake UI

**Files:**
- Modify: `src/features/ai/data-entry-intake.tsx`
- Modify: `src/features/ai/data-entry-intake-remediation.test.tsx`

**Interfaces:**
- Keeps one stable upload idempotency key per selected file fingerprint until a confirmed successful response.
- Refreshes server-provided draft summaries after successful upload batches.

- [ ] Add failing tests for ambiguous upload retry key reuse and post-upload draft-count refresh.
- [ ] Verify the tests fail on the current component.
- [ ] Add stable in-memory upload-key tracking and `router.refresh()` after at least one successful upload.
- [ ] Re-run the intake tests and confirm green.

### Task 3: Review and timestamp UI correctness

**Files:**
- Modify: `src/features/ai/data-entry-review.tsx`
- Modify: `src/features/ai/data-entry-review-image-recovery.test.tsx`
- Modify: `src/features/ai/agent-center-page.tsx`
- Modify: `src/features/ai/agent-center-page.test.tsx`

**Interfaces:**
- Applied property image controls cannot steal bindings from pending properties.
- Agent timestamps are deterministic across SSR and hydration.

- [ ] Add failing tests for applied-property image disabling and fixed run timestamp timezone.
- [ ] Verify RED.
- [ ] Disable all image mutation for already-applied properties while preserving failed-image recovery on pending properties; format run timestamps with `timeZone: "UTC"`.
- [ ] Verify GREEN.

### Task 4: Data-entry recovery observability

**Files:**
- Create or extend a forward migration under `supabase/migrations/`.
- Modify an existing database regression suite.

**Interfaces:**
- `ai.data_entry.requested` events in `needs_review` contribute to AI recovery health/notification behavior consistently with `ai.run.requested`.

- [ ] Add a failing DB assertion for data-entry `needs_review` visibility.
- [ ] Verify RED.
- [ ] Extend the relevant health/notification query or trigger with the data-entry event type while preserving tenant scoping.
- [ ] Verify GREEN.

### Task 5: Test isolation and durable documentation

**Files:**
- Modify: `supabase/tests/ai_data_entry_cleanup.sql`
- Modify: `docs/memory/CURRENT_STATE.md`
- Modify: `docs/superpowers/plans/2026-08-22-pr8-ai-data-entry-remediation.md`
- Modify: `docs/superpowers/specs/2026-08-22-ai-data-entry-design.md`
- Modify: `docs/SECURITY_REVIEW_AI_DATA_ENTRY.md`

- [ ] Isolate the outbound-lease SQL scenario so it leaves no shared `outbox_events` state.
- [ ] Replace stale random-path/design wording with deterministic opaque identity requirements.
- [ ] Extend the older remediation plan with the final recovery blockers now implemented.
- [ ] Update current-state verification facts only after the final CI run provides evidence.

### Task 6: Full verification and fresh review

- [ ] Run memory validation, lint, typecheck, coverage, database integration, Playwright E2E, production build/tests, auth-local E2E, npm audit, Snyk, and Trivy through the repository workflow.
- [ ] Inspect every failure; fix root cause with a RED regression first.
- [ ] Request fresh Codex and CodeRabbit review on the final head.
- [ ] Resolve only threads proven fixed on that exact head.
- [ ] Declare the PR technically merge-ready only when final CI is fully green and no release-blocking fresh finding remains.