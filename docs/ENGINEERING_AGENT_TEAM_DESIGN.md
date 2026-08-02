# Engineering Agent Team Design

Date: 2026-07-26
Status: Approved

## Decision

Provide a personal Codex plugin named `engineering-agent-team` with one explicit-only skill named `orchestrate-engineering-team`.

The plugin never runs automatically. When invoked, it performs read-only discovery, presents the proposed agents, tasks, file ownership, dependencies, models, reasoning effort, permissions, and verification evidence, then stops for explicit user approval. It may spawn agents or edit project files only after that approval.

## Model policy

- `gpt-5.6-sol` with `xhigh` reasoning handles orchestration, architecture, security review, high-risk database design, and production infrastructure reasoning.
- `gpt-5.6-terra` with `medium` or `high` reasoning handles exploration, bounded implementation, verification, and documentation.
- The plugin never uses or falls back to a 5.3 model.
- If an approved model is unavailable, execution fails closed and returns to the user.

## Coordination policy

- Maximum four active agents.
- Default delegation depth is one.
- Every writing agent receives exclusive file or module ownership.
- Each prompt states that other agents and user changes may exist and must be preserved.
- Security-sensitive implementation requires independent read-only review.
- Production changes, deployments, destructive actions, credentials, and external mutations require separate authorization.

## Distribution

The plugin is stored at `/home/mina/plugins/engineering-agent-team` and registered in the personal marketplace at `/home/mina/.agents/plugins/marketplace.json`, making it available to future Codex projects for the same user.

Invoke it explicitly as `$engineering-agent-team:orchestrate-engineering-team`. Its presence or discovery never authorizes execution.

## Alternatives considered

1. Automatically start agents when a repository opens. Rejected because the user requires manual invocation and approval.
2. Persist only project-scoped Voya agents. Rejected as the sole solution because it would not be reusable across future projects.
3. Use one large fixed team for every task. Rejected because role count should follow actual independent workstreams.

## Consequences

The approval step adds one interaction before execution, but makes cost, permissions, ownership, and model choice visible. The personal plugin supplies reusable routing while each repository retains its own higher-priority instructions and project-specific agents.
