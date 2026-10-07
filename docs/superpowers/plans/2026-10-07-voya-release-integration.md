# Voya release integration implementation plan

**Goal:** integrate PR #77 and PR #76 with the security remediation already merged by PR #79 on develop, preserve every fix, verify the combined system, and publish a reviewable release branch.

**Architecture:** Next.js modular monolith, organization-scoped Supabase RPCs, private media and leased outbox worker. Sorted forward migrations define the effective database contract. Managed deployment is a separate evidence plane.

**Immutable inputs:** main `9e25d55`, develop `e72a5f0`, PR76 `511e2ae`, PR77 `bc13fb9`, PR78 `a03ac23`.

## Task 1: reconcile PR77 with develop

- Resolve application, worker, SQL test, runner and documentation conflicts by behavior, preserving both remediation sets.
- Preserve Next 16.3.8 and undici 7.29.1; PR78's older Next upgrade is superseded in this candidate.
- Audit migration ordering and duplicate function renames. Add forward bridge/reconciliation migrations where sorted clean installs or upgraded databases regress.
- Verify tenant denial, AAL2, immutable replay, partial confirmation recovery, superseded claims, CRM fact preservation and atomic worker failure on a disposable local database.
- Expected: no conflict markers; relevant unit and SQL regressions pass without removing coverage.

## Task 2: integrate PR76

- Merge the pinned PR76 head and reconcile private image intake independent of AI, kill switches, completed media races and group-event privacy with Task 1.
- Verify actual worker execution and pinned OpenWA event harness as well as SQL contracts.
- Expected: preserved individual-chat filtering and no outbound/AI enablement.

## Task 3: validate the combined release

- Frozen dependency installation, memory validation, lint, typecheck, full unit suite, disposable DB suite with upgrade/concurrency checks, Deno typecheck, dependency audit.
- Build with bounded placeholder configuration; run production render checks and public browser smoke. Run authenticated browser suite when the supported local Supabase stack can start.
- Diagnose failed checks before fixes; write meaningful regressions for new defects. Keep blocked and unrun checks distinct.
- Fresh integration review after implementation; fix material findings and rerun affected checks.

## Task 4: publish and prepare deployment

- Commit scoped changes and publish the integration branch to GitHub using existing Git proxy authorization. Verify remote SHA.
- Prepare release description, migration/storage/function/scheduler preflight, backup and forward recovery plan. Check available provider credentials without printing values.
- Do not claim main promotion or production deployment from a local build or a preview. Live customer AI/outbound remain gated.

## Review focus

Migration ordering and wrapper recursion; least-privilege function ACLs after new forward definitions; mutable versus immutable replay identity; late executor/claim races; media-job isolation from AI failure; CRM established facts; auth and request-time rendering; bounded pagination; real scanner outcomes.

## Execution ledger

- Integration started from the verified develop head. PR77 merge exposes 37 conflicts; ownership is separated across application, confirmation, worker, database and documentation tasks.
- Authorization: user requested all previously proposed integration/fix work, and prior GitHub push authorization persists. No redundant approval gate for local fixes or publishing the review branch.
- Environment: managed runtime reports no provider secrets or outbound identities. Managed Supabase/Vercel parity remains unknown.
- Tasks 1–2: merged with behavior-preserving conflict resolution. Sorted installation reproduced a duplicate private clients rename; guarded bridge fixes clean and late upgrade paths.
- Task 3: immutable legacy CRM replay and pending follow-up visibility reproduced RED, corrected with forward migrations, and verified GREEN in the full 125-migration/90-SQL suite. OpenWA proposal sanitation retained. Independent review found no other material issue in its stated scope.
- Task 3: frozen unit suite 902/902, lint/types/Deno/manual, build/render, public browser smoke, OpenWA privacy and npm/Trivy pass. Local Snyk unavailable; remote gate remains required.
- Ruling: retain the pinned npm dependency tree during Deno checks — auto mode replaced Next locally with a newer unpinned version; frozen reinstall and manual resolution restore artifact consistency. Risk if wrong: the Edge graph check would fail, which its actual successful run rules out for this candidate.
- Ruling: use the verified cached Supabase CLI for stripped local child environments — npm's registry resolution hung before the status command while direct pinned CLI status completed in 0.15 seconds. No timeout increase or network-policy bypass.
- Task 3 complete: authenticated browser 25/25 and frozen public browser 6/6 pass; server-role database access and deliberate absent-scheduler fail-closed readiness are separately verified. No managed healthy-worker claim is inferred.
- Task 4: published candidate `c77dcc4` to both existing PRs and an integration branch using atomic fast-forward push. Three full GitHub Quality and security jobs passed; GitGuardian's historical test-fixture incidents remain an external gate. Main/develop remain unchanged pending release preflight.
- Scanner follow-up: initial helper failed because its container lacked the proxy CA and its default database mirror was denied. Read-only host trust plus the official GHCR database restores Trivy PASS with zero findings; self-tests pass and missing Snyk remains BLOCKED. No verification or security check was disabled.
