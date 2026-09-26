# Current state

## OpenWA integration verification — 2026-09-26 (checkout/local only)

- **Verified — code checkout:** VOYA has a signed OpenWA inbound route, individual-chat gate, provider-aware media/outbox adapters, and a validated booking-intent CRM proposal. Task 5's follow-up fix makes the synthetic WhatsApp Gemini response include `requestIntent: "unclear"`, matching the strict seven-field parser. OpenWA source remains a separate local checkout: upstream base `bc206c28c6ab5baad5d68d15bb116c4b06e8d855`, patched HEAD `fec2170c29a50e88285e7d8c287785ee3236f137`; no image was built or published.
- **Verified — local tests:** VOYA full unit suite 827/827, focused OpenWA/AI suite 137/137, authenticated harness tests 20/20, public browser E2E 6/6, authenticated browser E2E 24/24, guarded DB suite exit 0 on disposable loopback PostgreSQL 17, production build/render checks, lint, and typecheck passed. OpenWA pinned tests passed 1,062 tests across 6 suites; its lint and build passed.
- **Browser scope:** signed individual inbound, duplicate retry, group/channel/status/broadcast/missing-kind rejection, tampered-signature denial, and one phone echo were exercised with synthetic data against the dedicated local Supabase/Next harness. AI booking intent → CRM projection and no booking/occupancy writes are covered by Task 5 worker/unit and SQL tests; the authenticated browser harness does not run the Supabase Edge AI worker, so that full AI projection is not one Playwright path. No live model call was made.
- **Not verified / not deployed:** no managed Supabase/Vercel mutation, webhook registration, host configuration, image deployment, real message, or QR pairing occurred. Actual OpenWA host/session plugin and automation state is **Unknown**. The linked-device profile may receive/persist recent group history; the local callback gate does not prove groups stay only on the phone, so live pairing remains blocked until verified or explicitly accepted.
- **Runtime flags:** WhatsApp/OpenWA outbound and customer-data AI remain default-off; the dedicated host must use `VOYA_AUTOMATION_OWNER=true`, but that flag is not verified on any live host.

## Production and branch verification — 2026-09-23

- **Verified — managed Vercel:** current production deployment `dpl_FA2UUZZoZvqjMT3wJtiNp1Rgy66P` is READY on main SHA `9e25d55f496a06389effe65ca88d40740d5a93a0`. The official host `https://www.vigor.dpdns.org` returned HTTP 200 for `/api/health`, `/api/health/live`, `/api/health/ready`, and `/api/version`; the live/version endpoints reported that SHA.
- **Verified — managed Supabase:** production `nseeteviretfabdfrgrc` and staging `tvgarlsgtgrabtdovgvz` have 92 matching migrations and both report up to date. Application/auth data remains empty in both after the requested cleanup; the 16 currency and 19 timezone contracts remain.
- **Verified — managed Supabase:** `outbox-dispatch` is ACTIVE version 4 on both projects with identical bundle SHA and `verify_jwt=false` because it enforces its own bearer secret. The `voya-os-outbox-dispatch` Cron job is active every minute in both; the latest run returned HTTP 200 with zero claimed/completed/retried/AI-failed/review/overdue items.
- **Verified — product/policy:** `RESEND_ENABLED`, `WHATSAPP_OUTBOUND_ENABLED`, `HUMAN_HANDOFF_APPROVED`, `WHATSAPP_AI_AUTO_REPLIES`, `GEMINI_ENABLED`, and `GEMINI_CUSTOMER_DATA_APPROVED` remain false. No Meta access/webhook credentials or Gemini API key are configured in production. Meta's existing WhatsApp account is present, but the selected app is still in Development without the WhatsApp product; no token was generated. Do not enable customer-data AI or external delivery until credentials, consent/data-processing policy, and WhatsApp opt-in/template safeguards are in place.
- **Verified — managed Vercel / blocked:** `www.vigor.dpdns.org` is the official public host and works through Cloudflare, but it is not listed as an alias on the accessible Vercel project. Vercel reports that the domain belongs to another scope; that scope must transfer/release it or grant access before direct project attachment can be completed.
- **Verified — managed logs:** Vercel has no grouped runtime errors in the latest 6 hours; its 24-hour window contains one `/auth/callback` failure (`pkce_code_verifier_not_found`) on older deployment `dpl_5LbksWfGzpEVg5FexBpCYmLjbT7C` / commit `f6642d2`, at `2026-09-22T03:00:18Z`. Cause is unknown; no current recurrence was observed. Supabase production Auth logs showed 29 records in 24 hours, no error/fatal records after filtering, and two GoTrue deprecation warnings for `GOTRUE_JWT_ADMIN_GROUP_NAME` / `GOTRUE_JWT_DEFAULT_GROUP_NAME`. Supabase Edge Functions showed 55 `outbox-dispatch` POSTs with HTTP 200 in the latest hour and no 5xx records; the PgCron log view returned no data. Dashboard warns log ingestion can lag up to 24 hours, so absence is not a complete historical guarantee.
- **Verified — managed Supabase advisors:** production and staging both report 123 `authenticated_security_definer_function_executable` WARNs, 35 `rls_enabled_no_policy` INFOs, 33 unindexed foreign keys, 3 auth-RLS init-plan notices, and one duplicate index; unused-index notices differ (53 production, 36 staging). Many SECURITY DEFINER routines are intentional authenticated RPC entry points, but the broad warning count remains a triage item; do not blanket-revoke them without checking the function authorization contracts and SQL tests.
- **Verified — checkout:** merge commit `53bf699` brings production `main` SHA `9e25d55` into `develop` at `b125c0e`. PR #75 (`sync/main-to-develop-20260923`) is the replacement for conflicting PR #74; merge is pending PR checks. It also adds a local Supabase test that replays the scheduler migration with disposable Vault fixtures, asserts the Cron job, and cleans the fixtures. No protected checks are bypassed.
- **Verified — checkout/local:** 713 Vitest tests, lint, typecheck, project-memory validation, production-auth unit tests, and all 20 authenticated-browser harness unit tests pass. Dedicated local Supabase authenticated E2E passes 21/21, including replaying the schedule migration with disposable Vault fixtures, asserting the Cron job, and cleaning both job and secrets. Full PR CI on the updated head remains the merge gate.

