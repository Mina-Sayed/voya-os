# Architecture decision index

**Last verified:** 2026-08-05

This is the canonical index for `docs/adr/`. Read the relevant decision before changing the boundary it protects. ADRs describe intent and rationale; current migrations, executable code, and passing tests still determine runtime behavior.

## Decisions in this checkout

| ID | Decision | Status recorded in ADR | Protected boundary |
|---|---|---|---|
| [ADR-001](./ADR-001-safe-sharp-override.md) | Safe Sharp override | Accepted | Dependency security override; avoid unsafe Next downgrade |
| [ADR-002](./ADR-002-property-occupancy-lock.md) | Unified property occupancy ledger | Status metadata absent; implementation is present | Booking/block overlap control |
| [ADR-003](./ADR-003-production-auth-context-and-outbox-recovery.md) | Request-time workspace context and recoverable outbox leases | Accepted | Auth context and lease recovery |
| [ADR-004](./ADR-004-design-c-workspace-shell.md) | Design C workspace shell | Accepted for first live slice | Arabic RTL workspace navigation |
| [ADR-005](./ADR-005-crm-whatsapp-staff-inbox.md) | Provider-neutral CRM and WhatsApp inbox | Accepted for internal preview | Inbound inbox model; external delivery off |
| [ADR-006](./ADR-006-operations-task-registry.md) | Tenant-scoped operations task registry | Accepted for core preview | Operations task ownership |
| [ADR-007](./ADR-007-fleet-and-transport-operations.md) | Fleet and transport foundation | Accepted | Transport entities and allocation |
| [ADR-008](./ADR-008-booking-approval-and-stay-lifecycle.md) | Booking approval and stay lifecycle | Accepted for internal preview | Maker-checker and stay transitions |
| [ADR-009](./ADR-009-auth-rate-limiting-and-nonce-csp.md) | Auth rate limiting and nonce CSP | Accepted | Pre-auth abuse control and request CSP |
| [ADR-010](./ADR-010-gemini-meta-mfa-release-boundary.md) | Gemini, Meta, and MFA release boundary | Accepted; providers off by default | AAL2, synthetic AI, inbound-only WhatsApp |
| [ADR-011](./ADR-011-supabase-tokens-only-session-cookies.md) | Tokens-only Supabase session cookies | Accepted | SSR cookie encoding and user verification |
| ADR-012 | No file in this checkout | Numbering gap | Branch-only auth work uses this number elsewhere |
| [ADR-013](./ADR-013-database-enforced-production-security-invariants.md) | Database-enforced production security invariants | Accepted for human-reviewed merge; managed rollout gated | Grants, tenant FKs, lifecycle hardening |
| [ADR-014](./ADR-014-progressive-repository-memory.md) | Progressive repository memory architecture | Accepted | Durable AI context and memory maintenance |
| [ADR-015](./ADR-015-forward-only-auth-rate-limit-compatibility.md) | Forward-only auth rate-limit compatibility and migration reconciliation | Accepted for local implementation; managed rollout gated | Immutable migration history and rolling auth RPC contract |

## Branch and history notes

- `codex/auth-flow-fix` contains branch-only ADR-012 and a different ADR-013. The duplicate numbering must be resolved before merging that branch.
- A missing status field in ADR-002 is recorded as unknown metadata; no historical acceptance date is fabricated.

## Adding or superseding a decision

Create a new ADR only when a future engineer could accidentally reverse a durable boundary. Link the implementation, migration, and tests. Mark an old ADR superseded instead of rewriting its historical context.
