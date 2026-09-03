-- P1 auth rate-limit repair candidate (checkout-only, no managed apply).
-- Restores the narrow two-argument database-owned policy (magic_link 5/900,
-- password_sign_in 10/900) while preserving the V1 server-adapter scopes, and
-- keeps execution server-only: only service_role may execute, reached through
-- the server adapter. Browser roles receive no EXECUTE so anonymous callers
-- cannot mint arbitrary buckets (the purge worker is not scheduled, so bucket
-- rows would otherwise accumulate without bound).
-- The legacy four-argument overload is removed so no caller can supply
-- p_limit / p_window_seconds (see supabase/tests/auth_rate_limit_p1_repair.sql).
-- Managed apply remains gated; this file proves the contract on disposable DBs only.

ALTER TABLE public.auth_rate_limit_buckets
  DROP CONSTRAINT IF EXISTS auth_rate_limit_buckets_scope_check;

ALTER TABLE public.auth_rate_limit_buckets
  ADD CONSTRAINT auth_rate_limit_buckets_scope_check
  CHECK (scope IN ('magic_link', 'password_sign_in', 'password_sign_up', 'password_reset', 'invitation_resend'));

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

-- Legacy caller-parameterized overload must not survive: callers could
-- otherwise supply p_limit / p_window_seconds.
DROP FUNCTION IF EXISTS public.consume_auth_rate_limit(text, text, integer, integer);

REVOKE ALL ON FUNCTION public.consume_auth_rate_limit(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.consume_auth_rate_limit(text, text) TO service_role;

COMMENT ON FUNCTION public.consume_auth_rate_limit(text, text)
IS 'P1 repair candidate: fixed database-owned rate-limit policy (magic_link 5/900, password_sign_in 10/900 plus V1 scopes), server-only execution via service_role; callers supply only scope and a SHA-256 key.';
