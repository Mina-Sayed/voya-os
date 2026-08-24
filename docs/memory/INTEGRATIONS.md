# Integrations (checkout wiring)

**Last verified:** 2026-08-24
Only integrations with code or migration presence. This document describes
checkout wiring; it does not prove managed deployment or provider configuration.

## Supabase (platform)

| Aspect | Detail |
|---|---|
| Purpose | Auth, PostgreSQL, private property-image storage, and private AI-intake storage boundaries |
| Direction | App → Supabase; Auth callbacks → app |
| Clients | SSR user client (`createServerSupabaseClient`), route/proxy clients, service-role client |
| Auth mechanism | Publishable key + user JWT cookies; service role key server-only |
| Data ownership | Application schema in `public` + `auth.users` |
| Failure modes | Missing env fails closed; dependency errors reported via operational logger without leaking secrets |
| Config | `NEXT_PUBLIC_SUPABASE_*`, `SUPABASE_SERVICE_ROLE_KEY`, `AUTH_RATE_LIMIT_HMAC_SECRET`, `VOYA_APP_URL` |

### Supabase Storage — property images

| Aspect | Detail |
|---|---|
| Bucket | `property-images`, private, JPEG/PNG/WebP, 10 MiB provider limit |
| Upload | Server Action uses server-only service role at `org/property/uuid.ext`; metadata is registered through `register_property_image_v1` |
| Retrieval | Tenant-scoped `list_property_images_v1` followed by a five-minute signed URL in `/api/workspace/properties/[propertyId]/images/[imageId]` |
| Local proof | SQL harness validates metadata/path/size/MIME rules; local config omits the Storage provider schema |
| Managed proof | Unknown until the separate staging bucket/configuration and upload/signed-URL verification gate passes |

### Supabase Storage — AI intake images

| Aspect | Detail |
|---|---|
| Bucket | `ai-intake`, private, JPEG/PNG/WebP, 10 MiB per file; 20 files/25 MiB per draft |
| Upload | Authenticated bounded Node route writes with server-only service role under a deterministic tenant/draft/idempotency-bound path; metadata is registered through `register_ai_data_entry_input_v1` |
| Replay safety | The object ID is derived from organization, draft, and idempotency key. Existing objects are checksum-verified, metadata replay requires an active equivalent row, and cleanup checks for a successful peer registration before deleting a deterministic object |
| Lifecycle | Confirmed mappings copy into `property-images`; the AI idempotency-key path registers the property-image source record and maps its intake input in one authenticated PostgreSQL transaction. The confirmation action does not issue a second legacy mapping RPC. Service-only mapping helpers remain available for recovery boundaries. Unassigned inputs are archived before `applied`; terminal draft transitions archive remaining active metadata. Explicit reject/expiry/failure paths remove eligible private objects and surface cleanup failure rather than silently declaring success |
| Retrieval | No public URL. The worker downloads server-side for extraction. Human review uses an authenticated tenant-scoped preview route that resolves the input by draft/input ID and returns `private, no-store` bytes; callers never provide a storage path |
| Managed proof | Unknown until the new migrations, bucket, grants, and worker deployment are separately verified |

## Meta WhatsApp

| Aspect | Detail |
|---|---|
| Purpose | Inbound staff inbox foundation plus gated manual outbound delivery |
| Direction | Meta → `POST/GET /api/webhooks/whatsapp` → service-role RPC → tenant tables; outbox worker → Meta for gated outbound |
| Entry points | `src/app/api/webhooks/whatsapp/route.ts`, `src/lib/whatsapp/meta-webhook.ts`, `src/lib/whatsapp/meta-outbound.ts` |
| Auth | Verify token (GET); HMAC SHA-256 raw body signature (POST); server-only access token for outbound |
| App surfaces | `/workspace/whatsapp` staff UI + Server Actions for channel/message/note (user JWT RPCs) |
| Idempotency | Provider event key dedupe for inbound; outbound state is tied to the outbox event and provider message ID |
| Outbound | Manual text delivery is implemented behind `WHATSAPP_OUTBOUND_ENABLED` + human-handoff approval; disabled by default. The worker revalidates/renews the still-live DB event lease immediately before the Meta network call so a reclaimed event is not sent by a stale worker |
| Failure modes | 401 bad signature, 413 oversized, 503 missing config/ingest failure; ambiguous outbound delivery goes to review rather than blind replay; no partial secret logs |
| Ownership | Tenant WhatsApp tables; provider IDs stored as external references |

ADR-005, ADR-010.

## CRM V1

| Aspect | Detail |
|---|---|
| Purpose | Tenant-scoped leads, clients, append-only activity, and human follow-up queue |
| Direction | Next.js Server Actions → tenant-scoped Supabase RPCs → audit/outbox evidence |
| Duplicate handling | Normalized phone/email warnings only; no automatic merge |
| Conversion | Atomic lead-to-client command with source link and conversion activity |
| External delivery | None from CRM follow-up commands; WhatsApp/email delivery remains a separate gated boundary |

## Resend application email

| Aspect | Detail |
|---|---|
| Purpose | Transactional organization/member invitation delivery from the outbox |
| Entry points | `src/lib/email/resend.ts`, `supabase/functions/outbox-dispatch/index.ts` |
| Auth | Server-only `RESEND_API_KEY` and `RESEND_FROM`; `Idempotency-Key` is the outbox event id |
| Lease/idempotency | Immediately before Resend, the worker must renew a still-live delivery lease for the same worker. Resend's event-ID idempotency key is defense in depth, not a substitute for DB ownership |
| Gates | `RESEND_ENABLED`; missing/disabled configuration moves the event to `needs_review` |
| Managed proof | Unknown; no provider send or managed worker invocation occurred in this checkout pass |

