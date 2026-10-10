-- Broad private-helper closure: every `%without_workspace_aal2%` inner
-- implementation (the original R01 batch plus the later non-R01 batches) must
-- deny EXECUTE to all five roles. Complements the `_r01`-only revoke in
-- 20261008205745, which left ~30 non-R01 inners reachable through preserved
-- service_role / voya_outbox_worker grants.
\set ON_ERROR_STOP on

BEGIN;

-- (a) Broad final-state assert: zero EXECUTE grants for any of the five roles
-- over the broad predicate, including PUBLIC pseudo-grants.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_catalog.pg_proc AS routine
    JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = routine.pronamespace
    WHERE namespace.nspname = 'public'
      AND routine.proname LIKE '%\_without\_workspace\_aal2%' ESCAPE '\'
      AND (
        has_function_privilege('anon', routine.oid, 'EXECUTE')
        OR has_function_privilege('authenticated', routine.oid, 'EXECUTE')
        OR has_function_privilege('service_role', routine.oid, 'EXECUTE')
        OR has_function_privilege('voya_outbox_worker', routine.oid, 'EXECUTE')
        OR EXISTS (
          SELECT 1
          FROM aclexplode(coalesce(routine.proacl, acldefault('f', routine.proowner))) AS privilege
          WHERE privilege.grantee = 0
            AND privilege.privilege_type = 'EXECUTE'
        )
      )
  ) THEN
    RAISE EXCEPTION 'broad AAL2 helper closure violated: a %%without_workspace_aal2%% inner still grants EXECUTE to a browser/worker role or PUBLIC';
  END IF;

  RAISE NOTICE 'broad AAL2 helper closure holds: no EXECUTE grants to the five roles over %%without_workspace_aal2%%';
END;
$$;

-- (b) Synthetic-grant-then-migrate: a stub matching the broad predicate starts
-- executable by service_role, then the new migration must close it.
CREATE OR REPLACE FUNCTION public.synthetic_without_workspace_aal2_probe()
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $stub$ SELECT NULL::void $stub$;

GRANT EXECUTE ON FUNCTION public.synthetic_without_workspace_aal2_probe() TO service_role;

DO $$
BEGIN
  IF NOT has_function_privilege('service_role', 'public.synthetic_without_workspace_aal2_probe()'::regprocedure, 'EXECUTE') THEN
    RAISE EXCEPTION 'synthetic probe setup failed: service_role cannot execute the stub before the migration';
  END IF;
END;
$$;

-- Apply the broad revoke, then prove the grants are gone. The \ir path is
-- relative to this test file's directory (supabase/tests), matching `psql -f`
-- invocations from scripts/test-database-foundation.mjs (cwd = project root).
\ir ../migrations/20261009120000_revoke_all_private_aal2_helper_grants.sql

DO $$
DECLARE
  v_probe_oid oid := 'public.synthetic_without_workspace_aal2_probe()'::regprocedure;
BEGIN
  IF has_function_privilege('service_role', v_probe_oid, 'EXECUTE')
    OR has_function_privilege('voya_outbox_worker', v_probe_oid, 'EXECUTE')
    OR has_function_privilege('authenticated', v_probe_oid, 'EXECUTE')
    OR has_function_privilege('anon', v_probe_oid, 'EXECUTE')
    OR EXISTS (
      SELECT 1
      FROM aclexplode(coalesce(
        (SELECT proacl FROM pg_catalog.pg_proc WHERE oid = v_probe_oid),
        acldefault('f', (SELECT proowner FROM pg_catalog.pg_proc WHERE oid = v_probe_oid))
      )) AS privilege
      WHERE privilege.grantee = 0
        AND privilege.privilege_type = 'EXECUTE'
    ) THEN
    RAISE EXCEPTION 'broad AAL2 migration did not close the synthetic probe grants';
  END IF;

  RAISE NOTICE 'synthetic probe grants closed by the broad AAL2 migration';
END;
$$;

DROP FUNCTION public.synthetic_without_workspace_aal2_probe();

-- (c) Review-guard worker path: a review inner starts executable by the
-- worker, then the review-guard revoke migration must close it.
GRANT EXECUTE ON FUNCTION public.archive_lead_v1_without_review_guards(uuid, uuid, text, integer, text, uuid) TO voya_outbox_worker;

DO $$
DECLARE
  v_guard_oid oid := 'public.archive_lead_v1_without_review_guards(uuid, uuid, text, integer, text, uuid)'::regprocedure;
BEGIN
  IF NOT has_function_privilege('voya_outbox_worker', v_guard_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'review-guard probe setup failed: worker cannot execute the inner before the migration';
  END IF;
END;
$$;

-- Apply the review-guard revoke, then prove the grant is gone. Path is
-- relative to this test file's directory, like part (b) above.
\ir ../migrations/20261009130000_revoke_review_guard_worker_grants.sql

DO $$
DECLARE
  v_guard_oid oid := 'public.archive_lead_v1_without_review_guards(uuid, uuid, text, integer, text, uuid)'::regprocedure;
BEGIN
  IF has_function_privilege('service_role', v_guard_oid, 'EXECUTE')
    OR has_function_privilege('voya_outbox_worker', v_guard_oid, 'EXECUTE')
    OR has_function_privilege('authenticated', v_guard_oid, 'EXECUTE')
    OR has_function_privilege('anon', v_guard_oid, 'EXECUTE')
    OR EXISTS (
      SELECT 1
      FROM aclexplode(coalesce(
        (SELECT proacl FROM pg_catalog.pg_proc WHERE oid = v_guard_oid),
        acldefault('f', (SELECT proowner FROM pg_catalog.pg_proc WHERE oid = v_guard_oid))
      )) AS privilege
      WHERE privilege.grantee = 0
        AND privilege.privilege_type = 'EXECUTE'
    ) THEN
    RAISE EXCEPTION 'review-guard migration did not close the worker probe grant';
  END IF;

  RAISE NOTICE 'review-guard worker probe grant closed by the migration';
END;
$$;

ROLLBACK;

SELECT 'workspace RPC AAL2 broad closure tests passed' AS result;
