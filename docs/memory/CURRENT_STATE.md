# Current state

## Phase 0.4 CI/scanner/preview hygiene — 2026-09-03

Branch: `chore/ci-snyk-preview-clean` (base `origin/develop`).

- **Verified — checkout:** `npm run lint` clean; `npm run test:production:unit`
  7/7 pass (request-time `/workspace` guard, nonce CSP, loopback origin);
  `npm audit --omit=dev --audit-level=high` 0 vulnerabilities;
  `security-scan.sh --self-test` PASS (all guards, incl.
  `missing_snyk_is_blocked`); lockfile resolves `next 16.3.3` /
  `sharp 0.35.3` / `undici 7.29.0` / `postcss 8.5.26` with overrides applied.
- **Verified — checkout:** quality.yml no longer hard-fails on a missing
  Snyk credential: a probe step reads the token via `env` (the `secrets`
  context is rejected inside `if:` by the workflow parser) into
  `steps.snyk_auth.outputs.available`, the Snyk action runs only when that
  output is `true`, an absent token records
  `snyk/BLOCKED/authentication_missing` (skip-with-reason, not a PASS),
  findings still fail when the token is present, and Trivy (`exit-code: 1`) +
  `npm audit` + scanner self-test stay enforcing. Action SHAs remain
  digest-pinned.
- **Blocked — security tooling (K-025):** `npm run scan:security` in this
  worktree reports Trivy `FAIL/vulnerability_database_download_failed` (no
  trusted binary; container path denied at the docker socket) and Snyk
  `BLOCKED/binary_missing_or_untrusted` → overall `FAIL`. Not a PASS.
- **Guidance — preview parity (K-024):** push with a clean tree
  (`git status --porcelain` empty) so Vercel reports `gitDirty=0`; record the
  deployment id + reported commit/dirty flag as managed evidence before
  claiming artifact parity.
- **Unknown — managed:** no CI run, Vercel preview, or provider state was
  verified by this pass; no secrets touched, nothing deployed.

## WhatsApp AI Phase 1 feature branch — 2026-08-27

- **Working-tree candidate:** `feat/whatsapp-ai-agent-v1` is based directly on
  `origin/develop` and extends the existing WhatsApp inbox, AI runtime/outbox,
  CRM leads, and property/owner commands. Phase 1 includes signed text/image
  ingest, private Meta media retrieval, bounded conversation state, strict AI
  classification/extraction/reply, client lead projection, owner/property
  review, human takeover/return, and confirmation-gated property/photo writes.
- **Working-tree candidate:** existing V1 property RPC signatures remain
  available; additive extended overloads carry furnished-rental fields. No V2
  property RPCs or Phase 2 follow-up automation were added.
- **Unknown — managed Supabase/Storage/worker/Vercel/Meta/Gemini:** the new
  migration, grants, private bucket behavior, Edge worker, schedules, secrets,
  provider calls, and deployment state have not been applied or verified in a
  managed environment. Local tests do not prove managed parity.
- **Blocked — security tooling:** the local Trivy scan reported zero findings
  but the overall scanner gate remains blocked because the trusted Snyk binary
  is unavailable.

## PR #12 develop → main promotion candidate — 2026-08-27

- **Branch-only / current promotion:** PR #12 promotes `develop` into `main` and
  now includes the read-only AI Copilot, human-confirmed Gemini data entry,
  local Supabase bootstrap reliability, develop security/integrity hardening,
  and the follow-up PR #12 review remediation.
- **Branch-only hardening:** the nine prior Codex AI data-entry findings are
  closed in implementation: worker cleanup is lease/terminalization-aware,
  intake upload ownership is serialized, archived inputs are non-actionable,
  image application is bound to the confirmed property mapping, expired drafts
  retain cleanup recovery, image signatures are validated, sales-agent
  property proposals are read-only, submitter authorization is revalidated
  before Gemini export, and data-entry results retain the AAL2 read boundary.