## Google Gemini (checkout capability)

| Aspect | Detail |
|---|---|
| Purpose | Optional LLM generation for governed AI center |
| Direction | Supabase Edge outbox worker → Gemini `generateContent` API |
| Entry points | `src/lib/ai/gemini-runtime.ts`, `src/lib/ai/execution-contract.ts`, `supabase/functions/outbox-dispatch/index.ts` |
| Auth | `GEMINI_API_KEY` (server) |
| Gates | `GEMINI_ENABLED`; preview/test synthetic stub; customer data needs `GEMINI_CUSTOMER_DATA_APPROVED` |
| Data classes | `synthetic` vs `customer_redacted` |
| Structured output | `responseMimeType: application/json`; extraction receives a larger bounded output budget than ordinary proposals. Uploaded image IDs are bound to image ordinals in the extraction prompt and validated on return |
| Lease ownership | AI provider calls require a still-live DB outbox lease owned by the current worker immediately before `generateContent`. Data-entry renews after image loading; an expired/reclaimed lease is never revived by the old worker |
| Failure modes | disabled / missing key / not approved / request failed / invalid response — typed provider errors; permanent data-entry failure terminalizes DB state before private-object cleanup |
| Ownership | `ai_runs` / `ai_tool_calls` evidence in DB; bounded proposal output is human-review material, not source of record |

The `data_entry` run kind adds multimodal extraction from bounded private
inputs. It stores a tenant-scoped draft and requires explicit human
confirmation before calling the existing client/property/image commands. The
confirmation claim persists operator exclusions and an execution token
atomically; the trusted service boundary heartbeats that token during long
confirmation work and records final progress. AI image registration and input
mapping share one database transaction, so a mapping error cannot leave an
active source-of-record image behind. The synthetic preview/test path returns a
schema-valid fake payload without a network call. Live customer text/image
extraction was not run in this pass; action-time approval and separate managed
evidence remain required.

This is a gated checkout integration/runtime path. Live managed Gemini
execution is not implied unless separately verified with dated provider and
deployment evidence. The OpenAI SDK is not used by this checkout; historical
and product documentation may still reference OpenAI as archive/intent, not as
proof of current checkout or managed execution.

## Vercel / hosting (operational)

| Aspect | Detail |
|---|---|
| Evidence | Read-only Vercel provider snapshot captured 2026-08-05; `VERCEL_ENV` in Gemini env resolution; `.vercel/`; release docs |
| Role | Host Next.js app + env secrets |
| Agent rule | Do not deploy or mutate managed infra without explicit user approval |

Verified provider snapshot (2026-08-05): production deployment is READY at
`ac7dfdb051cbe0d573803a9a7bd0c5dcb4b3307f` on `codex/auth-flow-fix`; the
relevant HEAD preview is READY but marked `gitDirty=1`, so its exact artifact
content is **Unknown**. Production and preview health checks returned HTTP
200. Environment variable **names** were inspected without reading values;
encrypted-value correctness, Auth redirect/email settings, and backup/PITR
posture remain **Unknown**. No deploy, promotion, rollback, or provider
configuration mutation was performed.

## GitHub Actions

| Aspect | Detail |
|---|---|
| Entry | `.github/workflows/quality.yml` |
| Integrates | npm gates, Playwright, Postgres service, Snyk, Trivy |
| Secrets | `SNYK_TOKEN` |
| PR #8 evidence | `Quality and security` run #274 passed coverage, disposable DB, E2E, build/production checks, authenticated E2E, npm audit, Snyk, and Trivy on code head `469b6c03afb03e22cbe8262237066bc3cf3ab199`; documentation changes after that head require their own final run before release-readiness is claimed |

## Outbox → external channels (designed, not live delivery)

| Aspect | Detail |
|---|---|
| Purpose | Transactional staging for side effects after commit |
| DB API | Legacy lifecycle plus V1 `claim_outbox_delivery_events`, `mark_outbox_event_needs_review`, provider-context/status RPCs, AI execution RPCs, `renew_ai_event_lease_v1`, and `renew_outbox_delivery_lease_v1` |
| Consumer | DB role `voya_outbox_worker`; the source Edge Function uses a server-only service-role client for its focused worker RPC grants |
| App runtime | Source-only Supabase Edge Function `outbox-dispatch`; one batch is capped at 20 with a five-minute initial lease |
| Lease policy | The initial batch lease is not trusted for the whole batch lifetime. AI, Resend, and Meta calls revalidate and extend a still-live same-worker lease immediately before the external call; renewal cannot resurrect an expired/reclaimed lease |
| State policy | Retry at 1m/5m/15m/1h/6h; ambiguous or unsafe payloads become `needs_review`; permanent failures become `dead_letter` where applicable |
| Rule | Code and local SQL proof do not prove managed schedule, secrets, or provider delivery |

## Explicitly not integrated yet

- Payment processors
- SMS and non-Resend notification providers
- Channel managers / OTAs
- OpenAI / Anthropic

## Config flag summary (behavioral)

| Flag | Effect |
|---|---|
| `GEMINI_ENABLED` | allow provider path |
| `GEMINI_CUSTOMER_DATA_APPROVED` | allow customer_redacted prompts in non-synthetic envs |
| `WHATSAPP_OUTBOUND_ENABLED` | outbound (also needs human handoff) |
| `WHATSAPP_AI_AUTO_REPLIES` | AI auto-reply (also needs human handoff) |
| `HUMAN_HANDOFF_APPROVED` | required for outbound/auto-reply combo |
| `VOYA_DB_TEST` + local `*_test` DB | required for SQL test runner |
| `VOYA_AUTH_E2E_*` | disposable auth browser harness |
