# OpenWA integration for VOYA's primary WhatsApp Business number

**Status:** Proposed design — awaiting Mina's review. No application code,
database, provider configuration, or WhatsApp account has been changed.

## Agreed outcome

VOYA should handle one-to-one customer conversations from Mina's primary
WhatsApp Business number while the WhatsApp Business app remains usable on the
phone. VOYA should classify customer intent, capture useful facts, record
booking interest in the existing customer workflow, and let staff communicate
from VOYA or the phone.

Mina explicitly accepts that a group-message event may exist briefly in
OpenWA's process memory so it can be recognized and discarded. Group content
must not be persisted, logged, sent to plugins/webhooks/WebSockets, written to
VOYA, supplied to AI, or used to enqueue automation or an outbound reply. The
gate must fail closed for groups, channels, status/broadcast events, and
unknown or missing chat-kind metadata. This does **not** claim that the linked
OpenWA process never receives the event in memory.

Booking intent is a reviewable request, not an automatically confirmed stay.
The AI may classify/extract facts, but it must not confirm availability, invent
price or dates, create occupancy, or bypass existing booking commands and
maker-checker approval.

## Checkout evidence and current constraints

Verified — checkout at review start: branch
`sync/main-to-develop-20260923`, HEAD
`3da8295ceaafba1f05dd3306bea48f2f129d71ef`, clean working tree.

- VOYA already has tenant-scoped WhatsApp channels, conversations, message
  events, signed Meta webhook ingestion, a gated AI worker, and an outbox. The
  route and `resolve_whatsapp_webhook_provider_v1` currently allow only
  `meta_cloud` and `meta_cloud_sandbox`; a new OpenWA provider path is required.
- The current AI contract classifies `client_sales`, `existing_customer`,
  `owner_onboarding`, or `unknown`, and can extract dates, guests, area, and
  budget as lead facts. It does not create a booking. Booking drafts and
  confirmation are authenticated, tenant-scoped commands with existing
  availability and approval controls.
- OpenWA's database guide describes message history as optional and shows a
  webhook-only flow, but the current inbound message projector calls the
  message repository before dispatching the webhook. No general supported
  no-store switch was verified in its current environment example. Therefore a
  webhook-only filter is not an adequate privacy boundary.
- OpenWA is a self-hosted, unofficial WhatsApp Web gateway, not a Vercel
  serverless route. Its primary-number use carries a nonzero account
  restriction risk; pin the exact source/image and audit the selected engine
  before any pairing.

Relevant checkout sources: `src/app/api/webhooks/whatsapp/route.ts`,
`src/lib/whatsapp/meta-webhook.ts`,
`supabase/migrations/20260914000100_whatsapp_webhook_provider_resolution.sql`,
`src/lib/whatsapp/whatsapp-ai-worker.ts`,
`src/domain/ai/whatsapp-agent-contract.ts`,
`supabase/migrations/20260801000200_crm_whatsapp_inbox.sql`,
`supabase/migrations/20260722000500_booking_draft_command.sql`, ADR-005,
ADR-008, and ADR-022.

## Approaches considered

1. **Pinned OpenWA fork with an early individual-chat gate — selected.** Add a
   narrow guard to the audited message ingress path before plugin hooks,
   application persistence, webhook/WebSocket dispatch, AI, or automation.
   Allow only an explicitly classified individual chat. This matches the
   chosen OpenWA provider and primary number while preventing durable or
   downstream group-message handling. Trade-offs: the gateway is unofficial,
   the patch must be maintained, and the linked session receives group events
   transiently in memory as Mina accepted.
2. **Filter only in VOYA's webhook — rejected.** OpenWA's current path persists
   the message before webhook dispatch, so this would leave group content in
   OpenWA and could expose it to earlier hooks.
3. **Official Meta Embedded Signup/Coexistence — retained as a fallback, not
   selected now.** It is the supported path to investigate if the in-memory
   OpenWA boundary later becomes unacceptable. It requires a separate check of
   the account/app's current onboarding eligibility; this design does not
   assume that the existing Meta app is ready.