- **Branch-only manual-review fixes:** approval and booking amount presentation
  preserves bigint precision; mapped intake images no longer request deleted
  private previews; PostgreSQL numeric overflow is reported as invalid input;
  and executable booking confirmations/amendments come from a dedicated,
  actor-aware database projection that returns only currently executable changes.
- **Verification gate:** this section records checkout intent and code state,
  not a CI or managed-provider PASS. The remediation PR and then the updated
  PR #12 head must pass the complete GitHub quality/security workflow before merge.
- **Unknown — managed Supabase/Storage/worker/Vercel:** none of the new PR #12
  checkout migrations or runtime behavior is claimed deployed from this file.
  Managed parity still requires separate dated provider evidence.

**Last updated:** 2026-08-27

## AI data-entry feature branch — 2026-08-24

- **Working-tree candidate:** `codex/ai-data-entry-confirmation` extends the
  current V1 `develop` baseline with tenant-scoped AI drafts, private bounded
  image intake, synthetic-only worker validation, editable Arabic review, and
  human-confirmed deterministic CRM/property/image commands.
- **Verified — checkout/local:** 115 Vitest files / 521 tests, lint, typecheck,
  coverage (83.14% statements), diff check, disposable DB suite, production
  build, production-render smoke, public E2E (6/6), and authenticated browser
  E2E (19/19) pass. The browser proof covers draft creation, private image
  upload, queue submission, and absence of a source-record write before
  confirmation.
- **Verified — checkout/local:** `ai_data_entry_drafts` and
  `ai_data_entry_inputs` use tenant-qualified FKs, forced RLS, focused RPC
  grants, organization/draft-bound private storage paths, stable idempotency,
  version checks, audit evidence, and resumable partial progress. The existing
  AI lifecycle RPCs now recognize the new `ai.data_entry.requested` event type.
- **Verified — checkout/local:** authenticated AI data-entry RPCs enforce MFA
  AAL2 at the PostgreSQL boundary through `require_ai_data_entry_aal2_v1`; the
  service-role/worker heartbeat, progress, mapping, archival, and finalization
  helpers remain separate grants. AI property-image registration and intake
  mapping are atomic in one database transaction, and the confirmation action
  no longer performs a redundant legacy mapping call.
- **Unknown — managed Supabase/Storage/worker:** the new migration, private
  `ai-intake` bucket, Edge Function code, schedules, and secrets are not
  applied or verified in managed environments. Do not infer deployment parity
  from this branch or its local SQL tests.
- **Gated — product/provider:** live extraction of the new customer text/images
  was not run; explicit action-time approval is required before sending that
  data to Google Gemini. Synthetic preview/test remains external-call-free.
- **Blocked — security tooling:** `npm run scan:security` cannot run the
  required Trivy/Snyk binaries in this environment; this is not a PASS.

**Last verified:** 2026-08-25 (checkout/local only; working-tree candidate)

## V1 implementation worktree — 2026-08-17

- **Working-tree candidate:** `/home/mina/worktrees/voya-os/v1` on branch
  `codex/v1`, isolated from the other dirty worktrees and intended to combine
  the release baseline with the approved V1/security slices.
- **Verified — checkout/local:** password + Google sign-in, MFA/recovery,
  company-first onboarding, team lifecycle, commercial booking snapshot,
  property inventory, owner lifecycle, bounded owner assignment, and private
  image metadata/upload/signed-route contracts are implemented in the current
  worktree. The disposable local Storage bucket is verified private with a
  10MB limit and JPEG/PNG/WebP allowlist; authenticated browser proof covers
  upload, signed retrieval, and cross-tenant denial. Browser proof also covers
  property/owner create-edit-archive-restore and owner-to-property linking.