## develop → main merge — 2026-09-12

- **Verified — checkout:** `main` at `4615d86` merges `develop` (18 commits incl. PRs #28–#39 hardening + docs commit `1d6c6c4`). 33 files conflicted; all resolved per-file favoring the newer develop side (money/timezone contracts, AAL2 closures, WhatsApp AI safety, fleet idempotency), preserving auto-merged main content. Gates on merged tree: lint ✅, typecheck ✅, 137 files / 643 Vitest ✅, disposable-DB suite ✅, auth-local E2E 21/21 ✅. Local-only change; not pushed, no managed deployment implied.

## Review-fix pass — 2026-09-22 (uncommitted)

- **Working-tree candidate:** fixes for the PR-69 review findings, adapted to `main` (PR 69 itself was never merged; its Sept-14 RPCs are absent here): (1) new migration `20260922000100_close_whatsapp_base_read_aal2.sql` adds `require_workspace_aal2_v1()` to the three base WhatsApp reads + `supabase/tests/whatsapp_base_read_aal2.sql` (aal1 denial ×3, aal2 allow, grant posture); (2) WhatsApp property confirmation fails closed before any inventory write when images exceed the 20-active cap; (3) `/workspace` root sends membership-less users to `/onboarding` (was access-pending dead end); (4) approval action distinguishes `APPROVAL_NOT_OPERATIONALLY_READY` with invite-a-second-owner guidance.
- **Verified — checkout/local:** lint ✅, typecheck ✅, 139 files / 657 Vitest ✅ (incl. 3 new test files), disposable-DB suite ✅ (incl. new AAL2 test). No commits, no managed changes.
- **Working-tree candidate:** `20260922021951_close_authz_scope_gaps.sql` adds AAL2 wrappers for team reads/admin commands, makes the legacy lead read fail closed for missing membership, enforces task assignment scope for operations members, and applies the lead assignment boundary to CRM activity/follow-up child RPCs. `supabase/tests/authz_scope_remediation.sql` proves AAL1 denial, cross-tenant denial, cross-assignment denial, and owner oversight. The disposable-DB suite passes with these additions; managed deployment remains unknown.

## CTO readiness review — 2026-09-05

- **Verified — checkout:** reviewed clean `main` at `4ab9b839e9ff30bf75471768671fc1157edc0f34` and the ten open PRs. Detailed findings, immutable PR heads, test evidence, managed observations, and release gates are in [the readiness review](../CTO_READINESS_REVIEW_2026-09-05.md). Verdict: **NO-GO for customer production**; synthetic internal QA can continue.
- **Verified — checkout/local:** 134 Vitest files / 609 tests, coverage, lint, typecheck, 72-migration disposable DB suite, PR10/PR12 SQL regressions, owner concurrency, Deno check, clean isolated production build, production-render checks, and 6 public browser tests passed. Authenticated browser evidence is 21/21 from GitHub run `33231332384` on the same SHA; it was not rerun against the user's occupied local stack.
- **Verified — checkout/local:** explicit AAL1 database calls read/create properties; legacy booking RPCs allow a sales actor, after another owner's approval, to confirm a booking with no commercial amount/currency. Both proofs rolled back. PR #25's count functions also reproduced cross-tenant reads and anonymous execution when applied transactionally on the disposable database; that defect is **Branch-only**.
- **Verified — managed Supabase:** staging `tvgarlsgtgrabtdovgvz` is active, has 72 re-keyed migration records, private bounded image buckets, and ACTIVE outbox-dispatch v1. The two-argument auth limiter is service-role-only and the four-argument overload is absent. Staging still exposes the inspected non-AAL2 property RPCs and legacy booking RPCs. Seven tables retain unexpected authenticated DML grants, although current RLS policies do not allow those writes. No pg_cron/pg_net/cron.job was found; an external scheduler remains **Unknown**.
- **Verified — managed Vercel:** latest listed production deployment `dpl_EbZTNcEw62YcYPf5uBCaMvpHsmB3` reports older `374764db…` with `gitDirty=1`; public readiness/version endpoints return 404. The old Supabase project is `INACTIVE`; the deployed app's target database was not established. No managed mutations or provider sends were performed.
- **Contradiction / historical context:** older sections below and some memory documents describe onboarding/amendments as absent and the old managed auth limiter as currently exposed. Those statements must be read with their original dates/projects; they do not describe the reviewed main/staging combination. Main already has organization onboarding and amendment actions; cancellation request/execution controls remain branch-only in PR #27.
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

## Historical local verification snapshot (earlier checkout)

An earlier local implementation verification recorded **274/274 Vitest tests**, lint,
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
