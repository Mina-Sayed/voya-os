# Current state

**Last verified:** 2026-08-11  
**Local checkout verification:** 2026-08-11  
**Managed Supabase verification:** 2026-08-11 (read-only migration, grant, advisor, and health evidence)  
**Vercel verification:** 2026-08-11 (Preview smoke and Production promotion verified)
**Product/policy review:** 2026-08-05 (memory and ADR alignment only; no new business approval)  
Keep this file short. Update after meaningful branch, managed-environment, or
policy shifts.

## Truth-plane rule

This file deliberately separates the current Git checkout, managed provider
state, and product/policy decisions. A checkout migration is not an applied
managed migration; an applied managed function is not evidence that the
current application artifact calls it; and an accepted ADR is not deployment
evidence.

## Latest release verification — 2026-08-11

This section supersedes the historical 2026-08-05 snapshot below for the
release worktree and managed/deployed state.

- Release worktree: `codex/release-20260811`, clean, branch tip is updated by
  the release documentation commit (the production code artifact was built
  from `1849092`).
- The root `codex/production-security-remediation` worktree remains clean at
  `e6a7ae2`. The separate `codex/auth-flow-fix` worktree remains dirty and was
  intentionally not overwritten or deployed.
- Managed Supabase project `nseeteviretfabdfrgrc` is `ACTIVE_HEALTHY` in
  `eu-central-1` on PostgreSQL 17.6.1. Linked migration history is aligned at
  39/39, `db push --dry-run --include-all` reports up to date, and managed
  schema lint reports no errors. The local-only
  `20260805034227_restore_auth_rate_limit_compatibility` migration is not in
  this release candidate or managed history.
- Managed `consume_auth_rate_limit(text,text)` is SECURITY DEFINER and
  executable only by `service_role` (not `anon` or `authenticated`). The
  application therefore uses its server-only service-role adapter. The
  personal-workspace bootstrap remains executable by `authenticated` as a
  separate policy boundary.
- Vercel Preview `dpl_88UEPW3AjR5d6UGHs32Pifass7QR` and Production
  `dpl_81Qw42fSzF1jVWF5bR8Wem5UGy6c` are READY. The production alias is
  `https://voya-os.vercel.app`; manual deployments have no Git source linkage.
- Authenticated QA smoke reaches `/security/mfa?reason=challenge` in both
  environments because managed Auth now has a verified TOTP factor. The QR
  enrollment regression is covered with a pending-factor unit test; a verified
  factor was not removed merely to repeat the QR flow live.
- Local release verification: 59 Vitest files / 283 tests, lint, typecheck,
  production-render checks, public E2E (6/6), and high-severity npm audit all
  passed. The disposable authenticated local E2E runner remains blocked by a
  local Supabase container-health issue.
- Supabase advisors are not clean: 73 security findings (25 INFO, 48 WARN)
  and 55 performance findings (53 INFO, 2 WARN). They remain follow-up work.
- GitHub Actions cannot start because the account is locked due to billing;
  this is external runner state. Snyk was intentionally skipped per release
  instruction.

## Checkout truth

| Item | Value |
|---|---|
| Product stage | Release candidate / internal preview hardening — **not** an authorization to change managed production without explicit window |
| App shape | Next.js 16 modular monolith + Supabase |
| Default UI | Arabic RTL Design C workspace |
| Active branch (this workspace) | `codex/production-security-remediation` |
| HEAD | `5459c61` (`docs: record refreshed preview deployment`) |
| Working tree | Dirty: 27 unstaged tracked paths, 39 untracked status entries, 0 staged entries after local implementation |
| Notable local branches | `codex/production-readiness-complete`, `codex/auth-flow-fix`, `feature/foundation-dashboard` |
| Migration files in checkout | 31 tracked index entries / 37 present (36 managed-history candidates plus one repair) |
| SQL test files in checkout | 25 tracked / 31 present in the working tree |

The branch focuses on **production security remediation**:

