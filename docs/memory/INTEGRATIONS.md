# Integrations (checkout wiring)

**Last verified:** 2026-09-26 (WhatsApp/OpenWA checkout and synthetic E2E)
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

WhatsApp inbound images reuse this private `ai-intake` bucket. The outbox
worker selects the media adapter from its worker-only context: the existing
Meta adapter keeps its Graph API contract, while OpenWA uses the pinned
per-message `GET /api/sessions/{sessionId}/messages/{chatId}/{messageId}/media`
route with a server-only `X-API-Key`. Both paths cap at 10 MiB, validate image
MIME and signature, compute a checksum, and record the tenant/message-bound
object through `store_whatsapp_media_v1`. Unknown providers fail closed and
webhook JSON carries no image bytes. Staff preview uses the authenticated
`/api/workspace/whatsapp/media/[messageId]` route and a short-lived signed URL;
it never accepts a caller-supplied storage path. These OpenWA statements
describe checkout wiring only; managed function configuration and migration
state remain unverified.

## OpenWA WhatsApp (code-only)

**Verified — checkout/local, 2026-09-26:** source checkout
`/home/mina/voya-os-worktrees/openwa-voya-integration` is pinned to upstream
base `bc206c28c6ab5baad5d68d15bb116c4b06e8d855` with local patch HEAD
`fec2170c29a50e88285e7d8c287785ee3236f137` (`OpenWA 0.23.6`,
`whatsapp-web.js 1.34.7`). The patch and VOYA wiring are checkout-only; no
container image was built/published, no always-on OpenWA host or webhook was
configured, and no QR was paired. Actual host/session automation/plugin state
is **Unknown**.

VOYA accepts only signed, explicitly individual `@c.us`/`@lid` events; the
OpenWA gate drops groups, channels, status/broadcast, missing-kind, and
contradictory identity events before downstream persistence. The authenticated
local browser suite passed 24/24 with synthetic signed inbound, duplicate
retry, non-individual/tampered rejection, and phone-echo cases. The test-only
secret is generated per run and is not sourced from or logged as a provider
secret. `VOYA_AUTOMATION_OWNER=true` is required for a dedicated host runtime;
it is not verified on any deployed host.

**Privacy gate:** WhatsApp linked-device history can be copied to the paired
device profile; official product behavior does not guarantee that group
history is excluded. The code gate proves group events do not reach VOYA's
downstream tables/hooks/webhook/AI/outbox, not that a persistent OpenWA browser
profile cannot receive group history. Keep live QR pairing blocked until this
scope is resolved or explicitly accepted. OpenWA outbound and AI customer-data
execution remain default-off; no real message or model request was sent.

## Meta WhatsApp

### Historical provider snapshots (2026-09-11–12)

**Managed provider snapshot — historical (2026-09-11):**
the authenticated Meta Business account `Vigor Tourism Services and real state`
has Business ID `705402195813525`. Its WhatsApp Business Account is `voya`
with WABA ID `1051481030703109`; the linked Egyptian number was recorded as
`+20 15 *** 9288`, Phone Number ID `1236715869531440`, status **linked**, and
quality rating **high**. Meta shows the WhatsApp business account as
**approved**, but business verification is **not complete** and no payment
method, currency, or timezone is configured.

The assigned Meta app is `VOYA Customer Messaging` (App ID
`4378346602427181`). The system user `VOYA Cloud API` (ID
`61592905883960`, role Employee) has full access to the app. The app detail
view currently shows no linked assets, so app-to-WABA linkage remains an
open provider check even though the WhatsApp account and phone are present.
A new system-user access token was generated for `VOYA Customer Messaging`
with a 60-day expiry and the WhatsApp permissions
`whatsapp_business_manage_events`, `whatsapp_business_management`, and
`whatsapp_business_messaging`. It is stored only in the ignored local
`.env.local` as `META_WHATSAPP_ACCESS_TOKEN`; the value is not recorded in
memory, Git, logs, or chat. The previously supplied token was not persisted
and Meta rejected read-only Graph API checks with `API access blocked`
(OAuthException code 200). A fresh read-only request using the newly generated
token against Phone Number ID `1236715869531440` returned the same error, so
live provider access remains **Blocked — managed Meta** even though token
creation succeeded. The Meta Developers surface still requires account
confirmation because the developer account is blocked; no additional provider
permissions or settings were changed during this pass.

**Live unblock — historical (2026-09-12):** the prior session assigned the user and
system user to WABA `voya` with full access and generated a token. That token
was not present in the current managed runtimes during the 2026-09-23 audit.

**Sender-number registration — historical (2026-09-12):** a prior `hello_world`
test reported that the number was not registered for Cloud API and required a
code retry after a cooldown. This must be rechecked against the current Meta UI.

The actual Vercel project snapshot checked 2026-09-11 contains WhatsApp/Gemini
feature flags, model names, and Supabase configuration, but no
`GEMINI_API_KEY`, `META_WHATSAPP_ACCESS_TOKEN`, `META_WHATSAPP_APP_SECRET`, or
`WHATSAPP_VERIFY_TOKEN`. Supabase Edge secrets for both the active staging
project and the inactive legacy project also contain no Gemini key. Managed
live WhatsApp/Gemini delivery therefore remains **Blocked — missing provider
secrets and Meta API access**; local outbound and AI auto-reply flags remain
disabled.

**Local test snapshot — Verified — checkout/local (2026-09-11):** the ignored
`.env.local` contains the server-only Meta and Gemini keys (values omitted),
`GEMINI_ENABLED=true`, and `GEMINI_CUSTOMER_DATA_APPROVED=false`. A synthetic
Gemini request succeeded with a JSON response. The local WhatsApp inbox also
has a `meta_cloud_sandbox` channel registered against Phone Number ID
`1236715869531440`; no external message was sent and outbound/auto-reply gates
remain false.

