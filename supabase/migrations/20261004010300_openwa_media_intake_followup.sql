-- Preserve independent inbox media ownership, lease gating and rollout recovery.

CREATE OR REPLACE FUNCTION public.renew_whatsapp_media_event_lease_v1(
  p_event_id uuid,
  p_worker_id text,
  p_lease_seconds integer
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE v_updated_count integer;
BEGIN
  IF p_event_id IS NULL OR p_worker_id IS NULL
    OR char_length(btrim(p_worker_id)) NOT BETWEEN 1 AND 120
    OR p_lease_seconds IS NULL OR p_lease_seconds NOT BETWEEN 1 AND 900 THEN
    RAISE EXCEPTION 'WhatsApp media lease input is invalid' USING ERRCODE = '22023';
  END IF;
  UPDATE public.outbox_events AS event
  SET locked_until = timezone('utc', now()) + make_interval(secs => p_lease_seconds)
  WHERE id = p_event_id
    AND event_type = 'whatsapp.media.store_requested'
    AND state = 'processing'
    AND locked_by = p_worker_id
    AND locked_until > timezone('utc', now())
    AND EXISTS (
      SELECT 1 FROM public.whatsapp_message_events AS message
      JOIN public.whatsapp_conversations AS conversation
        ON conversation.organization_id = message.organization_id AND conversation.id = message.conversation_id
      JOIN public.whatsapp_channels AS channel
        ON channel.organization_id = conversation.organization_id AND channel.id = conversation.channel_id
      WHERE message.organization_id = event.organization_id
        AND message.id::text = event.payload ->> 'message_id'
        AND conversation.id::text = event.payload ->> 'conversation_id'
        AND channel.provider = 'openwa' AND channel.status = 'active' AND channel.kill_switch = false
    );
  GET DIAGNOSTICS v_updated_count = ROW_COUNT;
  RETURN v_updated_count = 1;
END;
$$;

CREATE OR REPLACE FUNCTION public.store_whatsapp_media_v1(
  p_event_id uuid,
  p_worker_id text,
  p_message_id uuid,
  p_storage_path text,
  p_mime_type text,
  p_byte_size bigint,
  p_checksum_sha256 text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_event public.outbox_events%ROWTYPE;
  v_message public.whatsapp_message_events%ROWTYPE;
  v_expected_path text;
  v_updated_count integer;
BEGIN
  IF p_event_id IS NULL OR p_message_id IS NULL
    OR p_worker_id IS NULL OR char_length(btrim(p_worker_id)) NOT BETWEEN 1 AND 120
    OR p_storage_path IS NULL OR p_storage_path <> lower(p_storage_path)
    OR p_mime_type IS NULL OR p_mime_type NOT IN ('image/jpeg', 'image/png', 'image/webp')
    OR p_byte_size IS NULL OR p_byte_size NOT BETWEEN 1 AND 10485760
    OR p_checksum_sha256 IS NULL OR p_checksum_sha256 !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'WhatsApp media input is invalid' USING ERRCODE = '22023';
  END IF;

  -- Serialize metadata registration with the channel kill switch. The channel
  -- is locked before the event/message to match inbound channel-first order.
  PERFORM channel.id
  FROM public.outbox_events AS event
  JOIN public.whatsapp_message_events AS message
    ON message.organization_id = event.organization_id AND message.id = p_message_id
  JOIN public.whatsapp_conversations AS conversation
    ON conversation.organization_id = message.organization_id AND conversation.id = message.conversation_id
  JOIN public.whatsapp_channels AS channel
    ON channel.organization_id = conversation.organization_id AND channel.id = conversation.channel_id
  WHERE event.id = p_event_id
    AND channel.status = 'active' AND channel.kill_switch = false
  FOR SHARE OF channel;
  IF NOT FOUND THEN RETURN false; END IF;

  SELECT event.* INTO v_event
  FROM public.outbox_events AS event
  WHERE event.id = p_event_id
    AND event.event_type IN ('whatsapp.ai.respond_requested', 'whatsapp.media.store_requested')
    AND event.state = 'processing'
    AND event.locked_by = p_worker_id
    AND event.locked_until > timezone('utc', now())
  FOR UPDATE;
  IF NOT FOUND OR (v_event.payload ->> 'message_id')::uuid IS DISTINCT FROM p_message_id THEN
    RETURN false;
  END IF;
  IF v_event.event_type = 'whatsapp.media.store_requested' AND NOT EXISTS (
    SELECT 1
    FROM public.whatsapp_message_events AS message
    JOIN public.whatsapp_conversations AS conversation
      ON conversation.organization_id = message.organization_id AND conversation.id = message.conversation_id
    JOIN public.whatsapp_channels AS channel
      ON channel.organization_id = conversation.organization_id AND channel.id = conversation.channel_id
    WHERE message.organization_id = v_event.organization_id AND message.id = p_message_id
      AND channel.provider = 'openwa' AND channel.status = 'active' AND channel.kill_switch = false
  ) THEN
    RETURN false;
  END IF;

  SELECT message.* INTO v_message
  FROM public.whatsapp_message_events AS message
  WHERE message.organization_id = v_event.organization_id
    AND message.id = p_message_id
    AND message.message_type = 'image'
  FOR UPDATE;
  IF NOT FOUND THEN RETURN false; END IF;
  IF v_message.media_status = 'stored' THEN
    RETURN v_message.media_storage_bucket = 'ai-intake'
      AND v_message.media_storage_path = p_storage_path
      AND v_message.media_mime_hint IS NOT DISTINCT FROM p_mime_type
      AND v_message.media_byte_size = p_byte_size
      AND v_message.media_checksum_sha256 = p_checksum_sha256;
  END IF;
  IF v_message.media_status <> 'pending' THEN RETURN false; END IF;

  v_expected_path := v_event.organization_id::text || '/' || v_message.conversation_id::text || '/' || p_message_id::text ||
    CASE p_mime_type WHEN 'image/jpeg' THEN '.jpg' WHEN 'image/png' THEN '.png' ELSE '.webp' END;
  IF p_storage_path <> v_expected_path
    OR p_storage_path !~ '^[0-9a-f-]{36}/[0-9a-f-]{36}/[0-9a-f-]{36}[.](jpg|png|webp)$' THEN
    RAISE EXCEPTION 'WhatsApp media storage path is invalid' USING ERRCODE = '22023';
  END IF;
  IF v_message.media_mime_hint IS NOT NULL AND v_message.media_mime_hint <> p_mime_type THEN
    RAISE EXCEPTION 'WhatsApp media MIME does not match webhook hint' USING ERRCODE = '22023';
  END IF;

  UPDATE public.whatsapp_message_events
  SET media_status = 'stored',
      media_mime_hint = p_mime_type,
      media_storage_bucket = 'ai-intake',
      media_storage_path = p_storage_path,
      media_byte_size = p_byte_size,
      media_checksum_sha256 = p_checksum_sha256,
      media_error_code = NULL,
      media_stored_at = timezone('utc', now())
  WHERE organization_id = v_event.organization_id
    AND id = p_message_id
    AND media_status = 'pending';
  GET DIAGNOSTICS v_updated_count = ROW_COUNT;
  RETURN v_updated_count = 1;
END;
$$;

CREATE OR REPLACE FUNCTION public.fail_whatsapp_media_v1(
  p_event_id uuid,
  p_worker_id text,
  p_message_id uuid,
  p_error_code text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE v_updated_count integer;
BEGIN
  IF p_event_id IS NULL OR p_message_id IS NULL
    OR p_worker_id IS NULL OR char_length(btrim(p_worker_id)) NOT BETWEEN 1 AND 120
    OR p_error_code IS NULL OR p_error_code !~ '^[a-z][a-z0-9_.-]{0,119}$' THEN
    RAISE EXCEPTION 'WhatsApp media failure input is invalid' USING ERRCODE = '22023';
  END IF;
  UPDATE public.whatsapp_message_events AS message
  SET media_status = 'failed', media_error_code = p_error_code
  FROM public.outbox_events AS event
  WHERE event.id = p_event_id
    AND event.organization_id = message.organization_id
    AND event.event_type IN ('whatsapp.ai.respond_requested', 'whatsapp.media.store_requested')
    AND event.state = 'processing'
    AND event.locked_by = p_worker_id
    AND event.locked_until > timezone('utc', now())
    AND (event.payload ->> 'message_id')::uuid = p_message_id
    AND message.id = p_message_id
    AND message.message_type = 'image'
    AND message.media_status = 'pending'
    -- Standalone intake owns the inbox outcome when present. AI failure may
    -- finish the AI run, but cannot cancel a separate download/retry.
    AND NOT EXISTS (
      SELECT 1 FROM public.outbox_events AS media_event
      WHERE media_event.organization_id = message.organization_id
        AND media_event.event_type = 'whatsapp.media.store_requested'
        AND media_event.payload ->> 'message_id' = message.id::text
    );
  GET DIAGNOSTICS v_updated_count = ROW_COUNT;
  RETURN v_updated_count = 1;
END;
$$;

CREATE OR REPLACE FUNCTION public.fail_whatsapp_media_event_v1(
  p_event_id uuid,
  p_worker_id text,
  p_message_id uuid,
  p_error_code text,
  p_retry_after_seconds integer,
  p_max_attempts integer
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_event public.outbox_events%ROWTYPE;
  v_message public.whatsapp_message_events%ROWTYPE;
  v_next_state text;
  v_updated_count integer;
BEGIN
  IF p_event_id IS NULL OR p_message_id IS NULL
    OR p_worker_id IS NULL OR char_length(btrim(p_worker_id)) NOT BETWEEN 1 AND 120
    OR p_error_code IS NULL OR p_error_code !~ '^[a-z][a-z0-9_.-]{0,119}$'
    OR p_retry_after_seconds IS NULL OR p_retry_after_seconds NOT BETWEEN 1 AND 86400
    OR p_max_attempts IS NULL OR p_max_attempts NOT BETWEEN 1 AND 20 THEN
    RAISE EXCEPTION 'WhatsApp media event failure input is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT event.* INTO v_event
  FROM public.outbox_events AS event
  WHERE event.id = p_event_id
    AND event.event_type = 'whatsapp.media.store_requested'
    AND event.state = 'processing'
    AND event.locked_by = p_worker_id
    AND event.locked_until > timezone('utc', now())
  FOR UPDATE;
  IF NOT FOUND OR (v_event.payload ->> 'message_id')::uuid IS DISTINCT FROM p_message_id THEN
    RETURN NULL;
  END IF;

  SELECT message.* INTO v_message
  FROM public.whatsapp_message_events AS message
  WHERE message.organization_id = v_event.organization_id
    AND message.id = p_message_id
    AND message.message_type = 'image'
    AND message.media_status IN ('pending', 'stored', 'failed')
  FOR UPDATE;
  IF NOT FOUND THEN RETURN NULL; END IF;

  -- A peer can commit storage after this worker's context was resolved.
  -- Settle the lease without turning successful media into a retry/review.
  IF v_message.media_status IN ('stored', 'failed') THEN
    UPDATE public.outbox_events
    SET state = 'completed', locked_by = NULL, locked_until = NULL, last_error_code = NULL
    WHERE id = p_event_id;
    RETURN 'completed';
  END IF;

  v_next_state := CASE WHEN v_event.attempts >= p_max_attempts THEN 'dead_letter' ELSE 'retry_wait' END;
  IF v_next_state = 'dead_letter' THEN
    UPDATE public.whatsapp_message_events
    SET media_status = 'failed', media_error_code = p_error_code
    WHERE organization_id = v_event.organization_id AND id = p_message_id AND media_status = 'pending';
    GET DIAGNOSTICS v_updated_count = ROW_COUNT;
    IF v_updated_count <> 1 THEN
      RAISE EXCEPTION 'WhatsApp media terminal transition changed concurrently' USING ERRCODE = '40001';
    END IF;
  END IF;

  UPDATE public.outbox_events
  SET state = v_next_state,
      available_at = CASE WHEN v_next_state = 'retry_wait'
        THEN timezone('utc', now()) + make_interval(secs => p_retry_after_seconds)
        ELSE available_at END,
      locked_by = NULL,
      locked_until = NULL,
      last_error_code = p_error_code
  WHERE id = p_event_id
    AND state = 'processing'
    AND locked_by = p_worker_id
    AND locked_until > timezone('utc', now());
  GET DIAGNOSTICS v_updated_count = ROW_COUNT;
  IF v_updated_count <> 1 THEN
    RAISE EXCEPTION 'WhatsApp media outbox transition lost its lease' USING ERRCODE = '40001';
  END IF;
  RETURN v_next_state;
END;
$$;

-- Images accepted before the INSERT trigger was deployed still need inbox
-- storage. A repeat application never resets terminal outcomes or AI flags.
INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload)
SELECT message.organization_id, 'whatsapp.media.store_requested', 1,
       'whatsapp-media:' || message.id::text,
       jsonb_build_object('conversation_id', message.conversation_id, 'message_id', message.id)
FROM public.whatsapp_message_events AS message
JOIN public.whatsapp_conversations AS conversation
  ON conversation.organization_id = message.organization_id AND conversation.id = message.conversation_id
JOIN public.whatsapp_channels AS channel
  ON channel.organization_id = conversation.organization_id AND channel.id = conversation.channel_id
WHERE message.message_type = 'image' AND message.media_status = 'pending'
  AND message.direction IN ('inbound', 'outbound') AND message.provider_media_id IS NOT NULL
  AND channel.provider = 'openwa'
ON CONFLICT (organization_id, event_type, dedupe_key) DO NOTHING;