- Working-tree migration candidates now use the seven managed divergent
  versions, include the exact managed-only bootstrap and password-signup
  history, and add the pending
  `20260805034227_restore_auth_rate_limit_compatibility` repair.
- Related working-tree application and test changes cover rate limits, auth
  forms, transport, WhatsApp notes, lifecycle hardening, and scanner path
  trust.
- Working-tree application code calls the policy-targeted two-argument
  `consume_auth_rate_limit` RPC. The checkout’s migration chain is dirty and
  must not be treated as deployed managed state.
- The four-argument overload remains intentionally present in the local
  compatibility phase; it accepts only the fixed legacy values and delegates
  to the two-argument function. It has not been applied to managed Supabase.
- **Branch-only from this checkout:** `codex/auth-flow-fix` contains the
  self-service workspace application flow and
  `20260803070631_self_service_workspace_bootstrap.sql`. That branch is not
  this checkout. Managed Supabase nevertheless contains the corresponding
  deployed function; those are separate facts.

Treat modified and untracked files on this branch as **Working-tree
candidate** evidence until merged and independently deployed.

## Managed Supabase truth (verified 2026-08-05)

This section records the newly verified managed-environment snapshot. It is
not inferred from the checkout inventory.

### Applied migration history

Managed Supabase currently records **36 migrations**. It includes:

- `20260803070631_self_service_workspace_bootstrap`
- `20260803085546_production_security_remediation`
- `20260803090304_revoke_postgrest_table_grants`
- `20260803090755_harden_runtime_security_advisors`
- `20260803092522_password_signup_rate_limit`

The checkout now represents all 36 managed records byte-for-byte and adds one
pending forward repair. The local representation does not prove managed apply;
do not infer deployment from filename parity.

### Deployed functions and grants

- Both `public.consume_auth_rate_limit(text, text)` and
  `public.consume_auth_rate_limit(text, text, integer, integer)` exist.
- Both are `SECURITY DEFINER` and currently executable by both `anon` and
  `authenticated`.
- The four-argument overload accepts caller-supplied `p_limit` and
  `p_window_seconds`. Managed rate-limit policy therefore must not be called
  fully database-owned or caller-independent until remediated and re-verified.
- `public.bootstrap_personal_workspace(uuid)` exists, is `SECURITY DEFINER`,
  and currently grants `EXECUTE` to `authenticated`. The function can create a
  profile, organization, owner membership, and audit evidence for the
  authenticated user.

Self-service workspace bootstrap is therefore **branch-only from the current
checkout perspective**, **verified present in managed Supabase**, and awaiting
product/policy and deployment alignment review. Managed function presence does
not mean the current checkout’s app exposes or calls that flow.

### Provider state

The read-only 2026-08-05 snapshot correlated production to clean revision
`ac7dfdb051cbe0d573803a9a7bd0c5dcb4b3307f` on `codex/auth-flow-fix`; that
artifact still calls the four-argument limiter and bootstrap. The relevant
preview reported the current HEAD but `gitDirty=1`, so exact artifact parity
remains unknown. No provider state was changed by this local implementation.

## Product / policy truth

- ADR-013 records the accepted target boundary for database-owned rate-limit
  policy and the managed rollout gate. It is policy/intent evidence, not proof
  that the managed overloads match the target.
- Current checkout product memory describes organizations as
  platform-provisioned and contains no self-service workspace application
  flow. The managed bootstrap function creates a policy/deployment alignment
  question; no new approval is recorded by this pass.
- Finance, tax, commission, settlement, cancellation, retention, provider
  delivery, and outbox-worker policy remain open where listed in the domain and
  release documents.

## What is solid in the checkout

- Auth boundary: password + magic link, tokens-only cookies, membership gating,
  MFA AAL2 policy
- Tenant-qualified schema + many SECURITY DEFINER command RPCs
- Booking draft → approval → confirm → stay events foundation
- Occupancy ledger preventing booking/block conflicts
- CRM WhatsApp **inbound** webhook path
- AI agent center foundation with disabled finance agent and read-only tools;
  the checkout contains a gated Gemini integration/runtime path, but live
  managed AI execution is not asserted without separate dated provider evidence
