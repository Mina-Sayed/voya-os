# Task 1 implementation report — WhatsApp ingress and secure media boundary

## Scope delivered

- Added provider-neutral inbound WhatsApp parsing for bounded text and image events, including optional image captions, supported MIME hints, and normalized received timestamps.
- Preserved raw-body HMAC verification, request body limits, generic route errors, Node route runtime, and the service-role-only webhook boundary.
- Switched the webhook route to `ingest_whatsapp_webhook_event_v1`; it sends the complete bounded ingress contract and returns `202` after persistence/enqueue only. It does not call Gemini or wait for AI work.
- Added a server-side Meta media adapter with injected `fetch`, Graph API version/token inputs, timeouts, a 10 MiB streamed-byte ceiling, HTTPS Meta-host allowlisting, JPEG/PNG/WebP MIME validation, and image-signature validation. It does not log provider content, tokens, or PII.

## Changed files

- `src/lib/whatsapp/meta-webhook.ts`
- `src/lib/whatsapp/meta-webhook.test.ts`
- `src/app/api/webhooks/whatsapp/route.ts`
- `src/app/api/webhooks/whatsapp/route.test.ts`
- `src/lib/whatsapp/meta-media.ts` (new)
- `src/lib/whatsapp/meta-media.test.ts` (new)

No Supabase migrations, worker, UI, CRM, or property files were modified.

## TDD evidence

1. Added the image/caption parser test before its implementation. It failed because the existing parser returned no image events; after the minimal parser extension, the test passed.
2. Changed the route test to require the V1 RPC and complete parameter shape before updating the route. It failed because the route called the legacy RPC and omitted media fields; after the route change, the test passed.
3. Added the media-adapter test before the module existed. The expected red result was a missing-module import failure; after implementation, the media suite passed.
4. Mutation-checked the returned-content-type rejection: the new test failed when the MIME comparison was temporarily removed and passed again after restoration.

## Verification

| Command | Result |
| --- | --- |
| `npm test -- src/lib/whatsapp/meta-webhook.test.ts src/lib/whatsapp/meta-media.test.ts src/app/api/webhooks/whatsapp/route.test.ts` | PASS — 3 files, 14 tests |
| `npm test` | PASS — 124 files, 573 tests |
| `npm run typecheck` | PASS |
| `npm run lint` | PASS with 3 existing unrelated Next navigation warnings; 0 errors |
| Synthetic public-config `npm run build -- --webpack` | PASS — compiled, type-checked, and emitted `.next/BUILD_ID` |
| `npm run scan:security` | BLOCKED — Trivy binary/container runtime and trusted Snyk binary unavailable |

The default build path was first blocked by absent public Supabase configuration. With synthetic public values, Turbopack was blocked by a host port-binding restriction; the Webpack fallback above completed. No real Meta request was made in any test.

## Decisions and concerns

- The V1 RPC input is explicitly: provider, channel ID, conversation key, event key, sender, message type, body text, provider media ID, MIME hint, caption, and normalized received timestamp. Task 2 owns the database migration and must retain/confirm these parameter names and nullable text/media semantics before integration.
- Media downloads are restricted to `graph.facebook.com` and Meta's `lookaside.fbsbx.com` CDN before the bearer token is sent. If Meta changes its documented media host, that allowlist needs an intentional update and test.
- The security scanner did not run, so no scanner-based clean result is claimed. The implemented route remains service-role-only and the adapter has no browser-facing environment access or provider logging.

## Commit

Committed: yes. The focused conventional commit includes this report and all implementation/test changes; the commit SHA is returned with the task status.
