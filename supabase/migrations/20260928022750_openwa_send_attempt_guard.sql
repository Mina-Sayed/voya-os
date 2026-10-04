-- OpenWA does not deduplicate outbound sends by VOYA's outbox event ID. Mark the
-- exact leased event before the HTTP request so a worker crash cannot repeat it.
ALTER TABLE public.outbox_events
  ADD COLUMN openwa_send_started_at timestamptz;

CREATE FUNCTION public.begin_openwa_send_attempt_v1(p_event_id uuid, p_worker_id text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_updated integer;
BEGIN
  IF p_event_id IS NULL OR p_worker_id IS NULL
    OR char_length(btrim(p_worker_id)) NOT BETWEEN 1 AND 120 THEN
    RAISE EXCEPTION 'OpenWA send attempt identity is invalid' USING ERRCODE = '22023';
  END IF;

  UPDATE public.outbox_events AS event
  SET openwa_send_started_at = timezone('utc', now())
  WHERE event.id = p_event_id
    AND event.event_type = 'whatsapp.message.send_requested'
    AND event.state = 'processing'
    AND event.locked_by = p_worker_id
    AND event.locked_until > timezone('utc', now())
    AND event.openwa_send_started_at IS NULL
    AND EXISTS (
      SELECT 1
      FROM public.whatsapp_message_events AS message
      JOIN public.whatsapp_conversations AS conversation
        ON conversation.organization_id = message.organization_id
       AND conversation.id = message.conversation_id
       AND conversation.id::text = event.payload ->> 'conversation_id'
      JOIN public.whatsapp_channels AS channel
        ON channel.organization_id = conversation.organization_id
       AND channel.id = conversation.channel_id
      WHERE message.organization_id = event.organization_id
        AND message.id = CASE
          WHEN event.payload ->> 'message_id' ~ '^[0-9a-fA-F-]{36}$'
            THEN (event.payload ->> 'message_id')::uuid
          ELSE NULL::uuid
        END
        AND message.direction = 'outbound'
        AND message.delivery_status = 'queued'
        AND channel.provider = 'openwa'
        AND channel.status = 'active'
        AND channel.kill_switch = false
        AND conversation.external_conversation_key ~ '^[A-Za-z0-9._:-]{1,250}@(c[.]us|lid)$'
    );
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RETURN v_updated = 1;
END;
$$;

-- Only a definite pre-send refusal may clear the mark. The worker never calls
-- this after an accepted, ambiguous, or permanent provider result.
CREATE FUNCTION public.clear_openwa_send_attempt_v1(p_event_id uuid, p_worker_id text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_updated integer;
BEGIN
  IF p_event_id IS NULL OR p_worker_id IS NULL
    OR char_length(btrim(p_worker_id)) NOT BETWEEN 1 AND 120 THEN
    RAISE EXCEPTION 'OpenWA send attempt identity is invalid' USING ERRCODE = '22023';
  END IF;

  UPDATE public.outbox_events AS event
  SET openwa_send_started_at = NULL
  WHERE event.id = p_event_id
    AND event.event_type = 'whatsapp.message.send_requested'
    AND event.state = 'processing'
    AND event.locked_by = p_worker_id
    AND event.locked_until > timezone('utc', now())
    AND event.openwa_send_started_at IS NOT NULL
    AND EXISTS (
      SELECT 1
      FROM public.whatsapp_message_events AS message
      JOIN public.whatsapp_conversations AS conversation
        ON conversation.organization_id = message.organization_id
       AND conversation.id = message.conversation_id
      JOIN public.whatsapp_channels AS channel
        ON channel.organization_id = conversation.organization_id
       AND channel.id = conversation.channel_id
      WHERE message.organization_id = event.organization_id
        AND message.id = CASE
          WHEN event.payload ->> 'message_id' ~ '^[0-9a-fA-F-]{36}$'
            THEN (event.payload ->> 'message_id')::uuid
          ELSE NULL::uuid
        END
        AND conversation.id::text = event.payload ->> 'conversation_id'
        AND message.direction = 'outbound'
        AND channel.provider = 'openwa'
    );
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RETURN v_updated = 1;
END;
$$;

REVOKE ALL ON FUNCTION public.begin_openwa_send_attempt_v1(uuid, text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.clear_openwa_send_attempt_v1(uuid, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.begin_openwa_send_attempt_v1(uuid, text)
  TO voya_outbox_worker, service_role;
GRANT EXECUTE ON FUNCTION public.clear_openwa_send_attempt_v1(uuid, text)
  TO voya_outbox_worker, service_role;
