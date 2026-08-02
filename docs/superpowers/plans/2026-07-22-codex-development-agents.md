# Codex Development Agents Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Configure project-scoped Codex agents that can safely orchestrate and implement Voya OS code changes.

**Architecture:** `.codex/config.toml` limits delegation to four direct children and registers four focused agents. Each standalone agent configuration contains its model, reasoning effort, and non-negotiable ownership and safety rules. The configuration is development tooling only and does not add AI behavior to the Voya OS product.

**Tech Stack:** Codex project configuration, TOML, Python 3 standard-library `tomllib` for validation.

## Global Constraints

- Agent files live only in `.codex/agents/`; application code and database schema are not changed by this plan.
- Use `gpt-5.6-sol` with `xhigh` reasoning for orchestration and security review.
- Use `gpt-5.6-terra` with `high` reasoning for database implementation and verification.
- Set `agents.max_threads = 4` and `agents.max_depth = 1`.
- The security reviewer is read-only; no agent may deploy, use production credentials, or make destructive database changes.
- Existing uncommitted user work must be preserved.

---

### Task 1: Register the project-scoped agents

**Files:**
- Create: `.codex/config.toml`
- Create: `.codex/agents/voya-orchestrator.toml`
- Create: `.codex/agents/database-worker.toml`
- Create: `.codex/agents/verification-worker.toml`
- Create: `.codex/agents/security-reviewer.toml`

**Interfaces:**
- Consumes: Codex's project configuration discovery from `.codex/config.toml`.
- Produces: Four named roles: `voya-orchestrator`, `database-worker`, `verification-worker`, and `security-reviewer`.

- [ ] **Step 1: Verify that the configuration files do not exist**

Run:

```bash
test ! -e .codex/config.toml
test ! -e .codex/agents/voya-orchestrator.toml
```

Expected: both commands exit `0` before the configuration is added.

- [ ] **Step 2: Add the registry and role configurations**

Create `.codex/config.toml` with the following registration shape:

```toml
[agents]
max_threads = 4
max_depth = 1

[agents.voya-orchestrator]
description = "Coordinates approved Voya OS engineering work."
config_file = "./agents/voya-orchestrator.toml"
```

Create each referenced agent file with required `name`, `description`, and `developer_instructions` fields. Set the models and reasoning effort required by the Global Constraints. Set `sandbox_mode = "read-only"` only on `security-reviewer`.

- [ ] **Step 3: Validate every TOML file**

Run:

```bash
python3 -c 'import pathlib, tomllib; [tomllib.loads(path.read_text()) for path in pathlib.Path(".codex").rglob("*.toml")]'
```

Expected: exit `0` with no output.

- [ ] **Step 4: Verify registration names and limits**

Run:

```bash
rg -n 'max_threads = 4|max_depth = 1|voya-orchestrator|database-worker|verification-worker|security-reviewer' .codex
```

Expected: all four role names and both limits are present.

### Task 2: Document activation and current-session behavior

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: the role names registered in `.codex/config.toml`.
- Produces: an exact command to start Codex in the repository and a sample prompt that dispatches the roles to an approved plan.

- [ ] **Step 1: Add a Codex Development Agents section to the README**

Add the following usage shape after the quality commands section:

```markdown
### Codex development agents

Start a new Codex session from the repository root after pulling the configuration:

```bash
cd /home/mina/voya-os
codex
```

Then request explicit delegation, for example:

```text
Use voya-orchestrator to execute docs/superpowers/plans/2026-07-21-property-availability-foundation.md.
Delegate the migration and SQL assertions to database-worker, verification to verification-worker,
and a final read-only review to security-reviewer. Preserve uncommitted work and do not deploy.
```
```

State that custom roles are discovered by a new session; the active session must supply equivalent role instructions explicitly.

- [ ] **Step 2: Re-run TOML validation and markdown whitespace validation**

Run:

```bash
python3 -c 'import pathlib, tomllib; [tomllib.loads(path.read_text()) for path in pathlib.Path(".codex").rglob("*.toml")]'
git diff --check
```

Expected: both commands exit `0`.

### Task 3: Activate the team for the current database plan

**Files:**
- No application file changes required.

**Interfaces:**
- Consumes: `docs/superpowers/plans/2026-07-21-property-availability-foundation.md`.
- Produces: one bounded database-worker task followed by independent verification and security-review reports.

- [ ] **Step 1: Start the orchestrator in a new Codex session**

Run from the repository root:

```bash
codex
```

Expected: Codex starts with the project configuration available.

- [ ] **Step 2: Send the explicit delegation prompt**

```text
Use voya-orchestrator to execute docs/superpowers/plans/2026-07-21-property-availability-foundation.md.
First, assign database-worker exclusive ownership of supabase/tests/property_availability_foundation.sql,
supabase/migrations/20260721000300_property_availability_foundation.sql,
scripts/test-database-foundation.mjs, and the two property/availability documents.
After implementation, assign verification-worker the full quality gates and security-reviewer a read-only review.
Preserve all uncommitted work. Do not deploy, use production credentials, or perform destructive operations.
```

Expected: the orchestrator delegates one implementation owner at a time, then collects test and review evidence.
