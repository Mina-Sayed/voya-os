# Known issues and gaps

**Last verified:** 2026-08-05  
Not a full bug audit. Evidence-backed items only. Severity is engineering impact, not a formal CVE score.

Legend: **Verified — `<truth plane>`** | **Suspected** | **Needs investigation**

Each issue also names its evidence plane. Checkout evidence does not prove
managed deployment; managed evidence does not prove current checkout behavior;
policy status is not inferred from either. Existing compact `Verified` cells
are retained where the Evidence column makes the plane clear; use the explicit
form for new or cross-plane issues.

## Security / correctness

| ID | Status | Issue | Evidence |
|---|---|---|---|
| K-001 | Verified | Finance domain is product-scoped in PRD/docs but **not implemented** in schema; AI finance agent is disabled stub | No finance tables in migrations; `agent-registry.ts` mode `disabled` |
| K-002 | Verified | Booking **cancellation policy/commands** incomplete relative to status enum | `cancelled` in check constraint; no full cancel command/policy slice like confirm |
| K-003 | Verified | Outbox **delivery worker** is DB-ready but app does not run durable external delivery | Worker RPCs + role exist; README/ADR gate outbound providers |
| K-004 | Verified — checkout + managed Supabase | Production security remediation is represented locally but is not applied to managed Supabase | Checkout has 37 present migration files (36 exact managed-history candidates plus one compatibility repair); managed evidence (2026-08-05) records 36 applied versions; managed apply remains gated |
| K-005 | Verified | Historical docs still describe **OpenAI** as AI provider | `docs/ARCHITECTURE.md` vs `gemini-runtime.ts` / ADR-010 |
| K-006 | Verified | `docs/DATABASE.md` catalogs finance tables that **do not exist** | Compare CREATE TABLE list vs DATABASE.md section 4 |
| K-007 | Suspected | Residual SELECT grants on early foundation tables may be broader than later RPC-only tables — safe only with RLS, but inconsistent access style | Early migration GRANTs vs later revoke patterns |
| K-008 | Needs investigation | Whether every workspace mutation path has identical idempotency/audit depth | Varies by command migration age; remediation focused on booking/transport/tasks/notes |
| K-009 | Verified — checkout | Current working-tree rate-limit source contract depends on uncommitted reconciliation and compatibility migrations | `src/lib/security/auth-rate-limit.ts` calls two arguments; the committed HEAD and production artifact still call four arguments |
| K-014 | Verified — checkout branch | `codex/auth-flow-fix` introduces self-service auth and a conflicting ADR-013 outside this checkout | branch comparison + `docs/adr/INDEX.md`; this is branch-only checkout evidence |
| K-015 | **P1 / Verified — managed Supabase** | Managed Supabase exposes the legacy four-argument `consume_auth_rate_limit(text, text, integer, integer)` overload to both `anon` and `authenticated`; anonymous callers can supply `p_limit` and `p_window_seconds` | Managed database evidence verified 2026-08-05: both overloads are `SECURITY DEFINER` and both are executable by both `anon` and `authenticated`; the local fixed-policy compatibility repair passes disposable tests but has not been applied or re-verified remotely |
| K-016 | High / Verified — checkout + managed Supabase + product/policy | Self-service workspace bootstrap differs across planes: branch-only in the current checkout, but deployed in managed Supabase; product/deployment alignment is unresolved | Current checkout has no bootstrap flow; `codex/auth-flow-fix` contains the branch migration; managed evidence verifies `public.bootstrap_personal_workspace(uuid)` is `SECURITY DEFINER` with `authenticated` `EXECUTE` and can create profile/org/owner membership/audit evidence |
| K-026 | Needs design — checkout | Pre-auth authentication actions do not expose a trusted client-IP signal to the limiter; adding an IP/abuse bucket needs provider-verified proxy/header trust, retention, and policy/schema decisions | HMAC email buckets now prevent targeted account-budget exhaustion; recommended follow-up is an edge/provider-aware IP limiter composed with the database limiter, not invented in this pass |
| K-043 | Verified — checkout | Booking amendment/cancellation RPCs exist, but no Server Actions or workspace controls call them; the approvals UI only renders `booking.confirm` decisions | `supabase/migrations/20260812015419_commercial_booking_v1.sql` exposes amendment/cancellation functions; `src/app/workspace/bookings/actions.ts` and `src/features/approvals/approval-requests-page.tsx` do not expose those commands |
| K-044 | Needs investigation — checkout/product policy | A user with only suspended memberships is treated as having no active membership by onboarding; the current self-service organization guard checks active memberships only | `loadActiveWorkspaceMemberships()` filters `status = 'active'`; `create_organization` rejects only an existing active membership |
| K-045 | Needs design — checkout | Fleet vehicle/driver creation commands have no idempotency key, so a repeated submit can create duplicate resources | `create_fleet_vehicle` / `create_fleet_driver` signatures and `src/app/workspace/transport/actions.ts` omit command idempotency |

