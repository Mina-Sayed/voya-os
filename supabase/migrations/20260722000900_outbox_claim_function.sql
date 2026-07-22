-- Voya OS: private, concurrency-safe outbox claim primitive for a worker.

CREATE OR REPLACE FUNCTION public.claim_outbox_events(
  p_worker_id text,
  p_limit integer,
  p_lease_seconds integer
)
RETURNS SETOF public.outbox_events
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  IF p_worker_id IS NULL OR char_length(btrim(p_worker_id)) = 0 THEN
    RAISE EXCEPTION 'worker id is required' USING ERRCODE = '22023';
  END IF;
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 100 THEN
    RAISE EXCEPTION 'claim limit must be between 1 and 100' USING ERRCODE = '22023';
  END IF;
  IF p_lease_seconds IS NULL OR p_lease_seconds < 1 OR p_lease_seconds > 900 THEN
    RAISE EXCEPTION 'lease duration must be between 1 and 900 seconds' USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  WITH eligible AS (
    SELECT event.id
    FROM public.outbox_events AS event
    WHERE event.state IN ('pending', 'retry_wait')
      AND event.available_at <= timezone('utc', now())
    ORDER BY event.available_at ASC, event.created_at ASC
    LIMIT p_limit
    FOR UPDATE SKIP LOCKED
  )
  UPDATE public.outbox_events AS event
  SET
    state = 'processing',
    attempts = event.attempts + 1,
    locked_by = p_worker_id,
    locked_until = timezone('utc', now()) + make_interval(secs => p_lease_seconds),
    last_error_code = NULL
  FROM eligible
  WHERE event.id = eligible.id
  RETURNING event.*;
END;
$$;

REVOKE ALL ON FUNCTION public.claim_outbox_events(text, integer, integer) FROM PUBLIC;
