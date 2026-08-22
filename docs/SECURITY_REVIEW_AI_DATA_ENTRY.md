# Security review — human-confirmed AI data entry

**Date:** 2026-08-22
**Checkout:** `codex/ai-data-entry-confirmation`
**Status:** Local checkout verified; managed rollout and live customer-data smoke gated

## Scope

This review covers the new text/image intake, governed extraction run, editable
draft, confirmation action, deterministic client/property/image writes, and
private `ai-intake` storage boundary.

## Controls verified in checkout

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
  JPEG/PNG/WebP, 10 MiB per file, 20 files/25 MiB per draft, random tenant paths,
  and private `ai-intake` storage. Failed metadata registration removes the
  uploaded object.
- Gemini receives no SQL, HTTP, credential, identity, or mutation tools. Source
  text and images are treated as untrusted content; schema validation rejects
  malformed, oversized, truncated, unknown-key, and foreign-image payloads.
- Confirmation is explicit and version/idempotency protected. It calls the
  existing `create_client_v1`, `create_property_v1`, and
  `register_property_image_v1` commands. Stable per-item keys make retries
  duplicate-safe; progress records partial batches without claiming full
  success.
- Reject cleanup removes only the draft's unmapped private inputs. It never
  deletes existing clients, properties, or images.
- Operational logs use safe operation/error codes and request IDs; raw prompts,
  files, API keys, cookies, provider messages, and contact values are not
  logged by the new path.

## Evidence

Verified — checkout/local:

- `npm test`: 98 files / 462 tests passed.
- `npm run lint`: passed.
- `tsc --noEmit --incremental false`: passed.
- `npm run test:db` against loopback `voya_pr7_test`: passed, including
  cross-role/grant, idempotency, worker lifecycle, confirmation/progress, and
  no-pre-confirmation-write assertions.
- Synthetic-only authenticated browser flow: 1 passed — create draft, upload a
  private image, submit to queue, and verify the client is absent from CRM
  before confirmation.
- Local production build and request-time security smoke passed.

## Outstanding gates

- `npm run scan:security` is **BLOCKED**, not PASS: the pinned Trivy binary and
  trusted Snyk binary are unavailable in this environment.
- No managed Supabase migration, Storage bucket, Edge Function, schedule, or
  provider configuration has been mutated or proven by this branch.
- Live Gemini customer-data extraction was not run. The provider gate requires
  explicit action-time approval to send the new customer text/images to Google.
- Retention/cleanup scheduling for expired drafts is not yet a managed
  operational job; the draft cleanup RPC/route remains an application boundary.

## Release recommendation

Do not merge or deploy this feature as live customer-data capability until the
security scanner gate, managed migration/grant/bucket verification, worker
deployment/secret verification, and an explicitly approved live provider smoke
are complete. Manual CRM/property operations remain safe and available with AI
disabled.