- Operations tasks + transport/fleet foundations
- CI quality workflow with unit, DB, e2e, production render, scanners

## Fresh local verification snapshot

The local implementation verification recorded **274/274 Vitest tests**, lint,
coverage (93.31% statements / 95.16% lines), memory validation, the guarded
disposable database suite, production build with synthetic non-secret
configuration, production-render checks, public E2E (6/6), and authenticated
E2E (9/9) as passing. Trivy passed; Snyk was unavailable, so the overall
security scanner gate remains blocked. These are checkout/local facts only.

## Release blockers / gates

- **P1:** Apply and verify the local compatibility candidate against managed
  Supabase, then deploy a clean two-argument artifact before dropping the
  managed four-argument
  `consume_auth_rate_limit` overload and its current `anon` and
  `authenticated` execution grants, then prove the final live signatures and
  privileges.
- Reconcile the 36 managed migration records with the approved workflow; the
  checkout candidate is prepared, but managed apply remains gated.
- Review self-service workspace bootstrap policy, application exposure,
  rollout ownership, abuse controls, and audit expectations before deciding
  whether the managed function should remain, be aligned to the current
  checkout, or be removed through an approved forward migration.
- Correlate a clean Vercel deployment to the two-argument artifact; the current
  production artifact still requires compatibility.
- Auth Site URL + redirect + SMTP configuration per environment
- Authenticated preview smoke evidence
- Backup/restore rehearsal
- Trusted Snyk executable / complete scanner gate
- Provider delivery (WhatsApp outbound, notifications, live AI customer data)
  still policy-gated off
- Finance / cancellation / settlement policy still open
- Outbox worker hosting + retry/dead-letter ops not production-complete in-app

The proposed database work is recorded separately in
[`docs/DB_REMEDIATION_PROPOSAL_2026-08-05.md`](../DB_REMEDIATION_PROPOSAL_2026-08-05.md)
and has not been executed.

## Technical debt affecting agents

1. **Dual documentation worlds:** aspirational `docs/ARCHITECTURE.md` /
   `docs/DATABASE.md` vs implemented schema — prefer `docs/memory/*` + the
   truth plane being asserted.
2. **PERMISSIONS.md** is a baseline matrix, not a single generated policy
   engine.
3. **ADR numbering gap:** no ADR-012 file (jumps 011 → 013).
4. **Finance named but disabled** in AI registry — easy to accidentally
   “implement” without policy.
5. **Workspace navigation** has both shell role filters and an older simpler
   `workspace-navigation.tsx` card list — shell is the live chrome.

## Care areas for future agents

- Do not apply production security migrations, revoke the managed overload, or
  change managed bootstrap behavior without preflight, backup, approval, and
  a verification window.
- Do not re-introduce broad `authenticated` table DML grants.
- Do not call service role from ordinary page reads.
- Do not enable Gemini customer data or WhatsApp outbound in previews.
- Preserve uncommitted user work on this branch.
- Keep checkout, managed, and policy claims separately labeled in memory and
  handoffs.

## Recent architectural themes (history signal)

Rough chronology visible in migrations/commits:

1. Tenancy + booking foundation + governance (audit/approvals)
2. Property availability + occupancy ledger + command RPCs
3. Outbox foundation + lease recovery + worker lifecycle RPCs
4. Lead/client/property owner commands and reads
5. CRM WhatsApp, AI center, tasks, transport, booking lifecycle
6. Auth rate limits, public execute hardening, webhook ingest
7. Production security remediation (current checkout focus)
8. Self-service workspace bootstrap (branch-only in checkout; present in
   managed Supabase; alignment unresolved)

## Next likely durable updates to this file

- Managed remediation result for the legacy rate-limit overload and grants
- Migration parity reconciliation and approved rollout status
- Decision and deployment alignment for self-service workspace bootstrap
- Clean Vercel artifact correlation after the two-argument compatibility release
- Any decision enabling outbound providers or finance
- Worker runtime selection for outbox
