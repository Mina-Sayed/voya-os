-- Close the residual voya_outbox_worker path on the five
-- `*without_review_guards` inners (review/maker-checker boundary, created by
-- 20261006010000_review_authz_and_idempotency). Their rename-time revoke
-- covered PUBLIC, anon, authenticated and service_role, but not
-- voya_outbox_worker, which the AAL2 broad revoke does not predicate on.
-- These inners enforce review binding on their wrappers; the worker role must
-- never execute them directly.
--
-- Forward-only, re-runnable; no down migration (re-granting re-opens the hole).
DO $migration$
DECLARE
  v_function regprocedure;
  v_matched integer := 0;
  v_revoked integer := 0;
BEGIN
  SELECT count(*)
    INTO v_matched
    FROM pg_catalog.pg_proc AS routine
    JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = routine.pronamespace
   WHERE namespace.nspname = 'public'
     AND routine.proname LIKE '%\_without\_review\_guards%' ESCAPE '\';

  -- Exactly the five review-guard inners; trip if a future migration adds or
  -- removes one so the inventory is re-examined.
  IF v_matched <> 5 THEN
    RAISE EXCEPTION 'Expected 5 private review-guard implementations, found %', v_matched;
  END IF;

  FOR v_function IN
    SELECT routine.oid::regprocedure
      FROM pg_catalog.pg_proc AS routine
      JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = routine.pronamespace
     WHERE namespace.nspname = 'public'
       AND routine.proname LIKE '%\_without\_review\_guards%' ESCAPE '\'
     ORDER BY routine.proname, routine.oid
  LOOP
    EXECUTE format(
      'REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated, service_role, voya_outbox_worker',
      v_function
    );
    v_revoked := v_revoked + 1;
  END LOOP;

  IF v_revoked <> v_matched THEN
    RAISE EXCEPTION 'Review-guard revoke visited % of % matched private implementations', v_revoked, v_matched;
  END IF;

  IF EXISTS (
    SELECT 1
      FROM pg_catalog.pg_proc AS routine
      JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = routine.pronamespace
     WHERE namespace.nspname = 'public'
       AND routine.proname LIKE '%\_without\_review\_guards%' ESCAPE '\'
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
    RAISE EXCEPTION 'Review-guard revoke left residual EXECUTE grants on private implementations';
  END IF;

  RAISE NOTICE 'Review-guard revoke closed % private implementations', v_revoked;
END;
$migration$;