## Proposed architecture

### 1. OpenWA ingress and privacy gate

Run a pinned, self-hosted OpenWA build with persistent session credentials,
restricted operator access, HTTPS, and a dedicated webhook signing secret.
Do not use a floating `latest` image. The selected engine must be audited
end-to-end; if it stores group message content before the gate, that engine is
not eligible for this deployment until the storage path is fixed and tested.

At the earliest application event boundary, before any plugin callback or
message store, normalize the engine metadata to a chat kind. Continue only
when the kind is explicitly `individual`. Drop `group`, `channel`, `status`,
`broadcast`, `unknown`, and missing-kind events. Do not infer chat kind from
customer text or trust a caller-provided organization ID.

For dropped group/non-individual events, there must be no message row, media
archive, persisted message-store entry, plugin callback, webhook, WebSocket
event, AI job, automation evaluation, outbox event, or log containing the body,
sender, group ID, or message ID. The accepted transient in-memory event is the
only exception. If an engine cannot satisfy this, pairing is blocked.

### 2. VOYA OpenWA webhook adapter

Add a Node.js webhook route dedicated to OpenWA, separate from Meta's
`x-hub-signature-256` route. It must:

- read a bounded raw request body and verify OpenWA's HMAC-SHA256 signature in
  constant time before parsing or trusting fields;
- authenticate the configured session/channel, require explicit
  `individual` kind, validate size/type/timestamps, and reject unknown event
  shapes without logging message contents;
- map the OpenWA session identifier to a configured `whatsapp_channels` row
  through a service-role-only provider-resolution RPC; never accept a tenant
  ID from the webhook payload;
- pass individual inbound and manual outbound echoes to the existing
  idempotent WhatsApp ingest boundary. Outbound echoes are recorded as
  outbound and must not trigger AI or an auto-reply loop;
- return a retryable failure when durable ingestion fails. OpenWA's retry
  delivery is at-least-once, so the event key must be stable and namespaced by
  provider/channel before the RPC's existing dedupe key is applied.

The required schema change is additive: permit provider `openwa` in the
provider-resolution boundary and add SQL coverage. Keep WhatsApp tables
tenant-scoped, force RLS, retain service-role-only ingestion, and do not grant
browser roles direct table writes.

### 3. Inbox, AI, and booking-request flow

Reuse VOYA's existing inbox, worker, outbox, and AI safety contract. AI only
receives an already-ingested individual inbound message. Extend the validated
conversation proposal as needed to classify business-relevant intent (for
example, general inquiry, booking request, existing customer, or handoff) and
extract only supported facts such as dates, guests, area/property preference,
and stated budget. Treat message text as untrusted input; low-confidence or
missing facts remain unknown and are shown for review.

A booking request is recorded in the tenant-scoped conversation/CRM lead as a
reviewable request with extracted facts and missing fields. Creating a formal
`bookings` row remains a staff action through the existing authenticated
booking-draft command after a real client/property/date selection. Approval,
availability/occupancy constraints, and final confirmation remain on the
existing workflow. No AI service-role path may mutate bookings or confirm a
reservation.

The target system supports replies from both VOYA and the phone. Manual
one-to-one messages sent on the phone are mirrored to VOYA when OpenWA emits
the individual outbound echo; the echo is never fed back into AI. Replies from
VOYA use an OpenWA outbound adapter through the existing lease-owned outbox.
Ambiguous send timeouts become operator-visible review items, not blind
retries.

Outbound and customer-data AI switches remain off by default during
implementation and synthetic/staging tests. Live AI processing additionally
requires explicit customer-data/provider approval and verified server-side
credentials. Live sends require the channel's active status, kill switch,
delivery lease, and existing outbound policy gates.

### 4. Message flow

1. WhatsApp Business linked session receives an event; the event can exist
   briefly in OpenWA memory.
