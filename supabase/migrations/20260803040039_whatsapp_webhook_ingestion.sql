-- Voya OS: signed Meta inbound events enter the provider-neutral inbox.
-- The function stores no raw provider payload and never creates outbound work.

CREATE OR REPLACE FUNCTION public.ingest_whatsapp_webhook_event(
  p_provider text,
  p_external_channel_id text,
  p_external_conversation_key text,
  p_event_key text,
  p_sender_phone text,
  p_body_text text,
  p_received_at timestamptz DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_channel public.whatsapp_channels%ROWTYPE;
  v_conversation public.whatsapp_conversations%ROWTYPE;
  v_existing public.whatsapp_message_events%ROWTYPE;
  v_message_id uuid;
  v_received_at timestamptz := coalesce(p_received_at, timezone('utc', now()));
BEGIN
  IF p_provider IS NULL OR p_provider !~ '^[a-z][a-z0-9_.-]{0,79}$'
    OR p_external_channel_id IS NULL OR char_length(btrim(p_external_channel_id)) NOT BETWEEN 1 AND 256
    OR p_external_conversation_key IS NULL OR char_length(btrim(p_external_conversation_key)) NOT BETWEEN 1 AND 256
    OR p_event_key IS NULL OR char_length(btrim(p_event_key)) NOT BETWEEN 1 AND 320
    OR p_sender_phone IS NULL OR char_length(btrim(p_sender_phone)) NOT BETWEEN 1 AND 80
    OR p_body_text IS NULL OR char_length(btrim(p_body_text)) NOT BETWEEN 1 AND 4096 THEN
    RAISE EXCEPTION 'webhook event input is invalid' USING ERRCODE = '22023';
  END IF;
  IF v_received_at < timezone('utc', now()) - interval '30 days'
    OR v_received_at > timezone('utc', now()) + interval '10 minutes' THEN
    v_received_at := timezone('utc', now());
  END IF;

  SELECT channel.* INTO v_channel
  FROM public.whatsapp_channels AS channel
  WHERE channel.provider = btrim(p_provider)
    AND channel.external_channel_id = btrim(p_external_channel_id)
    AND channel.status = 'active'
    AND channel.kill_switch = false
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'webhook channel is unavailable' USING ERRCODE = '42501';
  END IF;

  SELECT message.* INTO v_existing
  FROM public.whatsapp_message_events AS message
  WHERE message.organization_id = v_channel.organization_id
    AND message.event_key = btrim(p_event_key);
  IF FOUND THEN RETURN v_existing.id; END IF;

  SELECT conversation.* INTO v_conversation
  FROM public.whatsapp_conversations AS conversation
  WHERE conversation.organization_id = v_channel.organization_id
    AND conversation.channel_id = v_channel.id
    AND conversation.external_conversation_key = btrim(p_external_conversation_key)
  FOR UPDATE;

  IF NOT FOUND THEN
    INSERT INTO public.whatsapp_conversations (
      organization_id, channel_id, external_conversation_key, status, last_message_at
    ) VALUES (
      v_channel.organization_id, v_channel.id, btrim(p_external_conversation_key), 'open', v_received_at
    )
    ON CONFLICT (organization_id, channel_id, external_conversation_key) DO UPDATE
      SET last_message_at = EXCLUDED.last_message_at
    RETURNING * INTO v_conversation;
  END IF;

  INSERT INTO public.whatsapp_message_events (
    organization_id, conversation_id, event_key, direction, body_text,
    delivery_status, created_at, idempotency_key
  ) VALUES (
    v_channel.organization_id, v_conversation.id, btrim(p_event_key), 'inbound', btrim(p_body_text),
    'received', v_received_at, 'provider:' || btrim(p_event_key)
  )
  ON CONFLICT (organization_id, event_key) DO NOTHING
  RETURNING id INTO v_message_id;

  IF v_message_id IS NULL THEN
    SELECT message.id INTO v_message_id
    FROM public.whatsapp_message_events AS message
    WHERE message.organization_id = v_channel.organization_id
      AND message.event_key = btrim(p_event_key);
  END IF;

  UPDATE public.whatsapp_conversations
  SET last_message_at = greatest(coalesce(last_message_at, v_received_at), v_received_at), status = CASE WHEN status = 'closed' THEN 'open' ELSE status END
  WHERE id = v_conversation.id AND organization_id = v_channel.organization_id;

  INSERT INTO public.audit_events (
    organization_id, actor_type, action, resource_type, resource_id, outcome, after_delta
  ) VALUES (
    v_channel.organization_id, 'system', 'whatsapp.webhook.received', 'whatsapp_message_event', v_message_id, 'success',
    jsonb_build_object('provider', p_provider, 'channel_id', v_channel.id, 'direction', 'inbound')
  ) ON CONFLICT DO NOTHING;
  RETURN v_message_id;
END;
$$;

REVOKE ALL ON FUNCTION public.ingest_whatsapp_webhook_event(text, text, text, text, text, text, timestamptz) FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA public TO service_role;
GRANT EXECUTE ON FUNCTION public.ingest_whatsapp_webhook_event(text, text, text, text, text, text, timestamptz) TO service_role;
;

