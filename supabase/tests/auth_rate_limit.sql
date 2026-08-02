\set ON_ERROR_STOP on

DO $$
BEGIN
  IF to_regprocedure('public.consume_auth_rate_limit(text,text,integer,integer)') IS NULL THEN
    RAISE EXCEPTION 'consume_auth_rate_limit function is missing';
  END IF;
END;
$$;

SELECT has_function_privilege(
  'anon',
  'public.consume_auth_rate_limit(text,text,integer,integer)',
  'EXECUTE'
);
SELECT has_function_privilege(
  'authenticated',
  'public.consume_auth_rate_limit(text,text,integer,integer)',
  'EXECUTE'
);
SELECT NOT has_table_privilege('anon', 'public.auth_rate_limit_buckets', 'SELECT');
SELECT NOT has_table_privilege('authenticated', 'public.auth_rate_limit_buckets', 'SELECT');

TRUNCATE public.auth_rate_limit_buckets;

DO $$
DECLARE
  key_hash text := repeat('a', 64);
BEGIN
  IF NOT public.consume_auth_rate_limit('magic_link', key_hash, 2, 60) THEN
    RAISE EXCEPTION 'first auth attempt should be allowed';
  END IF;
  IF NOT public.consume_auth_rate_limit('magic_link', key_hash, 2, 60) THEN
    RAISE EXCEPTION 'second auth attempt should be allowed';
  END IF;
  IF public.consume_auth_rate_limit('magic_link', key_hash, 2, 60) THEN
    RAISE EXCEPTION 'third auth attempt should be rate limited';
  END IF;
END;
$$;

DO $$
DECLARE
  key_hash text := repeat('b', 64);
BEGIN
  IF NOT public.consume_auth_rate_limit('password_sign_in', key_hash, 1, 1) THEN
    RAISE EXCEPTION 'short-window auth attempt should be allowed';
  END IF;
  PERFORM pg_sleep(1.1);
  IF NOT public.consume_auth_rate_limit('password_sign_in', key_hash, 1, 1) THEN
    RAISE EXCEPTION 'expired auth window should be reset';
  END IF;
END;
$$;

DO $$
BEGIN
  BEGIN
    PERFORM public.consume_auth_rate_limit('unknown', repeat('c', 64), 1, 60);
    RAISE EXCEPTION 'unknown auth rate-limit scope was accepted';
  EXCEPTION WHEN invalid_parameter_value THEN
    NULL;
  END;
END;
$$;

SELECT 'auth rate-limit database integration tests passed' AS result;
