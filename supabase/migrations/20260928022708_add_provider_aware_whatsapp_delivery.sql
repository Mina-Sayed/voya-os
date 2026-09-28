-- Provider-aware WhatsApp delivery keeps the worker destination tenant-derived.
-- OpenWA remains gated in worker configuration and the channel/lease RPCs.

CREATE OR REPLACE FUNCTION public.resolve_whatsapp_outbox_delivery_v2(
  p_event_id uuid,
  p_worker_id text
)
RETURNS TABLE (
  provider text,
  provider_channel_id text,
  chat_id text,
  recipient_phone text,
  body_text text,
  message_id uuid
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  IF p_event_id IS NULL
    OR p_worker_id IS NULL
    OR char_length(btrim(p_worker_id)) NOT BETWEEN 1 AND 120 THEN
    RAISE EXCEPTION 'worker delivery context is invalid' USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  SELECT channel.provider,
         channel.external_channel_id,
         conversation.external_conversation_key,
         CASE WHEN channel.provider IN ('meta_cloud', 'meta_cloud_sandbox')
           THEN contact.normalized_value ELSE NULL END,
         message.body_text,
         message.id
  FROM public.outbox_events AS event
  JOIN public.whatsapp_message_events AS message
    ON message.id = (event.payload ->> 'message_id')::uuid
   AND message.organization_id = event.organization_id
   AND message.direction = 'outbound'
   AND message.delivery_status = 'queued'
  JOIN public.whatsapp_conversations AS conversation
    ON conversation.id = message.conversation_id
   AND conversation.organization_id = event.organization_id
   AND event.payload ->> 'conversation_id' = conversation.id::text
  JOIN public.whatsapp_channels AS channel
    ON channel.id = conversation.channel_id
   AND channel.organization_id = event.organization_id
  LEFT JOIN public.crm_contact_methods AS contact
    ON contact.id = conversation.contact_method_id
   AND contact.organization_id = event.organization_id
   AND contact.kind = 'whatsapp'
  WHERE event.id = p_event_id
    AND event.event_type = 'whatsapp.message.send_requested'
    AND event.state = 'processing'
    AND event.locked_by = p_worker_id
    AND event.locked_until > timezone('utc', now())
    AND channel.provider IN ('meta_cloud', 'meta_cloud_sandbox', 'openwa')
    AND channel.status = 'active'
    AND channel.kill_switch = false
    AND char_length(btrim(conversation.external_conversation_key)) BETWEEN 1 AND 256
    AND (
      (channel.provider IN ('meta_cloud', 'meta_cloud_sandbox')
        AND contact.normalized_value ~ '^\+?[1-9][0-9]{6,14}$')
      OR (channel.provider = 'openwa'
        AND conversation.external_conversation_key ~ '^[A-Za-z0-9._:-]{1,250}@(c[.]us|lid)$')
    )
  FOR SHARE OF channel;
END;
$$;

REVOKE ALL ON FUNCTION public.resolve_whatsapp_outbox_delivery_v2(uuid, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_whatsapp_outbox_delivery_v2(uuid, text)
  TO voya_outbox_worker, service_role;

CREATE OR REPLACE FUNCTION public.mark_whatsapp_message_sent_v2(
  p_event_id uuid,
  p_worker_id text,
  p_provider_message_id text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_organization_id uuid;
  v_channel_id uuid;
  v_provider text;
  v_conversation_id uuid;
  v_message public.whatsapp_message_events%ROWTYPE;
  v_echo public.whatsapp_message_events%ROWTYPE;
  v_duplicate_echo_ids uuid[] := ARRAY[]::uuid[];
  v_deleted_echo_count integer;
  v_updated_count integer;
BEGIN
  IF p_event_id IS NULL
    OR p_worker_id IS NULL OR char_length(btrim(p_worker_id)) NOT BETWEEN 1 AND 120
    OR p_provider_message_id IS NULL
    OR char_length(p_provider_message_id) NOT BETWEEN 1 AND 320
    OR p_provider_message_id IS DISTINCT FROM btrim(p_provider_message_id) THEN
    RAISE EXCEPTION 'WhatsApp delivery marker input is invalid' USING ERRCODE = '22023';
  END IF;

  -- Lock the channel first, matching OpenWA ingestion's channel-before-
  -- conversation order. The lock is taken even if a kill switch changed after
  -- dispatch, because a completed provider send still needs accurate evidence.
  SELECT channel.organization_id, channel.id, channel.provider, conversation.id
    INTO v_organization_id, v_channel_id, v_provider, v_conversation_id
  FROM public.outbox_events AS event
  JOIN public.whatsapp_message_events AS message
    ON message.id = (event.payload ->> 'message_id')::uuid
   AND message.organization_id = event.organization_id
   AND message.direction = 'outbound'
  JOIN public.whatsapp_conversations AS conversation
    ON conversation.id = message.conversation_id
   AND conversation.organization_id = event.organization_id
   AND event.payload ->> 'conversation_id' = conversation.id::text
  JOIN public.whatsapp_channels AS channel
    ON channel.id = conversation.channel_id
   AND channel.organization_id = event.organization_id
  WHERE event.id = p_event_id
    AND event.event_type = 'whatsapp.message.send_requested'
    AND event.state = 'processing'
    AND event.locked_by = p_worker_id
    AND event.locked_until > timezone('utc', now())
    AND channel.provider IN ('meta_cloud', 'meta_cloud_sandbox', 'openwa')
  FOR SHARE OF channel;
  IF NOT FOUND THEN
    RETURN false;
  END IF;

  PERFORM conversation.id
  FROM public.whatsapp_conversations AS conversation
  WHERE conversation.organization_id = v_organization_id
    AND conversation.channel_id = v_channel_id
    AND conversation.id = v_conversation_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN false;
  END IF;

  SELECT message.* INTO v_message
  FROM public.outbox_events AS event
  JOIN public.whatsapp_message_events AS message
    ON message.id = (event.payload ->> 'message_id')::uuid
   AND message.organization_id = event.organization_id
   AND message.conversation_id = v_conversation_id
   AND message.direction = 'outbound'
  WHERE event.id = p_event_id
    AND event.event_type = 'whatsapp.message.send_requested'
    AND event.state = 'processing'
    AND event.locked_by = p_worker_id
    AND event.locked_until > timezone('utc', now())
    AND event.organization_id = v_organization_id
    AND event.payload ->> 'conversation_id' = v_conversation_id::text
    AND message.delivery_status IN ('queued', 'sent')
  FOR UPDATE OF message;
  IF NOT FOUND THEN
    RETURN false;
  END IF;
  IF v_message.provider_message_id IS NOT NULL
    AND v_message.provider_message_id IS DISTINCT FROM p_provider_message_id THEN
    RETURN false;
  END IF;

  IF v_provider = 'openwa' THEN
    SELECT echo.* INTO v_echo
    FROM public.whatsapp_message_events AS echo
    WHERE echo.organization_id = v_organization_id
      AND echo.conversation_id = v_conversation_id
      AND echo.direction = 'outbound'
      AND echo.delivery_status = 'sent'
      AND echo.provider_message_id = p_provider_message_id
      AND echo.event_key LIKE 'openwa:%'
      AND echo.id <> v_message.id
    LIMIT 1
    FOR UPDATE;
  END IF;

  UPDATE public.whatsapp_message_events AS canonical
  SET body_text = CASE WHEN v_echo.id IS NOT NULL THEN v_echo.body_text ELSE canonical.body_text END,
      delivery_status = 'sent',
      provider_message_id = p_provider_message_id,
      sent_at = coalesce(canonical.sent_at, timezone('utc', now())),
      failed_at = NULL,
      provider_error_code = NULL
  WHERE canonical.organization_id = v_organization_id
    AND canonical.conversation_id = v_conversation_id
    AND canonical.id = v_message.id
    AND canonical.direction = 'outbound'
    AND (canonical.provider_message_id IS NULL OR canonical.provider_message_id = p_provider_message_id);
  GET DIAGNOSTICS v_updated_count = ROW_COUNT;
  IF v_updated_count <> 1 THEN
    RETURN false;
  END IF;

  IF v_provider = 'openwa' THEN
    SELECT coalesce(array_agg(echo.id ORDER BY echo.id), ARRAY[]::uuid[])
      INTO v_duplicate_echo_ids
    FROM public.whatsapp_message_events AS echo
    WHERE echo.organization_id = v_organization_id
      AND echo.conversation_id = v_conversation_id
      AND echo.direction = 'outbound'
      AND echo.delivery_status = 'sent'
      AND echo.provider_message_id = p_provider_message_id
      AND echo.event_key LIKE 'openwa:%'
      AND echo.id <> v_message.id;

    DELETE FROM public.whatsapp_message_events AS echo
    WHERE echo.organization_id = v_organization_id
      AND echo.conversation_id = v_conversation_id
      AND echo.direction = 'outbound'
      AND echo.delivery_status = 'sent'
      AND echo.provider_message_id = p_provider_message_id
      AND echo.event_key LIKE 'openwa:%'
      AND echo.id <> v_message.id;
    GET DIAGNOSTICS v_deleted_echo_count = ROW_COUNT;
    IF v_deleted_echo_count <> cardinality(v_duplicate_echo_ids) THEN
      RAISE EXCEPTION 'OpenWA echo reconciliation changed during deletion' USING ERRCODE = '40001';
    END IF;

    IF cardinality(v_duplicate_echo_ids) > 0 THEN
      INSERT INTO public.audit_events (
        organization_id, actor_type, action, resource_type, resource_id,
        outcome, after_delta
      ) VALUES (
        v_organization_id, 'system', 'whatsapp.openwa.echo.reconciled',
        'whatsapp_message_event', v_message.id, 'success',
        jsonb_build_object(
          'provider', 'openwa',
          'channel_id', v_channel_id,
          'direction', 'outbound',
          'provider_message_id', p_provider_message_id,
          'canonical_message_id', v_message.id,
          'duplicate_echo_id', v_echo.id,
          'duplicate_echo_ids', to_jsonb(v_duplicate_echo_ids)
        )
      );
    END IF;
  END IF;

  UPDATE public.whatsapp_conversations AS conversation
  SET last_message_at = greatest(coalesce(conversation.last_message_at, timezone('utc', now())), timezone('utc', now()))
  WHERE conversation.organization_id = v_organization_id
    AND conversation.channel_id = v_channel_id
    AND conversation.id = v_conversation_id;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.mark_whatsapp_message_sent_v2(uuid, text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mark_whatsapp_message_sent_v2(uuid, text, text)
  TO voya_outbox_worker, service_role;

-- Recheck channel status and its kill switch at the final worker lease renewal
-- for a destination-bearing WhatsApp event. Legacy/incomplete event fixtures
-- without message_id retain the existing generic lease-renewal behavior; the
-- dispatcher cannot send them because resolve_v2 returns no context.
CREATE OR REPLACE FUNCTION public.renew_outbox_delivery_lease_v1(
  p_event_id uuid,
  p_worker_id text,
  p_lease_seconds integer DEFAULT 300
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_count integer;
  v_channel_id uuid;
BEGIN
  IF p_event_id IS NULL
    OR p_worker_id IS NULL OR char_length(btrim(p_worker_id)) = 0 OR char_length(p_worker_id) > 120
    OR p_lease_seconds IS NULL OR p_lease_seconds < 1 OR p_lease_seconds > 900 THEN
    RAISE EXCEPTION 'outbox delivery lease renewal input is invalid' USING ERRCODE = '22023';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.outbox_events AS event
    WHERE event.id = p_event_id
      AND event.event_type = 'whatsapp.message.send_requested'
      AND event.payload ? 'message_id'
  ) THEN
    SELECT channel.id INTO v_channel_id
    FROM public.outbox_events AS event
    JOIN public.whatsapp_message_events AS message
      ON message.id = (event.payload ->> 'message_id')::uuid
     AND message.organization_id = event.organization_id
     AND message.direction = 'outbound'
     AND message.delivery_status = 'queued'
    JOIN public.whatsapp_conversations AS conversation
      ON conversation.id = message.conversation_id
     AND conversation.organization_id = event.organization_id
     AND event.payload ->> 'conversation_id' = conversation.id::text
    JOIN public.whatsapp_channels AS channel
      ON channel.id = conversation.channel_id
     AND channel.organization_id = event.organization_id
    LEFT JOIN public.crm_contact_methods AS contact
      ON contact.id = conversation.contact_method_id
     AND contact.organization_id = event.organization_id
     AND contact.kind = 'whatsapp'
    WHERE event.id = p_event_id
      AND event.state = 'processing'
      AND event.locked_by = p_worker_id
      AND event.locked_until > timezone('utc', now())
      AND channel.provider IN ('meta_cloud', 'meta_cloud_sandbox', 'openwa')
      AND channel.status = 'active'
      AND channel.kill_switch = false
      AND (
        (channel.provider IN ('meta_cloud', 'meta_cloud_sandbox')
          AND contact.normalized_value ~ '^\+?[1-9][0-9]{6,14}$')
        OR (channel.provider = 'openwa'
          AND conversation.external_conversation_key ~ '^[A-Za-z0-9._:-]{1,250}@(c[.]us|lid)$')
      )
    FOR SHARE OF channel;
    IF NOT FOUND THEN
      RETURN false;
    END IF;
  END IF;

  UPDATE public.outbox_events AS event
  SET locked_until = timezone('utc', now()) + make_interval(secs => p_lease_seconds)
  WHERE event.id = p_event_id
    AND event.event_type IN (
      'organization.invitation.send_requested',
      'member.invitation.resent',
      'whatsapp.message.send_requested'
    )
    AND event.state = 'processing'
    AND event.locked_by = p_worker_id
    AND event.locked_until > timezone('utc', now());
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count = 1;
END;
$$;

REVOKE ALL ON FUNCTION public.renew_outbox_delivery_lease_v1(uuid, text, integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.renew_outbox_delivery_lease_v1(uuid, text, integer)
  TO voya_outbox_worker, service_role;

-- Preserve Task 2's signed ingest RPC signature and execution boundary while
-- making a late message.sent echo update its exact canonical outbound row.
CREATE OR REPLACE FUNCTION public.ingest_whatsapp_openwa_event_v1(
  p_external_channel_id text,
  p_chat_id text,
  p_event_key text,
  p_provider_message_id text,
  p_contact_jid text,
  p_contact_phone text,
  p_contact_display text,
  p_direction text,
  p_message_type text,
  p_body_text text,
  p_provider_media_id text,
  p_media_mime_hint text,
  p_caption text,
  p_received_at timestamptz
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
  v_contact_method_id uuid;
  v_existing_contact_id uuid;
  v_message_id uuid;
  v_run_id uuid;
  v_external_channel_id text := NULLIF(btrim(p_external_channel_id), '');
  v_chat_id text := NULLIF(btrim(p_chat_id), '');
  v_event_key text := NULLIF(btrim(p_event_key), '');
  v_provider_message_id text := NULLIF(btrim(p_provider_message_id), '');
  v_contact_jid text := NULLIF(btrim(p_contact_jid), '');
  v_contact_phone text := NULLIF(btrim(p_contact_phone), '');
  v_contact_display text := NULLIF(btrim(p_contact_display), '');
  v_received_at timestamptz := coalesce(p_received_at, timezone('utc', now()));
  v_contact_identity text;
  v_contact_idempotency text;
  v_body_text text;
  v_caption text := NULLIF(btrim(p_caption), '');
  v_mime_hint text := NULLIF(lower(btrim(p_media_mime_hint)), '');
BEGIN
  IF p_direction IS NULL OR p_direction NOT IN ('inbound', 'outbound') THEN
    RAISE EXCEPTION 'OpenWA event direction is invalid' USING ERRCODE = '22023';
  END IF;
  IF v_external_channel_id IS NULL OR char_length(v_external_channel_id) NOT BETWEEN 1 AND 256
    OR p_external_channel_id IS DISTINCT FROM v_external_channel_id
    OR v_chat_id IS NULL OR char_length(v_chat_id) NOT BETWEEN 1 AND 256
    OR p_chat_id IS DISTINCT FROM v_chat_id
    OR v_event_key IS NULL OR char_length(v_event_key) NOT BETWEEN 1 AND 320
    OR p_event_key IS DISTINCT FROM v_event_key
    OR v_provider_message_id IS NULL OR char_length(v_provider_message_id) NOT BETWEEN 1 AND 320
    OR p_provider_message_id IS DISTINCT FROM v_provider_message_id
    OR v_contact_jid IS NULL OR char_length(v_contact_jid) NOT BETWEEN 1 AND 256
    OR p_contact_jid IS DISTINCT FROM v_contact_jid
    OR v_contact_jid <> v_chat_id
    OR v_contact_jid !~ '^[A-Za-z0-9._:-]{1,250}@(c[.]us|lid)$'
    OR (p_contact_phone IS NOT NULL AND (v_contact_phone IS NULL OR v_contact_phone !~ '^[0-9]{7,15}$'))
    OR p_contact_phone IS DISTINCT FROM v_contact_phone
    OR (v_contact_phone IS NOT NULL AND v_contact_jid LIKE '%@c.us'
      AND v_contact_phone <> split_part(v_contact_jid, '@', 1))
    OR (p_contact_display IS NOT NULL AND (v_contact_display IS NULL OR char_length(v_contact_display) > 160))
    OR p_message_type IS NULL OR p_message_type NOT IN ('text', 'image') THEN
    RAISE EXCEPTION 'OpenWA webhook event input is invalid' USING ERRCODE = '22023';
  END IF;

  IF p_message_type = 'text' THEN
    IF p_body_text IS NULL OR char_length(btrim(p_body_text)) NOT BETWEEN 1 AND 4096
      OR p_provider_media_id IS NOT NULL OR v_mime_hint IS NOT NULL OR v_caption IS NOT NULL THEN
      RAISE EXCEPTION 'OpenWA text input is invalid' USING ERRCODE = '22023';
    END IF;
    v_body_text := btrim(p_body_text);
  ELSE
    IF p_provider_media_id IS NULL
      OR char_length(btrim(p_provider_media_id)) NOT BETWEEN 1 AND 320
      OR p_provider_media_id IS DISTINCT FROM btrim(p_provider_media_id)
      OR btrim(p_provider_media_id) <> v_provider_message_id
      OR (v_mime_hint IS NOT NULL AND v_mime_hint NOT IN ('image/jpeg', 'image/png', 'image/webp'))
      OR (p_body_text IS NOT NULL AND char_length(btrim(p_body_text)) > 4096)
      OR (p_caption IS NOT NULL AND (v_caption IS NULL OR char_length(v_caption) > 4096)) THEN
      RAISE EXCEPTION 'OpenWA image input is invalid' USING ERRCODE = '22023';
    END IF;
    v_body_text := coalesce(v_caption, 'صورة مرفقة');
  END IF;

  IF char_length(v_body_text) NOT BETWEEN 1 AND 4096 THEN
    RAISE EXCEPTION 'OpenWA message text is invalid' USING ERRCODE = '22023';
  END IF;
  IF v_received_at < timezone('utc', now()) - interval '30 days'
    OR v_received_at > timezone('utc', now()) + interval '10 minutes' THEN
    v_received_at := timezone('utc', now());
  END IF;

  -- Keep the established channel-before-conversation lock order so a channel
  -- disable/kill-switch update serializes with signed ingest.
  SELECT channel.* INTO v_channel
  FROM public.whatsapp_channels AS channel
  WHERE channel.provider = 'openwa'
    AND channel.external_channel_id = v_external_channel_id
    AND channel.status = 'active'
    AND channel.kill_switch = false
  FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'OpenWA webhook channel is unavailable' USING ERRCODE = '42501';
  END IF;

  SELECT conversation.* INTO v_conversation
  FROM public.whatsapp_conversations AS conversation
  WHERE conversation.organization_id = v_channel.organization_id
    AND conversation.channel_id = v_channel.id
    AND conversation.external_conversation_key = v_chat_id
  FOR UPDATE;
  IF NOT FOUND THEN
    INSERT INTO public.whatsapp_conversations (
      organization_id, channel_id, external_conversation_key, status
    ) VALUES (
      v_channel.organization_id, v_channel.id, v_chat_id, 'open'
    ) ON CONFLICT (organization_id, channel_id, external_conversation_key) DO NOTHING;

    SELECT conversation.* INTO v_conversation
    FROM public.whatsapp_conversations AS conversation
    WHERE conversation.organization_id = v_channel.organization_id
      AND conversation.channel_id = v_channel.id
      AND conversation.external_conversation_key = v_chat_id
    FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'OpenWA conversation could not be locked' USING ERRCODE = '40001';
    END IF;
  END IF;

  SELECT message.* INTO v_existing
  FROM public.whatsapp_message_events AS message
  WHERE message.organization_id = v_channel.organization_id
    AND message.event_key = v_event_key;
  IF FOUND THEN
    IF v_existing.conversation_id <> v_conversation.id
      OR v_existing.provider_message_id IS DISTINCT FROM v_provider_message_id
      OR v_existing.direction <> p_direction THEN
      RAISE EXCEPTION 'OpenWA idempotency key conflicts with another message' USING ERRCODE = '23505';
    END IF;
    RETURN v_existing.id;
  END IF;

  IF p_direction = 'outbound' THEN
    SELECT message.* INTO v_existing
    FROM public.whatsapp_message_events AS message
    WHERE message.organization_id = v_channel.organization_id
      AND message.conversation_id = v_conversation.id
      AND message.direction = 'outbound'
      AND message.provider_message_id = v_provider_message_id
    FOR UPDATE;
    IF FOUND THEN
      UPDATE public.whatsapp_message_events AS canonical
      SET body_text = v_body_text
      WHERE canonical.organization_id = v_channel.organization_id
        AND canonical.conversation_id = v_conversation.id
        AND canonical.id = v_existing.id
        AND canonical.direction = 'outbound'
        AND canonical.provider_message_id = v_provider_message_id;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'OpenWA canonical echo row changed during reconciliation' USING ERRCODE = '40001';
      END IF;
      INSERT INTO public.audit_events (
        organization_id, actor_type, action, resource_type, resource_id,
        outcome, after_delta
      ) VALUES (
        v_channel.organization_id, 'system', 'whatsapp.openwa.echo.reconciled',
        'whatsapp_message_event', v_existing.id, 'success',
        jsonb_build_object(
          'provider', 'openwa',
          'channel_id', v_channel.id,
          'direction', 'outbound',
          'provider_message_id', v_provider_message_id,
          'canonical_message_id', v_existing.id,
          'event_key', v_event_key,
          'body_updated', true
        )
      );
      RETURN v_existing.id;
    END IF;
  END IF;

  -- Phone identities remain digits only; unresolved LIDs remain opaque CRM
  -- identities and never become phone fields.
  v_contact_identity := coalesce(v_contact_phone, 'openwa-jid:' || v_contact_jid);
  v_contact_idempotency := 'openwa-contact:'
    || encode(extensions.digest(v_contact_identity, 'sha256'), 'hex');
  SELECT contact.id INTO v_contact_method_id
  FROM public.crm_contact_methods AS contact
  WHERE contact.organization_id = v_channel.organization_id
    AND contact.kind = 'whatsapp'
    AND contact.normalized_value = v_contact_identity
  FOR UPDATE;
  IF v_contact_method_id IS NULL THEN
    INSERT INTO public.crm_contact_methods (
      organization_id, kind, normalized_value, display_value,
      idempotency_key, created_by_membership_id
    ) VALUES (
      v_channel.organization_id, 'whatsapp', v_contact_identity,
      coalesce(v_contact_display, v_contact_phone, 'WhatsApp contact'),
      v_contact_idempotency, v_channel.created_by_membership_id
    ) ON CONFLICT (organization_id, kind, normalized_value) DO NOTHING
    RETURNING id INTO v_contact_method_id;
    IF v_contact_method_id IS NULL THEN
      SELECT contact.id INTO v_contact_method_id
      FROM public.crm_contact_methods AS contact
      WHERE contact.organization_id = v_channel.organization_id
        AND contact.kind = 'whatsapp'
        AND contact.normalized_value = v_contact_identity;
    END IF;
  END IF;
  IF v_contact_method_id IS NULL THEN
    RAISE EXCEPTION 'OpenWA contact could not be resolved' USING ERRCODE = '40001';
  END IF;

  SELECT contact.id INTO v_existing_contact_id
  FROM public.crm_contact_methods AS contact
  WHERE contact.organization_id = v_channel.organization_id
    AND contact.id = v_conversation.contact_method_id
    AND contact.kind = 'whatsapp';
  IF v_existing_contact_id IS NULL THEN
    UPDATE public.whatsapp_conversations
    SET contact_method_id = v_contact_method_id
    WHERE organization_id = v_channel.organization_id
      AND channel_id = v_channel.id
      AND id = v_conversation.id;
    v_conversation.contact_method_id := v_contact_method_id;
  END IF;

  IF p_direction = 'inbound' THEN
    INSERT INTO public.whatsapp_message_events (
      organization_id, conversation_id, event_key, direction, body_text,
      delivery_status, created_at, idempotency_key, message_type,
      provider_message_id, provider_media_id, media_mime_hint, caption, media_status
    ) VALUES (
      v_channel.organization_id, v_conversation.id, v_event_key, 'inbound',
      v_body_text, 'received', v_received_at, 'provider:' || v_event_key,
      p_message_type, v_provider_message_id, NULLIF(btrim(p_provider_media_id), ''),
      v_mime_hint, v_caption,
      CASE WHEN p_message_type = 'image' THEN 'pending' ELSE 'not_applicable' END
    ) RETURNING id INTO v_message_id;

    UPDATE public.whatsapp_conversations
    SET last_message_at = greatest(coalesce(last_message_at, v_received_at), v_received_at),
        last_customer_message_at = greatest(coalesce(last_customer_message_at, v_received_at), v_received_at),
        status = CASE WHEN status = 'closed' THEN 'open' ELSE status END,
        ai_error_code = NULL,
        ai_state_version = ai_state_version + 1
    WHERE organization_id = v_channel.organization_id
      AND channel_id = v_channel.id
      AND id = v_conversation.id;

    IF v_conversation.ai_enabled THEN
      INSERT INTO public.ai_runs (
        organization_id, agent_kind, agent_version, status, purpose,
        model_name, prompt_version, initiated_by_membership_id,
        idempotency_key, whatsapp_conversation_id
      ) VALUES (
        v_channel.organization_id, 'whatsapp', 'whatsapp-v1', 'queued',
        'معالجة رسالة واتساب', 'unconfigured', 'unconfigured',
        v_channel.created_by_membership_id,
        'whatsapp-message:' || v_message_id::text, v_conversation.id
      ) ON CONFLICT (organization_id, idempotency_key) DO NOTHING;

      SELECT run.id INTO v_run_id
      FROM public.ai_runs AS run
      WHERE run.organization_id = v_channel.organization_id
        AND run.idempotency_key = 'whatsapp-message:' || v_message_id::text;

      INSERT INTO public.outbox_events (
        organization_id, event_type, schema_version, dedupe_key, payload
      ) VALUES (
        v_channel.organization_id, 'whatsapp.ai.respond_requested', 1,
        'whatsapp-ai:' || v_message_id::text,
        jsonb_build_object(
          'run_id', v_run_id,
          'conversation_id', v_conversation.id,
          'message_id', v_message_id,
          'agent_kind', 'whatsapp'
        )
      ) ON CONFLICT (organization_id, event_type, dedupe_key) DO NOTHING;
    END IF;

    INSERT INTO public.audit_events (
      organization_id, actor_type, action, resource_type, resource_id,
      outcome, after_delta
    ) VALUES (
      v_channel.organization_id, 'system', 'whatsapp.webhook.received',
      'whatsapp_message_event', v_message_id, 'success',
      jsonb_build_object(
        'provider', 'openwa', 'channel_id', v_channel.id,
        'direction', 'inbound', 'message_type', p_message_type,
        'has_media', p_message_type = 'image'
      )
    );
  ELSIF p_direction = 'outbound' THEN
    INSERT INTO public.whatsapp_message_events (
      organization_id, conversation_id, event_key, direction, body_text,
      delivery_status, created_at, idempotency_key, message_type,
      provider_message_id, provider_media_id, media_mime_hint, caption, media_status
    ) VALUES (
      v_channel.organization_id, v_conversation.id, v_event_key, 'outbound',
      v_body_text, 'sent', v_received_at, 'provider:' || v_event_key,
      p_message_type, v_provider_message_id, NULLIF(btrim(p_provider_media_id), ''),
      v_mime_hint, v_caption,
      CASE WHEN p_message_type = 'image' THEN 'pending' ELSE 'not_applicable' END
    ) RETURNING id INTO v_message_id;

    UPDATE public.whatsapp_conversations
    SET last_message_at = greatest(coalesce(last_message_at, v_received_at), v_received_at)
    WHERE organization_id = v_channel.organization_id
      AND channel_id = v_channel.id
      AND id = v_conversation.id;

    INSERT INTO public.audit_events (
      organization_id, actor_type, action, resource_type, resource_id,
      outcome, after_delta
    ) VALUES (
      v_channel.organization_id, 'system', 'whatsapp.openwa.echo.received',
      'whatsapp_message_event', v_message_id, 'success',
      jsonb_build_object(
        'provider', 'openwa', 'channel_id', v_channel.id,
        'direction', 'outbound', 'message_type', p_message_type,
        'has_media', p_message_type = 'image'
      )
    );
  ELSE
    RAISE EXCEPTION 'OpenWA event direction is invalid' USING ERRCODE = '22023';
  END IF;

  RETURN v_message_id;
END;
$$;

REVOKE ALL ON FUNCTION public.ingest_whatsapp_openwa_event_v1(
  text, text, text, text, text, text, text, text, text, text, text, text, text, timestamptz
) FROM PUBLIC, anon, authenticated, voya_outbox_worker;
GRANT EXECUTE ON FUNCTION public.ingest_whatsapp_openwa_event_v1(
  text, text, text, text, text, text, text, text, text, text, text, text, text, timestamptz
) TO service_role;
