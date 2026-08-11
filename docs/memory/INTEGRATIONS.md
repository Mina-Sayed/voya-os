# Integrations (checkout wiring)

**Last verified:** 2026-08-05  
Only integrations with code or migration presence. This document describes
checkout wiring; it does not prove managed deployment or provider configuration.

## Supabase (platform)

| Aspect | Detail |
|---|---|
| Purpose | Auth, PostgreSQL, (intended) storage later |
| Direction | App → Supabase; Auth callbacks → app |
| Clients | SSR user client (`createServerSupabaseClient`), route/proxy clients, service-role client |
| Auth mechanism | Publishable key + user JWT cookies; service role key server-only |
| Data ownership | Application schema in `public` + `auth.users` |
| Failure modes | Missing env fails closed; dependency errors reported via operational logger without leaking secrets |
| Config | `NEXT_PUBLIC_SUPABASE_*`, `SUPABASE_SERVICE_ROLE_KEY`, `AUTH_RATE_LIMIT_HMAC_SECRET`, `VOYA_APP_URL` |

## Meta WhatsApp

| Aspect | Detail |
|---|---|
| Purpose | Inbound staff inbox foundation |
| Direction | Meta → `POST/GET /api/webhooks/whatsapp` → service-role RPC → tenant tables |
| Entry points | `src/app/api/webhooks/whatsapp/route.ts`, `src/lib/whatsapp/meta-webhook.ts` |
| Auth | Verify token (GET); HMAC SHA-256 raw body signature (POST) |
| App surfaces | `/workspace/whatsapp` staff UI + Server Actions for channel/message/note (user JWT RPCs) |
| Idempotency | Provider event key dedupe inside ingest RPC |
| Outbound | **Disabled by default** (`WHATSAPP_OUTBOUND_ENABLED`, human handoff approval) |
| Failure modes | 401 bad signature, 413 oversized, 503 missing config/ingest failure; no partial secret logs |
| Ownership | Tenant WhatsApp tables; provider IDs stored as external references |

ADR-005, ADR-010.

## Google Gemini (checkout capability)

| Aspect | Detail |
|---|---|
| Purpose | Optional LLM generation for governed AI center |
| Direction | Server → Gemini `generateContent` API |
| Entry points | `src/lib/ai/gemini-runtime.ts`; domain tool policy in `src/domain/ai/*` |
| Auth | `GEMINI_API_KEY` (server) |
| Gates | `GEMINI_ENABLED`; preview/test synthetic stub; customer data needs `GEMINI_CUSTOMER_DATA_APPROVED` |
| Data classes | `synthetic` vs `customer_redacted` |
| Failure modes | disabled / missing key / not approved / request failed — typed provider errors |
| Ownership | `ai_runs` / `ai_tool_calls` evidence in DB; model output is not source of record |

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
| DB API | `claim_outbox_events`, `complete_outbox_event`, `fail_outbox_event`, `purge_outbox_events` |
| Consumer | DB role `voya_outbox_worker` |
| App runtime | No in-repo always-on worker implementation shipping deliveries |
| Rule | Do not pretend notifications/email/WhatsApp outbound are production-complete |

## Explicitly not integrated yet

- Payment processors
- SMS/email notification providers (beyond Supabase Auth email)
- Channel managers / OTAs
- Object storage workflows in app code (mentioned in design docs only)
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
