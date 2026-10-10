-- Keep the implementations behind the AAL2 wrappers private even when the
-- original RPC had a privileged service-role grant before it was renamed.
DO $migration$
DECLARE
  v_function regprocedure;
  v_count integer := 0;
BEGIN
  FOR v_function IN
    SELECT routine.oid::regprocedure
    FROM pg_catalog.pg_proc AS routine
    JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = routine.pronamespace
    WHERE namespace.nspname = 'public'
      AND right(routine.proname, length('_without_workspace_aal2_r01')) = '_without_workspace_aal2_r01'
    ORDER BY routine.proname, routine.oid
  LOOP
    EXECUTE format(
      'REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated, service_role, voya_outbox_worker',
      v_function
    );
    v_count := v_count + 1;
  END LOOP;

  IF v_count <> 18 THEN
    RAISE EXCEPTION 'Expected 18 private R01 AAL2 implementations, revoked grants from %', v_count;
  END IF;
END;
$migration$;
