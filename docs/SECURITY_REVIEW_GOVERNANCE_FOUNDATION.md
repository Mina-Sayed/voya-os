# Governance Foundation Security Review

**Review date:** 2026-07-21
**Scope:** append-only audit and approval-fact migration, tenant-qualified relational integrity, and database integration assertions.

## Controls added

- Audit events reject all update/delete operations through a database trigger, independently of grants.
- Approval decisions reject all update/delete operations; a requester cannot decide their own request.
- Approval request, decision, and audit actor references are bound to the same `organization_id` through composite foreign keys.
- RLS is enabled and forced on all three tables. No `authenticated` grants or policies are added, so browser clients cannot read or mutate governance source-of-record rows.
- The proposal hash is constrained to a lowercase SHA-256-shaped value. It is not treated as a substitute for canonicalization; server commands must produce the canonical snapshot and hash before any execution logic exists.

## Verification evidence

`npm run test:db` applies migrations in lexical order to an isolated database and proves table presence, self-approval rejection, cross-tenant requester rejection, audit update/delete rejection, and browser-role audit-write denial.

## Required next controls

1. Server-side proposal commands must canonicalize input, verify trusted membership/role/session assurance, evaluate the versioned approval policy, and append audit/outbox records in the same transaction.
2. Approval request state transitions and execution must consume one exact, unexpired approval snapshot exactly once; those transitions are not enabled by this foundation.
3. Add narrowly scoped, role/field-aware read policies only alongside server query tests. Do not grant blanket access to governance payloads.
4. Retain the existing availability-block concurrency, CSP, production migration GitOps, Snyk, and Trivy launch blockers.