### Current managed snapshot (2026-09-23)

- Business portfolio `Vigor Tourism Services and real state` has approved WABA `voya` (`1051481030703109`) and a linked phone with high quality. Business verification and a payment method are still missing.
- Existing app `VOYA Customer Messaging` (`4378346602427181`) remains in Development and has no WhatsApp product. System user `VOYA Cloud API` (`61592905883960`) has full access to the app and WABA; no token was generated in this session.
- Production Vercel and Supabase Edge runtimes still lack the Meta app secret, webhook verify token, and access token. No external messages were sent; outbound flags remain disabled.

### Runtime wiring

| Aspect | Detail |
|---|---|
| Purpose | Inbound staff inbox plus one gated WhatsApp AI conversation worker and manual outbound delivery |
| Direction | Meta and signed OpenWA inbound routes → service-role ingest/enqueue; the worker retrieves provider-specific media and dispatches trusted queued text by provider |
| Entry points | `src/app/api/webhooks/whatsapp/route.ts`, `src/app/api/webhooks/whatsapp/openwa/route.ts`, `src/lib/whatsapp/meta-webhook.ts`, `src/lib/whatsapp/openwa-webhook.ts`, `src/lib/whatsapp/meta-media.ts`, `src/lib/whatsapp/openwa-media.ts`, `src/lib/whatsapp/meta-outbound.ts`, `src/lib/whatsapp/openwa-outbound.ts`, `supabase/functions/outbox-dispatch/index.ts` |
| Auth | Meta verify token and HMAC SHA-256 raw-body signature; OpenWA HMAC raw-body signature; provider credentials remain server-only; outbound OpenWA requires an operator key scoped to one session |
| App surfaces | `/workspace/whatsapp` staff UI + Server Actions for channel/message/note, AI takeover, and owner/property confirmation (user JWT RPCs) |
| Idempotency | Provider event key dedupe for inbound; outbound state is tied to the outbox event and provider message ID |
| Outbound | AI reply policy remains Meta-only. Trusted queued text can route through Meta or OpenWA; OpenWA additionally requires `OPENWA_OUTBOUND_ENABLED` (default false), `WHATSAPP_OUTBOUND_ENABLED`, `HUMAN_HANDOFF_APPROVED`, an active non-killed channel, and a live worker lease. The worker renews the lease immediately before the provider call |
| Failure modes | 401 bad signature, 413 oversized, 503 missing config/ingest failure; unknown providers and non-individual OpenWA JIDs fail closed; uncertain OpenWA delivery and missing exact provider IDs go to review instead of blind replay; no partial secret logs |
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
| Purpose | Optional LLM generation for the governed AI center and the single `VOYA WhatsApp Agent` |
| Direction | Supabase Edge outbox worker → Gemini `generateContent` API |
| Entry points | `src/lib/ai/gemini-runtime.ts`, `src/lib/ai/execution-contract.ts`, `supabase/functions/outbox-dispatch/index.ts` |
| Auth | `GEMINI_API_KEY` (server) |
| Gates | `GEMINI_ENABLED`; preview/test synthetic stub; customer data needs `GEMINI_CUSTOMER_DATA_APPROVED` |
| Data classes | `synthetic` vs `customer_redacted` |
| Structured output | `responseMimeType: application/json`; WhatsApp accepts only seven top-level fields, including the closed `requestIntent` enum (`booking_request`, `general_inquiry`, `existing_customer`, `unclear`), and rejects unknown keys/actions. Booking intent is a reviewable CRM proposal only; the AI path does not create/confirm bookings. Uploaded media is passed as bounded inline image parts only after private server-side retrieval |
| Lease ownership | AI provider calls require a still-live DB outbox lease owned by the current worker immediately before `generateContent`. Data-entry renews after image loading; an expired/reclaimed lease is never revived by the old worker |
| Failure modes | disabled / missing key / not approved / request failed / invalid response — typed provider errors; permanent data-entry failure terminalizes DB state before private-object cleanup |
| Ownership | `ai_runs` / `ai_tool_calls` evidence in DB; bounded proposal output is human-review material, not source of record |

The WhatsApp worker persists validated conversation state and may project a
deterministic `client_sales` result into the existing CRM lead. Owner results
remain a JSONB draft; only an authenticated inventory role can call the
existing owner/property/ownership/image commands through the review action.
No Phase 2 follow-up automation is included in this branch.

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
| DB API | Legacy lifecycle plus V1 `claim_outbox_delivery_events`, `mark_outbox_event_needs_review`, WhatsApp context/media/state/result RPCs, AI execution RPCs, `renew_ai_event_lease_v1`, and `renew_outbox_delivery_lease_v1` |
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
| `OPENWA_OUTBOUND_ENABLED` | OpenWA text delivery; defaults false and is also gated by `WHATSAPP_OUTBOUND_ENABLED` and human approval |
| `WHATSAPP_AI_AUTO_REPLIES` | AI auto-reply (also needs human handoff) |
| `HUMAN_HANDOFF_APPROVED` | required for outbound/auto-reply combo |
| `META_WHATSAPP_ACCESS_TOKEN` | server-only Meta media retrieval and outbound token |
| `META_GRAPH_API_VERSION` | allowlisted Meta Graph API version; defaults to `v21.0` |
| `OPENWA_API_BASE_URL` / `OPENWA_API_KEY` | paired server-only OpenWA media and gated text-delivery configuration; use an operator key scoped to one session, never the OpenWA admin key |
| `VOYA_DB_TEST` + local `*_test` DB | required for SQL test runner |
| `VOYA_AUTH_E2E_*` | disposable auth browser harness |
