# Integrated release preparation

Candidate combines develop `e72a5f0` (merged PR #79), PR #77 `bc13fb9`, and
PR #76 `511e2ae`. Main remains `9e25d55` until promotion is separately proven.
Next 16.3.8 supersedes PR #78's 16.3.6 upgrade in this candidate. Sharp 0.35.5
fixes the high-severity dependency advisory found during integration.

## Integration fixes

- Resolve competing application/worker/SQL contracts without removing MFA,
  assignment checks, CRM fact protection, pagination, private media or recovery.
- Bridge duplicate private clients-read function renames before the October 6
  migrations. The bridge is guarded for existing installations; use the normal
  forward-migration process with missing historical versions reviewed explicitly.
- Preserve immutable CRM update results across the two remediation generations.
- Restore the OpenWA proposal-contact sanitizer around the newer AI ordering
  wrapper. Group privacy and media jobs remain independent of model execution.
- Prioritize pending follow-ups before completed history in the bounded lead
  details window, so actionable work retains its completion command.
- Check Deno with manual dependency resolution so it cannot replace the npm
  lockfile's frontend dependencies. Log safe local browser startup stages.

## Managed release gate

This checkout does not prove managed migration, grants, function, Storage,
Vercel, Vault or Cron parity. Available cloud configuration has no Supabase or
Vercel credentials. No provider deployment or live messaging is claimed here.

1. Pin the published candidate SHA and obtain complete green CI on that SHA,
   including Snyk. Its existing time-bounded Zod exception remains an exception,
   not a vulnerability fix. Do not bypass unavailable scanner/quota checks.
2. Record staging/production identifiers, current deployment SHA and fresh
   backup/PITR checkpoint. Export the applied migration versions without secrets.
3. Use [the read-only preflight](../supabase/ops/release_integration_preflight.sql)
   through an existing secure database connection. Compare every version against
   the candidate's sorted migration inventory. Empty private/public ACL violation
   rows and correct role grants are required; inspect the guard implementations
   independently because a name/grant check does not establish function parity.
4. Review the missing October 5 bridge explicitly if October 6 migrations were
   already applied. Dry-run the normal migration tool, then apply the exact
   forward set to staging. Never rewrite applied migration history.
5. Deploy the candidate worker and application to staging. Verify private
   `property-images`/`ai-intake` limits, worker bearer authorization, Vault secret
   presence, and active one-minute Cron plus recent successful worker execution.
   The preflight deliberately does not create/reconcile jobs or call providers.
6. Repeat authenticated tenant/role/media/booking/CRM smoke and probe health,
   readiness and version against the staging artifact. Preserve default-disabled
   external delivery and customer-data AI flags.
7. Promote only with the staged evidence and backup recorded. After production
   parity and version probes succeed, close superseded upgrade PR #78 and finish
   the PR #76/#77 bookkeeping against the actual merged commits.

## Recovery

Retain the previous immutable application/worker artifacts. On failure, stop
rollout and keep external delivery disabled; revert application traffic only
after checking database compatibility. Preserve audit/outbox evidence and leave
ambiguous deliveries in `needs_review`. Schema recovery uses a reviewed forward
fix or the recorded provider restore/PITR process, followed by tenant, MFA,
occupancy and worker checks. Never delete migrations or clear idempotency keys
to make a retry succeed.

Current test evidence and remaining blockers are recorded in
[CURRENT_STATE](memory/CURRENT_STATE.md); checkout evidence is not deployment.
