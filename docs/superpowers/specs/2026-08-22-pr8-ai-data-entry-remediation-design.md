# PR #8 AI data-entry remediation design

**Status:** Approved in chat; written for implementation review  
**Date:** 2026-08-22  
**Branch:** `codex/ai-data-entry-confirmation`  
**PR:** #8 — Enhance Gemini output and implement human-confirmed data entry

## Goal

Bring the existing human-confirmed AI data-entry implementation into alignment with ADR-020 and the repository security contract. The remediation must close every still-valid Codex review finding without weakening tenant isolation, role authorization, MFA-gated workspace access, or the rule that AI proposes while deterministic application commands remain the source of record.

This is a checkout-only remediation. It does not deploy or mutate managed Supabase, Storage, Vercel, or provider configuration.

## Non-goals

- No autonomous Gemini source-record writes.
- No finance, pricing, cancellation, settlement, or booking-policy expansion.
- No broad browser table/storage privileges.
- No rewrite of unrelated CRM/property flows.
- No managed-environment deployment or migration apply.

## 1. Trusted confirmation and progress boundary

`record_ai_data_entry_progress_v1` must no longer be an authenticated-user command that accepts caller-asserted success evidence. The browser/server-session path may request confirmation, but application progress is authoritative only when derived from deterministic commands that actually ran.

The confirmation path will therefore separate two responsibilities:

1. an authenticated, tenant- and role-checked claim that freezes the reviewed payload and obtains a durable confirmation execution claim; and
2. a trusted server-only progress/finalization RPC invoked with the service-role boundary after `create_client_v1`, `create_property_v1`, and property-image registration return concrete results.

The trusted finalizer validates draft/version/claim ownership and stores only server-derived `application_result`. `authenticated` and `anon` must not have EXECUTE on that finalizer. SQL tests must prove the grant posture and that an authenticated caller cannot forge `applied` or `partially_applied` state.

## 2. Confirmation serialization and idempotency

A draft confirmation is a resumable command, not a fire-and-forget loop. Concurrent requests using the same confirmation key must not independently execute the same item writes.

The database claim will persist a confirmation execution token/claim state. Exactly one request becomes the active executor. Replays with the same key return the existing claim/result state; requests with a different key while execution is in progress fail closed as stale/conflicting.

Per-item keys remain stable by draft and item identity. Client/property create functions used by this flow must be concurrency-safe: the insert path should use `INSERT ... ON CONFLICT DO NOTHING` (or an equivalent atomic pattern), then load and validate the existing row. A unique-constraint race must resolve to the original record for equivalent arguments rather than produce a false partial failure.

## 3. Partial-application recovery

`application_result` is part of the review state. Page loading must return prior successful client/property/image item results for `partially_applied` drafts.

The UI must:

- mark successfully applied records as completed;
- disable editing/removal of already-applied items during retry;
- submit only unapplied selected items for execution;
- keep previously returned record IDs visible as recovery evidence without exposing sensitive data unnecessarily.

Changing an already-applied item must not be possible from the retry UI. A retry must only attempt failed/unapplied items and then merge the new deterministic results with the stored application result.

## 4. Human selection and image ownership

Human confirmation must include explicit record selection. Each extracted client/property can be included or excluded before confirmation. Gemini false positives must not force rejecting the whole batch.

Every active intake image may map to at most one property within a confirmation payload. This invariant is enforced in domain validation, not only the UI. The UI should implement transfer semantics: selecting an image for one property removes it from another property in the same editable payload.

Mapped images are immutable during partial retry and cannot be reassigned.

## 5. AI worker terminal transition

For data-entry runs, the draft transition to `ready_for_review` must succeed before the AI run is terminalized as `succeeded`, or both transitions must be performed through one atomic worker RPC.

The preferred design is a dedicated worker finalization RPC that, under the existing outbox lease checks, validates the extraction payload, transitions the draft from `extracting` to `ready_for_review`, and marks the associated AI run successful in the same database transaction. If the transition fails, neither side reports terminal success.

Existing non-data-entry AI runs keep their current lifecycle.

## 6. Expiry semantics

Do not update a draft to `expired` and then raise an exception in the same transaction, because the exception rolls the update back.

Expiry must be persisted through a non-throwing state transition that returns an explicit result, or through a separate expiry command. After expiry is committed, confirmation returns a stable expired/stale outcome. Expired drafts are terminal and read-only.

## 7. Upload idempotency and cleanup

