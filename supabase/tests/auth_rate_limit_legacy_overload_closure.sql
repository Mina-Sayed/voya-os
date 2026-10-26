-- K-015: simulate a drifted managed database that still carries the legacy
-- four-argument overload granted to anon/authenticated, then re-apply the
-- forward migration and prove it is gone and nothing is anon-callable.

CREATE FUNCTION public.consume_auth_rate_limit(p_scope text, p_key_hash text, p_limit integer, p_window_seconds integer)
RETURNS boolean LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog AS $$ SELECT true $$;
GRANT EXECUTE ON FUNCTION public.consume_auth_rate_limit(text, text, integer, integer) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.consume_auth_rate_limit(text, text) TO anon;

\ir ../migrations/20261016200000_close_legacy_auth_rate_limit_overloads.sql

DO $$
DECLARE
  v_function regprocedure;
BEGIN
  IF to_regprocedure('public.consume_auth_rate_limit(text,text,integer,integer)') IS NOT NULL THEN
    RAISE EXCEPTION 'legacy four-argument auth rate-limit overload must be dropped';
  END IF;
  IF to_regprocedure('public.consume_auth_rate_limit(text,text)') IS NULL THEN
    RAISE EXCEPTION 'current two-argument auth rate-limit function must remain';
  END IF;
  FOR v_function IN
    SELECT routine.oid::regprocedure FROM pg_catalog.pg_proc AS routine
    JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = routine.pronamespace
    WHERE namespace.nspname = 'public' AND routine.proname = 'consume_auth_rate_limit'
  LOOP
    IF has_function_privilege('anon', v_function, 'EXECUTE')
      OR has_function_privilege('authenticated', v_function, 'EXECUTE') THEN
      RAISE EXCEPTION 'auth rate-limit function % must not be executable by anon/authenticated', v_function;
    END IF;
    IF NOT has_function_privilege('service_role', v_function, 'EXECUTE') THEN
      RAISE EXCEPTION 'auth rate-limit function % must stay executable by service_role', v_function;
    END IF;
  END LOOP;
END;
$$;
