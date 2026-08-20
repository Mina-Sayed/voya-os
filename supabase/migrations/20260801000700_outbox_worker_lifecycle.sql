-- Voya OS: complete the private outbox worker lifecycle.
-- Provider adapters remain outside the database. Workers must map provider
-- failures to a short, non-sensitive error code before calling fail_outbox_event.

CREATE INDEX IF NOT EXISTS outbox_events_terminal_retention_idx
  ON public.outbox_events (updated_at)
  WHERE state IN ('completed', 'dead_letter');

CREATE OR REPLACE FUNCTION public.complete_outbox_event(
  p_event_id uuid,
  p_worker_id text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  updated_count integer;
BEGIN
  IF p_event_id IS NULL THEN
    RAISE EXCEPTION 'event id is required' USING ERRCODE = '22023';
  END IF;
  IF p_worker_id IS NULL OR char_length(btrim(p_worker_id)) = 0 OR char_length(p_worker_id) > 120 THEN
    RAISE EXCEPTION 'worker id is invalid' USING ERRCODE = '22023';
  END IF;

  UPDATE public.outbox_events
  SET state = 'completed',
      locked_by = NULL,
      locked_until = NULL,
      last_error_code = NULL
  WHERE id = p_event_id
    AND state = 'processing'
    AND locked_by = p_worker_id
    AND locked_until > timezone('utc', now());

  GET DIAGNOSTICS updated_count = ROW_COUNT;
  RETURN updated_count = 1;
END;
$$;

CREATE OR REPLACE FUNCTION public.fail_outbox_event(
  p_event_id uuid,
  p_worker_id text,
  p_error_code text,
  p_retry_after_seconds integer DEFAULT 60,
  p_max_attempts integer DEFAULT 5
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  next_state text;
  updated_count integer;
BEGIN
  IF p_event_id IS NULL THEN
    RAISE EXCEPTION 'event id is required' USING ERRCODE = '22023';
  END IF;
  IF p_worker_id IS NULL OR char_length(btrim(p_worker_id)) = 0 OR char_length(p_worker_id) > 120 THEN
    RAISE EXCEPTION 'worker id is invalid' USING ERRCODE = '22023';
  END IF;
  IF p_error_code IS NULL OR p_error_code !~ '^[a-z][a-z0-9_.-]{0,119}$' THEN
    RAISE EXCEPTION 'error code must be a short safe identifier' USING ERRCODE = '22023';
  END IF;
  IF p_retry_after_seconds IS NULL OR p_retry_after_seconds < 1 OR p_retry_after_seconds > 86400 THEN
    RAISE EXCEPTION 'retry delay must be between 1 and 86400 seconds' USING ERRCODE = '22023';
  END IF;
  IF p_max_attempts IS NULL OR p_max_attempts < 1 OR p_max_attempts > 20 THEN
    RAISE EXCEPTION 'maximum attempts must be between 1 and 20' USING ERRCODE = '22023';
  END IF;

  SELECT CASE WHEN attempts >= p_max_attempts THEN 'dead_letter' ELSE 'retry_wait' END
  INTO next_state
  FROM public.outbox_events
  WHERE id = p_event_id
    AND state = 'processing'
    AND locked_by = p_worker_id
    AND locked_until > timezone('utc', now());

  IF next_state IS NULL THEN
    RETURN NULL;
  END IF;

  UPDATE public.outbox_events
  SET state = next_state,
      available_at = CASE
        WHEN next_state = 'retry_wait' THEN timezone('utc', now()) + make_interval(secs => p_retry_after_seconds)
        ELSE available_at
      END,
      locked_by = NULL,
      locked_until = NULL,
      last_error_code = p_error_code
  WHERE id = p_event_id
    AND state = 'processing'
    AND locked_by = p_worker_id
    AND locked_until > timezone('utc', now());

  GET DIAGNOSTICS updated_count = ROW_COUNT;
  IF updated_count <> 1 THEN
    RETURN NULL;
  END IF;
  RETURN next_state;
END;
$$;

CREATE OR REPLACE FUNCTION public.purge_outbox_events(
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
    RAISE EXCEPTION 'retention must be between 3600 and 31536000 seconds' USING ERRCODE = '22023';
  END IF;
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 1000 THEN
    RAISE EXCEPTION 'purge limit must be between 1 and 1000' USING ERRCODE = '22023';
  END IF;

  WITH eligible AS (
    SELECT id
    FROM public.outbox_events
    WHERE state IN ('completed', 'dead_letter')
      AND updated_at <= timezone('utc', now()) - make_interval(secs => p_retention_seconds)
    ORDER BY updated_at ASC
    LIMIT p_limit
    FOR UPDATE SKIP LOCKED
  )
  DELETE FROM public.outbox_events AS event
  USING eligible
  WHERE event.id = eligible.id;

  GET DIAGNOSTICS deleted_count = ROW_COUNT;
  RETURN deleted_count;
END;
$$;

REVOKE ALL ON FUNCTION public.complete_outbox_event(uuid, text) FROM PUBLIC, authenticated;

REVOKE ALL ON FUNCTION public.fail_outbox_event(uuid, text, text, integer, integer) FROM PUBLIC, authenticated;

REVOKE ALL ON FUNCTION public.purge_outbox_events(integer, integer) FROM PUBLIC, authenticated;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    REVOKE ALL ON FUNCTION public.complete_outbox_event(uuid, text) FROM anon;
    REVOKE ALL ON FUNCTION public.fail_outbox_event(uuid, text, text, integer, integer) FROM anon;
    REVOKE ALL ON FUNCTION public.purge_outbox_events(integer, integer) FROM anon;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.complete_outbox_event(uuid, text) FROM voya_outbox_worker;

REVOKE ALL ON FUNCTION public.fail_outbox_event(uuid, text, text, integer, integer) FROM voya_outbox_worker;

REVOKE ALL ON FUNCTION public.purge_outbox_events(integer, integer) FROM voya_outbox_worker;

GRANT EXECUTE ON FUNCTION public.complete_outbox_event(uuid, text) TO voya_outbox_worker;

GRANT EXECUTE ON FUNCTION public.fail_outbox_event(uuid, text, text, integer, integer) TO voya_outbox_worker;

GRANT EXECUTE ON FUNCTION public.purge_outbox_events(integer, integer) TO voya_outbox_worker;

