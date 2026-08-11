# ADR-014 — Progressive repository memory

**Status:** Accepted
**Date:** 2026-08-03

## Context

Voya OS contains valuable but differently authoritative material: executable Next.js and PostgreSQL behavior, SQL and browser tests, accepted ADRs, draft product/architecture documents, historical security reviews, branch-only work, and active uncommitted remediation. A future Codex session needs current context without treating every document as truth or loading the entire repository.

## Options considered

1. Extend only the existing product and architecture documents. Rejected because they intentionally mix product intent with superseded implementation assumptions.
2. Create one large `MEMORY.md`. Rejected because it duplicates source, consumes context, and becomes difficult to maintain.
3. Use a layered operating contract, routing index, focused memory documents, scoped nested contracts, an ADR index, and structural validation. Selected.

## Decision

The repository uses:

- root `AGENTS.md` as the operating contract;
- scoped `AGENTS.md` files for application and database boundaries;
- `docs/memory/INDEX.md` as the progressive-disclosure router;
- focused memory documents for project identity, architecture, domain rules, data, security, integrations, current state, known issues, glossary, sources, and maintenance;
- `docs/adr/INDEX.md` as the canonical decision router;
- `npm run test:memory` to validate required files, links, indexes, dates, agent routing, and Mermaid fences.

## Evidence and conflict rules

Use `Verified — <truth plane>` when a claim could cross planes (`checkout`,
`managed Supabase`, or `product/policy`), alongside `Working-tree candidate`,
`Branch-only`, `Inference`, `Planned`, `Contradiction`, and `Unknown`. A
verified checkout claim does not prove managed deployment; managed evidence
does not prove checkout parity; an accepted ADR does not prove implementation
or deployment. For current behavior, reproducible runtime/test evidence and
ordered migrations outrank memory and design documents. Policy approval and
technical implementation remain separate facts.

## Amendment — 2026-08-05

Repository evidence handling was refined to distinguish checkout truth,
managed-environment truth, and product/policy truth explicitly. This amendment
clarifies evidence labeling and plane boundaries; it does not change the
2026-08-03 decision or runtime behavior.

## Consequences

Agents normally load the root contract, the memory index, one to three topic documents, and the relevant source/tests as a context-budget target. They expand that set when a task crosses truth planes or security boundaries. Existing design drafts and security reviews remain available as history and intent but are not silently promoted to runtime truth. Memory changes become part of normal review and CI.

## Invariants

- No application, database, route, environment, or deployment behavior is changed by the memory layer.
- Existing dirty and untracked user work is preserved.
- Memory does not contain secrets, customer records, or copied source code.
- When implementation and memory disagree, the discrepancy is recorded and the memory is repaired.
- Checkout truth, managed-environment truth, and product/policy truth are recorded separately; one plane never silently proves another.

## Related implementation

- `AGENTS.md`
- `src/AGENTS.md`
- `supabase/AGENTS.md`
- `docs/memory/INDEX.md`
- `scripts/verify-project-memory.mjs`
- `scripts/verify-project-memory.test.mjs`
