# Integrations (checkout wiring)

**Last verified:** 2026-08-13
Only integrations with code or migration presence. This document describes
checkout wiring; it does not prove managed deployment or provider configuration.

## Supabase (platform)

| Aspect | Detail |
|---|---|
| Purpose | Auth, PostgreSQL, and private property-image storage boundary |
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

## Meta WhatsApp

| Aspect | Detail |
|---|---|
| Purpose | Inbound staff inbox foundation |
| Direction | Meta → `POST/GET /api/webhooks/whatsapp` → service-role RPC → tenant tables |
| Entry points | `src/app/api/webhooks/whatsapp/route.ts`, `src/lib/whatsapp/meta-webhook.ts` |
| Auth | Verify token (GET); HMAC SHA-256 raw body signature (POST) |
| App surfaces | `/workspace/whatsapp` staff UI + Server Actions for channel/message/note (user JWT RPCs) |
| Idempotency | Provider event key dedupe inside ingest RPC |
| Outbound | Manual text delivery is implemented behind `WHATSAPP_OUTBOUND_ENABLED` + human-handoff approval; disabled by default |
| Failure modes | 401 bad signature, 413 oversized, 503 missing config/ingest failure; no partial secret logs |
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
| Failure modes | disabled / missing key / not approved / request failed — typed provider errors |
| Ownership | `ai_runs` / `ai_tool_calls` evidence in DB; bounded proposal output is human-review material, not source of record |

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

## Outbox → external channels (designed, not live delivery)

| Aspect | Detail |
|---|---|
| Purpose | Transactional staging for side effects after commit |
| DB API | Legacy lifecycle plus V1 `claim_outbox_delivery_events`, `mark_outbox_event_needs_review`, provider-context/status RPCs, and AI execution RPCs |
| Consumer | DB role `voya_outbox_worker` |
| App runtime | Source-only Supabase Edge Function `outbox-dispatch`; one batch is capped at 20 with a five-minute lease |
| State policy | Retry at 1m/5m/15m/1h/6h; ambiguous or unsafe payloads become `needs_review`; permanent failures become `dead_letter` |
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
