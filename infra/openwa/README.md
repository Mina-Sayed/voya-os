# VOYA OpenWA gateway source

This directory builds the existing OpenWA gateway with VOYA's individual-chat
filter. It uses upstream commit `bc206c28c6ab5baad5d68d15bb116c4b06e8d855`
and the reviewed patch in this repository, so a separate public fork is not
required. The upstream Dockerfile supplies the application image; the image tag
includes the patch digest. No credentials or WhatsApp profiles belong in Git.

```sh
node infra/openwa/build.mjs --check  # fetch the pinned source and verify the patch
node infra/openwa/build.mjs          # build its Docker image locally
```

Use `gateway.env.example` as the gateway configuration. The VOYA deployment uses
`whatsapp-web.js` only. Baileys is not approved by this integration's data-flow
review: its separate raw-message store and mutation paths still handle groups.
The environment pin must be kept when running this image.

Run one gateway instance and one WhatsApp session. Publish its API behind HTTPS,
keep its management key private, and give VOYA an operator key scoped to the
session UUID. Set VOYA's server-only `OPENWA_API_BASE_URL`, `OPENWA_API_KEY`, and
`OPENWA_WEBHOOK_SECRET` in the intended environment. The outbox worker needs the
API URL/key separately in its Edge Function environment. Keep outbound/AI flags
disabled until the real message flow is tested.

VOYA records a durable OpenWA send-attempt mark before calling the gateway.
Only a definite pre-send refusal clears it for retry; an uncertain outcome or
expired worker lease stays in human review to avoid duplicate customer sends.

Register one signed webhook for `message.received` and `message.sent`, pointing
to VOYA's `/api/webhooks/whatsapp/openwa`. Its secret must match VOYA's webhook
secret. VOYA verifies the raw body and its signed `idempotencyKey` payload, then
dedupes by session/chat/direction/provider message ID across delivery registrations.

`WEBHOOK_MEDIA_INLINE_MAX_BYTES=0` is required: VOYA rejects inline base64 and
downloads images through the authenticated stored-media endpoint. Individual
media download must therefore be enabled; a message whose bytes were not stored
cannot be recovered from that endpoint. The 5 MiB download cap bounds this pilot.
VOYA owns automation; the gateway must not also run autonomous replies.

WWebJS live messages and message mutations are filtered before callbacks/media
download, and the main history projector filters before database access. That
does not prove what WhatsApp Web stores inside its retained Chromium profile.
The local unpaired QR test used an isolated tmpfs runtime and removed it after
shutdown. Tmpfs alone is not a guarantee against OS swap or crash diagnostics.
A paired test and the production retention decision remain separate release
gates; this directory does not deploy, pair a phone, or enable customer sends.

## Cloudflare Tunnel template (inactive)

`cloudflared.example.yml` is a locally-managed tunnel template for the gateway
bound on `127.0.0.1:2785`. It contains no tunnel token or credential file. A
custom hostname must belong to a zone managed in the Cloudflare account. The
template does not create a tunnel, DNS route, Access policy, or public endpoint.

After the owner approves public exposure, create a tunnel in Cloudflare, copy
its UUID and credentials path into the template, choose a hostname in that
Cloudflare zone, then run `cloudflared tunnel route dns` and
`cloudflared tunnel --config infra/openwa/cloudflared.example.yml run`. Keep
the API key scoped to the single session and separate from browser-visible
configuration. Do not commit the credentials JSON.
