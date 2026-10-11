# Voya controlled release closure implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Close the two review findings on PR #80, prove the integrated candidate, and finish managed release preflight without enabling customer outbound messaging.

**Architecture:** Keep the Next.js webhook boundary responsible for signed-event classification and transient retry responses. Keep database authorization in migrations and SQL regression proofs. Treat the checkout, Supabase environments, and Vercel deployment as separate evidence planes.

**Tech Stack:** Next.js 16, TypeScript, Vitest, Supabase PostgreSQL, Supabase CLI, GitHub Actions, Vercel.

**Spec:** PR #80 review comments and [`2026-10-07-voya-release-integration.md`](2026-10-07-voya-release-integration.md).

## Global Constraints

- Preserve verified TOTP AAL2, organization scoping, HMAC over exact OpenWA request bytes, and idempotent ingest.
- Never add service-role or worker execution to browser-callable business RPCs.
- Keep AI and WhatsApp outbound flags disabled until gateway setup, pairing, and a controlled synthetic delivery test are complete.
- Do not print, commit, or copy credentials, provider tokens, customer records, or real message content.
- Do not apply production migrations until the exact migration set has been rehearsed on an isolated production-like database and a current recoverable backup/PITR point is verified.
- User authorizes the release workflow; any paid Supabase branch still requires the provider cost confirmation gate.

## Review Focus

- The 18 extended AAL2 helpers must not be executable by `service_role`.
- A confirmed unknown or non-OpenWA session must terminate retries; resolver/database failures must remain retryable.
- Tests must prove no ingestion occurs on unknown or mismatched sessions.
- Production migrations must be forward-only, ordered, and tested against a compatible schema before application.
- Auth recovery, TOTP enrollment, and OpenWA phone pairing require user-held credentials or devices and must remain explicit handoff steps.

---

### Task 1: Prove private AAL2 helper grants

**Files:**
- Modify: `supabase/tests/workspace_rpc_aal2_extended_closure.sql`
- Modify: `scripts/test-database-foundation.mjs`
- Create: `supabase/migrations/<generated>_revoke_workspace_aal2_internal_helper_grants.sql`
- Test: the guarded disposable PostgreSQL suite invoked by `npm run test:db`

- [x] Add assertions that each discovered `_without_workspace_aal2_r01` helper is not executable by `service_role` or `voya_outbox_worker`.
- [x] Prove RED with a synthetic managed-like `service_role` grant on a disposable database, then verify the focused SQL regression passes after correction.
- [x] Add the forward migration because managed staging inspection proved the ACL exists; include it in the test-runner migration inventory and read-only release preflight.

### Task 2: Separate permanent channel mismatch from transient resolver failure

**Files:**
- Modify: `src/app/api/webhooks/whatsapp/openwa/route.ts`
- Test: `src/app/api/webhooks/whatsapp/openwa/route.test.ts`
- Inspect: `infra/openwa/individual-chats.patch` for the gateway's retry behavior

- [x] Add failing tests for an unknown session, a provider mismatch, and a resolver RPC error.
- [x] Keep unknown/mismatched registration terminal with a 404 and no ingest call.
- [x] Keep RPC or durable-ingest failures retryable with 503.
- [x] Run the webhook route tests (27/27) and full unit suite (903/903).

### Task 3: Verify the integrated candidate

**Files:**
- No production code beyond Tasks 1–2.
- Evidence: unit suite, guarded SQL suite, lint, typecheck, Deno check, build, production render checks, dependency/security scanners, and PR CI.

- [x] Run full checkout verification and record exact commands, counts, and blocked scanners.
- [x] Self-review the full candidate diff and migration ordering from the PR #80 base; no additional code issue found.
- [x] Keep preview health separate from production parity claims.

### Task 4: Update PR #80 evidence and managed release preflight

**Files:**
- Update PR #80 body with the completed review findings, exact verification evidence, remaining gates, and merge danger.
- Modify: `supabase/ops/release_integration_preflight.sql`
- Update: `docs/memory/CURRENT_STATE.md`, `docs/memory/SECURITY.md`, and `docs/RELEASE_INTEGRATION_2026-10-07.md` with dated, source-labeled evidence.

- [x] Re-read staging/production migration histories and readiness RPCs.
- [x] Rehearse the exact 92-main + 34-forward migration path on an isolated disposable database with synthetic grants and no production data.
- [ ] Verify a current production backup/PITR restore point.
- [x] No Supabase provider branch was created; the local schema rehearsal avoided an unquoted provider cost and customer-data copy.
- [x] Verify Vercel production artifact provenance; current result is CLI source with no Git commit metadata.
- [x] Update PR #80 with current evidence and keep it Draft while remote CI/scanner and backup gates remain outstanding.
- [x] Keep `main` and production unchanged because backup/PITR and other release gates are unverified.

## Completion Contract

- Both PR #80 findings have regression coverage and the full affected suites pass.
- PR #80 describes checkout evidence separately from managed-provider state and remains draft if any release gate is outstanding.
- No customer outbound message is sent; no production auth credential or MFA factor is changed by the agent.
- Any unavailable provider gate is named with the exact evidence needed to continue.
