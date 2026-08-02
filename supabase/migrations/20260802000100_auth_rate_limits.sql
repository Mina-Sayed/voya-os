-- Voya OS: database-backed pre-auth rate limits.
-- The bucket stores only a server-generated hash, never an email or address.

CREATE TABLE public.auth_rate_limit_buckets (
  key_hash text PRIMARY KEY CHECK (key_hash ~ '^[0-9a-f]{64}$'),
  scope text NOT NULL CHECK (scope IN ('magic_link', 'password_sign_in')),
  window_started_at timestamptz NOT NULL,
  attempt_count integer NOT NULL CHECK (attempt_count > 0),
  updated_at timestamptz NOT NULL DEFAULT timezone('utc', now())
);

CREATE INDEX auth_rate_limit_buckets_updated_at_idx
  ON public.auth_rate_limit_buckets (updated_at);

REVOKE ALL ON TABLE public.auth_rate_limit_buckets FROM PUBLIC;

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
  IF p_scope IS NULL OR p_scope NOT IN ('magic_link', 'password_sign_in') THEN
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

CREATE OR REPLACE FUNCTION public.purge_auth_rate_limit_buckets(
  p_retention_seconds integer,
  p_limit integer
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  deleted_count integer;
BEGIN
  IF p_retention_seconds IS NULL OR p_retention_seconds < 3600 OR p_retention_seconds > 31536000 THEN
    RAISE EXCEPTION 'auth rate-limit retention must be between 3600 and 31536000 seconds' USING ERRCODE = '22023';
  END IF;
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 1000 THEN
    RAISE EXCEPTION 'auth rate-limit purge limit must be between 1 and 1000' USING ERRCODE = '22023';
  END IF;

  WITH expired AS (
    SELECT key_hash
    FROM public.auth_rate_limit_buckets
    WHERE updated_at < clock_timestamp() - make_interval(secs => p_retention_seconds)
    ORDER BY updated_at ASC
    LIMIT p_limit
    FOR UPDATE SKIP LOCKED
  )
  DELETE FROM public.auth_rate_limit_buckets AS bucket
  USING expired
  WHERE bucket.key_hash = expired.key_hash;

  GET DIAGNOSTICS deleted_count = ROW_COUNT;
  RETURN deleted_count;
END;
$$;

REVOKE ALL ON FUNCTION public.consume_auth_rate_limit(text, text, integer, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.purge_auth_rate_limit_buckets(integer, integer) FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO anon, authenticated, voya_outbox_worker;
GRANT EXECUTE ON FUNCTION public.consume_auth_rate_limit(text, text, integer, integer) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.purge_auth_rate_limit_buckets(integer, integer) TO voya_outbox_worker;
