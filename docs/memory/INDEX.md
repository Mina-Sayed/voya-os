# Voya OS — Agent Memory Index

**Purpose:** Route AI agents and engineers to the minimum high-signal context for a task.  
**Do not** load every memory document by default. Prefer progressive disclosure.

**Last verified:** 2026-08-27

---

## Three separate truth planes

Do not infer one plane from another. Every durable claim should make its plane
clear:

| Plane | Answers | Evidence that can prove it |
|---|---|---|
| **Checkout truth** | What this Git ref contains right now | Current branch, `HEAD`, staged/unstaged/untracked state, tracked and working-tree files, and tests run against this checkout |
| **Managed-environment truth** | What a provider has actually applied or deployed | Dated read-only Supabase migration history, database function/security/grant inspection, and separately verified Vercel/provider deployment and environment state |
| **Product/policy truth** | What is accepted, approved, or still undecided | Accepted ADRs, explicit business decisions, and recorded open decisions |

Checkout migrations are implementation candidates; they do not prove managed
deployment. Accepted ADRs express intent and rationale; they do not prove that
the managed database or provider runtime matches them. Managed evidence does
not prove that the current checkout or its application artifact contains the
same behavior. Policy approval and technical implementation are separate
facts; neither silently substitutes for the other.

## How to use this memory

1. Read root [`AGENTS.md`](../../AGENTS.md) (operating contract).
2. Open this index and select **1–3** memory docs as the normal context-budget target; expand when the task crosses truth planes, security boundaries, or related domains.
3. Open the listed source-of-truth files for the plane being asserted (checkout, managed, or product/policy).
4. If memory and checkout implementation disagree: implementation + tests win. If managed evidence disagrees with checkout or an ADR, record the contradiction instead of silently choosing one.

## Evidence labels

- **Verified — `<truth plane>`** — proven for the explicitly named truth plane by current evidence. Use `Verified — checkout`, `Verified — managed Supabase`, or `Verified — product/policy` when the distinction matters. Checkout verification does not prove managed deployment; managed verification does not prove checkout parity; an accepted ADR does not prove implementation or deployment.
- **Working-tree candidate** — present locally but not yet committed or deployed.
- **Branch-only** — found on another branch/worktree, not this checkout.
- **Inference** — reasonable interpretation without explicit policy proof.
- **Planned** — design or product intent without current implementation.
- **Contradiction** — sources disagree; keep the conflict visible.
- **Unknown** — repository evidence is insufficient.

Nested agent instructions:

| Area | File |
|---|---|
| Application (`src/`) | [`src/AGENTS.md`](../../src/AGENTS.md) |
| Database (`supabase/`) | [`supabase/AGENTS.md`](../../supabase/AGENTS.md) |
| Historical docs (`docs/`) | [`docs/AGENTS.md`](../AGENTS.md) |
| Codex roles (`.codex/`) | [`.codex/AGENTS.md`](../../.codex/AGENTS.md) |

---

## Memory catalog

| Document | Answers |
|---|---|
| [PROJECT.md](./PROJECT.md) | What the product is, users, scope, non-goals |
| [ARCHITECTURE.md](./ARCHITECTURE.md) | Checkout runtime shape, boundaries, data flow |
| [DOMAIN_RULES.md](./DOMAIN_RULES.md) | Verified business/state rules |
| [DATA_MODEL.md](./DATA_MODEL.md) | Entities that actually exist and ownership |
| [SECURITY.md](./SECURITY.md) | AuthZ, tenancy, RLS, dangerous invariants |
| [INTEGRATIONS.md](./INTEGRATIONS.md) | Checkout integration wiring; managed execution requires separate evidence |
| [CURRENT_STATE.md](./CURRENT_STATE.md) | Active work, branch posture, blockers |
| [KNOWN_ISSUES.md](./KNOWN_ISSUES.md) | Evidence-backed gaps and risks |
| [GLOSSARY.md](./GLOSSARY.md) | Ambiguous project terms |
| [SOURCES_OF_TRUTH.md](./SOURCES_OF_TRUTH.md) | Authority hierarchy by category |
| [MAINTENANCE.md](./MAINTENANCE.md) | When/how to update memory |
| [ADR index](../adr/INDEX.md) | Canonical architecture decision map |
| [ADR_INDEX.md](./ADR_INDEX.md) | Compatibility pointer to the canonical ADR index; not a second source of truth |

