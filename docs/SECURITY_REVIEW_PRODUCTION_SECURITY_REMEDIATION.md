# Security Review: Production Security Remediation

## Scope

Forward migration `20260803085546_production_security_remediation.sql`, authentication rate-limit adapter, password and magic-link forms, transport error mapping, disposable PostgreSQL harness, and scanner trust boundary.

## Threats and controls

| Threat | Boundary control | Evidence |
|---|---|---|
| Anonymous caller weakens rate policy | Database maps the trusted scope to fixed limit/window values; the legacy signature rejects mismatches without mutating a bucket | Anonymous-role exhaustion, manipulation, unknown-scope, and window-reset SQL tests |
| Expired or changed approval confirms a booking | Booking and approval row locks, strict approved/unexpired predicate, exact snapshot/hash comparison, command-bound idempotency | Expired, boundary-time, tampered snapshot, retry, cross-booking key, and concurrent confirmation tests |
| Staff writes into another agent's conversation | RPC derives active role/membership and enforces owner/manager or unassigned/assigned-to-self access | Assigned, unassigned-agent, manager, suspended, and cross-tenant tests |
| Cross-tenant relationship is written directly | Tenant-qualified composite foreign keys and validated parent uniqueness | Catalog assertion plus direct negative SQL for every discovered unsafe relation |
| Vehicle or driver is allocated twice | Tenant/resource/time GiST exclusion constraints over active statuses | Vehicle, driver, adjacent, cancelled/released, null-end semantics, and simultaneous transaction tests |
| Idempotency key returns another command's result | Persisted booking-command identity and exact stay-event payload comparison | Exact retry and changed booking/event/notes/key tests |
| Terminal workflow state reopens | Locked explicit transition matrices in database RPCs | Valid transitions, same-state retries, and terminal/cancelled negative tests |
| Fake local scanner reports PASS | Shell functions are ignored; executable path, ownership, permissions, version output, container digest, and report parsing are validated | Scanner self-test and real pinned Trivy gate |
| Rejected Server Action leaves sign-in disabled | Synchronous `useRef` double-submit guard plus `try/catch/finally` cleanup and retry feedback | Rejected-promise and successful-retry component tests for both sign-in forms |

## Hostile-review findings fixed in this patch

- A booking already marked `pending_approval` but missing its pending row could not recover. The request command now safely recreates one after locking and normalizing actionable rows.
- Returning to a prior vehicle/driver combination collided with a historical outbox dedupe key. Assignment events now have a unique event identity while exact same-state retries remain no-ops.
- A redundant channel-only foreign key remained beside the tenant-qualified WhatsApp channel relationship. It is removed, and the catalog test rejects any unqualified FK between tenant-owned tables.
- The magic-link form had the same rejected-action cleanup defect as password sign-in and is covered by the same recovery pattern.
- Reassigning resources during `in_progress` previously moved transport backward to `assigned`; it now preserves the state.

## Authorization and least privilege

- `anon` and `authenticated` can execute only the rate-limit RPC signatures; neither role can access the bucket table.
- Booking, WhatsApp, transport, and task commands are executable only by `authenticated`; their function bodies derive actor and organization membership from `auth.uid()` and use `search_path = pg_catalog` with explicit schema qualification.
- `booking_command_idempotency` has forced RLS and no browser table grants.
- Existing browser table writes remain revoked. The migration reasserts function revokes and narrow grants after every body replacement.
- No secrets, raw credentials, production data, or provider payloads are added or logged.

## Migration and operational risks

1. **High — managed preflight and migration window required.** Existing cross-tenant rows or active fleet overlaps fail the migration. Unique/exclusion creation requires locks; production-sized rehearsal, read-only preflight, backup, and a controlled window are mandatory.
2. **High — authenticated Snyk evidence required for production.** Missing binary or credentials is `BLOCKED`, never `PASS`.
3. **High — managed Preview smoke and backup/restore rehearsal remain release gates.** Local disposable evidence cannot establish managed configuration or recovery readiness.
4. **Moderate — null transport return times are intentionally unbounded.** Operations must complete/cancel such requests to release the resource; alert on overdue active allocations.
5. **Moderate — operational alert routing remains external.** Monitor rate-limit denials, approval-expiry denials, SQLSTATE `23503`/`23P01` spikes, invalid transition attempts, and stale active fleet allocations without logging PII or SQL payloads.

## Release condition

Merge requires the complete local verification matrix and a clean committed branch. Production requires authenticated CI Snyk, real Trivy, managed migration parity/dry run, the read-only data preflight, backup/restore evidence, and authenticated Preview smoke. A missing external gate is a no-go, not an inferred pass.
