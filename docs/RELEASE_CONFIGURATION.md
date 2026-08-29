# Managed release configuration

The public deployments are:

- Production: `https://voya-os.vercel.app`
- Preview smoke deployment: `https://voya-os-minasayed290-8553-minas-projects-ed065580.vercel.app`
- Latest preview deployment: `https://voya-dzfiol3ii-minas-projects-ed065580.vercel.app`
- WhatsApp callback target: `https://voya-os.vercel.app/api/webhooks/whatsapp`

Configure the following in Vercel Environment Variables. Do not paste values into Git, tickets, chat, or logs.

| Variable | Preview | Production | Notes |
|---|---:|---:|---|
| `NEXT_PUBLIC_SUPABASE_URL` | yes | yes | Supabase project URL |
| `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` | yes | yes | Public browser key only |
| `VOYA_APP_URL` | yes | `https://voya-os.vercel.app` | Preview must use its own stable preview/branch origin |
| `SUPABASE_SERVICE_ROLE_KEY` | no | yes | Server-only webhook ingestion; never expose to the browser |
| `AUTH_RATE_LIMIT_HMAC_SECRET` | yes | yes | Server-only HMAC key for pre-auth bucket derivation; never expose or log. Rotating it starts fresh rate-limit buckets, so existing counters are not carried forward. |
| `GEMINI_API_KEY` | yes | yes | Preview is fake-only and never calls Gemini |
| `META_WHATSAPP_APP_SECRET` | no | yes | HMAC verification secret |
| `WHATSAPP_VERIFY_TOKEN` | no | yes | Meta webhook verification token |

Safe defaults and feature flags:

```text
GEMINI_ENABLED=false                 # enable only after provider review
GEMINI_MAIN_MODEL=gemini-3.1-flash-lite
GEMINI_EXTRACTION_MODEL=gemini-3.1-flash-lite
GEMINI_CUSTOMER_DATA_APPROVED=false
WHATSAPP_OUTBOUND_ENABLED=false
WHATSAPP_AI_AUTO_REPLIES=false
HUMAN_HANDOFF_APPROVED=false
```

Retention requirements:

- AI raw prompts/responses: 30 days.
- AI redacted metadata: 90 days.
- WhatsApp raw messages/media: 90 days.
- Application/security logs: 90 days; debug logs: 30 days.
- Audit logs: 12 months.
- Never store secrets or access tokens in logs or database rows.

Supabase Auth must also be configured with the production Site URL and both production/preview callback URLs, SMTP, leaked-password protection, and TOTP MFA enabled. These are managed-console settings and are not changed by the repository migration.

For magic-link UX, review **Authentication → Rate Limits** and set the
provider's "Send OTPs or magic links" last-request window to a short, explicit
value such as 15–30 seconds. Do not set it to zero: Supabase's provider limit
and the application-owned five-attempts-per-15-minutes email bucket are both
abuse controls. The browser does not add a second one-minute cooldown.
