-- Voya OS V1 auth/command rate-limit contract.
\set ON_ERROR_STOP on

DO $$
DECLARE
  v_function oid := to_regprocedure('public.consume_auth_rate_limit(text,text)');
BEGIN
  IF v_function IS NULL THEN
    RAISE EXCEPTION 'V1 consume_auth_rate_limit function is missing';
  END IF;
  IF to_regprocedure('public.consume_auth_rate_limit(text,text,integer,integer)') IS NOT NULL THEN
    RAISE EXCEPTION 'caller-parameterized rate-limit overload remains';
  END IF;
  IF NOT has_function_privilege('service_role', v_function, 'EXECUTE')
    OR has_function_privilege('anon', v_function, 'EXECUTE')
    OR has_function_privilege('authenticated', v_function, 'EXECUTE') THEN
    RAISE EXCEPTION 'V1 rate-limit execution grants are not server-only';
  END IF;
  IF (SELECT count(*)
      FROM pg_proc AS function_record
      WHERE function_record.oid = v_function
        AND function_record.prosecdef
        AND 'search_path=pg_catalog' = ANY (function_record.proconfig)
        AND NOT EXISTS (
          SELECT 1 FROM aclexplode(function_record.proacl) AS privilege
          WHERE privilege.grantee = 0 AND privilege.privilege_type = 'EXECUTE'
        )) <> 1 THEN
    RAISE EXCEPTION 'V1 rate-limit function security mode is unsafe';
  END IF;
END;
$$;

SELECT NOT has_table_privilege('anon', 'public.auth_rate_limit_buckets', 'SELECT');
SELECT NOT has_table_privilege('authenticated', 'public.auth_rate_limit_buckets', 'SELECT');
SELECT c.relrowsecurity
FROM pg_class AS c
JOIN pg_namespace AS n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relname = 'auth_rate_limit_buckets';

TRUNCATE public.auth_rate_limit_buckets;

BEGIN;
SET LOCAL ROLE service_role;
DO $$
DECLARE
  attempt integer;
BEGIN
  FOR attempt IN 1..5 LOOP
    IF NOT public.consume_auth_rate_limit('password_sign_up', repeat('a', 64)) THEN
      RAISE EXCEPTION 'password signup attempt % should be allowed', attempt;
    END IF;
  END LOOP;
  IF public.consume_auth_rate_limit('password_sign_up', repeat('a', 64)) THEN
    RAISE EXCEPTION 'sixth password signup attempt should be rate limited';
  END IF;
  IF NOT public.consume_auth_rate_limit('password_sign_in', repeat('a', 64)) THEN
    RAISE EXCEPTION 'separate sign-in scope should not share signup bucket';
  END IF;
  IF NOT public.consume_auth_rate_limit('password_reset', repeat('b', 64)) THEN
    RAISE EXCEPTION 'password reset scope should be available';
  END IF;
  IF NOT public.consume_auth_rate_limit('invitation_resend', repeat('c', 64)) THEN
    RAISE EXCEPTION 'invitation resend scope should be available';
  END IF;

  BEGIN
    PERFORM public.consume_auth_rate_limit('magic_link', repeat('d', 64));
    RAISE EXCEPTION 'removed magic-link scope was accepted';
  EXCEPTION WHEN invalid_parameter_value THEN
    NULL;
  END;

  BEGIN
    PERFORM public.consume_auth_rate_limit('password_sign_in', 'not-a-digest');
    RAISE EXCEPTION 'malformed bucket key was accepted';
  EXCEPTION WHEN invalid_parameter_value THEN
    NULL;
  END;
END;
$$;
COMMIT;

SELECT 'V1 auth rate-limit integration tests passed' AS result;
