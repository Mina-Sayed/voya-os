# Memory maintenance protocol

**Last verified:** 2026-08-05  

Memory is durable project knowledge. Update it for **semantic** changes, not every line edit. Keep checkout, managed-environment, and product/policy facts separate.

## Truth-plane update rules

| Plane | Record | Required evidence |
|---|---|---|
| **Checkout** | Branch/HEAD, staged/unstaged/untracked posture, working-tree candidates, local test results | Git state and commands run against this checkout; never call an uncommitted migration deployed |
| **Managed environment** | Applied Supabase migrations, deployed function definitions, security mode, grants, and verified provider state | Dated read-only provider/database evidence; name the provider and do not infer Vercel state from Supabase or local files |
| **Product/policy** | Accepted ADRs, approved business decisions, and unresolved decisions | Canonical ADR/approval or explicit open-decision record; do not treat implementation/deployment as policy approval |

When one plane contradicts another, preserve both facts and add a
cross-plane issue rather than rewriting one plane to make the contradiction
disappear. A similarly named migration is not migration parity.

For claims that could be confused across planes, use `Verified — checkout`,
`Verified — managed Supabase`, or `Verified — product/policy`; compact labels
are acceptable when the adjacent evidence names the plane unambiguously.

## When to update which file

| Change type | Update |
|---|---|
| New major subsystem or boundary shift | ARCHITECTURE, INDEX routing row, maybe nested AGENTS |
| New/changed entity, FK, occupancy, tenant ownership | DATA_MODEL, possibly DOMAIN_RULES + SECURITY |
| Booking/task/transport/approval state machine change | DOMAIN_RULES (+ ADR if decision-level) |
| Auth/MFA/RLS/grants/service-role/webhook trust change | SECURITY, INTEGRATIONS if external, ADR if decision-level |
| New external provider or flag | INTEGRATIONS, SECURITY as needed |
| Meaningful branch/release posture change | CURRENT_STATE |
| Discovered durable bug/gap/doc lie | KNOWN_ISSUES (+ fix SOURCES if authority unclear) |
| New ambiguous term | GLOSSARY |
| New/superseded architecture decision | ADR under `docs/adr/` + canonical `docs/adr/INDEX.md` |
| Only typo/refactors with same behavior | **Do not** update memory |

## ADR rules

- Create ADRs sparingly for decisions future agents might reverse by accident.
- Prefer “Current implementation indicates…” when historical intent is unknown.
- Status values: Proposed / Accepted / Superseded / Rejected.
- Link related migrations/tests/code paths.
- The canonical ADR catalog is `docs/adr/INDEX.md`; `docs/memory/ADR_INDEX.md`
  is a compatibility pointer only and must not become a second catalog.
- Do not invent retroactive rationale.

## Anti-rot practices

1. Every memory doc has **Last verified** date — bump when re-checked. For
   current-state claims, also record separate local and managed verification
   dates, plus a Vercel date or explicit unknown state when relevant.
2. Prefer links to paths (`supabase/migrations/...`) over fragile line numbers.
3. One fact lives in **one** primary memory doc; others cross-link.
4. INDEX remains the router — keep the matrix current when areas appear.
5. On discrepancy: implementation+tests win; repair memory in the same PR when practical.
6. Do not duplicate full SQL or source into memory.
7. Nested `AGENTS.md` files stay local and short; root AGENTS stays the contract.
8. Keep the normal 1–3 document selection a context-budget target, not a hard
   limit; expand it when a task crosses truth planes or security boundaries.

## PR checklist (memory-affecting work)

- [ ] Did boundaries, tenancy, or authz change? → SECURITY / ARCHITECTURE
- [ ] Did schema/RPC contracts change? → DATA_MODEL + tests
- [ ] Did business lifecycle change? → DOMAIN_RULES
- [ ] Did providers/flags change? → INTEGRATIONS
- [ ] Is this the active engineering focus? → CURRENT_STATE
- [ ] New irreversible decision? → ADR + canonical `docs/adr/INDEX.md`
- [ ] Does the change assert managed state or provider deployment? → dated
      managed evidence + CURRENT_STATE/KNOWN_ISSUES; do not infer it from Git

## What not to do

- Do not create `MEMORY.md` megadumps.
- Do not auto-generate memory from entire git diffs.
- Do not update memory for dependency bumps unless architecture/security impact is real (exception: ADR-001-style forced overrides).
- Do not delete historical SECURITY_REVIEW files casually; they are evidence archives.
