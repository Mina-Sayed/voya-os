# ADR-018: One lease-owned outbox dispatch worker with gated provider delivery

## Status

Accepted for V1 checkout; managed deployment, secrets, schedule, and provider
verification remain release gates.

## Context

Voya already had a tenant-scoped transactional outbox and recoverable lease
RPCs, but no in-repository delivery runtime. Completing an event merely because
the provider was disabled would lose a business side effect; retrying an
ambiguous provider timeout blindly could duplicate a message.

## Decision

Use one Supabase Edge Function, `outbox-dispatch`, on a one-minute schedule.
Each invocation claims at most 20 supported delivery events for a five-minute
lease. It calls only worker-specific RPCs, uses a server-only privileged
credential, and never exposes that credential or provider keys to the browser.

The database adds the `needs_review` terminal-review state, an allowlisted
delivery claim RPC, lease-owned provider-context/status RPCs, and the existing
complete/fail lifecycle. Retry timing is 1 minute, 5 minutes, 15 minutes, 1
hour, and 6 hours; the initial attempt plus five retries gives six total
attempts. Ambiguous provider outcomes move to `needs_review` instead of a blind
retry. Permanent failures become `dead_letter` and update the provider-neutral
message/invitation status where applicable.

Application email uses a small Resend adapter with the outbox event ID as the
internal idempotency key and the provider idempotency header as a second layer.
Manual WhatsApp outbound uses Meta text delivery only after both
`WHATSAPP_OUTBOUND_ENABLED` and `HUMAN_HANDOFF_APPROVED` are true. Inbound
webhook verification remains unchanged, while the sender phone is now retained
as a tenant-scoped contact method for a future reviewed reply.

Invitation links never place the raw one-time token in the database. The server
action seals it with an AES-256-GCM application/worker key, stores only the
sealed value in the private outbox payload, and the worker decrypts it in
memory immediately before the Resend call. Legacy callers remain available but
produce a reviewable event without a delivery secret until migrated.

## Consequences

- Provider delivery is real code with deterministic flags, idempotency, retry,
  and ambiguous-delivery handling, but it is still disabled until staging
  secrets and provider test evidence exist.
- Unsupported historical/domain events remain outside the delivery claim
  allowlist instead of being silently marked completed.
- `needs_review` requires an owner/operator runbook for inspection and replay;
  this ADR does not invent an automatic replay policy.
- The Edge Function is source-only in this checkout. No managed Supabase,
  Resend, Meta, or scheduler state is claimed from local tests.

## Verification

- `supabase/tests/outbox_dispatch_v1.sql`
- `src/lib/outbox/dispatch-contract.test.ts`
- `src/lib/outbox/sealed-payload.test.ts`
- `src/lib/outbox/worker-config.test.ts`
- `src/lib/email/resend.test.ts`
- `src/lib/whatsapp/meta-outbound.test.ts`
