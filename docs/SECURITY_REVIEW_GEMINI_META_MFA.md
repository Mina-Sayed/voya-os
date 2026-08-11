# Security review: Gemini, Meta webhook, and workspace MFA

## Scope

Reviewed `src/domain/auth/mfa-policy.ts`, the `/security/mfa` Server Actions/page, `src/lib/ai/gemini-runtime.ts`, `src/lib/whatsapp/meta-webhook.ts`, the WhatsApp route, and migration `20260803040039_whatsapp_webhook_ingestion.sql`.

## Controls verified

- Workspace context fails closed unless Supabase reports AAL2 and a verified TOTP factor.
- MFA enrollment and challenge inputs are server-validated; provider errors and factor secrets are not logged or returned as raw errors.
- Preview/test Gemini calls are deterministic and network-free. Production customer data requires an explicit approval flag and a server-side API key.
- Gemini output is treated as untrusted text; this adapter has no domain mutation or arbitrary tool execution path.
- Meta signatures are calculated over the exact raw body and compared with a constant-time operation. Payload size, event type, and field lengths are bounded.
- Webhook ingestion is callable only by `service_role`, resolves the channel server-side, deduplicates provider event IDs, stores no raw provider payload, and does not create outbound work.
- Default outbound WhatsApp and AI auto-reply flags are false; human handoff approval is an independent gate.

## Reproduction and evidence

`npm test -- --run src/domain/auth/mfa-policy.test.ts src/features/auth/workspace-context.test.ts src/lib/ai/gemini-runtime.test.ts src/lib/whatsapp/meta-webhook.test.ts src/app/api/webhooks/whatsapp/route.test.ts` passed. The disposable PostgreSQL suite passed the webhook privilege, idempotency, inbound-only, and existing CRM/WhatsApp assertions. Supabase MCP privilege inspection confirmed anonymous/authenticated execution is false and `service_role` execution is true.

## Residual release blockers

- Vercel MCP cannot write Environment Variables; production secrets and Preview URL configuration still require the Vercel console/API.
- Supabase Auth Site URL, redirect allowlist, SMTP, leaked-password protection, and TOTP policy are managed settings and require console evidence.
- No outbound worker or AI auto-reply is enabled. A future worker requires a separate threat model, retry/dead-letter evidence, retention purge, and human-handoff approval.
- Snyk remains blocked until an authenticated binary/credential is available.
