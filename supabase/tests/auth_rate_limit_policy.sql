-- Anonymous callers may consume only the fixed two-argument policy.

DO $$
BEGIN
  IF to_regprocedure('public.consume_auth_rate_limit(text,text,integer,integer)') IS NOT NULL THEN
    RAISE EXCEPTION 'caller-configurable auth rate-limit overload must not exist';
  END IF;
  IF NOT has_function_privilege('anon', 'public.consume_auth_rate_limit(text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'anon must be able to consume the fixed auth rate-limit policy';
  END IF;
END;
$$;

SET ROLE anon;
SELECT public.consume_auth_rate_limit(
  'magic_link',
  'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
);
RESET ROLE;
