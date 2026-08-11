# `.codex/` — Codex engineering roles

Root contract: [`../AGENTS.md`](../AGENTS.md).  
Memory router: [`../docs/memory/INDEX.md`](../docs/memory/INDEX.md).

## Purpose

Optional multi-agent development roles for Codex sessions. They do **not** replace product AI assistants inside the Voya workspace.

Configured in `config.toml`:

| Role | File | Use for |
|---|---|---|
| `voya-orchestrator` | `agents/voya-orchestrator.toml` | Plan allocation, bounded delegation, evidence synthesis |
| `database-worker` | `agents/database-worker.toml` | Migrations + SQL tests (exclusive file ownership) |
| `verification-worker` | `agents/verification-worker.toml` | Running quality gates, returning evidence |
| `security-reviewer` | `agents/security-reviewer.toml` | Independent tenancy/security review |

## Operating rules for these roles

1. Read root AGENTS + relevant `docs/memory/*` before editing.
2. Database-worker owns `supabase/migrations` + `supabase/tests` during delegated work — avoid parallel writers.
3. Security-reviewer should load `docs/memory/SECURITY.md` + ADR index + changed SQL/app auth paths.
4. Verification-worker must use disposable DB guards and never production credentials.
5. Orchestrator waits for explicit user approval of allocation when its instructions require it.
6. None of these roles may deploy, widen production access, or invent finance policy.

## Memory routing by role

| Role | Minimum memory |
|---|---|
| Orchestrator | INDEX, CURRENT_STATE, ARCHITECTURE |
| Database-worker | DATA_MODEL, SECURITY, DOMAIN_RULES, supabase/AGENTS |
| Verification-worker | INDEX, CURRENT_STATE, SOURCES_OF_TRUTH |
| Security-reviewer | SECURITY, DOMAIN_RULES, `docs/adr/INDEX.md`, KNOWN_ISSUES |
