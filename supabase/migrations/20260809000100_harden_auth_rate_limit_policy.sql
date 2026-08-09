-- Keep every browser-callable auth rate-limit policy database-owned.
-- The previous signup migration accidentally replaced the rolling-compatible
-- four-argument overload with a caller-configurable implementation.

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
    WHEN 'magic_link' THEN
      v_limit := 5;
      v_window_seconds := 900;
    WHEN 'password_sign_in' THEN
      v_limit := 10;
      v_window_seconds := 900;
    WHEN 'password_sign_up' THEN
      v_limit := 5;
      v_window_seconds := 3600;
    ELSE
      RAISE EXCEPTION 'unsupported auth rate-limit scope' USING ERRCODE = '22023';
  END CASE;

  IF p_key_hash IS NULL OR p_key_hash !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'auth rate-limit key must be a sha256 hex digest' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.auth_rate_limit_buckets (
    key_hash,
    scope,
    window_started_at,
    attempt_count,
    updated_at
  ) VALUES (
    p_key_hash,
    p_scope,
    v_now,
    1,
    v_now
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

REVOKE ALL ON FUNCTION public.consume_auth_rate_limit(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.consume_auth_rate_limit(text, text) TO anon, authenticated;

REVOKE ALL ON FUNCTION public.consume_auth_rate_limit(text, text, integer, integer)
  FROM PUBLIC, anon, authenticated;
DROP FUNCTION public.consume_auth_rate_limit(text, text, integer, integer);

COMMENT ON FUNCTION public.consume_auth_rate_limit(text, text)
IS 'Consumes a fixed database-owned pre-auth rate-limit policy; callers supply only scope and a SHA-256 key.';
