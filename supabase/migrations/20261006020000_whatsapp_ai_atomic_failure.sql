-- Finalize the leased WhatsApp AI event and its run atomically after the last
-- provider attempt. A failed lease check changes neither record.
CREATE OR REPLACE FUNCTION public.fail_whatsapp_ai_delivery_v1(
  p_event_id uuid, p_worker_id text, p_error_code text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_organization_id uuid;
  v_run_id uuid;
  v_run_status text;
  v_updated integer;
BEGIN
  IF p_event_id IS NULL OR p_worker_id IS NULL
    OR char_length(btrim(p_worker_id)) = 0 OR char_length(p_worker_id) > 120
    OR p_error_code IS NULL OR p_error_code !~ '^[a-z][a-z0-9_.-]{0,119}$' THEN
    RAISE EXCEPTION 'WhatsApp AI finalization input is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT event.organization_id, NULLIF(event.payload->>'run_id', '')::uuid
  INTO v_organization_id, v_run_id
  FROM public.outbox_events AS event
  WHERE event.id = p_event_id
    AND event.event_type = 'whatsapp.ai.respond_requested'
    AND event.state = 'processing'
    AND event.attempts >= 6
    AND event.locked_by = p_worker_id
    AND event.locked_until > timezone('utc', now())
  FOR UPDATE;
  IF NOT FOUND THEN RETURN false; END IF;
  IF v_run_id IS NULL THEN
    RAISE EXCEPTION 'WhatsApp AI run reference is missing' USING ERRCODE = '23514';
  END IF;

  SELECT run.status INTO v_run_status
  FROM public.ai_runs AS run
  WHERE run.organization_id = v_organization_id
    AND run.id = v_run_id
    AND run.agent_kind = 'whatsapp'
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'WhatsApp AI run is missing' USING ERRCODE = '23503';
  END IF;
  IF v_run_status IN ('queued', 'running') THEN
    UPDATE public.ai_runs AS run
    SET status = 'failed', finished_at = timezone('utc', now()), error_code = p_error_code
    WHERE run.organization_id = v_organization_id AND run.id = v_run_id;
  ELSIF v_run_status NOT IN ('failed', 'succeeded', 'cancelled', 'stopped') THEN
    RAISE EXCEPTION 'WhatsApp AI run state cannot be finalized' USING ERRCODE = '23514';
  END IF;

  UPDATE public.outbox_events AS event
  SET state = 'dead_letter', locked_by = NULL, locked_until = NULL,
      last_error_code = p_error_code
  WHERE event.id = p_event_id AND event.organization_id = v_organization_id
    AND event.state = 'processing' AND event.locked_by = p_worker_id
    AND event.locked_until > timezone('utc', now());
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  IF v_updated <> 1 THEN
    RAISE EXCEPTION 'WhatsApp AI event lease changed during finalization' USING ERRCODE = '40001';
  END IF;
  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.fail_whatsapp_ai_delivery_v1(uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fail_whatsapp_ai_delivery_v1(uuid, text, text) TO voya_outbox_worker, service_role;
