-- P1 auth rate-limit repair candidate (checkout-only).
-- Proves the narrow two-argument contract is database-owned, server-only
-- (service_role via the server adapter), and that no browser role can supply
-- p_limit / p_window_seconds. Anonymous callers must not mint arbitrary
-- buckets: the purge worker is unscheduled, so anon execution would let bucket
-- rows accumulate without bound.
-- The legacy four-argument overload must be absent.
\set ON_ERROR_STOP on

DO $$
DECLARE
  v_narrow oid := to_regprocedure('public.consume_auth_rate_limit(text,text)');
  v_legacy oid := to_regprocedure('public.consume_auth_rate_limit(text,text,integer,integer)');
  v_narrow_def text;
BEGIN
  IF v_narrow IS NULL THEN
    RAISE EXCEPTION 'P1 repair: narrow consume_auth_rate_limit(text,text) is missing';
  END IF;

  SELECT pg_get_functiondef(v_narrow) INTO v_narrow_def;

  IF v_narrow_def NOT LIKE '%magic_link%'
    OR v_narrow_def NOT LIKE '%password_sign_in%' THEN
    RAISE EXCEPTION 'P1 repair: narrow function does not contain the magic_link/password_sign_in policy';
  END IF;

  IF v_narrow_def LIKE '%p_limit%'
    OR v_narrow_def LIKE '%p_window_seconds%' THEN
    RAISE EXCEPTION 'P1 repair: narrow function must not accept caller-controlled policy parameters';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc AS function_record
    WHERE function_record.oid = v_narrow
      AND function_record.prosecdef
      AND 'search_path=pg_catalog' = ANY (function_record.proconfig)
      AND NOT EXISTS (
        SELECT 1 FROM aclexplode(function_record.proacl) AS privilege
        WHERE privilege.grantee = 0 AND privilege.privilege_type = 'EXECUTE'
      )
  ) THEN
    RAISE EXCEPTION 'P1 repair: narrow function security mode or ACL is unsafe';
  END IF;

  IF has_function_privilege('anon', v_narrow, 'EXECUTE')
    OR has_function_privilege('authenticated', v_narrow, 'EXECUTE') THEN
    RAISE EXCEPTION 'P1 repair: browser roles must not execute the rate-limit path';
  END IF;

  IF NOT has_function_privilege('service_role', v_narrow, 'EXECUTE') THEN
    RAISE EXCEPTION 'P1 repair: service_role must retain the narrow path for the server adapter';
  END IF;

  IF v_legacy IS NOT NULL THEN
    RAISE EXCEPTION 'P1 repair: legacy four-argument overload must be absent';
  END IF;
END;
$$;

-- Browser roles hold no execution path: the legacy overload is absent
-- (42883) and the narrow function is server-only, so anon/authenticated
-- calls fail closed with insufficient_privilege (42501).
BEGIN;
SET LOCAL ROLE anon;
DO $$
BEGIN
  BEGIN
    PERFORM public.consume_auth_rate_limit('magic_link', repeat('7', 64), 1000, 1);
    RAISE EXCEPTION 'P1 repair: anon supplied custom p_limit/p_window_seconds';
  EXCEPTION
    WHEN undefined_function OR insufficient_privilege OR invalid_parameter_value THEN
      NULL;
  END;

  BEGIN
    PERFORM public.consume_auth_rate_limit('password_sign_in', repeat('7', 64), 1000, 1);
    RAISE EXCEPTION 'P1 repair: anon supplied custom p_limit/p_window_seconds';
  EXCEPTION
    WHEN undefined_function OR insufficient_privilege OR invalid_parameter_value THEN
      NULL;
  END;

  BEGIN
    PERFORM public.consume_auth_rate_limit('magic_link', repeat('a', 64));
    RAISE EXCEPTION 'P1 repair: anon executed the server-only narrow path';
  EXCEPTION
    WHEN insufficient_privilege THEN
      NULL;
  END;
END;
$$;
ROLLBACK;

BEGIN;
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  BEGIN
    PERFORM public.consume_auth_rate_limit('magic_link', repeat('8', 64), 1000, 1);
    RAISE EXCEPTION 'P1 repair: authenticated supplied custom p_limit/p_window_seconds';
  EXCEPTION
    WHEN undefined_function OR insufficient_privilege OR invalid_parameter_value THEN
      NULL;
  END;

  BEGIN
    PERFORM public.consume_auth_rate_limit('password_sign_in', repeat('8', 64));
    RAISE EXCEPTION 'P1 repair: authenticated executed the server-only narrow path';
  EXCEPTION
    WHEN insufficient_privilege THEN
      NULL;
  END;
END;
$$;
ROLLBACK;

-- Fixed database-owned limits: magic_link 5/900, password_sign_in 10/900.
DO $$
DECLARE
  attempt integer;
BEGIN
  DELETE FROM public.auth_rate_limit_buckets
  WHERE (scope, key_hash) IN (('magic_link', repeat('e', 64)), ('password_sign_in', repeat('f', 64)));

  FOR attempt IN 1..5 LOOP
    IF NOT public.consume_auth_rate_limit('magic_link', repeat('e', 64)) THEN
      RAISE EXCEPTION 'P1 repair: magic_link attempt % should be allowed', attempt;
    END IF;
  END LOOP;
  IF public.consume_auth_rate_limit('magic_link', repeat('e', 64)) THEN
    RAISE EXCEPTION 'P1 repair: sixth magic_link attempt should be rate limited';
  END IF;

  FOR attempt IN 1..10 LOOP
    IF NOT public.consume_auth_rate_limit('password_sign_in', repeat('f', 64)) THEN
      RAISE EXCEPTION 'P1 repair: password_sign_in attempt % should be allowed', attempt;
    END IF;
  END LOOP;
  IF public.consume_auth_rate_limit('password_sign_in', repeat('f', 64)) THEN
    RAISE EXCEPTION 'P1 repair: eleventh password_sign_in attempt should be rate limited';
  END IF;

  BEGIN
    -- Invalid hex digest fixture (built via repeat so no secret-like literal).
    PERFORM public.consume_auth_rate_limit('password_sign_in', repeat('z', 64));
    RAISE EXCEPTION 'P1 repair: malformed bucket key was accepted';
  EXCEPTION WHEN invalid_parameter_value THEN
    NULL;
  END;

  DELETE FROM public.auth_rate_limit_buckets
  WHERE (scope, key_hash) IN (('magic_link', repeat('e', 64)), ('password_sign_in', repeat('f', 64)));
END;
$$;

SELECT 'P1 auth rate-limit repair candidate tests passed' AS result;