---

## Task routing matrix

| Task / area | Load first | Then open | Tests / evidence |
|---|---|---|---|
| **Product / scope** | PROJECT | PRD only if product intent needed | — |
| **Frontend / workspace UI** | ARCHITECTURE, DOMAIN_RULES | `src/app/workspace/`, `src/features/` | colocated `*.test.tsx`, e2e |
| **Server Actions / commands** | SECURITY, DOMAIN_RULES | matching `src/app/workspace/**/actions.ts` | `command-actions.test.ts` |
| **Auth / session / MFA** | SECURITY | `src/features/auth/`, `src/lib/supabase/`, ADR-010/011 | auth unit + e2e auth-local |
| **Authorization / roles** | SECURITY, DOMAIN_RULES | page `requireWorkspaceMembership`, RPC role checks | SQL role-denial tests |
| **Database / migrations** | DATA_MODEL, SECURITY, CURRENT_STATE | Checkout: `supabase/migrations/`, `supabase/tests/`; managed: dated migration/function/grant evidence | `npm run test:db`; managed read-only verification |
| **Booking lifecycle** | DOMAIN_RULES, DATA_MODEL | booking lifecycle migration + `bookings/actions.ts` | `booking_lifecycle.sql` |
| **Occupancy / availability** | DOMAIN_RULES, ADR-002 | occupancy + availability migrations | `booking_occupancy_concurrency.sql` |
| **WhatsApp / Meta** | INTEGRATIONS, SECURITY | webhook route, `20260827153809_whatsapp_ai_agent_phase1.sql`, worker, inbox UI | `whatsapp_webhook.sql`, `whatsapp_ai_agent_phase1.sql`, route/E2E tests |
| **AI / Gemini / tools** | INTEGRATIONS, SECURITY | `src/domain/ai/`, `src/lib/ai/`, ADR-010 | tool-policy + gemini tests |
| **Outbox / workers** | ARCHITECTURE, INTEGRATIONS | outbox migrations, ADR-003 | `outbox_foundation.sql` |
| **Security review** | SECURITY, CURRENT_STATE, KNOWN_ISSUES | latest security review docs + canonical ADR index; managed grants/functions when deployment is asserted | `scan:security`, SQL grant tests, dated provider evidence |
| **CI / release** | CURRENT_STATE | `.github/workflows/quality.yml`, RELEASE_* | CI job list |
| **Permissions matrix intent** | DOMAIN_RULES | `docs/PERMISSIONS.md` as **intent**, not final code | RPC + page role gates |
| **Stale docs conflict** | SOURCES_OF_TRUTH | implementation + tests | resolve + update memory |

---

## Progressive disclosure rules

- **Always:** root AGENTS.md.
- **Usually:** INDEX + 1–3 domain docs + source code, as a context-budget target rather than a hard limit.
- **Security-sensitive changes:** SECURITY + relevant ADR + SQL tests.
- **Never auto-load:** every `SECURITY_REVIEW_*.md`, every plan under `docs/superpowers/`, full PRD/ARCHITECTURE drafts.
- Historical docs under `docs/` are **evidence archives**. Prefer `docs/memory/` for current agent context.

---

## Quick checkout snapshot

This is a checkout summary, not managed deployment proof.

Single **Next.js 16 modular monolith** + **Supabase Auth/PostgreSQL**.  
Ordinary authenticated browser mutations flow through Server Actions and authorized RPCs. Privileged webhook, service-role, and worker flows use separate trust boundaries. Direct browser table writes remain deny-by-default unless a specifically documented exception exists.  
Tenant root is `organization_id`. Confirmed inventory is database-enforced. Finance tables are **not implemented**. The checkout contains a gated Gemini integration/runtime path; live managed AI execution is not implied unless separately verified. Historical/product documentation may still reference OpenAI.
