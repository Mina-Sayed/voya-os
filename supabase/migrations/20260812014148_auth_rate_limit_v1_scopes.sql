-- Voya OS V1: database-owned auth and transactional-command throttles.
-- The application calls this RPC through the server-only service role client.
-- No browser role receives execute access, and callers never provide policy
-- parameters. The old four-argument rolling-deploy overload is removed only
-- after the V1 application has switched to the two-argument contract.

ALTER TABLE public.auth_rate_limit_buckets
  DROP CONSTRAINT IF EXISTS auth_rate_limit_buckets_scope_check;

ALTER TABLE public.auth_rate_limit_buckets
  ADD CONSTRAINT auth_rate_limit_buckets_scope_check
  CHECK (scope IN ('password_sign_in', 'password_sign_up', 'password_reset', 'invitation_resend'));

CREATE OR REPLACE FUNCTION public.consume_auth_rate_limit(
  p_scope text,
  p_key_hash text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_now timestamptz := clock_timestamp();
  v_limit integer;
  v_window_seconds integer;
  v_is_allowed boolean;
BEGIN
  CASE p_scope
    WHEN 'password_sign_in' THEN
      v_limit := 10;
      v_window_seconds := 900;
    WHEN 'password_sign_up' THEN
      v_limit := 5;
      v_window_seconds := 3600;
    WHEN 'password_reset' THEN
      v_limit := 5;
      v_window_seconds := 900;
    WHEN 'invitation_resend' THEN
      v_limit := 5;
      v_window_seconds := 3600;
    ELSE
      RAISE EXCEPTION 'unsupported auth rate-limit scope' USING ERRCODE = '22023';
  END CASE;

  IF p_key_hash IS NULL OR p_key_hash !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'auth rate-limit key must be a sha256 hex digest' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.auth_rate_limit_buckets (
    key_hash, scope, window_started_at, attempt_count, updated_at
  ) VALUES (
    p_key_hash, p_scope, v_now, 1, v_now
  )
  ON CONFLICT (scope, key_hash) DO UPDATE
  SET
    window_started_at = CASE
      WHEN public.auth_rate_limit_buckets.window_started_at
        + make_interval(secs => v_window_seconds) <= v_now
        THEN v_now
      ELSE public.auth_rate_limit_buckets.window_started_at
    END,
    attempt_count = CASE
      WHEN public.auth_rate_limit_buckets.window_started_at
        + make_interval(secs => v_window_seconds) <= v_now
        THEN 1
      ELSE public.auth_rate_limit_buckets.attempt_count + 1
    END,
    updated_at = v_now
  RETURNING attempt_count <= v_limit INTO v_is_allowed;

  RETURN v_is_allowed;
END;
$$;

DROP FUNCTION IF EXISTS public.consume_auth_rate_limit(text, text, integer, integer);

REVOKE ALL ON FUNCTION public.consume_auth_rate_limit(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.consume_auth_rate_limit(text, text) TO service_role;

COMMENT ON FUNCTION public.consume_auth_rate_limit(text, text)
IS 'Consumes fixed V1 database-owned auth/command rate-limit policy; only server-side service role may execute it.';
