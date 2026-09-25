# Task 3 implementation report

Status: implementation and verification are complete in the VOYA checkout. No
managed migration or setting was changed, no OpenWA host was contacted, and no
webhook was registered or real message sent. Task 1's separate OpenWA checkout
was read-only and remains unmodified.

## TDD evidence

- `npm test -- src/lib/whatsapp/openwa-media.test.ts` initially failed 11/11
  assertions because the adapter factory was not present. After implementation,
  all 11 adapter tests passed.
- `npm test -- src/lib/whatsapp/whatsapp-ai-worker.test.ts src/lib/outbox/worker-config.test.ts`
  initially failed 6 tests (10 passed): provider selection was absent and the
  OpenWA server config fields/pair validation were missing.
- The unknown-provider text regression failed as intended:
  `npm test -- src/lib/whatsapp/whatsapp-ai-worker.test.ts` reported one failed
  test (12 passed), because the helper returned `null` instead of rejecting.
  The allowlist now runs before the text fast path; known-provider text still
  returns `null` without calling either adapter.
- The group-JID selector regression failed as intended:
  `npm test -- src/lib/whatsapp/whatsapp-ai-worker.test.ts` reported one failed
  test (13 passed), because the OpenWA adapter was called with the group JID.
  The selector now rejects non-direct OpenWA chat IDs before either adapter is
  called.
- Before adding the V2 migration, the guarded local database suite failed at
  `whatsapp_ai_agent_phase1.sql` with `WhatsApp AI V2 worker context is
  missing`. A later fixture assertion initially compared OpenWA's provider
  message ID with VOYA's internal UUID; it was corrected to assert the literal
  provider message ID stored by Task 2.

## Verification

- `npm test -- src/lib/whatsapp/openwa-media.test.ts src/lib/whatsapp/whatsapp-ai-worker.test.ts` — 2 files, 25 tests passed.
- `npm test -- src/app/api/webhooks/whatsapp/openwa/route.test.ts` — 1 file, 22 tests passed; the existing signed group-event test confirms no Supabase client or RPC is invoked.
- `npm test` — 147 files, 787 tests passed. Vitest printed a non-failing JSDOM navigation notice.
- `npm run lint -- src/lib/whatsapp/openwa-media.ts src/lib/whatsapp/openwa-media.test.ts src/lib/whatsapp/whatsapp-ai-worker.ts src/lib/whatsapp/whatsapp-ai-worker.test.ts src/lib/outbox/worker-config.ts src/lib/outbox/worker-config.test.ts src/lib/ai/whatsapp-ai-worker-edge-contract.test.ts supabase/functions/outbox-dispatch/index.ts` — passed with no diagnostics.
- `npm run typecheck` — passed.
- `npm run test:db` with `VOYA_DB_TEST=1` and the guarded loopback database `voya_test` — passed (exit 0), including the unchanged Meta media/storage scenario, the separate OpenWA V2 context fixture, role-grant assertions, and the OpenWA webhook SQL suite. The runner reset only the disposable local `voya_test` schema.
- `git diff --check` — passed.

## Self-review

- V1's return contract and the Meta-sandbox owner-image/storage scenario remain
  unchanged. V2 returns every V1 field, retains the legacy `phone_number_id`,
  and adds `provider_channel_id` plus the tenant-qualified conversation's
  `chat_id`. V2 execution is revoked from browser roles and granted only to
  `voya_outbox_worker` and `service_role`.
- The worker uses the OpenWA session, direct chat JID, and Task 2 provider
  message ID for OpenWA images; Meta continues using its existing media ID and
  adapter. Unknown providers fail in the selector before any adapter,
  generation, or CRM projection call; group JIDs fail before adapter
  invocation. Media remains out of webhook JSON and logs, and storage remains
  in private `ai-intake` through the existing RPC.
- The Meta reply kill gate, booking/handoff boundaries, forced RLS, and tenant
  ownership paths were not weakened. This task adds no OpenWA send/reply path.
- In the pinned OpenWA checkout at
  `fec2170c29a50e88285e7d8c287785ee3236f137`, `.env.minimal` already sets
  `WEBHOOK_MEDIA_INLINE_MAX_BYTES=0` and `inline-media.ts` defines zero as never
  inline. The controller plus global `api` prefix confirm the per-message GET
  path; `ApiKeyGuard` accepts `x-api-key`. The public docs' differing API
  version label was not used as a contract. No duplicate inline-media docs or
  deployed setting changes were made.
- The test runner's migration inventory now classifies the new forward
  migration with the post-PR13 migrations so both upgrade and clean-install
  database paths handle it.

## Concerns

Managed migration history, Edge deployment, and OpenWA runtime configuration
remain unverified by design. No OpenWA API/webhook credentials were read or
provisioned; the API key is server-only configuration plumbing and test
fixtures only.

Implementation commit SHA: `08f1e60cb8ad912aab41c8a2bc23bebab3b6c53c`.
