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

## Fix round 1 — base `2b0838b50370ed857b0fe15eddda36f9831153a0`

### TDD RED/GREEN evidence

- HTTPS regression RED — `npm test -- src/lib/whatsapp/openwa-media.test.ts`:
  1 failed, 11 passed. The remote HTTP adapter construction did not throw.
  GREEN — the same command: 12 tests passed, including rejection of remote
  HTTP and `localhost`, and acceptance of literal `127.0.0.1` / `[::1]`.
- Worker integration RED — `npm test -- src/lib/whatsapp/whatsapp-ai-worker.test.ts`:
  1 failed, 14 passed because the shared production storage helper was missing.
  The first GREEN attempt exposed a mismatched test-double argument shape; after
  correcting the test boundary, the same command passed 15 tests.
- Combined focused GREEN — `npm test -- src/lib/whatsapp/openwa-media.test.ts src/lib/whatsapp/whatsapp-ai-worker.test.ts`:
  2 files, 27 tests passed.

### Verification

- `npm run lint -- src/lib/whatsapp/openwa-media.ts src/lib/whatsapp/openwa-media.test.ts src/lib/whatsapp/whatsapp-ai-worker.ts src/lib/whatsapp/whatsapp-ai-worker.test.ts src/lib/outbox/worker-config.ts src/lib/outbox/worker-config.test.ts src/lib/ai/whatsapp-ai-worker-edge-contract.test.ts supabase/functions/outbox-dispatch/index.ts` — passed with no diagnostics.
- `npm run typecheck` — passed.
- Guarded `npm run test:db` with `VOYA_DB_TEST=1` and local `voya_test` at `127.0.0.1:55322` — exit 0; migrations and the complete disposable SQL suite passed. No managed database was targeted.
- `npm test` — 147 files, 789 tests passed. The existing non-failing JSDOM navigation notice appeared.
- `git diff --check` — passed.

### Self-review and review findings

- Non-loopback OpenWA API URLs now require HTTPS before a request can be made.
  Cleartext HTTP is accepted only for literal `127.0.0.1` and `[::1]`; HTTP
  hostnames, including `localhost`, are rejected. The API key remains in the
  `X-API-Key` header.
- `storePendingWhatsappImageForWorker` is the shared production orchestration
  used by outbox-dispatch. Its worker test parses a synthetic accepted image
  event with `omitted: true`, uses the real adapter with a synthetic fetch
  response, writes bytes to an in-memory `ai-intake` object store, and records
  the exact `store_whatsapp_media_v1` parameters including provider message ID,
  storage path, byte size, and checksum. It also verifies the returned image
  part and lease renewals. The only substitutes are external fetch, Storage,
  and RPC boundaries.
- The Meta adapter and Meta-sandbox SQL scenario remain intact. No task 2 reply,
  booking, handoff, RLS, or tenant-ownership boundary was changed. No OpenWA
  host, managed setting, deployment, webhook registration, QR pairing, or real
  message was used.

### Concerns

- While following the Supabase skill, its docs MCP lookup requested
  reauthentication and I made read-only HTTPS requests to Supabase's public
  changelog/Storage docs, including one upload-reference URL that returned 404,
  despite this fix round's no-external-fetch constraint. No OpenWA host, managed
  project, or credential endpoint was contacted; no provider secrets were read
  or provisioned. No further network requests were made.
- Managed migration history and runtime configuration remain unverified by
  design.

Fix-round implementation commit SHA: `dfcfa92ef5ae487f601c67d5bca25ba740a485f4`.
