# Sources of truth

**Last verified:** 2026-08-05  

When sources conflict, first identify the truth plane. **Do not silently let
checkout files, managed provider state, or product policy stand in for one
another.**

## Truth-plane authority

There is no single cross-plane hierarchy:

### A. Checkout truth

For this Git checkout, use reproducible local runtime/test behavior first,
then executable code/configuration and the ordered migration/test files that
are actually present in the checkout. Staged, unstaged, and untracked files
must be called out separately. Uncommitted migrations and other dirty-tree
files are **Working-tree candidate** evidence, not managed deployment evidence.

### B. Managed-environment truth

For Supabase or Vercel claims, use dated read-only evidence from that provider:

- Supabase migration history for applied versions;
- database catalog/function inspection for deployed definitions and
  `SECURITY DEFINER` state;
- privilege inspection for `anon`, `authenticated`, service roles, and other
  principals; and
- separately verified Vercel deployment, environment, domain, and runtime
  state when those claims matter.

Checkout migration filenames, a local build, an accepted ADR, or a similarly
named migration do not prove managed state. A managed snapshot also does not
prove that the current checkout or application artifact contains the same
behavior. Record the provider and verification date with managed claims.

### C. Product/policy truth

Accepted ADRs in [`docs/adr/INDEX.md`](../adr/INDEX.md) express intentional
architecture/security policy and rationale. Explicitly approved business
decisions are authoritative for product policy. Unresolved finance, tax,
commission, settlement, cancellation, retention, provider, or deployment
decisions remain open; implementation or managed state does not silently
resolve them. ADRs and approvals do not prove deployment.

Agent memory (`docs/memory/*`) is a curated router and discrepancy record,
not a higher authority than the plane it describes. Security reviews, plans,
PRDs, architecture drafts, chat history, and branch names are secondary or
historical evidence unless independently verified.

## Category map

| Category | Checkout authority | Managed-environment authority | Product/policy authority |
|---|---|---|---|
| **DB schema / constraints** | `supabase/migrations/*.sql` in this checkout | Applied migration history + live catalog/constraint inspection | Accepted ADRs describe intent; `docs/DATABASE.md` may be aspirational |
| **RPC contracts** | Function definitions present in checkout migrations + call sites | Live function signatures, bodies, security mode, and behavior | ADRs/plans describe target compatibility |
| **RLS / grants** | Checkout migrations changing policies/grants + SQL tests | Live privilege/catalog inspection, including `has_function_privilege` | Generic permissions prose alone |
| **Auth session** | `src/lib/supabase/*`, `src/features/auth/*`, `src/proxy.ts` | Deployed app/provider configuration when explicitly checked | ADR-011 and AUTH_FLOW.md |
| **MFA policy** | `src/domain/auth/mfa-policy.ts` + workspace context | Deployed app behavior when explicitly checked | ADR-010 |
| **Role allow-lists (pages)** | `requireWorkspaceMembership` call sites | Deployed app behavior when explicitly checked | Shell `allowedRoles`, PERMISSIONS.md intent |
| **Role allow-lists (commands)** | RPC bodies + Server Action checks | Live RPC body/grants when deployment is asserted | UI disabled buttons |
| **Booking lifecycle** | Lifecycle migrations (+ remediation) | Live function/constraint inspection | `booking_lifecycle.sql`, ADR-008/013, PRD future finance effects |
| **Occupancy** | Occupancy migration + booking exclusion | Live exclusion constraints and catalog state | Concurrency SQL tests, ADR-002 |
| **AI tools** | `src/domain/ai/tool-policy.ts`, agent registry | Deployed flags/provider state when checked | AI_AGENTS.md, ADR-010, stale OpenAI sections |
| **WhatsApp webhook** | Webhook route + Meta adapter + ingest migration | Provider configuration and deployed route only when checked | Route tests, ADR-005/010, auto-reply design claims |
| **Outbox** | Outbox migrations and worker code | Managed worker/runtime deployment when checked | ADR-003; assumption that a worker is deployed |
| **HTTP security headers/CSP** | `next.config.ts`, CSP helper, proxy | Deployed response evidence when checked | ADR-009 |
| **CI gates** | `.github/workflows/quality.yml` | CI run evidence for a specific revision | TEST_PLAN.md; local-only scripts not in CI |
| **Env/config requirements** | `public-config.ts`, health route, README | Provider environment/config inspection with date | RELEASE_CONFIGURATION.md; `.env.local` (never commit) |
| **UX copy/IA** | `src/features/**`, workspace shell | Deployed app behavior when checked | UX_DESIGN_SYSTEM.md, ADR-004 |
| **Implemented product capability** | Implemented application surface in this checkout | Deployed application surface only when explicitly verified | Approved product scope where relevant; not inferred from implementation |
| **Product/policy intent** | Checkout implementation does not prove product intent | Managed deployment does not prove product intent | Accepted decisions, ADRs, PRD/product approvals, and explicit open decisions |
| **Release process** | RELEASE_RUNBOOK.md + current branch reality | Provider deployment state and approved window evidence | README status blurbs and old deployment notes |

## Conflict resolution protocol

1. Label the claim as checkout, managed-environment, or product/policy truth.
2. Reproduce with the smallest local test, SQL assertion, or dated provider read that can prove that plane.
3. Record a non-trivial cross-plane contradiction in [KNOWN_ISSUES.md](./KNOWN_ISSUES.md).
4. Fix code/tests when checkout behavior is wrong; fix memory when the description is wrong; use an approved migration/release process for managed state.
5. Only change aspirational docs when doing intentional doc-debt work — do not “update everything” in feature PRs.
6. If policy is genuinely undecided, leave an **open decision** — do not encode guessed business rules.

## What agents must cite

For security or tenancy claims in PRs/reviews, cite:

- migration file name(s), and/or
- test file name(s), and/or
- ADR id for policy/intent claims, and/or
- dated provider/database evidence for managed-state claims

Avoid citing only a SECURITY_REVIEW document, local migration, or accepted ADR
when claiming current managed behavior.
