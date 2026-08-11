# `src/` — application agent notes

Read root [`AGENTS.md`](../AGENTS.md) and [`docs/memory/INDEX.md`](../docs/memory/INDEX.md) first.  
This file only covers **local** conventions for the Next.js application tree.

## Layout

| Path | Responsibility |
|---|---|
| `app/` | App Router pages, layouts, Server Actions, route handlers |
| `features/` | UI feature modules + auth/workspace helpers (often with colocated tests) |
| `domain/` | Pure-ish rules: tenancy brands, stay ranges, MFA policy, AI tool policy |
| `lib/` | Infrastructure adapters (Supabase, CSP, rate limit, Gemini, Meta webhook, observability) |
| `proxy.ts` | Session refresh + nonce CSP (Next proxy entry) |
| `test/` | Shared vitest setup / smoke |

## Command pattern (mutations)

1. `"use server"` action in `app/workspace/<area>/actions.ts` (or auth routes).
2. Parse/validate form fields locally (Arabic error strings are product UX).
3. `loadActionWorkspaceMembership()` / explicit role checks.
4. `createServerSupabaseClient()` → `.rpc(name, { p_organization_id: membership.organizationId, ... })`.
5. Map Postgres `error.code` → `denied | invalid | retry`.
6. `reportWorkspaceActionFailure` / operational logger on unexpected failures — **scrub secrets**.
7. `revalidatePath` for affected workspace routes.

**Do not** add browser-side Supabase writes for business tables.

## Read pattern

- Pages: `requireWorkspaceMembership(roleSet?)` then RPC list/read functions.
- Dashboard may compose multiple RPCs with role-conditional fetches (`live-dashboard-data.ts`).
- Always `connection()` / request-time auth where workspace context requires it (see workspace-context).

## Auth-critical modules

- `features/auth/workspace-context.ts` — memberships, MFA, org cookie
- `features/auth/require-workspace-membership.ts` — page gate
- `lib/supabase/server-auth.ts` — SSR client + service role factory
- `lib/supabase/proxy-client.ts` / `route-client.ts` — must stay **tokens-only** aligned
- `domain/auth/mfa-policy.ts` — AAL2 rules
- `app/api/webhooks/whatsapp/route.ts` — signature + service role only

## UI notes

- Live chrome/navigation role filters: `features/workspace/workspace-shell.tsx`.
- Feature pages are Arabic-first; keep RTL and accessible labels.
- `features/workspace/workspace-navigation.tsx` is a simpler card list — not the full shell source of truth.

## Forbidden patterns

- Trusting `organization_id` / role from the client body without membership bind
- `createServiceRoleSupabaseClient()` on ordinary user page renders
- Logging raw provider errors that may contain tokens/PII
- Calling Gemini or Meta from Client Components
- Inventing finance posting UI without schema + policy + ADR
- Disabling MFA checks to “make e2e easier” in production paths

## Tests

- Colocate `*.test.ts(x)` next to units.
- Cross-action regression: `app/workspace/command-actions.test.ts`.
- Auth/config: features/auth + lib/supabase tests.
- After auth or protected-route cache changes: `npm run test:production` (and auth-local e2e when session behavior changes).

## Memory to load by task

| Task | Memory |
|---|---|
| Any src change | INDEX + ARCHITECTURE |
| Auth/session/MFA | SECURITY + INTEGRATIONS (Supabase) |
| Booking/tasks/transport actions | DOMAIN_RULES + SECURITY |
| WhatsApp/AI | INTEGRATIONS + SECURITY |
| Navigation/roles UI | DOMAIN_RULES + SECURITY |
