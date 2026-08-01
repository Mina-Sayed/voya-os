# ADR-003: Request-Time Workspace Context and Recoverable Outbox Leases

## Status

Accepted on 22 July 2026.

## Context

Next.js prerendered protected workspace pages while they evaluated an empty build-time Supabase session, producing a shared cached redirect to sign-in. The application also rejected users with more than one active organization membership, repeated membership resolution across pages and commands, and allowed crashed outbox claims to remain in `processing` forever.

## Options

1. Patch every route independently with dynamic flags and retain the unique-membership assumption.
2. Centralize request-time workspace context, refresh sessions in a Next.js proxy, validate an organization cookie against current memberships, and recover expired outbox leases through a narrow worker role.
3. Move all application behavior into a separate backend-for-frontend service.

## Decision

Choose option 2. `connection()` establishes a request-time boundary before workspace authentication. `src/proxy.ts` refreshes Supabase cookies but performs no authorization. The workspace-context service validates the selected organization against active memberships on every request, and database RPCs remain the final tenant/role enforcement point.

`claim_outbox_events` may reclaim only expired `processing` leases. A NOLOGIN `voya_outbox_worker` role receives function execution without direct table privileges. The worker lifecycle is completed by separate ownership-checked functions for completion, bounded retry/dead-letter transitions, and explicit batched terminal retention; provider delivery and alert routing remain outside the database.

## Consequences

- Protected pages cannot be safely prerendered or shared-cache stored.
- Multi-organization users must select an organization explicitly.
- A forged or stale organization cookie has no authority and fails closed.
- Session maintenance and authorization remain separate responsibilities.
- Crashed workers no longer strand an event permanently after its lease expires.
- Production delivery remains disabled until a reviewed worker runtime, provider adapter, dead-letter alerting, and operational metrics are deployed.

## Rollback

Roll back the application through the prior immutable deployment. Database rollback uses a reviewed forward migration restoring the prior function body and revoking the worker role's function grant; applied migration history is never rewritten.
