# `docs/` — documentation agent notes

Root contract: [`AGENTS.md`](../AGENTS.md).

Memory router: [`memory/INDEX.md`](memory/INDEX.md).

## Two layers

| Layer | Path | Role |
|---|---|---|
| **Living agent memory** | `docs/memory/*` | High-signal current model for Codex/agents |
| **Human/product archive** | most other `docs/*` | PRD, plans, security reviews, runbooks, design drafts |

When onboarding or implementing, **prefer `docs/memory/`**. Use archive docs for deep historical evidence, release ops, or product intent — then verify against code.

## How to treat common docs

| Doc | Treat as |
|---|---|
| `memory/*` | Primary agent context (keep fresh) |
| `adr/*` | Decision records — check vs implementation before relying |
| `PRD.md`, `USER_FLOWS.md` | Product intent; may exceed implemented scope |
| `ARCHITECTURE.md`, `DATABASE.md` | Mixed design + aspirational future (finance/OpenAI staleness) |
| `PERMISSIONS.md` | Baseline matrix intent; runtime is RPC/page checks |
| `AUTH_FLOW.md` | Helpful narrative; verify against `src/features/auth` |
| `AI_AGENTS.md` | Product AI design; tool allowlist in code wins |
| `TEST_PLAN.md` | Quality intent; CI workflow is actual enforced gate set |
| `RELEASE_*.md` | Operational process for humans |
| `SECURITY_REVIEW_*.md` | Point-in-time evidence — not auto-current |
| `superpowers/plans` / `superpowers/specs` | Execution history / designs — not runtime truth |
| `CHAT_AND_WORK_SUMMARY_*` | Time-boxed snapshot |

## Editing rules

1. **Do not** replace living memory with a paste of PRD/ARCHITECTURE.
2. When fixing stale claims discovered in archive docs during feature work, either:
   - update the specific misleading section, or
   - add a pointer to `docs/memory/*` / KNOWN_ISSUES — avoid drive-by full rewrites.
3. New security reviews remain valid as evidence files; also update `memory/SECURITY.md` / `CURRENT_STATE.md` if invariants changed.
4. New ADRs: add the file under `adr/` + a row in the canonical `adr/INDEX.md`.
   `memory/ADR_INDEX.md` is only a compatibility pointer, not a second ADR
   source of truth.
5. Preserve valuable history; do not delete review evidence to “clean up” unless asked.

## Memory maintenance

Follow [`memory/MAINTENANCE.md`](memory/MAINTENANCE.md).
