-- OpenWA is a distinct signed provider path. Its session identifier is opaque
-- and globally unique so provider resolution cannot select another tenant.
CREATE UNIQUE INDEX whatsapp_channels_openwa_external_id_uidx
  ON public.whatsapp_channels (provider, external_channel_id)
  WHERE provider = 'openwa';

-- Preserve Meta's preferred-provider and fallback behavior while allowing an
-- exact OpenWA provider lookup.
CREATE OR REPLACE FUNCTION public.resolve_whatsapp_webhook_provider_v1(
  p_external_channel_id text,
  p_preferred_provider text DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_external_channel_id text := btrim(p_external_channel_id);
  v_preferred_provider text := nullif(btrim(p_preferred_provider), '');
  v_provider text;
  v_provider_count integer;
BEGIN
  IF p_external_channel_id IS NULL
    OR char_length(v_external_channel_id) NOT BETWEEN 1 AND 256
    OR (v_preferred_provider = 'openwa' AND p_external_channel_id IS DISTINCT FROM v_external_channel_id)
    OR (v_preferred_provider IS NOT NULL AND v_preferred_provider NOT IN ('meta_cloud', 'meta_cloud_sandbox', 'openwa')) THEN
    RAISE EXCEPTION 'webhook provider lookup input is invalid' USING ERRCODE = '22023';
  END IF;

  IF v_preferred_provider IS NOT NULL THEN
    SELECT channel.provider
      INTO v_provider
    FROM public.whatsapp_channels AS channel
    WHERE channel.external_channel_id = v_external_channel_id
      AND channel.provider = v_preferred_provider
      AND channel.provider IN ('meta_cloud', 'meta_cloud_sandbox', 'openwa')
      AND channel.status = 'active'
      AND channel.kill_switch = false
    LIMIT 1;

    IF v_provider IS NOT NULL THEN
      RETURN v_provider;
    END IF;
  END IF;

  -- The OpenWA route rejects this Meta-only fallback result unless the exact
  -- preferred provider resolved. Existing Meta fallback behavior is unchanged.
  SELECT count(DISTINCT channel.provider), min(channel.provider)
    INTO v_provider_count, v_provider
  FROM public.whatsapp_channels AS channel
  WHERE channel.external_channel_id = v_external_channel_id
    AND channel.provider IN ('meta_cloud', 'meta_cloud_sandbox')
    AND channel.status = 'active'
    AND channel.kill_switch = false;

  IF v_provider_count <> 1 OR v_provider IS NULL THEN
    RAISE EXCEPTION 'webhook channel provider is unavailable or ambiguous' USING ERRCODE = '42501';
  END IF;

  RETURN v_provider;
END;
$$;

REVOKE ALL ON FUNCTION public.resolve_whatsapp_webhook_provider_v1(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_whatsapp_webhook_provider_v1(text, text) TO service_role;

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

  -- The signed session ID is the only provider routing key. A shared row lock
  -- lets distinct chats ingest concurrently while a channel disable/kill-switch
  -- update waits for any in-flight transaction to finish.
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

  -- Lock the tenant-qualified conversation before checking the idempotency key
  -- or inserting a message in either direction.
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

  -- Phone identities are digits only. Unresolved WhatsApp LIDs remain an
  -- opaque non-phone CRM contact identity and keep a safe display label.
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

-- Keep the guarded V1 RPC contract, but remove the reserved opaque OpenWA LID
-- namespace from model-provided phone fields before persisting structured state.
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
  v_safe_state jsonb := p_structured_state;
  v_lead_state jsonb;
BEGIN
  IF p_event_id IS NULL OR p_worker_id IS NULL OR char_length(btrim(p_worker_id)) NOT BETWEEN 1 AND 120
    OR p_confidence IS NULL OR p_confidence NOT IN ('high', 'medium', 'low') THEN
    RAISE EXCEPTION 'WhatsApp AI result safety input is invalid' USING ERRCODE = '22023';
  END IF;

  IF jsonb_typeof(v_safe_state) = 'object' AND jsonb_typeof(v_safe_state -> 'lead') = 'object' THEN
    v_lead_state := v_safe_state -> 'lead';
    IF position('@' IN coalesce(v_lead_state ->> 'phone', '')) > 0
      OR lower(left(btrim(v_lead_state ->> 'phone'), 320)) LIKE 'openwa-jid:%' THEN
      v_lead_state := jsonb_set(v_lead_state, '{phone}', 'null'::jsonb, true);
    END IF;
    IF position('@' IN coalesce(v_lead_state ->> 'whatsapp', '')) > 0
      OR lower(left(btrim(v_lead_state ->> 'whatsapp'), 320)) LIKE 'openwa-jid:%' THEN
      v_lead_state := jsonb_set(v_lead_state, '{whatsapp}', 'null'::jsonb, true);
    END IF;
    v_safe_state := jsonb_set(v_safe_state, '{lead}', v_lead_state, true);
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
    v_safe_state,
    p_reply,
    p_recommended_action,
    p_confidence,
    v_allow_reply
  ) AS applied;
END;
$$;

-- The implementation primitive remains uncallable by worker roles directly;
-- the wrapper above enforces both channel policy and safe OpenWA phone fields.
CREATE OR REPLACE FUNCTION public.apply_whatsapp_ai_result_v1_legacy(
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
  v_contact public.crm_contact_methods%ROWTYPE;
  v_lead public.leads%ROWTYPE;
  v_lead_data jsonb;
  v_outcome text := 'applied';
  v_lead_id uuid;
  v_outbound_message_id uuid;
  v_lead_name text;
  v_phone text;
  v_whatsapp text;
  v_contact_phone text;
  v_email text;
  v_requested_area text;
  v_budget_text text;
  v_notes text;
  v_check_in date;
  v_check_out date;
  v_next_follow_up_at timestamptz;
  v_guests integer;
  v_bedrooms integer;
  v_lead_status text;
  v_title text;
  v_normalized_phone text;
  v_normalized_email text;
  v_qualified boolean := false;
BEGIN
  IF p_event_id IS NULL OR p_worker_id IS NULL OR char_length(btrim(p_worker_id)) NOT BETWEEN 1 AND 120
    OR p_conversation_type IS NULL OR p_conversation_type NOT IN ('unknown', 'owner_onboarding', 'client_sales', 'existing_customer')
    OR p_structured_state IS NULL OR jsonb_typeof(p_structured_state) <> 'object'
    OR char_length(p_structured_state::text) > 50000
    OR p_recommended_action IS NULL OR p_recommended_action NOT IN ('continue', 'ready_for_review', 'handoff', 'no_reply')
    OR p_confidence IS NULL OR p_confidence NOT IN ('high', 'medium', 'low')
    OR p_send_reply IS NULL THEN
    RAISE EXCEPTION 'WhatsApp AI result input is invalid' USING ERRCODE = '22023';
  END IF;
  IF p_reply IS NOT NULL AND char_length(btrim(p_reply)) > 4096 THEN
    RAISE EXCEPTION 'WhatsApp AI reply is too long' USING ERRCODE = '22023';
  END IF;

  SELECT event.* INTO v_event
  FROM public.outbox_events AS event
  WHERE event.id = p_event_id
    AND event.event_type = 'whatsapp.ai.respond_requested'
    AND event.state = 'processing'
    AND event.locked_by = p_worker_id
    AND event.locked_until > timezone('utc', now());
  IF NOT FOUND THEN
    RAISE EXCEPTION 'WhatsApp AI event is not owned by this worker' USING ERRCODE = '40001';
  END IF;

  SELECT message.* INTO v_message
  FROM public.whatsapp_message_events AS message
  WHERE message.organization_id = v_event.organization_id
    AND message.id::text = v_event.payload ->> 'message_id';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'WhatsApp AI message is missing' USING ERRCODE = '23503';
  END IF;
  IF v_message.message_type = 'image' AND v_message.media_status <> 'stored' THEN
    RAISE EXCEPTION 'WhatsApp AI image is not stored' USING ERRCODE = '40001';
  END IF;

  SELECT conversation.* INTO v_conversation
  FROM public.whatsapp_conversations AS conversation
  WHERE conversation.organization_id = v_event.organization_id
    AND conversation.id::text = v_event.payload ->> 'conversation_id'
    AND conversation.id = v_message.conversation_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'WhatsApp AI conversation is missing' USING ERRCODE = '23503';
  END IF;

  IF v_conversation.last_ai_processed_message_id = v_message.id THEN
    SELECT message.id INTO v_outbound_message_id
    FROM public.whatsapp_message_events AS message
    WHERE message.organization_id = v_event.organization_id
      AND message.conversation_id = v_conversation.id
      AND message.idempotency_key = 'whatsapp-ai-reply:' || v_message.id::text;
    RETURN QUERY SELECT 'replayed', v_conversation.lead_id, v_outbound_message_id;
    RETURN;
  END IF;

  IF NOT v_conversation.ai_enabled OR v_conversation.status = 'closed' THEN
    UPDATE public.whatsapp_conversations
    SET last_ai_processed_message_id = v_message.id,
        ai_state_version = ai_state_version + 1,
        ai_error_code = CASE WHEN NOT ai_enabled THEN 'ai_disabled' ELSE 'conversation_closed' END
    WHERE organization_id = v_event.organization_id AND id = v_conversation.id;
    RETURN QUERY SELECT 'skipped', v_conversation.lead_id, NULL::uuid;
    RETURN;
  END IF;

  SELECT contact.* INTO v_contact
  FROM public.crm_contact_methods AS contact
  WHERE contact.organization_id = v_event.organization_id
    AND contact.id = v_conversation.contact_method_id
    AND contact.kind = 'whatsapp';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'WhatsApp contact is missing' USING ERRCODE = '23503';
  END IF;

  v_lead_data := CASE WHEN jsonb_typeof(p_structured_state -> 'lead') = 'object'
    THEN p_structured_state -> 'lead' ELSE '{}'::jsonb END;
  v_lead_name := NULLIF(left(btrim(v_lead_data ->> 'name'), 160), '');
  v_phone := NULLIF(left(btrim(v_lead_data ->> 'phone'), 320), '');
  v_whatsapp := NULLIF(left(btrim(v_lead_data ->> 'whatsapp'), 320), '');
  IF position('@' IN coalesce(v_phone, '')) > 0 OR lower(v_phone) LIKE 'openwa-jid:%' THEN v_phone := NULL; END IF;
  IF position('@' IN coalesce(v_whatsapp, '')) > 0 OR lower(v_whatsapp) LIKE 'openwa-jid:%' THEN v_whatsapp := NULL; END IF;
  v_contact_phone := CASE
    WHEN lower(v_contact.normalized_value) LIKE 'openwa-jid:%' THEN NULL
    ELSE v_contact.normalized_value
  END;
  v_email := NULLIF(left(lower(btrim(v_lead_data ->> 'email')), 320), '');
  v_requested_area := NULLIF(left(btrim(v_lead_data ->> 'requestedArea'), 320), '');
  v_budget_text := NULLIF(left(btrim(v_lead_data ->> 'budgetText'), 320), '');
  v_notes := NULLIF(left(btrim(v_lead_data ->> 'notes'), 2000), '');
  v_normalized_phone := public.crm_normalize_phone(coalesce(v_phone, v_whatsapp, v_contact_phone));
  v_normalized_email := public.crm_normalize_email(v_email);

  BEGIN
    IF NULLIF(btrim(v_lead_data ->> 'checkIn'), '') IS NOT NULL THEN
      v_check_in := (v_lead_data ->> 'checkIn')::date;
    END IF;
    IF NULLIF(btrim(v_lead_data ->> 'checkOut'), '') IS NOT NULL THEN
      v_check_out := (v_lead_data ->> 'checkOut')::date;
    END IF;
  EXCEPTION WHEN others THEN
    v_check_in := NULL;
    v_check_out := NULL;
  END;
  BEGIN
    IF NULLIF(btrim(v_lead_data ->> 'guests'), '') IS NOT NULL THEN
      v_guests := (v_lead_data ->> 'guests')::integer;
    END IF;
    IF NULLIF(btrim(v_lead_data ->> 'bedrooms'), '') IS NOT NULL THEN
      v_bedrooms := (v_lead_data ->> 'bedrooms')::integer;
    END IF;
  EXCEPTION WHEN others THEN
    v_guests := NULL;
    v_bedrooms := NULL;
  END;
  BEGIN
    IF NULLIF(btrim(v_lead_data ->> 'nextFollowUpAt'), '') IS NOT NULL THEN
      v_next_follow_up_at := (v_lead_data ->> 'nextFollowUpAt')::timestamptz;
    END IF;
  EXCEPTION WHEN others THEN
    v_next_follow_up_at := NULL;
  END;
  IF v_check_in IS NOT NULL AND v_check_out IS NOT NULL AND v_check_in >= v_check_out THEN
    v_check_in := NULL;
    v_check_out := NULL;
  END IF;
  v_qualified := v_requested_area IS NOT NULL
    AND v_check_in IS NOT NULL AND v_check_out IS NOT NULL
    AND v_bedrooms IS NOT NULL AND v_guests IS NOT NULL AND v_budget_text IS NOT NULL;
  v_lead_status := CASE WHEN v_qualified THEN 'qualified' ELSE 'new' END;

  IF p_conversation_type = 'client_sales' THEN
    SELECT lead_record.* INTO v_lead
    FROM public.leads AS lead_record
    WHERE lead_record.organization_id = v_event.organization_id
      AND lead_record.id = v_conversation.lead_id
    FOR UPDATE;
    IF NOT FOUND THEN
      v_title := left(coalesce(
        v_lead_name,
        CASE WHEN v_contact_phone IS NULL AND lower(v_contact.normalized_value) LIKE 'openwa-jid:%'
          THEN coalesce(NULLIF(left(btrim(v_contact.display_value), 160), ''), 'WhatsApp contact')
          ELSE 'WhatsApp ' || v_contact.normalized_value
        END
      ), 160);
      INSERT INTO public.leads (
        organization_id, title, name, phone, whatsapp, email,
        normalized_phone, normalized_email, source, status,
        requested_check_in, requested_check_out, requested_area,
        guests, bedrooms, budget_text, notes, next_follow_up_at,
        idempotency_key
      ) VALUES (
        v_event.organization_id, v_title, v_lead_name,
        coalesce(v_phone, v_contact_phone),
        coalesce(v_whatsapp, v_contact_phone), v_email,
        v_normalized_phone, v_normalized_email, 'whatsapp', v_lead_status,
        v_check_in, v_check_out, v_requested_area, v_guests, v_bedrooms,
        v_budget_text, v_notes, v_next_follow_up_at,
        'whatsapp-conversation:' || v_conversation.id::text
      )
      ON CONFLICT (organization_id, idempotency_key) DO UPDATE
        SET updated_at = timezone('utc', now())
      RETURNING id INTO v_lead_id;
      IF v_lead_id IS NULL THEN
        SELECT lead_record.id INTO v_lead_id
        FROM public.leads AS lead_record
        WHERE lead_record.organization_id = v_event.organization_id
          AND lead_record.idempotency_key = 'whatsapp-conversation:' || v_conversation.id::text;
      END IF;
      INSERT INTO public.audit_events (
        organization_id, actor_type, action, resource_type, resource_id,
        outcome, after_delta
      ) VALUES (
        v_event.organization_id, 'system', 'whatsapp.lead.projected',
        'lead', v_lead_id, 'success',
        jsonb_build_object('conversation_id', v_conversation.id, 'source', 'whatsapp', 'status', v_lead_status)
      );
    ELSE
      v_lead_id := v_lead.id;
      UPDATE public.leads
      SET title = coalesce(v_lead_name, title),
          name = coalesce(v_lead_name, name),
          phone = coalesce(v_phone, phone),
          whatsapp = coalesce(v_whatsapp, whatsapp),
          email = coalesce(v_email, email),
          normalized_phone = coalesce(v_normalized_phone, normalized_phone),
          normalized_email = coalesce(v_normalized_email, normalized_email),
          requested_area = coalesce(v_requested_area, requested_area),
          requested_check_in = coalesce(v_check_in, requested_check_in),
          requested_check_out = coalesce(v_check_out, requested_check_out),
          guests = coalesce(v_guests, guests),
          bedrooms = coalesce(v_bedrooms, bedrooms),
          budget_text = coalesce(v_budget_text, budget_text),
          notes = coalesce(v_notes, notes),
          next_follow_up_at = coalesce(v_next_follow_up_at, next_follow_up_at),
          status = CASE WHEN status = 'new' AND v_qualified THEN 'qualified' ELSE status END,
          version = version + 1
      WHERE organization_id = v_event.organization_id AND id = v_lead.id;
    END IF;
    UPDATE public.whatsapp_conversations
    SET lead_id = v_lead_id
    WHERE organization_id = v_event.organization_id AND id = v_conversation.id;
  ELSE
    v_lead_id := v_conversation.lead_id;
  END IF;

  IF p_recommended_action = 'handoff' THEN
    UPDATE public.whatsapp_conversations
    SET ai_enabled = false, status = 'handoff'
    WHERE organization_id = v_event.organization_id AND id = v_conversation.id;
    p_send_reply := false;
  END IF;

  UPDATE public.whatsapp_conversations
  SET conversation_type = p_conversation_type,
      structured_state = p_structured_state,
      last_ai_processed_message_id = v_message.id,
      ai_state_version = ai_state_version + 1,
      ai_error_code = NULL,
      next_follow_up_at = CASE
        WHEN NULLIF(btrim(p_structured_state #>> '{lead,nextFollowUpAt}'), '') IS NULL THEN next_follow_up_at
        ELSE v_next_follow_up_at
      END
  WHERE organization_id = v_event.organization_id AND id = v_conversation.id;

  IF p_send_reply AND p_recommended_action <> 'no_reply' AND p_reply IS NOT NULL AND char_length(btrim(p_reply)) BETWEEN 1 AND 4096 THEN
    INSERT INTO public.whatsapp_message_events (
      organization_id, conversation_id, event_key, direction, body_text,
      delivery_status, idempotency_key, message_type
    ) VALUES (
      v_event.organization_id, v_conversation.id,
      'ai:' || v_message.id::text, 'outbound', btrim(p_reply), 'queued',
      'whatsapp-ai-reply:' || v_message.id::text, 'text'
    )
    ON CONFLICT (organization_id, idempotency_key) DO NOTHING
    RETURNING id INTO v_outbound_message_id;
    IF v_outbound_message_id IS NULL THEN
      SELECT message.id INTO v_outbound_message_id
      FROM public.whatsapp_message_events AS message
      WHERE message.organization_id = v_event.organization_id
        AND message.idempotency_key = 'whatsapp-ai-reply:' || v_message.id::text;
    END IF;
    INSERT INTO public.outbox_events (
      organization_id, event_type, schema_version, dedupe_key, payload
    ) VALUES (
      v_event.organization_id, 'whatsapp.message.send_requested', 1,
      'whatsapp-message:' || v_outbound_message_id::text,
      jsonb_build_object('message_id', v_outbound_message_id, 'conversation_id', v_conversation.id)
    )
    ON CONFLICT (organization_id, event_type, dedupe_key) DO NOTHING;
    UPDATE public.whatsapp_conversations
    SET last_message_at = timezone('utc', now()), last_ai_message_at = timezone('utc', now())
    WHERE organization_id = v_event.organization_id AND id = v_conversation.id;
    INSERT INTO public.audit_events (
      organization_id, actor_type, action, resource_type, resource_id,
      outcome, after_delta
    ) VALUES (
      v_event.organization_id, 'system', 'whatsapp.ai.reply.queued',
      'whatsapp_message_event', v_outbound_message_id, 'success',
      jsonb_build_object('conversation_id', v_conversation.id, 'source_message_id', v_message.id)
    );
  END IF;

  INSERT INTO public.audit_events (
    organization_id, actor_type, action, resource_type, resource_id,
    outcome, after_delta
  ) VALUES (
    v_event.organization_id, 'system', 'whatsapp.ai.result.applied',
    'whatsapp_conversation', v_conversation.id, 'success',
    jsonb_build_object('conversation_type', p_conversation_type, 'recommended_action', p_recommended_action, 'confidence', p_confidence, 'lead_id', v_lead_id)
  );
  RETURN QUERY SELECT v_outcome, v_lead_id, v_outbound_message_id;
END;
$$;

REVOKE ALL ON FUNCTION public.apply_whatsapp_ai_result_v1_legacy(uuid, text, text, jsonb, text, text, text, boolean)
  FROM PUBLIC, anon, authenticated, voya_outbox_worker, service_role;
REVOKE ALL ON FUNCTION public.apply_whatsapp_ai_result_v1(uuid, text, text, jsonb, text, text, text, boolean)
  FROM PUBLIC, anon, authenticated, voya_outbox_worker, service_role;
GRANT EXECUTE ON FUNCTION public.apply_whatsapp_ai_result_v1(uuid, text, text, jsonb, text, text, text, boolean)
  TO voya_outbox_worker, service_role;
