-- Keep accepted OpenWA images in the private inbox even when AI is disabled.
-- Media storage is its own leased outbox action; the AI worker may still read
-- the resulting ai-intake object, but this event never calls a model.

CREATE OR REPLACE FUNCTION public.enqueue_openwa_image_media_intake_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  IF NEW.message_type = 'image' AND NEW.media_status = 'pending'
    AND NEW.direction IN ('inbound', 'outbound')
    AND NEW.provider_media_id IS NOT NULL
    AND EXISTS (
      SELECT 1 FROM public.whatsapp_conversations AS conversation
      JOIN public.whatsapp_channels AS channel
        ON channel.organization_id = conversation.organization_id
       AND channel.id = conversation.channel_id
      WHERE conversation.organization_id = NEW.organization_id
        AND conversation.id = NEW.conversation_id
        AND channel.provider = 'openwa'
    ) THEN
    INSERT INTO public.outbox_events (
      organization_id, event_type, schema_version, dedupe_key, payload
    ) VALUES (
      NEW.organization_id,
      'whatsapp.media.store_requested',
      1,
      'whatsapp-media:' || NEW.id::text,
      jsonb_build_object('conversation_id', NEW.conversation_id, 'message_id', NEW.id)
    )
    ON CONFLICT (organization_id, event_type, dedupe_key) DO NOTHING;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER whatsapp_openwa_image_media_intake
AFTER INSERT ON public.whatsapp_message_events
FOR EACH ROW
EXECUTE FUNCTION public.enqueue_openwa_image_media_intake_v1();

CREATE OR REPLACE FUNCTION public.claim_outbox_delivery_events(
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
  IF p_worker_id IS NULL OR char_length(btrim(p_worker_id)) = 0 OR char_length(p_worker_id) > 120
    OR p_limit IS NULL OR p_limit < 1 OR p_limit > 20
    OR p_lease_seconds IS NULL OR p_lease_seconds < 1 OR p_lease_seconds > 900 THEN
    RAISE EXCEPTION 'outbox claim input is invalid' USING ERRCODE = '22023';
  END IF;
  UPDATE public.outbox_events AS event
  SET state = 'needs_review',
      locked_by = NULL,
      locked_until = NULL,
      last_error_code = 'worker_lease_expired_ambiguous'
  WHERE event.event_type = 'whatsapp.message.send_requested'
    AND event.state = 'processing'
    AND event.locked_until <= timezone('utc', now());

  RETURN QUERY
  WITH eligible AS (
    SELECT event.id
    FROM public.outbox_events AS event
    WHERE event.event_type IN (
      'organization.invitation.send_requested',
      'member.invitation.resent',
      'whatsapp.message.send_requested',
      'ai.run.requested',
      'ai.data_entry.requested',
      'whatsapp.ai.respond_requested',
      'whatsapp.media.store_requested'
    )
      AND (
        (event.state IN ('pending', 'retry_wait') AND event.available_at <= timezone('utc', now()))
        OR (event.state = 'processing' AND event.locked_until <= timezone('utc', now()))
      )
    ORDER BY CASE WHEN event.state = 'processing' THEN event.locked_until ELSE event.available_at END ASC,
             event.created_at ASC
    LIMIT p_limit
    FOR UPDATE SKIP LOCKED
  )
  UPDATE public.outbox_events AS event
  SET state = 'processing',
      attempts = event.attempts + 1,
      locked_by = p_worker_id,
      locked_until = timezone('utc', now()) + make_interval(secs => p_lease_seconds),
      last_error_code = NULL
  FROM eligible
  WHERE event.id = eligible.id
  RETURNING event.*;
END;
$$;

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
  UPDATE public.outbox_events
  SET locked_until = timezone('utc', now()) + make_interval(secs => p_lease_seconds)
  WHERE id = p_event_id
    AND event_type = 'whatsapp.media.store_requested'
    AND state = 'processing'
    AND locked_by = p_worker_id
    AND locked_until > timezone('utc', now());
  GET DIAGNOSTICS v_updated_count = ROW_COUNT;
  RETURN v_updated_count = 1;
END;
$$;

CREATE OR REPLACE FUNCTION public.resolve_whatsapp_media_intake_v1(
  p_event_id uuid,
  p_worker_id text
)
RETURNS TABLE (
  organization_id uuid,
  conversation_id uuid,
  message_id uuid,
  provider text,
  provider_channel_id text,
  chat_id text,
  provider_media_id text,
  mime_type_hint text,
  media_status text,
  channel_enabled boolean
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
  SELECT event.organization_id,
         conversation.id,
         message.id,
         channel.provider,
         channel.external_channel_id,
         conversation.external_conversation_key,
         message.provider_media_id,
         message.media_mime_hint,
         message.media_status,
         channel.status = 'active' AND channel.kill_switch = false
  FROM public.outbox_events AS event
  JOIN public.whatsapp_message_events AS message
    ON message.organization_id = event.organization_id
   AND message.id::text = event.payload ->> 'message_id'
   AND message.message_type = 'image'
   AND message.direction IN ('inbound', 'outbound')
   AND message.provider_media_id IS NOT NULL
   AND message.media_status IN ('pending', 'stored', 'failed')
  JOIN public.whatsapp_conversations AS conversation
    ON conversation.organization_id = event.organization_id
   AND conversation.id = message.conversation_id
   AND conversation.id::text = event.payload ->> 'conversation_id'
  JOIN public.whatsapp_channels AS channel
    ON channel.organization_id = event.organization_id
   AND channel.id = conversation.channel_id
   AND channel.provider = 'openwa'
  WHERE event.id = p_event_id
    AND event.event_type = 'whatsapp.media.store_requested'
    AND event.state = 'processing'
    AND event.locked_by = p_worker_id
    AND event.locked_until > timezone('utc', now());
$$;

-- Share the same path, MIME, checksum and size validation for AI and standalone
-- media events. The event lease is still server-worker owned in either case.
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
    OR p_mime_type NOT IN ('image/jpeg', 'image/png', 'image/webp')
    OR p_byte_size IS NULL OR p_byte_size NOT BETWEEN 1 AND 10485760
    OR p_checksum_sha256 IS NULL OR p_checksum_sha256 !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'WhatsApp media input is invalid' USING ERRCODE = '22023';
  END IF;

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
    AND message.media_status = 'pending';
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
    AND message.media_status = 'pending'
  FOR UPDATE;
  IF NOT FOUND THEN RETURN NULL; END IF;

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

REVOKE ALL ON FUNCTION public.claim_outbox_delivery_events(text, integer, integer) FROM PUBLIC, authenticated, anon;
REVOKE ALL ON FUNCTION public.renew_whatsapp_media_event_lease_v1(uuid, text, integer) FROM PUBLIC, authenticated, anon;
REVOKE ALL ON FUNCTION public.resolve_whatsapp_media_intake_v1(uuid, text) FROM PUBLIC, authenticated, anon;
GRANT EXECUTE ON FUNCTION public.claim_outbox_delivery_events(text, integer, integer) TO voya_outbox_worker, service_role;
GRANT EXECUTE ON FUNCTION public.renew_whatsapp_media_event_lease_v1(uuid, text, integer) TO voya_outbox_worker, service_role;
GRANT EXECUTE ON FUNCTION public.resolve_whatsapp_media_intake_v1(uuid, text) TO voya_outbox_worker, service_role;
REVOKE ALL ON FUNCTION public.fail_whatsapp_media_event_v1(uuid, text, uuid, text, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fail_whatsapp_media_event_v1(uuid, text, uuid, text, integer, integer) TO voya_outbox_worker, service_role;
