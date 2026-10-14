# Runbook: Production `/api/health` returns 503

**Means:** the readiness gate is failing closed. One of: public env misconfiguration,
database unreachable, or the outbox scheduler RPC not reporting ready. The app
is up (see `/api/version`) but declaring itself unfit for traffic.

**First check (distinguish deploy lag from real failure):**
```bash
curl -s "https://voya-os.vercel.app/api/version"   # expect: current main SHA, production
curl -s -o /dev/null -w "%{http_code}\n" "https://voya-os.vercel.app/api/health"
```
- Version stale (old SHA) → the deploy hasn't landed; check Vercel Deployments, not the DB.
- Version current + health 503 → real gate failure. Next: Vercel Runtime Logs,
  filter `runtime.health.ready` (JSON, has `requestId` + `code`):
  - `code=runtime_configuration_missing` → public env (URL/keys) misconfigured on the
    deployment. Compare Vercel Environment Variables with a green preview deployment.
  - `code=runtime_dependency_unavailable` → database or scheduler. Check migration parity:
    `supabase migration list --linked` (remote count must equal the file count on main;
    any pending entry means the DB is behind the code) and whether
    `outbox_dispatch_scheduler_ready_v1` exists in that set.

**Then:** fix the underlying gate (config vars, or promote the pending migrations
per `prod-promotion-checklist.md`). Do not silence the endpoint — the 503 is the signal.

**Escalate to:** repo owner (Supabase/Vercel dashboards). Rollback path: Vercel
Deployments → promote the previous production deployment (instant, no code change).
Record what the gate reported before rolling back.
