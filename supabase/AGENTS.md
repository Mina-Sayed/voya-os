# `supabase/` — database agent notes

Root contract: [`AGENTS.md`](../AGENTS.md).  
Memory router: [`docs/memory/INDEX.md`](../docs/memory/INDEX.md).  
Memory: [`docs/memory/DATA_MODEL.md`](../docs/memory/DATA_MODEL.md), [`docs/memory/SECURITY.md`](../docs/memory/SECURITY.md), [`docs/memory/DOMAIN_RULES.md`](../docs/memory/DOMAIN_RULES.md).

## Authority

- **Migrations** in `migrations/` are the schema/RPC/grants source of truth.
- **SQL tests** in `tests/` prove invariants on a disposable database.
- Do not treat `docs/DATABASE.md` aspirational catalogs as implemented schema.

## Layout

| Path | Role |
|---|---|
| `migrations/*.sql` | Ordered forward migrations |
| `tests/*.sql` | Assertion scripts run by `npm run test:db` |
| `config.toml` | Local Supabase config |

## Hard rules

1. **Tenant-qualified FKs** for relations between tenant-owned rows (`(organization_id, id)`).
2. Prefer **SECURITY DEFINER** command/read RPCs with:
   - `SET search_path` locked down (`pg_catalog` / safe explicit paths)
   - `auth.uid()` membership + role checks
   - `REVOKE` from `PUBLIC`/`anon` as appropriate; explicit `GRANT EXECUTE`
3. **FORCE RLS** on tenant tables; do not rely on UI.
4. Confirmed inventory conflicts use **constraints** (booking exclude + `property_occupancies`), not app-only locks.
5. Append-only evidence tables must not gain casual UPDATE/DELETE grants.
6. Outbox claim/complete/fail stay off `authenticated`/`anon`.
7. WhatsApp ingest stays **service_role** (or tighter), never anon.
8. **No finance/cancellation policy invention** in migrations “while you’re here.”
9. Production security migrations may need **preflight** scripts and maintenance windows (see ADR-013).

## Writing a migration

1. Add `YYYYMMDDHHMMSS_name.sql` with clear comments of invariant intent.
2. Include grants/revokes explicitly; don’t assume defaults are safe.
3. Extend or add `tests/*.sql` for:
   - cross-tenant denial
   - role denial
   - idempotency
   - concurrency/constraint where relevant
   - grant posture
4. Update agent memory (DATA_MODEL / DOMAIN_RULES / SECURITY / CURRENT_STATE) when semantics change.
5. Consider an ADR only for decision-level boundary changes.

## Running tests

```bash
VOYA_DB_TEST=1 DATABASE_URL=postgresql://...@127.0.0.1:5432/yourdb_test npm run test:db
```

Runner refuses non-loopback hosts and DB names not matching `*_test`  
(`scripts/test-database-foundation.mjs`). **Never** point at shared/prod.

## Related app touchpoints

After RPC signature changes, update:

- matching Server Actions under `src/app/workspace/**/actions.ts`
- unit tests mocking `rpc`
- any read pages calling the function

## Codex role

`.codex/agents/database-worker.toml` expects exclusive ownership of migration/SQL test files when delegated — honor that during multi-agent work.
