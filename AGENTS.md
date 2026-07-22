<!-- BEGIN:nextjs-agent-rules -->
# This is NOT the Next.js you know

This version has breaking changes — APIs, conventions, and file structure may all differ from your training data. Read the relevant guide in `node_modules/next/dist/docs/` before writing any code. Heed deprecation notices.
<!-- END:nextjs-agent-rules -->

## Product documentation map

- [Product requirements](docs/PRD.md), [user flows](docs/USER_FLOWS.md), and [roles](docs/PERMISSIONS.md)
- [database contract](docs/DATABASE.md) and [architecture](docs/ARCHITECTURE.md)
- [AI controls](docs/AI_AGENTS.md) and [test plan](docs/TEST_PLAN.md)

Do not invent unresolved finance, approval, tax, retention, or external-provider policy. Keep browser writes deny-by-default; use reviewed server-owned commands with tenant authorization, audit evidence, and database invariants.
