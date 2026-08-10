-- Only the server-owned service role may consume the fixed policy.

DO $$
BEGIN
  IF to_regprocedure('public.consume_auth_rate_limit(text,text,integer,integer)') IS NOT NULL THEN
    RAISE EXCEPTION 'caller-configurable auth rate-limit overload must not exist';
  END IF;
  IF has_function_privilege('anon', 'public.consume_auth_rate_limit(text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'anon must not consume the auth rate-limit policy directly';
  END IF;
  IF has_function_privilege('authenticated', 'public.consume_auth_rate_limit(text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated must not consume the auth rate-limit policy directly';
  END IF;
  IF NOT has_function_privilege('service_role', 'public.consume_auth_rate_limit(text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'service_role must be able to consume the auth rate-limit policy';
  END IF;
END;
$$;

SET ROLE anon;
DO $$
BEGIN
  BEGIN
    PERFORM public.consume_auth_rate_limit(
      'magic_link',
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    );
    RAISE EXCEPTION 'anon unexpectedly consumed the auth rate-limit policy';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END;
$$;
RESET ROLE;

SET ROLE service_role;
SELECT public.consume_auth_rate_limit(
  'magic_link',
  'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
);
RESET ROLE;
