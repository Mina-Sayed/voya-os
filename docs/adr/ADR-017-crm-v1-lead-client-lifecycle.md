# ADR-017: V1 CRM lead, client, activity, and follow-up lifecycle

**Status:** Accepted for the V1 checkout; managed rollout is not verified
**Date:** 2026-08-13

## Context

The existing registry could store only a minimal lead title and client name.
V1 needs a usable sales workflow that preserves the current data, captures
contact and request facts, records human activity, schedules follow-ups, and
converts a lead to a client without inventing pricing or automatically merging
people.

## Decision

- Keep the legacy `create_lead`, `list_leads`, `create_client`, and
  `list_clients` RPCs for compatibility with existing rows and callers.
- Use the tenant-scoped `*_v1` RPCs for the V1 UI. Lead and client commands
  require active membership, optimistic versions for edits/archive, and
  organization-scoped idempotency keys.
- Require a V1 lead name and at least one contact method. Normalize phone and
  email only for duplicate detection; preserve the submitted display value.
- Treat duplicate detection as a review warning. There is no automatic merge,
  overwrite, or inferred identity.
- Store CRM activities append-only. Follow-ups are explicit human work items;
  completion is a command that records actor/time evidence and does not send
  an external message by itself.
- Convert a lead atomically into a client, link both records, append a
  conversion activity, audit the transition, and stage one outbox event.

## Consequences

The V1 UI can support the complete local CRM journey without making financial,
tax, communication, or identity policy decisions. Legacy rows without the V1
`name` field remain readable through a title fallback, while new V1 commands
enforce the stronger contract. Managed grants, migration application, and any
external notification delivery still require separate staging evidence.

## Evidence

- Migration: `supabase/migrations/20260813000200_crm_v1.sql`
- SQL proof: `supabase/tests/crm_v1.sql`
- Server actions/UI: `src/app/workspace/leads/`,
  `src/app/workspace/clients/`, and `src/features/{leads,clients}/`

## Owner-only CRM permanent deletion (2026-11-12 amendment)

- The original V1 **archive** actions remain the default for historical records and remain accessible to CRM write roles.
- The new delete buttons act on exactly **one** lead or client at a time, and are visible only to an active owner. Server Actions and database RPCs enforce the owner restriction independently. The database additionally requires AAL2, typed exact-name confirmation, optimistic version matching and organization-scoped row locks.
- Permanent deletion is permitted **only for records with no linked dependencies**. All foreign keys remain RESTRICT; conversion history, bookings, CRM activity, follow-ups, WhatsApp conversations and consent records are never cascaded or detached. Linked records must be archived instead.
- Each successful deletion writes a PII-free immutable audit event. CRM deletion never changes Supabase Auth accounts, organization membership, workspace settings or Storage object contents.
- This is **not** a "clear all organization data" feature. A tenant-wide cleanup requires a separate, explicitly scoped, reviewed workflow with retention/legal holds, asynchronous object-storage cleanup, dependency checks and rollback policy. Dashboard-only or ad hoc SQL deletion is not a supported operating procedure.
- Release gating: first apply and verify the new RPC migration on staging, then deploy the UI. Missing migrations fail closed. No migration may be applied automatically to managed Production by simply opening or previewing a PR.
