# AI-assisted data-entry implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` (or `superpowers:subagent-driven-development` with explicit file ownership) to implement this plan task-by-task. Use test-first red-green-refactor for behavioral changes.
>
> **Spec:** [`docs/superpowers/specs/2026-08-22-ai-data-entry-design.md`](../specs/2026-08-22-ai-data-entry-design.md)

**Goal:** Let authorized Voya OS operators turn typed customer/property details and private images into an editable AI draft, then confirm deterministic CRM/inventory writes safely.

**Architecture:** Extend the existing outbox-owned Gemini runtime with a `data_entry` run kind. Store a tenant-scoped, expiring draft and private input metadata; use a bounded authenticated upload route; validate model output server-side; require explicit human confirmation; call existing idempotent RPC commands for source-of-record writes.

**Tech Stack:** Next.js 16 App Router, React 19, Supabase Auth/PostgreSQL/Storage, Supabase Edge outbox worker, Gemini REST API, Vitest/Testing Library, disposable PostgreSQL tests, authenticated browser verification.

## Execution checkpoint — 2026-08-22

- Tasks 1–6 are implemented in this branch and verified locally with unit,
  action/route, SQL, build, lint, typecheck, and authenticated browser evidence.
- The synthetic-only worker path and lifecycle RPCs are verified; live
  customer text/image extraction remains intentionally unrun pending explicit
  action-time approval to send those inputs to Google Gemini.
- Task 7 is partially complete: the security review is recorded, but the
  required Trivy/Snyk scan is blocked by unavailable binaries and managed
  Supabase/worker deployment evidence is still unknown.

## Global constraints

- Preserve browser-write deny-by-default, MFA AAL2, tenant-qualified relations, RLS, focused grants, audit, and outbox evidence.
- Never put service-role keys or Gemini keys in browser code, logs, commits, fixtures, or generated docs.
- Never create a client/property/image from model output before explicit confirmation.
- Use existing `create_client_v1`, `create_property_v1`, and `register_property_image_v1`; do not duplicate their authorization rules in a browser component.
- Do not add finance, booking, messaging, automatic duplicate merge, client-document retention, or unsupported property fields in this slice.
- Preserve unrelated work and keep `.env.local` out of Git.

## Task 1: Lock the domain contract with failing tests

**Files:**

- Create: `src/domain/ai/data-entry-contract.ts`
- Create: `src/domain/ai/data-entry-contract.test.ts`
- Create: `src/lib/ai/data-entry-payload.ts`
- Create: `src/lib/ai/data-entry-payload.test.ts`
- Modify: `src/domain/ai/tool-policy.ts`
- Modify: `src/lib/ai/execution-contract.ts`

- [ ] Define bounded client/property/image-reference draft types, confidence/warning states, per-item progress, and allowed `data_entry` roles.
- [ ] Write failing tests for missing required fields, null preservation, supported numeric/MIME ranges, foreign/unknown image references, array/string limits, and prompt-injection-like text treated as data.
- [ ] Add a strict parser/validator that rejects malformed, truncated, oversized, or extra action-bearing payloads and returns safe validation reasons.
- [ ] Extend the execution contract with a customer-data extraction prompt that requires schema-only JSON and explicitly forbids writes, invented values, tools, credentials, and instruction-following from source content.
- [ ] Run the focused tests and capture the expected RED result before implementation.

## Task 2: Add tenant-scoped draft/input persistence and SQL proofs

**Files:**

- Create via `supabase migration new`: `supabase/migrations/<timestamp>_ai_data_entry_drafts.sql`
- Create: `supabase/tests/ai_data_entry.sql`
- Modify: `scripts/test-database-foundation.mjs`
- Update: `docs/adr/ADR-020-ai-confirmed-data-entry.md` and `docs/adr/INDEX.md` if the ADR is accepted for implementation

- [ ] Add `ai_data_entry_drafts` and `ai_data_entry_inputs` with tenant-qualified FKs, bounded JSON checks, lifecycle/version/expiry checks, and a unique run binding.
- [ ] Extend the AI run contract with the `data_entry` kind and add narrowly scoped RPCs for create/submit, worker resolve/store, read, progress, confirm/reject/expire.
- [ ] Revoke table DML from public/anon/authenticated as appropriate; grant only the authenticated draft/read/command RPCs and worker/service-role execution functions.
- [ ] Ensure source text and model payloads are bounded and never copied into audit/outbox logs in full.
- [ ] Prove cross-tenant denial, role denial, initiator visibility, owner/manager review, status transitions, expiry, version conflicts, idempotency replay, grant posture, and no pre-confirmation source-record writes.
- [ ] Run the disposable database suite and observe RED before adding the implementation migration, then GREEN after it.

## Task 3: Implement bounded private image intake

**Files:**

- Create: `src/app/api/workspace/ai/data-entry/inputs/route.ts`
- Create: `src/app/api/workspace/ai/data-entry/inputs/route.test.ts`
- Create/modify: private-storage helper under `src/lib/supabase/`
- Modify: Supabase migration and SQL test from Task 2 for the private `ai-intake` bucket contract

