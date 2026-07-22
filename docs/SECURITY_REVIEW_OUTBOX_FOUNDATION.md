# Security Review: Transactional Outbox Foundation

Date: 2026-07-22

## Boundary

`outbox_events` stores durable, tenant-scoped intents for post-commit work. It
is not a browser queue and no worker/provider execution is enabled in this
slice.

## Controls verified

- Forced RLS and revoked table privileges deny all direct browser access.
- Every event has a tenant, validated event type, positive schema version,
  object payload, and non-empty dedupe key.
- Tenant/event/dedupe uniqueness prevents duplicate logical effects.
- Lease state is constrained: only `processing` rows may hold a worker lease.
- Creating a property owner now writes its audit event and corresponding
  `property_owner.created` outbox event in the same transaction.
- The private claim function validates its worker, batch, and lease inputs,
  uses `FOR UPDATE SKIP LOCKED`, increments attempts atomically, and exposes no
  execute grant to browser roles. Integration tests prove two workers claim
  distinct eligible events.

## Deferred controls

Worker identity provisioning, lease recovery, backoff schedule, dead-letter
alerting, payload retention, and notification providers require the pending
worker-runtime decision. No implementation may send a provider request before
those controls and tests exist.
