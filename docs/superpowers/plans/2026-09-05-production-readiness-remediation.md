# Voya OS production-readiness remediation — 2026-09-05

## Scope

Close the actionable P1/P2 findings in the 2026-09-05 CTO readiness review on
fresh branches based on `develop`, while preserving the product-policy gates
for finance, cancellation effects, provider activation, and managed
deployment. Each branch must remain reviewable and independently testable;
PRs target `develop` and are opened only after local verification and a
three-way comparison against `origin/develop`.

The four review/memory files on the user's `main` checkout are evidence for
this work. They are intentionally not copied into implementation branches so
their uncommitted state is preserved. Claims about managed Supabase/Vercel
remain separate from checkout evidence; this work does not mutate managed
infrastructure or send provider traffic.

## Branch and PR decomposition

1. `codex/readiness-p1-auth` — R-01: enforce the workspace AAL2 boundary on
   exposed commercial property reads and writes, including every current
   property-command overload. Add negative SQL proofs for AAL1, positive
   AAL2 coverage, role/membership behavior, and focused grant checks.
2. `codex/readiness-p1-booking-guards` — R-02: make legacy booking write
   entry points enforce the same approved commercial snapshot requirements as
   the current lifecycle, preserving historical reads. Add role, approval,
   amount/currency, overload, and replay proofs.
3. `codex/readiness-p1-money` — R-04: define an exact decimal-string to
   currency-minor-unit conversion boundary and its inverse in the booking
   action/presentation path. Do not invent pricing, tax, settlement, or
   currency policy; reject ambiguous input and test create/edit/approval/display
   paths.
4. `codex/readiness-p1-timezone` — R-07: parse transport `datetime-local`
   values using an explicit organization/property IANA timezone rather than
   the server timezone, expose the timezone in the operator UI, and add
   UTC/Cairo/DST regression tests.
5. `codex/readiness-p1-whatsapp-safety` — R-05: re-check the channel kill
   switch at AI start, lease renewal, and result application; make low
   confidence auto-replies fail closed at both helper and trusted-worker
   boundaries. Add behavioral SQL/unit tests for flag changes between queue
   and execution and for safe handoff.
6. `codex/readiness-p2-grants` — R-09: reconcile authenticated direct DML
   privileges for the seven business tables with the checkout's RPC-only
   boundary and add a catalog proof. Do not rely on RLS alone.

The PR-25 counter implementation is not merged or copied: its cross-tenant
and `PUBLIC` execution findings are a merge blocker. Cancellation wiring,
worker scheduling/backup evidence, dashboard aggregate redesign, and release
promotion remain separate follow-up work where product/operations decisions or
managed-environment evidence are required.

## Execution protocol

For every branch:

1. Start from the latest local `origin/develop` and record the base SHA.
2. Read the exact migration/action/worker code and existing adjacent tests.
3. Add the smallest regression test or SQL proof first and run it against a
   disposable database/unit harness to demonstrate the pre-fix failure.
4. Implement the minimal fix through the existing server-action/RPC and
   tenant/AAL2 boundaries. Keep identity, organization, role, and provider
   flags server/DB-derived.
5. Run the focused tests to green, then lint/typecheck and the relevant SQL
   suite. Never use the running demo database for destructive test resets.
6. Review the diff for secrets, tenant leaks, changed grants, policy invention,
   and unrelated changes. Commit with a scoped Conventional Commit.
7. Push the branch and open a draft or ready PR to `develop` only if GitHub
   credentials and network access are available. Record URL, head SHA, base
   SHA, checks, and any external blocker.

## Final verification gate

After all feasible branches are prepared, run fresh `npm run lint`,
`npm run typecheck`, `npm test`, `npm run test:memory`, the disposable DB
runner, focused browser/production checks where the harness is safe, and
`npm run scan:security`. Compare each branch with `git diff
origin/develop...HEAD` and inspect PR checks. Report local checkout results as
`Verified — checkout/local`; do not label managed deployment, scheduler,
provider delivery, or release parity verified without dated provider evidence.
