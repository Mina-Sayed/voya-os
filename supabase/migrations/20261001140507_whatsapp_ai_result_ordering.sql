-- Reject a WhatsApp AI result built for an inbound message that is older than
-- the conversation's current processed-message cursor. The conversation lock
-- spans the comparison and the legacy projection call, so concurrent applies
-- cannot pass a stale check against the same cursor and then overwrite newer
-- state.

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
  v_event public.outbox_events%ROWTYPE;
  v_message public.whatsapp_message_events%ROWTYPE;
  v_conversation public.whatsapp_conversations%ROWTYPE;
  v_processed_created_at timestamptz;
  v_channel_enabled boolean;
  v_allow_reply boolean;
BEGIN
  IF p_event_id IS NULL OR p_worker_id IS NULL OR char_length(btrim(p_worker_id)) NOT BETWEEN 1 AND 120
    OR p_confidence IS NULL OR p_confidence NOT IN ('high', 'medium', 'low') THEN
    RAISE EXCEPTION 'WhatsApp AI result safety input is invalid' USING ERRCODE = '22023';
  END IF;

  -- Lock the same conversation row that the implementation locks below.
  -- The order tuple matches resolve_whatsapp_ai_execution_v1's message-history
  -- ordering (created_at, id), including deterministic ties.
  SELECT event.* INTO v_event
  FROM public.outbox_events AS event
  WHERE event.id = p_event_id
    AND event.event_type = 'whatsapp.ai.respond_requested'
    AND event.state = 'processing'
    AND event.locked_by = p_worker_id
    AND event.locked_until > timezone('utc', now());

  IF FOUND THEN
    SELECT message.* INTO v_message
    FROM public.whatsapp_message_events AS message
    WHERE message.organization_id = v_event.organization_id
      AND message.id::text = v_event.payload ->> 'message_id';

    IF FOUND THEN
      SELECT conversation.* INTO v_conversation
      FROM public.whatsapp_conversations AS conversation
      WHERE conversation.organization_id = v_event.organization_id
        AND conversation.id::text = v_event.payload ->> 'conversation_id'
        AND conversation.id = v_message.conversation_id
      FOR UPDATE;

      IF FOUND AND v_conversation.last_ai_processed_message_id IS NOT NULL THEN
        SELECT processed.created_at INTO v_processed_created_at
        FROM public.whatsapp_message_events AS processed
        WHERE processed.organization_id = v_event.organization_id
          AND processed.id = v_conversation.last_ai_processed_message_id;

        IF v_processed_created_at IS NOT NULL
          AND (v_message.created_at, v_message.id)
            < (v_processed_created_at, v_conversation.last_ai_processed_message_id) THEN
          RETURN QUERY SELECT 'stale', v_conversation.lead_id, NULL::uuid;
          RETURN;
        END IF;
      END IF;
    END IF;
  END IF;

  -- Preserve the existing kill-switch and low-confidence reply policy.
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

REVOKE ALL ON FUNCTION public.apply_whatsapp_ai_result_v1(uuid, text, text, jsonb, text, text, text, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.apply_whatsapp_ai_result_v1(uuid, text, text, jsonb, text, text, text, boolean) TO voya_outbox_worker, service_role;
