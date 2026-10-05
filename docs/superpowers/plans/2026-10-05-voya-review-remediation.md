# Voya OS Review Remediation Plan

**Goal:** Remediate each still-applicable finding F01–F14 from the supplied review against the latest `origin/develop`, with tests and evidence, then open a PR.

**Architecture:** Preserve historical migrations and add forward migrations for database changes. Fix application and worker paths at their trust boundaries, retain tenant and MFA policy, and use local/disposable verification only. Findings already fixed on the new base will be documented as covered by existing code and tests rather than duplicated.

**Tech Stack:** Next.js 16, TypeScript, Vitest, PostgreSQL/Supabase migrations and SQL tests, Deno Edge Function.

## Global Constraints

- Never modify managed Supabase or Vercel environments.
- Preserve `.env.local` and do not print or commit secrets.
- Do not modify the dirty primary checkout.
- Do not rewrite historical migrations.
- Verify database changes only on disposable local PostgreSQL.
- Separate checkout verification from managed deployment truth.

## Review Focus

- Direct authenticated RPC calls with AAL1 and cross-agent lead IDs.
- Reuse of an idempotency key with a changed command, resource, or payload.
- High-cardinality unauthenticated requests and login contention.
- Lease expiry and worker retry exhaustion with the AI run and event in different states.
- Missing scheduler credentials during install and scheduler reconciliation after setup.
- Cross-tenant media reads and browser decoding under production CSP.
- Large tenant lists and low-confidence AI contact extraction.
- Assertions that only print values, PUBLIC function execution inherited by roles, keyboard focus contrast, and malformed Server Action inputs.

## Execution Tasks

1. **AuthZ and command integrity (F01–F03).** Trace the active booking and CRM RPCs on this base. Add direct SQL regressions first, then enforce AAL2/role/membership gates, lock and authorize target leads before replay/mutation, and bind booking/CRM replay keys to a canonical request and stored result. Extend SQL tests and action contract tests.
2. **Authentication and worker lifecycle (F04–F07).** Add bounded source-based auth throttling before bucket allocation while retaining account abuse controls; add safe bucket cleanup. Make WhatsApp AI failure finalization atomic and observable. Bound worker claim/processing behavior and add idempotent scheduler reconciliation plus readiness evidence that does not falsely claim a hosted job ran.
3. **Media, list performance, and AI integrity (F08–F10).** Stream authorized WhatsApp bytes from the same-origin media route and test decode under production CSP. Bound leads/properties page reads with pagination/detail loading or equivalent batching. Keep extracted WhatsApp facts as proposals and prevent unconfirmed overwrite of established CRM fields.
4. **Test/security/UI/action hardening (F11–F14).** Convert result-only checks to assertions and prove the failure mode; revoke unintended PUBLIC function execute defaults and assert catalog posture; improve visible focus contrast; parse action inputs at runtime and match signup/recovery password minimums to Supabase config.
5. **Verification and publication.** Run focused RED/GREEN checks while implementing, the repository database runner against a disposable loopback `*_test` database, full lint/typecheck/unit/coverage and applicable browser/production checks. Obtain an independent security/correctness review, address supported findings, then open and attach a PR. Report hosted scheduler/deployment facts as unknown unless read-only evidence is available.

## Done

- Every F01–F14 is either fixed with a regression proof or shown already fixed on this base with a passing relevant test.
- No managed environment was mutated.
- The branch passes applicable verification, has an independent review, and an open PR attached to this task.
