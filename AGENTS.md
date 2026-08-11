# Voya OS — Agent Operating Contract

Arabic-first, multi-tenant **furnished rental operations** workspace.
Checkout implementation stack: **Next.js 16 (App Router) + Supabase Auth/PostgreSQL**.
Shape: **single modular monolith** (not a monorepo, not microservices).

This file is a **router + contract**, not the full documentation set.

---

## 1. Read project memory first

Durable agent memory lives in [`docs/memory/`](docs/memory/INDEX.md).

| Need | Start here |
|---|---|
| What to load for a task | [`docs/memory/INDEX.md`](docs/memory/INDEX.md) |
| Product identity / scope | [`docs/memory/PROJECT.md`](docs/memory/PROJECT.md) |
| Runtime architecture | [`docs/memory/ARCHITECTURE.md`](docs/memory/ARCHITECTURE.md) |
| Business rules | [`docs/memory/DOMAIN_RULES.md`](docs/memory/DOMAIN_RULES.md) |
| Schema / entities | [`docs/memory/DATA_MODEL.md`](docs/memory/DATA_MODEL.md) |
| AuthZ / tenancy / secrets | [`docs/memory/SECURITY.md`](docs/memory/SECURITY.md) |
| External systems | [`docs/memory/INTEGRATIONS.md`](docs/memory/INTEGRATIONS.md) |
| Active branch / blockers | [`docs/memory/CURRENT_STATE.md`](docs/memory/CURRENT_STATE.md) |
| Authority when docs conflict | [`docs/memory/SOURCES_OF_TRUTH.md`](docs/memory/SOURCES_OF_TRUTH.md) |
| Update rules | [`docs/memory/MAINTENANCE.md`](docs/memory/MAINTENANCE.md) |
| Decision records | [`docs/adr/INDEX.md`](docs/adr/INDEX.md) |

**Progressive disclosure:** root AGENTS + INDEX + **1–3** memory docs as a normal context-budget target; expand when the task crosses truth planes or security boundaries.
Do **not** bulk-load every `docs/SECURITY_REVIEW_*.md` or superpowers plan.

Nested contracts: [`src/AGENTS.md`](src/AGENTS.md) · [`supabase/AGENTS.md`](supabase/AGENTS.md) · [`docs/AGENTS.md`](docs/AGENTS.md) · [`.codex/AGENTS.md`](.codex/AGENTS.md)

---

## 2. Source-of-truth rules

1. **Implementation + passing tests win** over README/PRD/architecture drafts.
2. **Schema authority** = `supabase/migrations/`, proven by `supabase/tests/`.
3. **Command authority** = SECURITY DEFINER RPCs + Server Actions that call them.
4. **Accepted ADRs** document intentional boundaries; supersede explicitly if reversing.
5. Historical `docs/*` drafts may be aspirational (especially finance + OpenAI mentions).
6. Chat is ephemeral. If it matters, write it into memory/ADR/code.

Checkout contents, managed provider state, and product/policy decisions are
separate evidence planes. Dated read-only provider evidence is required for
claims about applied migrations, deployed functions/grants, or Vercel state;
checkout files and accepted ADRs do not prove deployment.

Details: [`docs/memory/SOURCES_OF_TRUTH.md`](docs/memory/SOURCES_OF_TRUTH.md).

---

## 3. Critical engineering principles

1. **Tenant isolation:** every business fact is organization-scoped; never trust client org/role/user ids.
2. **Browser writes deny-by-default:** derive user, membership, organization on the server.
3. **Database enforces concurrency-critical invariants** (confirmed occupancy, tenant FKs, exclusions).
4. **Idempotency + audit (+ outbox when defined)** on sensitive commands.
5. **Arabic RTL default;** keep mixed-direction rendering correct.
6. **Do not invent** finance, tax, cancellation, settlement, or provider policy.
7. **AI proposes;** deterministic services remain source of record. No autonomous money/inventory mutations.
8. **Next.js 16:** before changing framework behavior, read guides under `node_modules/next/dist/docs/`.
9. **Never commit or print secrets.**
10. **Preserve unrelated dirty work;** do not revert user changes.

