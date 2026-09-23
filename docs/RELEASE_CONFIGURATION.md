# Managed release configuration

The public deployments are:

- Production: `https://www.vigor.dpdns.org`
- Develop preview: `https://voya-os-git-develop-minas-projects-ed065580.vercel.app`
- Latest sync preview: `https://voya-je4izr46r-minas-projects-ed065580.vercel.app`
- WhatsApp callback target: `https://www.vigor.dpdns.org/api/webhooks/whatsapp`

The official hostname currently resolves through Cloudflare and serves the
production health/version endpoints. Vercel reports the domain is owned by a
different scope, so direct alias management from the `Mina's projects`
`voya-os` project is pending transfer or access from that owning scope.

Configure these values in the matching runtime. Do not paste values into Git,
tickets, chat, or logs.

## Vercel Production and Preview

| Variable | Preview | Production | Notes |
|---|---:|---:|---|
| `NEXT_PUBLIC_SUPABASE_URL` | yes | yes | Supabase project URL |
| `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` | yes | yes | Public browser key only |
| `VOYA_APP_URL` | yes | `https://www.vigor.dpdns.org` | Preview must use its own stable preview/branch origin |
| `SUPABASE_SERVICE_ROLE_KEY` | no | yes | Server-only webhook ingestion; never expose to the browser |
| `AUTH_RATE_LIMIT_HMAC_SECRET` | yes | yes | Server-only HMAC key for pre-auth bucket derivation; never expose or log. Rotating it starts fresh rate-limit buckets, so existing counters are not carried forward. |
| `META_WHATSAPP_APP_SECRET` | no | yes | HMAC verification secret |
| `WHATSAPP_VERIFY_TOKEN` | no | yes | Meta webhook verification token |

`META_WHATSAPP_APP_SECRET` and `WHATSAPP_VERIFY_TOKEN` are read by the
Vercel webhook route. The worker's provider credentials belong in Supabase
Edge Function secrets below.

## Supabase Edge Function secrets

Supabase injects `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` into
`outbox-dispatch`. Configure these additional secrets for both production and
staging:

| Secret | Purpose |
|---|---|
| `OUTBOX_WORKER_SECRET` | Custom bearer authentication for scheduled invocations |
| `OUTBOX_PAYLOAD_ENCRYPTION_KEY` | 32-byte key for decrypting outbox payloads |
| `VOYA_APP_URL` | Production uses `https://www.vigor.dpdns.org`; staging uses its own preview origin |
| `META_WHATSAPP_ACCESS_TOKEN` | Durable Meta system-user token for the connected WABA/phone |
| `META_GRAPH_API_VERSION` | Optional; code currently defaults to `v21.0`, pin and verify a supported version |
| `GEMINI_API_KEY` | Gemini API authorization key |
| `GEMINI_MAIN_MODEL` | Optional model override |
| `GEMINI_EXTRACTION_MODEL` | Optional model override |
| `RESEND_API_KEY`, `RESEND_FROM` | Required only if email delivery is explicitly enabled |

Set the feature flags in Supabase Edge Function secrets, not only in Vercel:

```text
GEMINI_ENABLED=false                 # enable only after provider review
GEMINI_MAIN_MODEL=gemini-3.1-flash-lite
GEMINI_EXTRACTION_MODEL=gemini-3.1-flash-lite
GEMINI_CUSTOMER_DATA_APPROVED=false
WHATSAPP_OUTBOUND_ENABLED=false
WHATSAPP_AI_AUTO_REPLIES=false
HUMAN_HANDOFF_APPROVED=false
RESEND_ENABLED=false
```

The WhatsApp `phone_number_id` is stored in the active `whatsapp_channels`
record as `external_channel_id`; it is not a project-wide environment variable.
The `outbox-dispatch` worker is scheduled by the `voya-os-outbox-dispatch`
Supabase Cron job every minute. The job reads `outbox_dispatch_url` and
`outbox_worker_secret` from Supabase Vault. Keep both values out of source
control and logs.

Retention requirements:

- AI raw prompts/responses: 30 days.
- AI redacted metadata: 90 days.
- WhatsApp raw messages/media: 90 days.
- Application/security logs: 90 days; debug logs: 30 days.
- Audit logs: 12 months.
- Never store secrets or access tokens in logs or database rows.
- Before enabling real outbound messaging, verify recipient opt-in, the
  24-hour messaging window, approved templates for messages outside that
  window, and a human escalation path.
- Before enabling Gemini on customer conversations or images, approve the
  provider's data-processing, retention, and residency terms for the data sent.

Supabase Auth must also be configured with the production Site URL and both production/preview callback URLs, SMTP, leaked-password protection, and TOTP MFA enabled. These are managed-console settings and are not changed by the repository migration.

For magic-link UX, review **Authentication → Rate Limits** and set the
provider's "Send OTPs or magic links" last-request window to a short, explicit
value such as 15–30 seconds. Do not set it to zero: Supabase's provider limit
and the application-owned five-attempts-per-15-minutes email bucket are both
abuse controls. The browser does not add a second one-minute cooldown.
