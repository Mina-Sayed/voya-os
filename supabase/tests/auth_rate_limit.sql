\set ON_ERROR_STOP on

DO $$
DECLARE
  v_canonical oid := to_regprocedure('public.consume_auth_rate_limit(text,text)');
  v_legacy oid := to_regprocedure('public.consume_auth_rate_limit(text,text,integer,integer)');
  v_definition text;
BEGIN
  IF v_canonical IS NULL OR v_legacy IS NULL THEN
    RAISE EXCEPTION 'consume_auth_rate_limit function is missing';
  END IF;

  IF NOT has_function_privilege('anon', v_canonical, 'EXECUTE')
    OR NOT has_function_privilege('authenticated', v_canonical, 'EXECUTE')
    OR NOT has_function_privilege('service_role', v_canonical, 'EXECUTE')
    OR NOT has_function_privilege('anon', v_legacy, 'EXECUTE')
    OR NOT has_function_privilege('authenticated', v_legacy, 'EXECUTE')
    OR NOT has_function_privilege('service_role', v_legacy, 'EXECUTE') THEN
    RAISE EXCEPTION 'expected auth rate-limit execution grants are missing';
  END IF;

  IF (SELECT count(*)
      FROM pg_proc AS function_record
      WHERE function_record.oid IN (v_canonical, v_legacy)
        AND function_record.prosecdef
        AND 'search_path=pg_catalog' = ANY (function_record.proconfig)
        AND NOT EXISTS (
          SELECT 1
          FROM aclexplode(function_record.proacl) AS privilege
          WHERE privilege.grantee = 0
            AND privilege.privilege_type = 'EXECUTE'
        )) <> 2 THEN
    RAISE EXCEPTION 'auth rate-limit functions must be SECURITY DEFINER, pg_catalog-only, and non-PUBLIC';
  END IF;

  SELECT pg_get_functiondef(v_legacy)
  INTO v_definition;
  IF v_definition LIKE '%ON CONFLICT (key_hash)%'
    OR v_definition NOT LIKE '%auth rate-limit policy is database controlled%' THEN
    RAISE EXCEPTION 'legacy overload is not the fixed-policy compatibility wrapper';
  END IF;
END;
$$;

BEGIN;
SET LOCAL ROLE anon;
SELECT public.consume_auth_rate_limit('magic_link', repeat('d', 64));
SELECT public.consume_auth_rate_limit('magic_link', repeat('e', 64), 5, 900);
ROLLBACK;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT public.consume_auth_rate_limit('password_sign_in', repeat('f', 64));
SELECT public.consume_auth_rate_limit('password_sign_in', repeat('a', 64), 10, 900);
ROLLBACK;

SELECT NOT has_function_privilege(
  'anon',
  'public.create_booking_draft(uuid,uuid,uuid,date,date,text,uuid)',
  'EXECUTE'
);
SELECT c.relrowsecurity
FROM pg_class AS c
JOIN pg_namespace AS n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relname = 'auth_rate_limit_buckets';
SELECT NOT has_table_privilege('anon', 'public.auth_rate_limit_buckets', 'SELECT');
SELECT NOT has_table_privilege('authenticated', 'public.auth_rate_limit_buckets', 'SELECT');

TRUNCATE public.auth_rate_limit_buckets;

DO $$
DECLARE
  key_hash text := repeat('a', 64);
  compatibility_key_hash text := repeat('d', 64);
  attempt integer;
BEGIN
  IF NOT public.consume_auth_rate_limit('magic_link', compatibility_key_hash, 5, 900) THEN
    RAISE EXCEPTION 'exact legacy compatibility policy should be accepted';
  END IF;

  BEGIN
    PERFORM public.consume_auth_rate_limit('magic_link', compatibility_key_hash, 1000, 1);
    RAISE EXCEPTION 'legacy caller-controlled policy was accepted';
  EXCEPTION WHEN invalid_parameter_value THEN
    NULL;
  END;

  FOR attempt IN 1..5 LOOP
    IF NOT public.consume_auth_rate_limit('magic_link', key_hash) THEN
      RAISE EXCEPTION 'magic-link attempt % should be allowed', attempt;
    END IF;
  END LOOP;
  IF public.consume_auth_rate_limit('magic_link', key_hash) THEN
    RAISE EXCEPTION 'sixth magic-link attempt should be rate limited';
  END IF;

  BEGIN
    PERFORM public.consume_auth_rate_limit('magic_link', key_hash, 1000, 1);
    RAISE EXCEPTION 'legacy caller-controlled policy was accepted';
  EXCEPTION WHEN invalid_parameter_value THEN
    NULL;
  END;

  IF public.consume_auth_rate_limit('magic_link', key_hash) THEN
    RAISE EXCEPTION 'policy manipulation must not reset an exhausted bucket';
  END IF;

  BEGIN
    PERFORM public.consume_auth_rate_limit('password_sign_up', repeat('c', 64), 1, 1);
    RAISE EXCEPTION 'password-signup scope must remain unsupported until policy approval';
  EXCEPTION WHEN invalid_parameter_value THEN
    NULL;
  END;
