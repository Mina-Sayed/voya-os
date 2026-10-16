-- K-015: an older managed snapshot still exposes the four-argument
-- consume_auth_rate_limit(text, text, integer, integer) overload to anon and
-- authenticated, letting a caller choose its own limit and window. The
-- checkout dropped it in 20260812014148, but managed databases that drifted
-- may still carry it. This forward migration is idempotent and safe on any
-- plane: it drops that overload if present and leaves every remaining
-- overload executable by service_role only (the application calls the
-- two-argument version through the server-side service-role client).

DO $$
DECLARE
  v_function regprocedure;
BEGIN
  IF to_regprocedure('public.consume_auth_rate_limit(text,text,integer,integer)') IS NOT NULL THEN
    DROP FUNCTION public.consume_auth_rate_limit(text, text, integer, integer);
  END IF;

  FOR v_function IN
    SELECT routine.oid::regprocedure
    FROM pg_catalog.pg_proc AS routine
    JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = routine.pronamespace
    WHERE namespace.nspname = 'public' AND routine.proname = 'consume_auth_rate_limit'
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', v_function);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', v_function);
  END LOOP;
END;
$$;
