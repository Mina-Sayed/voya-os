# Database Foundation Security Review

**Review date:** 2026-07-21
**Scope:** tenant/booking SQL migration, isolated PostgreSQL integration harness, and GitHub quality workflow.

## Result

The slice introduces a defensible read boundary, not booking write capability. All checked tenant roots have forced RLS and active-membership policies; the browser-role has read grants only. The database rejects confirmed booking overlap and cross-tenant property/client references.

## Evidence

- `npm run test:db` passed against a clean PostgreSQL 17 container. It proves same-tenant reads, suspended-user denial, no authenticated booking writes, invalid date rejection, adjacent confirmed-stay success, confirmed overlap rejection, draft overlap allowance, and cross-tenant foreign-key rejection.
- `npm run lint`, `npm run test:coverage` (93.33% statements), `npm run test:e2e`, and `npm run build` passed.
- `npm audit --omit=dev --audit-level=high` passed with no high/critical issue. It still reports two inherited moderate PostCSS advisories through Next.js; no forced downgrade is approved.
- Trivy container image used locally is pinned to `aquasec/trivy@sha256:05d0126976bdedcd0782a0336f77832dbea1c81b9cc5e4b3a5ea5d2ec863aca7`. Its first-run 100 MB vulnerability database download did not complete in this environment. The CI workflow retains mandatory Trivy scanning.
- Local Snyk cannot authenticate without a token. The CI workflow requires the repository `SNYK_TOKEN` secret and runs the pinned Snyk action.

## Findings and required next controls

1. **High — no write-command boundary yet.** Do not grant browser writes or attach live dashboard data. A server-side command must validate trusted membership, role, approval, idempotency, state/version, and emit audit/outbox records atomically.
2. **High — availability blocks are not protected against booking confirmation.** The booking exclusion constraint only protects `bookings`. Implement the documented per-property transaction lock or approved unified occupancy model before confirmation writes exist.
3. **Medium — RLS policy is row-level, not field-level.** Client data currently has only a non-sensitive `display_name`; add explicit field policy/redaction before PII, financial references, documents, notes, or exports.
4. **Medium — no CSP yet.** Preserve the foundation review requirement for a request-aware nonce CSP before authentication or third-party integrations.
5. **Medium — migration execution is privileged.** Production migration credentials can bypass RLS. Require reviewed, audited GitOps migration deployment and no dashboard-only drift.

## Security review conclusion

The migration is appropriate only as the read-only data foundation. It does not satisfy finance/audit immutability, approvals, write authorization, user bootstrap, availability block concurrency, or AI governance; those remain hard launch blockers.
