-- P1 auth rate-limit repair candidate (checkout-only).
-- Proves the narrow two-argument contract is database-owned and that an
-- anonymous caller cannot supply p_limit / p_window_seconds.
-- The legacy four-argument overload must either be absent or, if present,
-- accept only fixed values and reject password_sign_up with no anon grant.
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

  IF NOT has_function_privilege('anon', v_narrow, 'EXECUTE')
    OR NOT has_function_privilege('authenticated', v_narrow, 'EXECUTE') THEN
    RAISE EXCEPTION 'P1 repair: anon/authenticated must retain the narrow pre-auth path';
  END IF;

  IF NOT has_function_privilege('service_role', v_narrow, 'EXECUTE') THEN
    RAISE EXCEPTION 'P1 repair: service_role must retain the narrow path for the server adapter';
  END IF;

  IF v_legacy IS NOT NULL THEN
    IF has_function_privilege('anon', v_legacy, 'EXECUTE')
      OR has_function_privilege('authenticated', v_legacy, 'EXECUTE') THEN
      RAISE EXCEPTION 'P1 repair: anon/authenticated must not retain the legacy four-argument overload';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM pg_proc AS function_record
      WHERE function_record.oid = v_legacy
        AND function_record.prosecdef
        AND 'search_path=pg_catalog' = ANY (function_record.proconfig)
        AND NOT EXISTS (
          SELECT 1 FROM aclexplode(function_record.proacl) AS privilege
          WHERE privilege.grantee = 0 AND privilege.privilege_type = 'EXECUTE'
        )
    ) THEN
      RAISE EXCEPTION 'P1 repair: legacy overload security mode or ACL is unsafe';
    END IF;
  END IF;
END;
$$;

-- Anonymous callers cannot supply caller-controlled policy parameters.
-- The legacy overload is either absent (42883) or denied (42501) or refuses
-- custom policy (22023). Any successful consume with custom limits fails closed.
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
    PERFORM public.consume_auth_rate_limit('password_sign_up', repeat('7', 64), 5, 3600);
    IF to_regprocedure('public.consume_auth_rate_limit(text,text,integer,integer)') IS NOT NULL THEN
      RAISE EXCEPTION 'P1 repair: legacy wrapper accepted password_sign_up';
    END IF;
  EXCEPTION
    WHEN undefined_function OR insufficient_privilege OR invalid_parameter_value THEN
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
END;
$$;
ROLLBACK;

-- Narrow pre-auth path remains callable by anon with fixed database policy.
BEGIN;
SET LOCAL ROLE anon;
DO $$
BEGIN
  PERFORM public.consume_auth_rate_limit('magic_link', repeat('a', 64));
  PERFORM public.consume_auth_rate_limit('password_sign_in', repeat('b', 64));
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
    PERFORM public.consume_auth_rate_limit('password_sign_in', 'not-a-digest');
    RAISE EXCEPTION 'P1 repair: malformed bucket key was accepted';
  EXCEPTION WHEN invalid_parameter_value THEN
    NULL;
  END;

  DELETE FROM public.auth_rate_limit_buckets
  WHERE (scope, key_hash) IN (('magic_link', repeat('e', 64)), ('password_sign_in', repeat('f', 64)));
END;
$$;

SELECT 'P1 auth rate-limit repair candidate tests passed' AS result;
