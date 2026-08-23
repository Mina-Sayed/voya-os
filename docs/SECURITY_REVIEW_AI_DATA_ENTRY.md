# Security review — human-confirmed AI data entry

**Date:** 2026-08-23
**Checkout:** `codex/ai-data-entry-confirmation`
**Status:** Checkout/CI verification only; managed rollout and live customer-data smoke gated

## Scope

This review covers the text/image intake, governed extraction run, editable
review draft, confirmation action, deterministic client/property/image writes,
partial recovery, and private `ai-intake` storage boundary.

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
  storage. Replay metadata/checksum mismatches fail closed and failed metadata
  registration inspects Storage cleanup errors.
- Human review can display an intake image only through an authenticated,
  tenant-scoped preview route. The route resolves the input from
  `list_ai_data_entry_inputs_v1`, never accepts a storage path from the caller,
  downloads only the database-authorized private object with the service role,
  validates byte size, and returns `private, no-store` content.
- Gemini receives no SQL, HTTP, credential, identity, or mutation tools. Source
  text and images are treated as untrusted content; schema validation rejects
  malformed, oversized, truncated, unknown-key, foreign-image, and duplicate
  image-assignment payloads.
- Confirmation is explicit and version/idempotency protected. A durable
  execution token serializes confirmation work, while the trusted service
  boundary records only deterministic command results that actually ran.
  Stale `confirmed` leases remain reclaimable through the same database claim
  function; active leases reject overlapping execution.
- Operator exclusions are stored as `excluded_by_operator` terminal decisions
  in `application_result`. Partial reloads restore those exclusions rather than
  silently re-including false-positive model records. Operators can explicitly
  re-include an excluded record on a later retry.
- Partial application state stores successful record IDs and safe per-item error
  codes. Successful items remain locked and skipped on retry; the review UI
  exposes actionable errors for failed client/property/image items.
- One intake image can be assigned to only one proposed property. Successful
  mappings are recorded through the trusted mapping RPC and the private intake
  object is removed after the property image is registered.
- Permanent extraction failure and retry exhaustion clean validated private
  intake objects before the worker closes the data-entry run/event. If Storage
  cleanup fails, the worker does not declare terminal success/failure; it moves
  the event to `needs_review` with a safe cleanup error code so private files are
  not silently orphaned.
- Reject cleanup removes only the draft's unmapped private inputs. It never
  deletes existing clients, properties, or registered property images.
- Operational logs use safe operation/error codes and request IDs; raw prompts,
  files, API keys, cookies, provider messages, and contact values are not
  logged by the new path.

## Verification contract

The final PR head must pass the repository `Quality and security` workflow,
including project-memory validation, lint, TypeScript, coverage/unit tests,
disposable PostgreSQL tests, Playwright E2E, production build/render checks,
local authenticated E2E, `npm audit`, Snyk, and Trivy. Regression coverage for
this follow-up specifically includes durable operator exclusion recovery,
stale-confirmed review access, per-item failure rendering, and tenant-authorized
private image preview behavior.

A prior red-phase workflow intentionally failed on the exclusion recovery test
before the implementation persisted `excluded_by_operator`; the repaired head
must make that same test pass together with the full suite.

## Outstanding gates

- No managed Supabase migration, Storage bucket, Edge Function, schedule, or
  provider configuration has been mutated or proven by this branch.
- Live Gemini customer-data extraction was not run. The provider gate requires
  explicit action-time approval to send customer text/images to Google.
- Retention/cleanup scheduling for merely expired or abandoned drafts remains a
  managed operational concern; the application boundaries cover explicit
  rejection, successful mapping, permanent extraction failure, and retry
  exhaustion.

## Release recommendation

Do not deploy this feature as live customer-data capability until the final PR
head is green, a fresh code review has no unresolved release-blocking finding,
managed migration/grant/bucket verification is complete, the worker deployment
and secrets are verified, and an explicitly approved live provider smoke is
performed. Manual CRM/property operations remain available independently of the
AI provider.
