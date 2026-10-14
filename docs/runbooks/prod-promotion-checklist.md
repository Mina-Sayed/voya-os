# Runbook: Promoting migrations to production Supabase

**Means:** applying the pending `supabase/migrations` set to the production database.
This is the one write this repo ever performs against managed infrastructure.
Every step below is a gate; a red step stops the line.

## Pre-flight (all must hold)
1. Owner confirms a current backup / PITR restore point exists. No confirmation, no push.
2. Work from a clean detached worktree at `origin/main`. Never promote from a
   feature branch or a dirty checkout (stray files, e.g. draft migrations, must
   never reach production).
3. Link check — prove the target is production by count, not by trust:
   `supabase migration list --linked` must show the known production baseline
   applied (92 at last promotion) and must NOT show the staging count. A staging
   count aborts the run immediately.
4. Pending-set review: list the exact versions to be pushed; confirm no draft,
   experimental, or Stay-scope file is among them.

## Push
5. `supabase db push --linked` from the clean worktree. Watch full output; any
   `ERROR` or `RAISE EXCEPTION` (the revoke migrations self-verify) aborts —
   do not retry blindly, read the failing migration first.

## Post-verify (all must hold)
6. `migration list`: remote applied count equals the local file count, zero pending.
7. `curl .../api/version` shows the deployed SHA; `curl .../api/health` returns
   200 `{"status":"ok"}` (it is fail-closed: 503 means the DB is still behind).
8. Record the promotion (date, SHA range, counts, health evidence) in `.agent-runs/`.

## Rollback
Migrations here are forward-only by design (no down files; re-granting would
re-open holes). Rollback means restoring from the pre-push backup (owner,
Supabase dashboard), then re-verifying health. There is no `db pull-back`.
