# ADR-021: Bounded readiness dependency probe

**Status:** Accepted for PR #10

**Supersedes:** The readiness semantics in ADR-019; ADR-019's liveness and release-identity guidance remains applicable.

## Decision

`/api/health/ready` and its `/api/health` alias validate public application configuration and run a bounded, service-role Supabase dependency probe. The probe has a short abort timeout and returns `503 {"status":"not_ready"}` on configuration, transport, or timeout failure. `/api/health/live` remains process-only and does not query a provider.

This endpoint reports application readiness for traffic and deployment orchestration. It does not certify managed Supabase availability beyond the single bounded query, and it does not expose provider details or secrets.

## Consequences

- A stalled dependency cannot hold the health request open indefinitely.
- Operators can distinguish process liveness from application readiness.
- Provider health remains an operational signal, not a product or release guarantee; managed-environment verification still requires provider evidence.