The upload storage path must be stable for a given draft plus `x-idempotency-key`. Replaying the same upload after a lost response must address the same object/registration identity and return the existing input when checksum, MIME, size, and draft match.

The stable object identifier should be derived server-side from a cryptographic hash of the tenant, draft, and idempotency key rather than trusting the key as a path segment.

All Storage operations must inspect returned `{ error }` values. Failed cleanup is operationally reported and must not be presented to the user as successful cleanup. Intake object cleanup remains best-effort where rollback is impossible, but orphaned-object failures must be observable for later remediation.

## 8. Image-only draft creation

The product supports image-only intake. Draft creation therefore permits empty source text. The UI no longer marks text as required and explains that the operator must provide text, images, or both before submission.

Submission remains the authoritative content gate: a draft can enter extraction only when it has non-empty source text or at least one active image input.

## 9. Gemini truncated-response parsing

Partial-array extraction must stop at the selected JSON array boundary. The fallback parser may recover complete strings from a truncated array but must never consume keys/strings from later fields such as `risks` into `suggestions`.

Regression tests cover truncated JSON where `suggestions` is closed before a later truncated `risks` array, and the inverse ordering where applicable.

## 10. Draft navigation and terminal UI

All reviewable drafts returned by the bounded server query must remain reachable. Remove the duplicated five-item truncation from the review loader and selector. If the existing twenty-row server bound remains, the UI may render all twenty; pagination is not required for this remediation.

`applied`, `rejected`, `expired`, and `failed` drafts are terminal. They must not render the editable confirmation/rejection form. `applied` renders a read-only completion summary. `partially_applied` renders resumable review state with completed items locked.

## 11. Tests and verification

Use failing tests first where practical. Required regression coverage:

### Domain/unit

- duplicate `imageInputIds` across properties rejected;
- record include/exclude behavior;
- partial JSON arrays do not consume later fields;
- applied/partial UI behavior and draft switching;
- image-only creation and submission rules.

### Server action/route

- deterministic upload retry path and equivalent replay success;
- storage cleanup returned errors are handled/logged;
- partial retry skips successful items;
- authenticated action cannot fabricate application progress;
- stale/concurrent confirmation produces safe retry behavior.

### SQL/database

- progress/finalization RPC is worker/service-only;
- authenticated and anon denial for trusted finalization;
- tenant and role checks remain intact;
- concurrent confirmation claim has one executor;
- equivalent concurrent client/property idempotency returns one record;
- expiry persists as terminal state;
- atomic data-entry extraction success leaves both run and draft consistent.

### Full checkout gates

Run the repository-required verification appropriate to the touched surfaces:

- `npm test`
- `npm run lint`
- `npm run typecheck`
- `npm run test:memory`
- `npm run test:db` against the guarded disposable loopback test database when available
- `npm run build`
- `npm run test:production` if protected rendering behavior changes
- relevant authenticated E2E for data entry when the local harness is available
- `git diff --check` equivalent through repository/CI evidence

Security scanning remains a separate gate; unavailable trusted scanners are BLOCKED, never reported as PASS.

## 12. Documentation and evidence

After implementation, update living memory to match checkout truth:

- `docs/memory/SECURITY.md` for the trusted finalization boundary;
- `docs/memory/DOMAIN_RULES.md` for human selection, partial recovery, and image uniqueness;
- `docs/memory/CURRENT_STATE.md` for the remediated branch verification snapshot;
- `docs/memory/DATA_MODEL.md` only if persisted claim/result fields change the model materially.

Update `docs/SECURITY_REVIEW_AI_DATA_ENTRY.md` with the new checkout evidence. Do not claim managed Supabase/Storage deployment from branch verification.

## Acceptance criteria

PR #8 is merge-ready only when all of the following are true on its new head:

1. No authenticated caller can directly assert successful AI data-entry application progress.
2. Concurrent confirmation/replay cannot create false `partially_applied` state or duplicate records.
3. Partial retries preserve and lock completed item results.
4. One intake image cannot be assigned to multiple properties.
5. Image-only intake is reachable and submission still rejects empty drafts.
6. AI run success and draft readiness cannot diverge on worker finalization.
7. Expiry is durably persisted.
8. Upload retry paths are stable and cleanup errors are checked.
9. Gemini fallback parsing keeps list fields separated.
10. Operators can exclude false-positive extracted records.
11. All bounded reviewable drafts remain reachable and terminal drafts are read-only.
12. New regression tests pass together with the repository quality gates.
13. A fresh Codex review is run against the new head after remediation; resolved GitHub threads alone are not accepted as proof of correctness.
