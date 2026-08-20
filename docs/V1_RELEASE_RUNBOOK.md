# Voya OS V1 release runbook

**Status:** checkout candidate only — 2026-08-17

This runbook is the release contract for the complete V1 slice. It separates
checkout proof from managed Supabase/Vercel/provider proof. No managed deploy,
provider send, scheduler change, or production mutation was performed while
building this candidate.

## V1 boundary

Included: password/Google identity, MFA AAL2 and recovery, company-first
onboarding, team lifecycle, property inventory and private images, CRM
lead/client lifecycle, commercial booking snapshots and maker-checker,
amendment/cancellation commands, tasks and transport, in-app notifications,
outbox delivery contracts, signed WhatsApp inbound and manual outbound queue,
provider-gated AI proposals, audit, health/version probes, and release
evidence.

Excluded: finance ledger/payments/refunds/taxes/FX, marketplace/guest portal,
building hierarchy, autonomous AI mutations or replies, and unapproved
provider policy. Legacy bookings are preserved; missing commercial facts remain
`NEEDS_COMPLETION` and are never assigned a guessed price or currency.

## Release flow

```mermaid
flowchart LR
  Local["Checkout + disposable DB"] --> CI["CI gates + real scanners"]
  CI --> Staging["Separate staging Supabase/Vercel"]
  Staging --> Pilot["Small production pilot"]
  Pilot --> Observe["Probes, audit, outbox, support review"]
  Observe --> Release["V1 rollout or rollback artifact"]
```

## 1. Checkout gate

Run from the V1 worktree with an explicit disposable database URL:

```bash
npm ci
npm test
npm run typecheck
npm run lint
npm run test:memory
VOYA_DB_TEST=1 DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:55322/voya_test npm run test:db
supabase db lint --local --level error --fail-on error
npm run build
npm run test:production
git diff --check
npm run scan:security
npm audit --audit-level=high
```

The DB harness must refuse anything except loopback `*_test`. A local green
run proves checkout/schema behavior only. If Snyk or another required scanner
is unavailable, record `BLOCKED`; do not convert a Trivy/npm result into a
security PASS. On 2026-08-17, Trivy completed with zero high/critical findings,
`npm audit --audit-level=high` found zero vulnerabilities after the dependency
overrides were installed, but Snyk was `BLOCKED` because its trusted binary was
unavailable. The security gate therefore remains `BLOCKED` until the required
scanner is available and rerun.

Record the exact source commit, migration list/count, test counts, build
artifact, and any dirty/untracked files. Do not stage or commit unrelated work.

## 2. Staging gate (managed, separately authorized)

Use a dedicated staging Supabase project and Vercel environment. Apply the
exact immutable checkout artifact through the normal migration/GitOps path:

1. Confirm a fresh provider backup/PITR checkpoint and record its timestamp.
2. Run the migration dry-run; apply all V1 migrations forward-only.
3. Run managed schema lint/security/performance review and verify worker-only
   grants, browser denials, tenant composite FKs, and RLS posture.
4. Configure the private `property-images` bucket and verify upload plus
   five-minute signed retrieval with a disposable tenant.
5. Deploy the `outbox-dispatch` Edge Function with `verify_jwt=false` and
   exact worker authorization. Configure a one-minute schedule and verify a
   lease/claim/complete cycle.
6. Keep `RESEND_ENABLED`, `WHATSAPP_OUTBOUND_ENABLED`, and
   `HUMAN_HANDOFF_APPROVED` false until sandbox/provider consent is recorded.
7. For Gemini, run synthetic preview first. Production-like customer-redacted
   calls require a separate data-processing approval and `GEMINI_ENABLED` plus
   `GEMINI_CUSTOMER_DATA_APPROVED`.
8. Verify `/api/health/live`, `/api/health/ready`, `/api/health`, and
   `/api/version`; compare `/api/version.commit` with the intended artifact.

Staging evidence must include project/environment identifiers, migration
history, grant checks, backup/PITR state, deployment IDs, probe responses,
worker event IDs, and provider response IDs. Never include secret values.

