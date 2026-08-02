# ADR-005: Provider-neutral CRM and WhatsApp staff inbox foundation

## Status

Accepted for internal preview; external delivery is disabled.

## Context

The Design C workspace needs a real operational surface for customer conversations, but the provider credentials, webhook verification contract, consent wording, retention period, and outbound worker policy are not approved. A fake “sent” state would create unsafe operational expectations.

## Decision

Add tenant-scoped contact methods, append-only consent events, provider-neutral WhatsApp channel identities, conversations, message events, and internal notes. Browser roles cannot access these tables directly; all reads and writes use allowlisted SECURITY DEFINER RPCs that resolve the active membership from `auth.uid()` and the requested organization.

Manual replies are stored as `queued` message events and create an outbox request containing only message/conversation identifiers. The UI explicitly says delivery has not been claimed. A future provider worker must verify the channel, consent, kill switch, delivery status, replay key, and tenant context before sending.

## Security boundaries

- No provider token, callback signature, raw provider payload, or secret is stored in this migration.
- Contact and message data are never granted directly to `authenticated`.
- Cross-tenant IDs are checked inside every command/read RPC.
- Audit events omit message bodies and contact values.
- Channel kill switch and disabled status prevent queued replies.

## Consequences

Staff can test the CRM/inbox workflow and ownership model now, while outbound delivery remains safely unavailable until Meta sandbox configuration, webhook verification, consent policy, retention, and worker lifecycle are approved and tested.
