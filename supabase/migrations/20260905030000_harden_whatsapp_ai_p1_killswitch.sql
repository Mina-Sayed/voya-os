-- R-05: re-check the WhatsApp AI channel kill switch at every worker boundary
-- after enqueue, and never auto-reply on low-confidence model output.
--
-- Ingest already rejects killed/inactive channels, but a switch flipped while
-- an event sits queued (or while the worker holds its lease) must fail closed
-- before any provider call and before any outbound reply is queued:
--
-- 1) renew_whatsapp_ai_event_lease_v1 joins the event's conversation/channel
--    and returns false unless the conversation is open + AI-enabled and the
--    channel is active with kill_switch = false. The worker renews immediately
--    before Gemini/media work, so a killed channel cannot continue into the
--    provider path.
-- 2) start_whatsapp_ai_run_v1 applies the same gate to the queued -> running
--    transition.
-- 3) apply_whatsapp_ai_result_v1 keeps its signature but becomes a safety
--    wrapper: the existing implementation is preserved as
--    apply_whatsapp_ai_result_v1_legacy (worker/service_role only) and the
--    public entry point forces p_send_reply off unless the channel is
--    currently enabled AND the model confidence is not 'low'. Lead/state
--    projection still applies; only the automatic outbound reply is denied.

-- ---------------------------------------------------------------------------
-- Kill switch at lease renewal (called immediately before provider work)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.renew_whatsapp_ai_event_lease_v1(
  p_event_id uuid,
  p_worker_id text,
  p_lease_seconds integer
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_updated_count integer;
BEGIN
  IF p_event_id IS NULL OR p_worker_id IS NULL OR char_length(btrim(p_worker_id)) NOT BETWEEN 1 AND 120
    OR p_lease_seconds IS NULL OR p_lease_seconds NOT BETWEEN 1 AND 900 THEN
    RAISE EXCEPTION 'WhatsApp AI lease input is invalid' USING ERRCODE = '22023';
  END IF;

  UPDATE public.outbox_events AS event
  SET locked_until = timezone('utc', now()) + make_interval(secs => p_lease_seconds)
  FROM public.whatsapp_conversations AS conversation
  JOIN public.whatsapp_channels AS channel
    ON channel.organization_id = conversation.organization_id
   AND channel.id = conversation.channel_id
  WHERE event.id = p_event_id
    AND event.event_type = 'whatsapp.ai.respond_requested'
    AND event.state = 'processing'
    AND event.locked_by = p_worker_id
    AND event.locked_until > timezone('utc', now())
    AND conversation.organization_id = event.organization_id
    AND conversation.id::text = event.payload ->> 'conversation_id'
    AND conversation.status <> 'closed'
    AND conversation.ai_enabled
    AND channel.status = 'active'
    AND channel.kill_switch = false;

  GET DIAGNOSTICS v_updated_count = ROW_COUNT;
  RETURN v_updated_count = 1;
END;
$$;

REVOKE ALL ON FUNCTION public.renew_whatsapp_ai_event_lease_v1(uuid, text, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.renew_whatsapp_ai_event_lease_v1(uuid, text, integer) TO voya_outbox_worker, service_role;

-- ---------------------------------------------------------------------------
-- Kill switch at run start (queued -> running must also fail closed)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.start_whatsapp_ai_run_v1(
  p_event_id uuid,
  p_worker_id text,
  p_model_name text,
  p_prompt_version text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_updated_count integer;
BEGIN
  IF p_model_name IS NULL OR char_length(btrim(p_model_name)) NOT BETWEEN 1 AND 120
    OR p_prompt_version IS NULL OR char_length(btrim(p_prompt_version)) NOT BETWEEN 1 AND 120 THEN
    RAISE EXCEPTION 'WhatsApp AI run metadata is invalid' USING ERRCODE = '22023';
  END IF;

  UPDATE public.ai_runs AS run
  SET status = 'running',
      model_name = btrim(p_model_name),
      prompt_version = btrim(p_prompt_version),
      started_at = coalesce(run.started_at, timezone('utc', now())),
      finished_at = NULL,
      error_code = NULL
  FROM public.outbox_events AS event
  JOIN public.whatsapp_conversations AS conversation
    ON conversation.organization_id = event.organization_id
   AND conversation.id::text = event.payload ->> 'conversation_id'
  JOIN public.whatsapp_channels AS channel
    ON channel.organization_id = conversation.organization_id
   AND channel.id = conversation.channel_id
  WHERE event.id = p_event_id
    AND event.organization_id = run.organization_id
    AND event.event_type = 'whatsapp.ai.respond_requested'
    AND event.state = 'processing'
    AND event.locked_by = p_worker_id
    AND event.locked_until > timezone('utc', now())
    AND run.id::text = event.payload ->> 'run_id'
    AND run.agent_kind = 'whatsapp'
    AND run.status IN ('queued', 'running')
    AND conversation.status <> 'closed'
    AND conversation.ai_enabled
    AND channel.status = 'active'
    AND channel.kill_switch = false;

  GET DIAGNOSTICS v_updated_count = ROW_COUNT;
  RETURN v_updated_count = 1;
END;
$$;

REVOKE ALL ON FUNCTION public.start_whatsapp_ai_run_v1(uuid, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.start_whatsapp_ai_run_v1(uuid, text, text, text) TO voya_outbox_worker, service_role;

-- ---------------------------------------------------------------------------
-- Reply safety: keep the implementation as an internal primitive and enforce
-- channel + confidence policy at the public worker command boundary.
-- ---------------------------------------------------------------------------

ALTER FUNCTION public.apply_whatsapp_ai_result_v1(
  uuid, text, text, jsonb, text, text, text, boolean
) RENAME TO apply_whatsapp_ai_result_v1_legacy;

CREATE OR REPLACE FUNCTION public.apply_whatsapp_ai_result_v1(
  p_event_id uuid,
  p_worker_id text,
  p_conversation_type text,
  p_structured_state jsonb,
  p_reply text,
  p_recommended_action text,
  p_confidence text,
  p_send_reply boolean
)
RETURNS TABLE (outcome text, lead_id uuid, outbound_message_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_channel_enabled boolean;
  v_allow_reply boolean;
BEGIN
  IF p_event_id IS NULL OR p_worker_id IS NULL OR char_length(btrim(p_worker_id)) NOT BETWEEN 1 AND 120
    OR p_confidence IS NULL OR p_confidence NOT IN ('high', 'medium', 'low') THEN
    RAISE EXCEPTION 'WhatsApp AI result safety input is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT channel.status = 'active'
    AND channel.kill_switch = false
  INTO v_channel_enabled
  FROM public.outbox_events AS event
  JOIN public.whatsapp_conversations AS conversation
    ON conversation.organization_id = event.organization_id
   AND conversation.id::text = event.payload ->> 'conversation_id'
  JOIN public.whatsapp_channels AS channel
    ON channel.organization_id = conversation.organization_id
   AND channel.id = conversation.channel_id
  WHERE event.id = p_event_id
    AND event.event_type = 'whatsapp.ai.respond_requested'
    AND event.state = 'processing'
    AND event.locked_by = p_worker_id
    AND event.locked_until > timezone('utc', now());

  v_allow_reply := coalesce(v_channel_enabled, false)
    AND p_send_reply
    AND p_confidence <> 'low';

  RETURN QUERY
  SELECT applied.outcome, applied.lead_id, applied.outbound_message_id
  FROM public.apply_whatsapp_ai_result_v1_legacy(
    p_event_id,
    p_worker_id,
    p_conversation_type,
    p_structured_state,
    p_reply,
    p_recommended_action,
    p_confidence,
    v_allow_reply
  ) AS applied;
END;
$$;

REVOKE ALL ON FUNCTION public.apply_whatsapp_ai_result_v1_legacy(uuid, text, text, jsonb, text, text, text, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.apply_whatsapp_ai_result_v1_legacy(uuid, text, text, jsonb, text, text, text, boolean) TO voya_outbox_worker, service_role;
REVOKE ALL ON FUNCTION public.apply_whatsapp_ai_result_v1(uuid, text, text, jsonb, text, text, text, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.apply_whatsapp_ai_result_v1(uuid, text, text, jsonb, text, text, text, boolean) TO voya_outbox_worker, service_role;
