-- R11: atomically terminalize a WhatsApp AI run and its leased outbox event.
CREATE OR REPLACE FUNCTION public.fail_whatsapp_ai_outbox_event_v1(
  p_event_id uuid,
  p_worker_id text,
  p_error_code text,
  p_retry_after_seconds integer DEFAULT 60,
  p_max_attempts integer DEFAULT 6
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_event public.outbox_events%ROWTYPE;
  v_next_state text;
  v_updated_count integer;
BEGIN
  IF p_event_id IS NULL OR p_worker_id IS NULL
    OR char_length(btrim(p_worker_id)) = 0 OR char_length(p_worker_id) > 120 THEN
    RAISE EXCEPTION 'outbox event or worker id is invalid' USING ERRCODE = '22023';
  END IF;
  IF p_error_code IS NULL OR p_error_code !~ '^[a-z][a-z0-9_.-]{0,119}$'
    OR p_retry_after_seconds IS NULL OR p_retry_after_seconds < 1 OR p_retry_after_seconds > 86400
    OR p_max_attempts IS NULL OR p_max_attempts < 1 OR p_max_attempts > 20 THEN
    RAISE EXCEPTION 'outbox failure parameters are invalid' USING ERRCODE = '22023';
  END IF;

  SELECT event.* INTO v_event
  FROM public.outbox_events AS event
  WHERE event.id = p_event_id
    AND event.event_type = 'whatsapp.ai.respond_requested'
    AND event.state = 'processing'
    AND event.locked_by = p_worker_id
    AND event.locked_until > timezone('utc', now())
  FOR UPDATE;
  IF NOT FOUND THEN RETURN NULL; END IF;
  v_next_state := CASE WHEN v_event.attempts >= p_max_attempts THEN 'dead_letter' ELSE 'retry_wait' END;

  IF v_next_state = 'dead_letter' THEN
    UPDATE public.ai_runs AS run
    SET status = 'failed', finished_at = timezone('utc', now()), error_code = 'whatsapp_ai_retry_exhausted'
    WHERE run.organization_id = v_event.organization_id
      AND run.id::text = v_event.payload ->> 'run_id'
      AND run.agent_kind = 'whatsapp'
      AND run.status IN ('queued', 'running');
    GET DIAGNOSTICS v_updated_count = ROW_COUNT;
    IF v_updated_count <> 1 THEN
      RAISE EXCEPTION 'WhatsApp AI run terminal transition failed' USING ERRCODE = '40001';
    END IF;
  END IF;

  UPDATE public.outbox_events
  SET state = v_next_state,
      available_at = CASE
        WHEN v_next_state = 'retry_wait' THEN timezone('utc', now()) + make_interval(secs => p_retry_after_seconds)
        ELSE available_at
      END,
      locked_by = NULL,
      locked_until = NULL,
      last_error_code = p_error_code
  WHERE id = p_event_id
    AND state = 'processing'
    AND locked_by = p_worker_id
    AND locked_until > timezone('utc', now());
  GET DIAGNOSTICS v_updated_count = ROW_COUNT;
  IF v_updated_count <> 1 THEN
    RAISE EXCEPTION 'WhatsApp AI outbox transition lost its lease' USING ERRCODE = '40001';
  END IF;
  RETURN v_next_state;
END;
$$;

REVOKE ALL ON FUNCTION public.fail_whatsapp_ai_outbox_event_v1(uuid, text, text, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fail_whatsapp_ai_outbox_event_v1(uuid, text, text, integer, integer) TO voya_outbox_worker, service_role;

-- R12: update WhatsApp/invitation delivery facts in the same transaction that
-- releases or dead-letters the leased outbox event.
CREATE OR REPLACE FUNCTION public.fail_outbox_delivery_event_v1(
  p_event_id uuid,
  p_worker_id text,
  p_error_code text,
  p_retry_after_seconds integer DEFAULT 60,
  p_max_attempts integer DEFAULT 6
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_event public.outbox_events%ROWTYPE;
  v_next_state text;
  v_updated_count integer;
  v_invitation_id uuid;
  v_delivery_status text;
BEGIN
  IF p_event_id IS NULL OR p_worker_id IS NULL
    OR char_length(btrim(p_worker_id)) = 0 OR char_length(p_worker_id) > 120 THEN
    RAISE EXCEPTION 'outbox event or worker id is invalid' USING ERRCODE = '22023';
  END IF;
  IF p_error_code IS NULL OR p_error_code !~ '^[a-z][a-z0-9_.-]{0,119}$'
    OR p_retry_after_seconds IS NULL OR p_retry_after_seconds < 1 OR p_retry_after_seconds > 86400
    OR p_max_attempts IS NULL OR p_max_attempts < 1 OR p_max_attempts > 20 THEN
    RAISE EXCEPTION 'outbox failure parameters are invalid' USING ERRCODE = '22023';
  END IF;

  SELECT event.* INTO v_event
  FROM public.outbox_events AS event
  WHERE event.id = p_event_id
    AND event.event_type IN (
      'whatsapp.message.send_requested',
      'organization.invitation.send_requested',
      'member.invitation.resent'
    )
    AND event.state = 'processing'
    AND event.locked_by = p_worker_id
    AND event.locked_until > timezone('utc', now())
  FOR UPDATE;
  IF NOT FOUND THEN RETURN NULL; END IF;
  v_next_state := CASE WHEN v_event.attempts >= p_max_attempts THEN 'dead_letter' ELSE 'retry_wait' END;

  IF v_next_state = 'dead_letter' AND v_event.event_type = 'whatsapp.message.send_requested' THEN
    UPDATE public.whatsapp_message_events AS message
    SET delivery_status = 'failed',
        failed_at = timezone('utc', now()),
        provider_error_code = p_error_code
    WHERE message.organization_id = v_event.organization_id
      AND message.id = (v_event.payload ->> 'message_id')::uuid
      AND message.direction = 'outbound'
      AND message.delivery_status IN ('queued', 'failed');
    GET DIAGNOSTICS v_updated_count = ROW_COUNT;
    IF v_updated_count <> 1 THEN
      RAISE EXCEPTION 'WhatsApp message terminal transition failed' USING ERRCODE = '40001';
    END IF;
  ELSIF v_next_state = 'dead_letter' THEN
    v_invitation_id := (v_event.payload ->> 'invitation_id')::uuid;
    SELECT invitation.delivery_status INTO v_delivery_status
    FROM public.organization_invitations AS invitation
    WHERE invitation.organization_id = v_event.organization_id
      AND invitation.id = v_invitation_id
    FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'invitation delivery target is missing' USING ERRCODE = '40001';
    END IF;
    UPDATE public.organization_invitations
    SET delivery_status = 'failed', updated_at = timezone('utc', now())
    WHERE organization_id = v_event.organization_id
      AND id = v_invitation_id
      AND delivery_status IN ('pending', 'failed');
    GET DIAGNOSTICS v_updated_count = ROW_COUNT;
    IF v_updated_count <> 1 THEN
      RAISE EXCEPTION 'invitation terminal transition failed' USING ERRCODE = '40001';
    END IF;
  END IF;

  UPDATE public.outbox_events
  SET state = v_next_state,
      available_at = CASE
        WHEN v_next_state = 'retry_wait' THEN timezone('utc', now()) + make_interval(secs => p_retry_after_seconds)
        ELSE available_at
      END,
      locked_by = NULL,
      locked_until = NULL,
      last_error_code = p_error_code
  WHERE id = p_event_id
    AND state = 'processing'
    AND locked_by = p_worker_id
    AND locked_until > timezone('utc', now());
  GET DIAGNOSTICS v_updated_count = ROW_COUNT;
  IF v_updated_count <> 1 THEN
    RAISE EXCEPTION 'delivery outbox transition lost its lease' USING ERRCODE = '40001';
  END IF;
  RETURN v_next_state;
END;
$$;

REVOKE ALL ON FUNCTION public.fail_outbox_delivery_event_v1(uuid, text, text, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fail_outbox_delivery_event_v1(uuid, text, text, integer, integer) TO voya_outbox_worker, service_role;
