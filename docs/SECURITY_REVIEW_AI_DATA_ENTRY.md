# Security review — human-confirmed AI data entry

**Date:** 2026-08-24
**Checkout:** `codex/ai-data-entry-confirmation`
**Status:** Checkout/CI verification only; managed rollout and live customer-data smoke gated

## Scope

This review covers the text/image intake, governed extraction run, editable
review draft, confirmation action, deterministic client/property/image writes,
partial recovery, private `ai-intake` storage boundary, and outbox/provider
lease ownership immediately before external delivery.

## Controls verified by the branch design and regression suite

- Drafts and inputs are organization-scoped with tenant-qualified foreign keys,
  forced RLS, bounded source/payload sizes, expiry/version fields, and focused
  RPC grants.
- The browser cannot insert into draft/input tables. Server Actions derive the
  active membership and organization from the verified session; RPCs repeat the
  role and tenant checks.
- `owner`, `manager`, `sales_agent`, and `operations` can collect drafts. Only
  owner/manager/operations can persist properties/images through the existing
  property commands. Viewer/accountant paths fail closed for data-entry writes.
- Image upload is a bounded Node route, not a Server Action. It accepts only
  JPEG/PNG/WebP, 10 MiB per file, 20 files/25 MiB per draft, deterministic
  tenant/draft/idempotency-bound private paths, and private `ai-intake`
  storage. Replay metadata/checksum mismatches fail closed. Failed metadata
  registration checks the resolved Storage cleanup result and will not delete a
  peer request's successfully registered deterministic object.
- Human review can display an intake image only through an authenticated,
  tenant-scoped preview route. The route resolves the input from
  `list_ai_data_entry_inputs_v1`, never accepts a storage path from the caller,
  downloads only the database-authorized private object with the service role,
  validates byte size, and returns `private, no-store` content.
- Gemini receives no SQL, HTTP, credential, identity, or mutation tools. Source
  text and images are treated as untrusted content; schema validation rejects
  malformed, oversized, unknown-image, foreign-image, and duplicate
  image-assignment payloads. Extraction uses a larger bounded output budget than
  ordinary proposal generation and image IDs are explicitly bound to image
  ordinals in the prompt.
- A worker must still own a live outbox lease immediately before every Gemini
  call. Data-entry revalidation occurs after private image loading and before
  provider invocation; ordinary AI calls revalidate immediately before the
  provider as well. The trusted renewal RPC cannot revive an expired lease and
  is executable only by the dedicated worker/service boundary.
- Email and WhatsApp provider sends also revalidate a still-live delivery lease
  immediately before the external network call. This closes late-in-batch
  stale-worker sends; Resend's provider idempotency remains an additional layer,
  while WhatsApp does not rely on provider-side idempotency for this guarantee.
- Confirmation is explicit and version/idempotency protected. A durable
  execution token serializes confirmation work, while the trusted service
  boundary records only deterministic command results that actually ran.
  Confirmation executions maintain a trusted heartbeat before source-record,
  image, cleanup, and finalization operations. Stale `confirmed` claims remain
  reclaimable only after the trusted heartbeat is stale; active claims reject
  overlapping execution. Every authenticated AI data-entry RPC enforces the
  same MFA AAL2 requirement inside PostgreSQL; service-role/worker helpers are
  separately granted and do not depend on an end-user assurance claim.
- Operator exclusions are stored atomically with the confirmation claim as
  `excluded_by_operator` terminal decisions in `application_result`. Partial
  reloads restore those exclusions rather than silently re-including
  false-positive model records. Operators can explicitly re-include an
  excluded record on a later retry.
- Partial application state stores successful record IDs and safe per-item error
  codes. Successful items remain locked and skipped on retry; failed image
  mappings remain reviewable even after the parent property was created; the
  review UI exposes actionable errors for failed client/property/image items.
- One intake image can be assigned to only one proposed property. For the AI
  idempotency-key path, property-image registration and intake mapping are one
  PostgreSQL transaction: if mapping fails, the property-image row, audit event,
  and outbox evidence roll back together. The confirmation action therefore
  does not issue a second legacy mapping RPC; service-only mapping remains a
  separate recovery boundary.
- Unassigned intake inputs are archived through a token-bound trusted RPC before
  a draft can become `applied`; terminal status transitions also archive any
  remaining active intake metadata in the database.
- Permanent extraction failure and retry exhaustion first atomically terminalize
  the AI run and draft at the database boundary. Only after that trusted
  transition succeeds does the worker remove validated private intake objects.
  If Storage cleanup then fails, the outbox event is moved to `needs_review`
  instead of being silently completed, preserving an operator-visible recovery
  path without risking deletion before terminal state is durable.
- Submission detects expired collecting drafts while holding the draft lock and
  returns before enqueueing an AI run/outbox event. The Server Action then
  performs private-object cleanup for the expired draft; the terminal database
  transition archives its input metadata atomically.
- Reject cleanup removes only the draft's unmapped private inputs. It never
  deletes existing clients, properties, or registered property images.
- Operational logs use safe operation/error codes and request IDs; raw prompts,
  files, API keys, cookies, provider messages, and contact values are not
  logged by the new path.

## Verification contract

The final PR head must pass the repository `Quality and security` workflow,
including project-memory validation, lint, TypeScript, coverage/unit tests,
disposable PostgreSQL tests, Playwright E2E, production build/render checks,
local authenticated E2E, `npm audit`, Snyk, and Trivy.

The pre-fix red phases proved the new ownership controls were not vacuous:

- AI provider lease tests failed before `renew_ai_event_lease_v1` and the
  pre-provider renewal calls were implemented.
- Outbound provider lease run `#266` failed exactly the new Resend, Meta, and
  trusted-RPC assertions while 495 other tests passed.

After both fixes, `Quality and security` run `#274` passed the complete pipeline
on head `469b6c03afb03e22cbe8262237066bc3cf3ab199`, including the disposable DB
suite, authenticated E2E, `npm audit`, Snyk, and Trivy.

Regression coverage now includes durable operator exclusion recovery,
stale-confirmed review access, per-item failure rendering, tenant-authorized
private image preview, extraction retry idempotency, terminal cleanup ordering,
AI provider lease takeover, and email/WhatsApp delivery lease takeover.

## Outstanding gates

- No managed Supabase migration, Storage bucket, Edge Function, schedule, or
  provider configuration has been mutated or proven by this branch.
- Live Gemini customer-data extraction was not run. The provider gate requires
  explicit action-time approval to send customer text/images to Google.
- A background retention sweep for abandoned `collecting` drafts that receive
  no later application request remains a managed operational concern. Explicit
  submission expiry, confirmation expiry, rejection, application, permanent
  failure, and retry exhaustion have terminal metadata/cleanup paths in the
  checkout.
- Fresh PR review must complete without a new unresolved release-blocking
  finding after the final documentation/code head is established.

## Release recommendation

Do not deploy this feature as live customer-data capability until the final PR
head is green, a fresh code review has no unresolved release-blocking finding,
managed migration/grant/bucket verification is complete, the worker deployment
and secrets are verified, and an explicitly approved live provider smoke is
performed. Manual CRM/property operations remain available independently of the
AI provider.