- **Verified — checkout/local:** CRM, operations tasks with assignment notices,
  transport with an in-app assignment notice, in-app notifications, outbox
  dispatch contracts, signed WhatsApp inbound/manual outbound queue, sealed
  invitation payloads, Resend/Meta adapters, controlled AI execution RPCs,
  liveness, readiness, version probes, System Health, filtered audit details,
  overdue-task notification production, approval-result notices, and terminal
  delivery-failure notices are implemented. The full disposable 54-migration DB
  suite passes; local schema lint is green; 90 Vitest files / 421 tests pass;
  authenticated browser E2E is 18/18 (including System Health, transport,
  signed WhatsApp inbound/manual queue, and AI queued-proposal journeys); and
  public browser smoke is 6/6. Typecheck, lint, production build,
  production-render, production-render unit checks, and `git diff --check` are
  green.
- **Verified — checkout/local quality:** `npm run test:coverage` passes all 421
  tests at 89.83% statements / 93.67% lines / 77.01% branches / 95.97%
  functions. The latest security scan could not download Trivy's pinned
  vulnerability database before timeout; Snyk remains `BLOCKED` because its
  trusted binary is unavailable. The required security gate is `BLOCKED`, not
  PASS.
- **Working-tree candidate:** the Edge Function is source-only. Provider flags
  remain fail-closed by default; AI output is a bounded proposal for human
  review and cannot mutate booking, inventory, or finance source records.
- **Unknown — managed Supabase/Storage/Vercel:** none of the new V1
  migrations, Storage bucket settings, Edge Function schedule/secrets,
  provider delivery, or deployment state has been applied or verified by this
  local pass. Staging, backup/restore drill, and production pilot evidence are
  still release gates. Do not infer managed parity from the green local harness.
- **Remaining — managed/release:** Resend/Meta provider delivery and callback
  reconciliation, worker schedule/secrets and soak, live AI provider/tool
  evaluation, clean immutable release commit/tag, trusted Snyk execution,
  backup/restore RPO/RTO proof, staging parity, and limited pilot evidence.
  Local delivery-failure notices and AI queued proposals do not substitute for
  managed provider evidence.

**Last verified:** 2026-08-17
**Local checkout verification:** 2026-08-17
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

- Release worktree: `codex/release-20260811`; the production code artifact was
  built from `2c97e4e` and release evidence was updated afterward.
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
- Vercel Preview `dpl_Cu2MYCHPTcmdxLFV3kNNbMzKcmAF` and Production
  `dpl_8kahW92SAuvhLcdmq8kQRvLjGiNa` are READY. The production alias is
  `https://voya-os.vercel.app`; manual deployments have no Git source linkage.
- Root PKCE compatibility bridge is verified in Preview and Production:
  `/?code=...` returns a same-origin 307 to `/auth/callback?code=...` and
  ignores unrelated query parameters.
- The deployed sign-in artifact contains the new retry behavior and no longer
  contains the client-side 60-second countdown or its old wait copy.
- Managed Supabase Auth logs first showed the reported magic-link attempts
  rejected before delivery with `over_email_send_rate_limit` and a localhost
  referrer. Managed Auth URL configuration is now corrected to the production
  Site URL with the production callback allowed. Custom SMTP is enabled with
  sender/username aligned, port 587, and a 30-second per-user interval, but
  the next OTP attempt still failed at Gmail with SMTP `535 5.7.8 Username and
  Password not accepted` and HTTP 500; delivery remains blocked until the
  Gmail App Password is corrected.
- Authenticated QA smoke reaches `/security/mfa?reason=challenge` in both
  environments because managed Auth now has a verified TOTP factor. The QR
  enrollment regression is covered with a pending-factor unit test; a verified
  factor was not removed merely to repeat the QR flow live.
- Local release verification: 60 Vitest files / 286 tests, lint, typecheck,
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
- Configure Vercel Git integration if provider-native branch/commit linkage is
  required; the current manual deployment is traced by this release branch.
- **P1:** Correct the production Gmail App Password; the current `/otp`
  request reaches Gmail but is rejected with SMTP `535` before delivery. Auth
  URL/redirects, sender alignment, port, and the 30-second provider interval
  are now verified managed settings, while the deployed UI no longer adds a
  second client countdown.
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