## Architecture / product

| ID | Status | Issue | Evidence |
|---|---|---|---|
| K-010 | Verified | Architecture doc status still “Proposed” while substantial system is implemented | `docs/ARCHITECTURE.md` header |
| K-011 | Verified | Permissions matrix is aspirational baseline; runtime is scattered role checks | `docs/PERMISSIONS.md` + per-RPC role arrays |
| K-012 | Verified | ADR sequence skips **012** | `docs/adr/` listing |
| K-013 | Verified | Property “building/unit hierarchy” left open; model is flat bookable property | PRD + properties table |

## Reliability / operations

| ID | Status | Issue | Evidence |
|---|---|---|---|
| K-020 | Verified | External WhatsApp/AI delivery intentionally off until contracts/monitoring/rollback approved | README, ADR-010, gemini flags |
| K-021 | Verified | DB tests and auth e2e require disposable local infrastructure — easy to skip and ship false confidence | The guarded `test:db`, public E2E, and `test:e2e:auth-local` passed locally on 2026-08-05; the guards remain required |
| K-022 | Verified — checkout + managed Supabase | Managed migration drift is an active release gate, not only a recurring suspicion | Managed Supabase records 36 migrations; checkout now carries exact historical candidates plus one pending repair; approved managed rollout is pending |
| K-023 | Verified | No in-repository metrics, tracing, alerting, or SLO implementation is present | observability adapter + CI/runtime inventory |
| K-024 | Verified — managed Vercel snapshot | Production correlates to a clean four-argument artifact; the relevant preview is dirty/ambiguous | Read-only 2026-08-05 evidence: production `ac7dfdb…` is clean and calls four args; preview reports HEAD with `gitDirty=1`; no provider mutation was performed. Phase 0.4 guidance (2026-09-03, checkout): push preview branches with a clean tree (`git status --porcelain` empty) and record the Vercel deployment id + reported commit/dirty flag before claiming artifact parity |
| K-025 | Verified — checkout | Overall security scanner gate is blocked by unavailable Snyk tooling | `npm run scan:security` reports Snyk `BLOCKED` and overall `BLOCKED`/`FAIL`, never PASS (guard enforced by `--self-test`, incl. `missing_snyk_is_blocked`). Phase 0.4 (2026-09-03, checkout): quality.yml runs the self-test as evidence, gates the Snyk action on `secrets.SNYK_TOKEN != ''` with a `BLOCKED/authentication_missing` skip-with-reason record when absent (findings still fail when the token is present), and keeps Trivy (`exit-code: 1`) + `npm audit` enforcing. In the Phase 0.4 worktree Trivy could not run (no trusted binary; container path needs a docker socket this env denies) and `npm audit --omit=dev --audit-level=high` reports 0 vulnerabilities |

## Developer experience / docs

| ID | Status | Issue | Evidence |
|---|---|---|---|
| K-030 | Verified | Large volume of `SECURITY_REVIEW_*.md` and plans — high noise for agents if loaded wholesale | `docs/` tree |
| K-031 | Verified | `workspace-navigation.tsx` card grid is not the full shell nav source of truth | Live chrome uses `workspace-shell.tsx` |
| K-032 | Verified | Chat/work summary docs are time-bound snapshots, not living architecture | e.g. `CHAT_AND_WORK_SUMMARY_2026-07-26.md` |
| K-033 | Verified | `loadActionWorkspaceMembership()` collapses several auth recovery states to `null`, making action-level diagnosis less precise | `src/features/auth/workspace-context.ts` |

## Testing gaps (meaningful)

| ID | Status | Issue | Evidence |
|---|---|---|---|
| K-040 | Verified | Full finance/reversal suites in TEST_PLAN have no implementation target yet | TEST_PLAN FR-6 vs migrations |
| K-041 | Suspected | Field-level redaction policy not systematically enforced beyond operational error scrubbing | observability helper + permissions intent |
| K-042 | Needs investigation | English LTR parity coverage depth vs Arabic-first paths | locale domain exists; product claims bilingual equivalence |

## What not to “fix” casually during unrelated tasks

- Do not implement finance tables to silence K-001 without policy ADRs.
- Do not enable outbound providers to silence K-020 without release controls.
- Do not delete aspirational docs wholesale; mark/route via memory instead (this system).
