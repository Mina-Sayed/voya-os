-- Broad private-helper closure for every `%without_workspace_aal2%` inner
-- implementation: the original R01 batch (`*_without_workspace_aal2_r01`,
-- closed narrowly by 20261008205745) plus the ~30 non-R01 inners created by
-- earlier wrapper-generator migrations (property, authz-scope, confirmation,
-- release-bridge, ...). Those generators revoked only
-- `FROM PUBLIC, anon, authenticated`, so any service_role / voya_outbox_worker
-- grant preserved from the original RPC leaked through the rename.
--
-- CANONICAL REVOKE PATTERN: future wrapper-generator migrations must revoke
-- the renamed inner from all five roles (PUBLIC, anon, authenticated,
-- service_role, voya_outbox_worker) at rename time. Do NOT copy the old
-- three-role template still embedded in the already-applied migrations
-- (e.g. 20261001141018, 20261001143244); applied migrations are never edited.
-- This file's broad predicate is the durable backstop, enforced by
-- supabase/tests/workspace_rpc_aal2_broad_closure.sql.
--
-- Re-runnable: REVOKE on an already-closed catalog has no effect, and every
-- assertion below passes on a clean catalog too. There is no down migration:
-- re-granting these inners would re-open the hole (forward-only by design).
DO $migration$
DECLARE
  v_function regprocedure;
  v_matched integer := 0;
  v_revoked integer := 0;
  v_r01 integer := 0;
BEGIN
  SELECT count(*)
    INTO v_matched
    FROM pg_catalog.pg_proc AS routine
    JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = routine.pronamespace
   WHERE namespace.nspname = 'public'
     AND routine.proname LIKE '%\_without\_workspace\_aal2%' ESCAPE '\';

  SELECT count(*)
    INTO v_r01
    FROM pg_catalog.pg_proc AS routine
    JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = routine.pronamespace
   WHERE namespace.nspname = 'public'
     AND routine.proname LIKE '%\_without\_workspace\_aal2\_r01' ESCAPE '\';

  -- The R01 extended surface created exactly 18 `_r01` inners; trip if a
  -- future migration adds or removes one so the inventory is re-examined.
  IF v_r01 <> 18 THEN
    RAISE EXCEPTION 'Expected 18 private R01 AAL2 implementations, found %', v_r01;
  END IF;

  FOR v_function IN
    SELECT routine.oid::regprocedure
      FROM pg_catalog.pg_proc AS routine
      JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = routine.pronamespace
     WHERE namespace.nspname = 'public'
       AND routine.proname LIKE '%\_without\_workspace\_aal2%' ESCAPE '\'
     ORDER BY routine.proname, routine.oid
  LOOP
    EXECUTE format(
      'REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated, service_role, voya_outbox_worker',
      v_function
    );
    v_revoked := v_revoked + 1;
  END LOOP;

  -- Self-consistent count: every matched inner was visited, no magic total.
  IF v_revoked <> v_matched THEN
    RAISE EXCEPTION 'Broad AAL2 revoke visited % of % matched private implementations', v_revoked, v_matched;
  END IF;

  -- Zero-residual: fail closed if any matched inner still grants EXECUTE to
  -- any of the five roles (named roles via privilege check, PUBLIC via ACL).
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
    RAISE EXCEPTION 'Broad AAL2 revoke left residual EXECUTE grants on private implementations';
  END IF;

  RAISE NOTICE 'Broad AAL2 revoke closed % private implementations (% R01)', v_revoked, v_r01;
END;
$migration$;
