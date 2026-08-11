-- Voya OS: restore the rolling-deploy compatibility contract after the
-- password-signup migration replaced it with caller-controlled policy.
-- The canonical two-argument function remains the policy owner. This
-- overload is temporary and must be removed only after all deployed clients
-- use the canonical signature.

SET lock_timeout = '5s';
SET statement_timeout = '15min';

CREATE OR REPLACE FUNCTION public.consume_auth_rate_limit(
  p_scope text,
  p_key_hash text,
  p_limit integer,
  p_window_seconds integer
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_expected_limit integer;
  v_expected_window_seconds integer := 900;
BEGIN
  CASE p_scope
    WHEN 'magic_link' THEN v_expected_limit := 5;
    WHEN 'password_sign_in' THEN v_expected_limit := 10;
    ELSE
      RAISE EXCEPTION 'unsupported auth rate-limit scope' USING ERRCODE = '22023';
  END CASE;

  IF p_limit IS DISTINCT FROM v_expected_limit
    OR p_window_seconds IS DISTINCT FROM v_expected_window_seconds THEN
    RAISE EXCEPTION 'auth rate-limit policy is database controlled' USING ERRCODE = '22023';
  END IF;

  RETURN public.consume_auth_rate_limit(p_scope, p_key_hash);
END;
$$;

REVOKE ALL ON FUNCTION public.consume_auth_rate_limit(text, text, integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.consume_auth_rate_limit(text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.consume_auth_rate_limit(text, text, integer, integer) TO anon, authenticated, service_role;

RESET statement_timeout;
RESET lock_timeout;
