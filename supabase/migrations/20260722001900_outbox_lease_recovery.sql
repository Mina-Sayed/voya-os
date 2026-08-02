-- Voya OS: recover expired outbox leases through one narrow worker capability.

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'voya_outbox_worker') THEN
    CREATE ROLE voya_outbox_worker NOLOGIN NOINHERIT;
  END IF;
END;
$$;

ALTER ROLE voya_outbox_worker NOLOGIN NOINHERIT;

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
    WHERE (
      event.state IN ('pending', 'retry_wait')
      AND event.available_at <= now()
    ) OR (
      event.state = 'processing'
      AND event.locked_until <= now()
    )
    ORDER BY
      CASE WHEN event.state = 'processing' THEN event.locked_until ELSE event.available_at END ASC,
      event.created_at ASC
    LIMIT p_limit
    FOR UPDATE SKIP LOCKED
  )
  UPDATE public.outbox_events AS event
  SET
    state = 'processing',
    attempts = event.attempts + 1,
    locked_by = p_worker_id,
    locked_until = now() + make_interval(secs => p_lease_seconds),
    last_error_code = NULL
  FROM eligible
  WHERE event.id = eligible.id
  RETURNING event.*;
END;
$$;

REVOKE ALL ON FUNCTION public.claim_outbox_events(text, integer, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.claim_outbox_events(text, integer, integer) FROM authenticated;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    REVOKE ALL ON FUNCTION public.claim_outbox_events(text, integer, integer) FROM anon;
    REVOKE ALL ON TABLE public.outbox_events FROM anon;
  END IF;
END;
$$;
REVOKE ALL ON TABLE public.outbox_events FROM PUBLIC;
REVOKE ALL ON TABLE public.outbox_events FROM authenticated;
REVOKE ALL ON TABLE public.outbox_events FROM voya_outbox_worker;
GRANT USAGE ON SCHEMA public TO voya_outbox_worker;
GRANT EXECUTE ON FUNCTION public.claim_outbox_events(text, integer, integer) TO voya_outbox_worker;
