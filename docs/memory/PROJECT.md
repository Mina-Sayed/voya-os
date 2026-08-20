# Project identity

**Last verified:** 2026-08-13
**Evidence class:** implementation + README + PRD intent (scope claims checked against code)

## What it is

**Voya OS** is an Arabic-first, multi-tenant operating workspace for teams that manage **furnished apartment rentals**. Staff operate inventory, demand (leads/clients), bookings/stays, operational tasks, light transport, approvals, audit, in-app notifications, a WhatsApp staff inbox foundation, and governed AI assistance.

It is **not** a guest marketplace, channel manager, full accounting system, or autonomous AI operator.

## Primary users (application roles)

| Role | Meaning in product |
|---|---|
| `owner` | Organization owner / tenant administrator |
| `manager` | Day-to-day operational administrator |
| `sales_agent` | Leads, clients, booking proposals |
| `operations` | Properties, availability, stays, tasks, transport |
| `accountant` | Read/prepare finance surfaces when they exist (finance not implemented) |
| `viewer` | Restricted read (UI mostly hides write paths; DB still enforces) |

**Property owner** is a **business record** (`property_owners`), not the `owner` membership role.

In the **current checkout/application**, organizations are **platform-provisioned** and there is no self-service tenant bootstrap flow. This is checkout truth only; the managed Supabase environment currently contains a self-service bootstrap function. See [CURRENT_STATE.md](./CURRENT_STATE.md) for the separated managed and policy status.

## Core capabilities that exist in code

- Password + Google sign-in (Supabase Auth), multi-org selection, MFA AAL2 gate; Magic Link login is intentionally removed
- Arabic RTL Design C workspace shell with role-aware navigation
- Property owners, properties, availability blocks
- Clients and leads registries
- Booking drafts → approval request → decide → confirm → check-in/out
- Operations tasks and fleet/transport requests
- Approvals read + booking approval decisions
- Audit activity and in-app notifications
- WhatsApp staff inbox (inbound webhook path; outbound disabled by default)
- AI agent center (human-requested proposal execution through a gated worker; finance agent disabled)

## Explicit non-goals / not implemented

Verified absent from migrations/tables (despite aspirational docs):

- Payments, expenses, commissions, settlements, general ledger
- Cancellation / refund / pricing policy commands
- Guest self-service portal, public marketplace
- Autonomous AI mutations of source-of-record data
- Managed outbox worker deployment, scheduler/secrets/provider delivery, and backup/restore evidence (source function and local proofs exist; managed gate remains unknown)

## Primary workflows

1. **Sign in** → MFA if needed → select organization if multi-membership → workspace
2. **Supply setup** → property owners → properties → availability blocks
3. **Demand** → leads → clients
4. **Booking** → draft → request approval → (other actor) decide → confirm → stay events
5. **Operations** → tasks / transport around stays
6. **CRM channel** → WhatsApp inbox review (staff-mediated)
7. **AI assist** → create run request → gated worker proposal → human review (no source-record writes from model)

## Major modules (code layout)

| Path | Responsibility |
|---|---|
| `src/app/` | Routes, Server Actions, webhooks |
| `src/features/` | UI + auth/workspace feature logic |
| `src/domain/` | Framework-light invariants (booking stay, MFA, AI tools, locale) |
| `src/lib/` | Supabase adapters, security, AI/WhatsApp adapters |
| `supabase/migrations/` | Authoritative schema, RPCs, RLS, constraints |
| `supabase/tests/` | SQL assertions for DB invariants |
| `e2e/`, `scripts/` | Browser and guarded production/db checks |

## Critical product constraints

1. Cross-tenant access is unacceptable.
2. Confirmed inventory must stay correct under concurrency.
3. Browser must not be the write authority.
4. Arabic RTL is the default product surface.
5. Do not invent finance, tax, cancellation, settlement, or provider policy.
6. AI proposes; deterministic services remain authoritative.

## Related human docs (secondary)

- Intent/product: `docs/PRD.md`, `docs/USER_FLOWS.md`
- Permissions intent: `docs/PERMISSIONS.md` (baseline matrix; not fully encoded as one table)
- UX: `docs/UX_DESIGN_SYSTEM.md`
