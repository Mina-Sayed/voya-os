-- Voya OS: isolate self-service password signup attempts from sign-in and magic-link budgets.

ALTER TABLE public.auth_rate_limit_buckets
  DROP CONSTRAINT IF EXISTS auth_rate_limit_buckets_scope_check;

ALTER TABLE public.auth_rate_limit_buckets
  ADD CONSTRAINT auth_rate_limit_buckets_scope_check
  CHECK (scope IN ('magic_link', 'password_sign_in', 'password_sign_up'));

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
  now_at timestamptz := clock_timestamp();
  is_allowed boolean;
BEGIN
  IF p_scope IS NULL OR p_scope NOT IN ('magic_link', 'password_sign_in', 'password_sign_up') THEN
    RAISE EXCEPTION 'unsupported auth rate-limit scope' USING ERRCODE = '22023';
  END IF;
  IF p_key_hash IS NULL OR p_key_hash !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'auth rate-limit key must be a sha256 hex digest' USING ERRCODE = '22023';
  END IF;
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 1000 THEN
    RAISE EXCEPTION 'auth rate-limit must be between 1 and 1000' USING ERRCODE = '22023';
  END IF;
  IF p_window_seconds IS NULL OR p_window_seconds < 1 OR p_window_seconds > 86400 THEN
    RAISE EXCEPTION 'auth rate-limit window must be between 1 and 86400 seconds' USING ERRCODE = '22023';
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
    now_at,
    1,
    now_at
  )
  ON CONFLICT (key_hash) DO UPDATE
  SET
    scope = EXCLUDED.scope,
    window_started_at = CASE
      WHEN public.auth_rate_limit_buckets.window_started_at + make_interval(secs => p_window_seconds) <= now_at
        THEN now_at
      ELSE public.auth_rate_limit_buckets.window_started_at
    END,
    attempt_count = CASE
      WHEN public.auth_rate_limit_buckets.window_started_at + make_interval(secs => p_window_seconds) <= now_at
        THEN 1
      ELSE public.auth_rate_limit_buckets.attempt_count + 1
    END,
    updated_at = now_at
  RETURNING attempt_count <= p_limit INTO is_allowed;

  RETURN is_allowed;
END;
$$;
;

