# Security Review: Transactional Outbox Foundation

Date: 2026-08-01

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
- Only the current worker holding a non-expired lease can complete or fail an event; stale workers receive a no-op result.
- Retry failures accept only bounded, non-sensitive error codes and move to `retry_wait` until the configured maximum attempts, then to `dead_letter`.
- A worker-only, batched purge function removes terminal events only after an explicit bounded retention interval.
- Creating a property owner now writes its audit event and corresponding
  `property_owner.created` outbox event in the same transaction.
- The private claim function validates its worker, batch, and lease inputs,
  uses `FOR UPDATE SKIP LOCKED`, increments attempts atomically, and exposes no
  execute grant to browser roles. Integration tests prove two workers claim
  distinct eligible events.

## Deferred controls

Dead-letter alert routing, provider adapters, retry metrics, and the concrete
worker runtime still require deployment decisions. No implementation may send
a provider request before those controls and tests exist.