2. OpenWA's earliest gate drops any event not positively identified as an
   individual chat. No group event proceeds to another application component.
3. An individual event is HMAC-signed and posted to VOYA. VOYA verifies the
   raw body, resolves the configured channel, and ingests it idempotently.
4. The existing inbox stores the direct message. Only eligible inbound
   individual messages can enqueue the AI worker.
5. AI updates a reviewable conversation/lead proposal. Staff can create a
   booking draft through existing authorized commands; the normal approval
   and occupancy safeguards still apply.
6. A staff-approved/manual or explicitly enabled automatic reply is sent by
   the existing outbox worker through OpenWA. Phone-originated outbound echoes
   are mirrored without scheduling another AI response.

## Acceptance and test contract

No primary-number QR is shown or scanned until all of the following pass in
the pinned OpenWA build and VOYA checkout:

1. **OpenWA negative tests:** group, channel, status, broadcast, malformed, and
   missing-kind events produce zero message rows, media files, plugin calls,
   webhook deliveries, WebSocket events, AI/automation calls, or outbox rows.
   Inspect every supported persistent message store and logs, not only the
   primary `messages` table.
2. **OpenWA positive tests:** an individual inbound text reaches the signed
   webhook once logically despite retry; an individual image follows the
   existing bounded private-media path; a phone-originated individual reply
   is mirrored as outbound only.
3. **VOYA route tests:** valid HMAC accepted; missing/invalid HMAC rejected;
   oversized body rejected; altered raw body rejected; unknown session,
   provider, and chat kind fail closed; duplicate delivery does not duplicate
   messages, AI jobs, or replies; `fromMe` never triggers AI.
4. **Database tests:** `openwa` resolves only to its configured tenant channel;
   cross-tenant channel IDs fail; service-role ingestion remains narrowly
   granted; `anon`/authenticated cannot call the privileged ingest path; event
   retries are idempotent.
5. **AI/booking tests:** group payloads never reach the model; direct
   conversations preserve the existing strict response schema; no invented
   price/availability/date; low-confidence requests hand off; booking intent
   is reviewable; no reservation is confirmed or occupancy created by AI.
6. **E2E pre-pair test:** use synthetic signed individual and group events,
   inspect the inbox/lead/booking-request proposal, exercise a human-created
   booking draft, and prove group content is absent from every persistent and
   downstream surface. Do not send real messages during this phase.

After code review and the written implementation plan are separately
approved, a live primary-number pairing is a distinct action-time gate. It
must state the OpenWA account-restriction risk and confirm the exact phone
linking action. Production AI/outbound enablement and managed migrations are
separate gates; this spec does not authorize them.

## Scope exclusions and unresolved gates

- No group chat viewing, syncing, storage, AI, or sending; no import of group
  history.
- No production migration, secret provisioning, worker deployment, webhook
  registration, number pairing, or customer message send as part of this spec.
- Retention period for individual message history and customer-data AI consent
  remain policy gates. The implementation must document any duplicate direct
  message copies retained by OpenWA and VOYA before live use.
- The primary number's coexistence/linked-device state, selected OpenWA engine,
  and account eligibility must be re-read at implementation time; this
  checkout design is not managed-provider proof.

## References

- [OpenWA webhooks](https://docs.open-wa.org/guides/webhooks/)
- [OpenWA authentication](https://docs.open-wa.org/guides/authentication/)
- [OpenWA deployment](https://docs.open-wa.org/self-hosting/deployment/)
- [OpenWA ban risk and safe sending](https://docs.open-wa.org/guides/safe-sending/)
- [OpenWA database design](https://github.com/rmyndharis/OpenWA/blob/main/docs/05-database-design.md)
- [OpenWA inbound message projector](https://github.com/rmyndharis/OpenWA/blob/main/src/modules/session/message-projector.service.ts)
- [Meta Embedded Signup documentation](https://www.postman.com/meta/whatsapp-business-platform/documentation/du6gzjv/embedded-signup)
