-- P1 hardening for queued WhatsApp AI work.
--
-- 1) A channel kill switch must stop already-queued AI work before any provider call.
-- 2) Outbound AI replies must be re-checked at the DB command boundary.
-- 3) Low-confidence model output is never eligible for automatic WhatsApp reply.
--
-- Auth rate-limit policy is already repaired in
-- 20260810182752_harden_auth_rate_limit_policy.sql; this slice adds a regression
-- assertion for the legacy caller-configurable overload in the SQL test suite.

CREATE OR REPLACE FUNCTION public.guard_whatsapp_ai_execution_v1(
  p_event_id uuid,
  p_worker_id text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_allowed boolean;
BEGIN
  IF p_event_id IS NULL OR p_worker_id IS NULL
    OR char_length(btrim(p_worker_id)) NOT BETWEEN 1 AND 120 THEN
    RAISE EXCEPTION 'WhatsApp AI guard input is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT channel.status = 'active'
    AND channel.kill_switch = false
    AND conversation.status <> 'closed'
    AND conversation.ai_enabled
  INTO v_allowed
  FROM public.outbox_events AS event
  JOIN public.whatsapp_conversations AS conversation
    ON conversation.organization_id = event.organization_id
   AND conversation.id::text = event.payload ->> 'conversation_id'
  JOIN public.whatsapp_channels AS channel
    ON channel.organization_id = event.organization_id
   AND channel.id = conversation.channel_id
  WHERE event.id = p_event_id
    AND event.event_type = 'whatsapp.ai.respond_requested'
    AND event.state = 'processing'
    AND event.locked_by = p_worker_id
    AND event.locked_until > timezone('utc', now());

  RETURN coalesce(v_allowed, false);
END;
$$;

REVOKE ALL ON FUNCTION public.guard_whatsapp_ai_execution_v1(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.guard_whatsapp_ai_execution_v1(uuid, text) TO voya_outbox_worker, service_role;

CREATE OR REPLACE FUNCTION public.apply_whatsapp_ai_result_v2(
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
    ON channel.organization_id = event.organization_id
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
  FROM public.apply_whatsapp_ai_result_v1(
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

REVOKE ALL ON FUNCTION public.apply_whatsapp_ai_result_v2(uuid, text, text, jsonb, text, text, text, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.apply_whatsapp_ai_result_v2(uuid, text, text, jsonb, text, text, text, boolean) TO voya_outbox_worker, service_role;