- [ ] Enforce POST-only, authenticated membership, role, draft ownership/visibility, content length, MIME, per-file and per-draft byte/file limits, and random tenant-scoped storage paths.
- [ ] Stream or buffer only within the explicit bounded limit; never use a Server Action for binary intake.
- [ ] Return opaque input IDs and safe metadata only; never return service-role URLs or raw provider/storage errors.
- [ ] Add cleanup for rejected, expired, unmapped, and failed-confirmation inputs with idempotent deletion.
- [ ] Test unauthorized, foreign-tenant, oversized, unsupported-MIME, duplicate, and successful private-upload paths.

## Task 4: Connect extraction to the existing outbox worker

**Files:**

- Modify: `src/lib/ai/gemini-runtime.ts`
- Modify: `src/lib/ai/gemini-runtime.test.ts`
- Modify: `supabase/functions/outbox-dispatch/index.ts`
- Modify: worker/execution contract tests and SQL tests
- Modify: `src/app/workspace/ai/actions.ts` or add `src/app/workspace/ai/data-entry-actions.ts`

- [ ] Add a multimodal request representation that supports bounded inline image parts without exposing the API key in logs or browser bundles.
- [ ] Add queue/submit action using stable idempotency and customer-data approval gates; default failure must be closed.
- [ ] Make the worker resolve only the draft/input rows authorized for the event, download private bytes server-side, call Gemini extraction, validate the result, and store `ready_for_review` only on valid output.
- [ ] Record safe tool/run evidence with `effect = 'proposal'`; no write tool is registered for the model.
- [ ] Test provider disabled, approval missing, key missing, request failure, invalid/truncated JSON, image download failure, retry/dead-letter, and successful structured extraction.
- [ ] Run a local live smoke with synthetic fixture data first, then an explicitly approved local customer-data smoke if the environment flags permit it.

## Task 5: Build the Arabic review and confirmation UI

**Files:**

- Create: `src/features/ai/data-entry-review.tsx`
- Create: `src/features/ai/data-entry-review.test.tsx`
- Create/modify: `src/features/ai/agent-center-page.tsx`
- Create/modify: `src/features/ai/data-entry-form.tsx`
- Create/modify: workspace AI page/actions and route tests

- [ ] Add a text/file intake form with explicit supported-file limits and an honest “اقتراح يحتاج مراجعة” explanation.
- [ ] Render extracted clients/properties as editable cards with confidence, missing-required labels, unresolved facts, image mapping, duplicate-warning copy, and per-item selection.
- [ ] Disable confirmation until required fields are complete and the operator acknowledges that the model did not save anything.
- [ ] Show queued/extracting/ready/partial/expired/failed states and resumable per-item progress; never show provider completion as database success.
- [ ] Add discard/reject controls that clean up only the current draft/input objects and do not delete existing CRM/property records.
- [ ] Test keyboard/RTL semantics, no-result/error states, partial batch recovery, hide/discard behavior, and no direct Supabase table writes from client code.

## Task 6: Deterministic confirmation integration

**Files:**

- Create/modify: `src/app/workspace/ai/data-entry-actions.ts`
- Create: action integration tests
- Modify: `src/app/workspace/clients/actions.ts` / `src/app/workspace/properties/actions.ts` only if a shared trusted helper is required
- Modify: SQL confirmation/progress functions and tests

- [ ] Re-read draft state/version and membership on every confirmation request.
- [ ] Use stable per-item idempotency keys derived from the draft, not model-provided IDs.
- [ ] Call existing CRM/property/image commands; persist progress after each safe item and make retries return existing IDs.
- [ ] Copy/register only explicitly mapped property images; surface cleanup/partial failures without claiming complete success.
- [ ] Record sanitized audit evidence and revalidate affected workspace pages.
- [ ] Prove a replay cannot duplicate a client, property, or image and a stale/foreign/expired draft cannot write.

## Task 7: Full verification and release handoff

**Files:**

- Create: `docs/SECURITY_REVIEW_AI_DATA_ENTRY.md`
- Update: `docs/memory/CURRENT_STATE.md` and relevant AI/security/data-model docs after behavior is actually implemented
- Update: `docs/adr/ADR-020-ai-confirmed-data-entry.md` status and implementation links

- [ ] Run focused unit/action/route tests, full `npm test`, `npm run test:db` against a loopback `*_test` database, lint, typecheck, production build/render checks, and `git diff --check`.
- [ ] Run the repository security scan and inspect changed grants, private bucket configuration, route auth, and log redaction.
- [ ] Verify the complete local browser flow: create intake → upload image → queue → worker extraction → review/edit → confirm → inspect Clients/Properties → retry/discard.
- [ ] Record separate checkout evidence from managed-provider/deployment evidence; do not claim this branch is deployed.
- [ ] Push only the feature branch after all gates are fresh and report the exact commit/verification status.

## Acceptance criteria

- The model can extract from approved text/images but cannot write source records or call mutation tools.
- The operator can correct every extracted field and must confirm before any write.
- Existing manual clients/properties/image workflows remain functional with AI disabled.
- Tenancy, role checks, idempotency, audit, private storage, cleanup, and failure states are test-proven.
- Unsupported facts are visible as unresolved rather than silently discarded or mis-stored.