## 3. Production pilot gate

Before enabling a pilot, verify the backup/restore owner, RPO/RTO decision,
support contact, incident path, and rollback artifact. Then use disposable or
approved pilot identities to verify:

- sign-in → MFA → organization selection → workspace;
- property/private-image access cannot cross tenants;
- lead/client → booking snapshot → maker-checker → confirm → stay event;
- task assignment creates exactly one in-app notification;
- outbox failures are retryable/dead-lettered and ambiguous results become
  `needs_review`;
- AI output is labeled as a proposal and cannot mutate booking/inventory/
  finance; and
- live/readiness/version probes, structured redacted logs, audit activity, and
  alerts are visible to the operator.

Start with one organization and a small internal team. Keep external email and
WhatsApp disabled until their consent/sandbox test is explicitly approved.
Expand only after the pilot has no open P1/P2 security or data-isolation issue.

## 4. Rollback and recovery

- Application failure: route traffic back to the previous immutable artifact;
  do not rewrite migration history.
- Schema failure: stop rollout, preserve the backup/PITR checkpoint, and use a
  reviewed forward fix or managed restore under the approved incident process.
- Outbox ambiguity: leave `needs_review`, inspect provider/event IDs, and
  replay only after an owner confirms whether delivery occurred.
- AI/provider outage: disable the provider flag; manual booking and operations
  workflows remain the source of record.
- After restore: rerun tenant isolation, auth/MFA, booking occupancy,
  notifications, outbox lease, and probe checks before reopening traffic.

## Current gate result

| Plane | Result | Evidence |
|---|---|---|
| Checkout/local | Verified | 54-migration disposable DB suite, 90 Vitest files / 421 tests, schema lint, typecheck, lint, build, production-render, public browser E2E 6/6, authenticated browser E2E 18/18, property/owner lifecycle, private-image browser/tenant proof, transport assignment/status, signed WhatsApp inbound/manual queue, AI queued-proposal proof, System Health, filtered audit details, overdue-task producer, approval-result notices, and terminal-delivery-failure notices; coverage 89.83% statements / 93.67% lines / 77.01% branches / 95.97% functions |
| Managed Supabase/Storage | Unknown | No V1 migration, bucket, grant, or backup proof in this pass |
| Managed Edge worker/providers | Unknown | Source exists; no schedule, secret, Resend, Meta, or Gemini send proof |
| Vercel staging/pilot | Unknown | No deploy or promotion performed from this worktree |
| Security scanner gate | Blocked | Latest Trivy run timed out while downloading its pinned vulnerability database; npm audit evidence remains zero vulnerabilities; Snyk executable unavailable and therefore not a PASS |
| Product/policy | Planned/approval-gated | Finance and provider policy remain explicit non-goals |

## Remaining work before a complete V1 release

The approved checkout slice is now locally implemented and verified. The
remaining work is release/provider work, not an untested local placeholder:

- **Managed parity:** apply and independently verify the 54-migration
  candidate, private Storage policy, RLS/grants, worker RPCs, Edge Function
  schedule/secrets, and release SHA in a dedicated staging environment. No
  managed claim follows from the local green harness.
- **External delivery:** Resend invitation delivery, Meta sandbox outbound
  delivery, provider callbacks/status reconciliation, consent/handoff
  operations, and worker soak still require managed credentials, sandbox
  approval, and provider evidence. Local failure notices and retry/dead-letter
  behavior are implemented and tested, but they do not prove provider delivery.
- **AI policy gate:** the local surface intentionally records a human-reviewed
  queued proposal and never performs automatic booking/inventory/finance
  mutations. Any live provider, domain-tool, customer-data, or execution path
  requires the separate approval and staging evaluation defined by policy.
- **Release operations:** create a clean immutable commit/tag, make CI and the
  trusted Snyk scanner available, complete backup/PITR plus restore RPO/RTO
  evidence, then run staging and limited pilot gates before production.