END;
$$;

DO $$
DECLARE
  v_key_hash text := repeat('b', 64);
BEGIN
  IF NOT public.consume_auth_rate_limit('password_sign_in', v_key_hash) THEN
    RAISE EXCEPTION 'password auth attempt should be allowed';
  END IF;
  UPDATE public.auth_rate_limit_buckets AS bucket
  SET window_started_at = clock_timestamp() - interval '901 seconds'
  WHERE bucket.scope = 'password_sign_in' AND bucket.key_hash = v_key_hash;
  IF NOT public.consume_auth_rate_limit('password_sign_in', v_key_hash) THEN
    RAISE EXCEPTION 'expired auth window should be reset';
  END IF;
  IF (SELECT attempt_count FROM public.auth_rate_limit_buckets AS bucket
      WHERE bucket.scope = 'password_sign_in' AND bucket.key_hash = v_key_hash) <> 1 THEN
    RAISE EXCEPTION 'expired auth window must restart at one attempt';
  END IF;
END;
$$;

DO $$
BEGIN
  BEGIN
    PERFORM public.consume_auth_rate_limit('unknown', repeat('c', 64));
    RAISE EXCEPTION 'unknown auth rate-limit scope was accepted';
  EXCEPTION WHEN invalid_parameter_value THEN
    NULL;
  END;
END;
$$;

-- The application now derives its opaque bucket key with a server-held HMAC.
-- This disposable proof uses a synthetic secret only to show that a public
-- SHA-256 guess lands in a different bucket and cannot consume the trusted one.
DO $$
DECLARE
  canonical_input text := concat_ws(chr(31), 'voya-auth-rate-limit:v2', 'magic_link', 'operator@example.com');
  trusted_key text := encode(extensions.hmac(canonical_input, repeat('s', 32), 'sha256'), 'hex');
  public_key text := encode(extensions.digest(canonical_input, 'sha256'), 'hex');
BEGIN
  IF trusted_key = public_key THEN
    RAISE EXCEPTION 'public SHA-256 derivation unexpectedly matches the trusted HMAC bucket';
  END IF;
END;
$$;

SELECT encode(extensions.hmac(
  concat_ws(chr(31), 'voya-auth-rate-limit:v2', 'magic_link', 'operator@example.com'),
  repeat('s', 32),
  'sha256'
), 'hex') AS trusted_key \gset rate_limit_hmac_

BEGIN;
SET LOCAL ROLE service_role;
SELECT public.consume_auth_rate_limit(
  'magic_link',
  :'rate_limit_hmac_trusted_key'
);
COMMIT;

SELECT encode(extensions.digest(
  concat_ws(chr(31), 'voya-auth-rate-limit:v2', 'magic_link', 'operator@example.com'),
  'sha256'
), 'hex') AS public_key \gset rate_limit_hmac_

BEGIN;
SET LOCAL ROLE anon;
SELECT public.consume_auth_rate_limit(
  'magic_link',
  :'rate_limit_hmac_public_key'
);
COMMIT;

DO $$
DECLARE
  canonical_input text := concat_ws(chr(31), 'voya-auth-rate-limit:v2', 'magic_link', 'operator@example.com');
  trusted_key text := encode(extensions.hmac(canonical_input, repeat('s', 32), 'sha256'), 'hex');
  public_key text := encode(extensions.digest(canonical_input, 'sha256'), 'hex');
BEGIN
  IF (SELECT attempt_count
      FROM public.auth_rate_limit_buckets
      WHERE scope = 'magic_link' AND key_hash = trusted_key) <> 1
    OR (SELECT attempt_count
        FROM public.auth_rate_limit_buckets
        WHERE scope = 'magic_link' AND key_hash = public_key) <> 1 THEN
    RAISE EXCEPTION 'direct public derivation consumed or replaced the trusted HMAC bucket';
  END IF;
END;
$$;

SELECT 'auth rate-limit database integration tests passed' AS result;