---

## 4. Security invariants (do not casually break)

- Workspace access requires **MFA AAL2** (verified TOTP) after sign-in.
- Session cookies use Supabase SSR **`tokens-only`** encoding; verify users with `getUser()`.
- Ordinary authenticated staff mutations flow through Server Actions and
  authorized RPCs, not broad table DML grants. Privileged webhook, service-role,
  and worker flows use separate narrowly scoped trust boundaries.
- **Service role** is server-only (webhooks/workers), never `NEXT_PUBLIC_*`.
- WhatsApp webhook: verify **raw-body HMAC**, then service-role ingest only.
- `anon` must not execute staff RPCs. The public auth rate-limit surface must
  use a database-owned policy, and every overload and grant must be verified in
  managed environments before that invariant is claimed as deployed.
- Maker-checker: booking approver ≠ requester; approval does not waive occupancy constraints.

Full map: [`docs/memory/SECURITY.md`](docs/memory/SECURITY.md).

---

## 5. Repository map (code)

| Path | Role |
|---|---|
| `src/app/` | Routes, Server Actions, webhooks |
| `src/features/` | UI + feature/auth logic |
| `src/domain/` | Framework-light rules (booking, MFA, AI tools, locale) |
| `src/lib/` | Supabase, security, AI, WhatsApp adapters |
| `supabase/migrations/` | Schema, RLS, RPCs, constraints |
| `supabase/tests/` | SQL proofs |
| `e2e/`, `scripts/` | Browser + guarded production/DB checks |
| `.codex/agents/` | Optional Codex engineering roles |
| `docs/memory/` | Durable agent memory |
| `docs/adr/` | Architecture decisions |

---

## 6. Commands

```bash
npm run dev
npm run lint
npm test
npm run test:coverage
npm run test:memory
npm run test:db          # VOYA_DB_TEST=1 + local DATABASE_URL to *_test only
npm run test:e2e
npm run test:e2e:auth-local
npm run test:production  # after build without trusting shared cache
npm run scan:security
npm run build && npm run start
```

---

## 7. Testing expectations

- Prefer **failing test first** for behavior changes.
- Commands need **tenant isolation, role denial, idempotency, error-path** coverage as applicable.
- DB/security changes need SQL tests on disposable DB only — never shared/production.
- Protected routes: keep request-time rendering; run production render checks when touching auth/cache boundaries.
- Colocate unit tests as `*.test.ts` / `*.test.tsx`.

---

## 8. Coding conventions

- TypeScript, function components, 2-space indent, existing ESLint.
- `PascalCase` components, `camelCase` utilities.
- Keep domain logic independent of Next/Supabase where practical.
- Conventional Commits; scoped staging; no secret materials.

---

## 9. After meaningful changes

Update memory per [`docs/memory/MAINTENANCE.md`](docs/memory/MAINTENANCE.md).
At minimum consider CURRENT_STATE for branch-level shifts; SECURITY/DATA_MODEL/DOMAIN_RULES when those boundaries move.

---

## 10. Hard non-goals for agents unless explicitly ordered

- Deploying or mutating managed production/preview infrastructure
- Enabling live customer AI data or WhatsApp outbound in shared envs
- Implementing full finance/ledger to “match the PRD”
- Rewriting Git history or merging unrelated branches
- Expanding scope into marketplace, guest portal, or microservices

## 11. Evidence labels

Use `Verified — <truth plane>` when recording a claim that could cross planes
(`checkout`, `managed Supabase`, or `product/policy`), alongside
`Working-tree candidate`, `Branch-only`, `Inference`, `Planned`, `Contradiction`,
and `Unknown`. Verified checkout evidence does not prove managed deployment;
managed evidence does not prove checkout parity; an accepted ADR does not prove
implementation or deployment. Never present an uncommitted migration, another
branch, or a design-only feature as deployed behavior.
