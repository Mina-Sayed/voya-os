-- Voya OS: Phase 1 WhatsApp AI intake.
--
-- This migration extends the existing inbox and AI/outbox boundaries. It does
-- not create a second CRM/property system and does not publish inventory from
-- a model response. All external-ingest and worker helpers below are narrow
-- service_role/worker RPCs; staff confirmation still uses authenticated
-- command boundaries.

-- ---------------------------------------------------------------------------
-- Existing WhatsApp rows: media metadata and conversational state
-- ---------------------------------------------------------------------------

ALTER TABLE public.whatsapp_message_events
  ADD COLUMN IF NOT EXISTS message_type text NOT NULL DEFAULT 'text',
  ADD COLUMN IF NOT EXISTS provider_media_id text,
  ADD COLUMN IF NOT EXISTS media_mime_hint text,
  ADD COLUMN IF NOT EXISTS caption text,
  ADD COLUMN IF NOT EXISTS media_status text NOT NULL DEFAULT 'not_applicable',
  ADD COLUMN IF NOT EXISTS media_storage_bucket text,
  ADD COLUMN IF NOT EXISTS media_storage_path text,
  ADD COLUMN IF NOT EXISTS media_byte_size bigint,
  ADD COLUMN IF NOT EXISTS media_checksum_sha256 text,
  ADD COLUMN IF NOT EXISTS media_error_code text,
  ADD COLUMN IF NOT EXISTS media_stored_at timestamptz;

ALTER TABLE public.whatsapp_message_events
  ADD CONSTRAINT whatsapp_message_type_check
    CHECK (message_type IN ('text', 'image')),
  ADD CONSTRAINT whatsapp_message_provider_media_id_check
    CHECK (provider_media_id IS NULL OR char_length(btrim(provider_media_id)) BETWEEN 1 AND 320),
  ADD CONSTRAINT whatsapp_message_media_mime_hint_check
    CHECK (media_mime_hint IS NULL OR media_mime_hint IN ('image/jpeg', 'image/png', 'image/webp')),
  ADD CONSTRAINT whatsapp_message_caption_check
    CHECK (caption IS NULL OR char_length(caption) BETWEEN 1 AND 4096),
  ADD CONSTRAINT whatsapp_message_media_status_check
    CHECK (media_status IN ('not_applicable', 'pending', 'stored', 'failed', 'expired')),
  ADD CONSTRAINT whatsapp_message_media_bucket_check
    CHECK (media_storage_bucket IS NULL OR media_storage_bucket = 'ai-intake'),
  ADD CONSTRAINT whatsapp_message_media_path_check
    CHECK (media_storage_path IS NULL OR (
      media_storage_path = lower(media_storage_path)
      AND media_storage_path ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}/[0-9a-f-]{36}[.](jpg|jpeg|png|webp)$'
    )),
  ADD CONSTRAINT whatsapp_message_media_size_check
    CHECK (media_byte_size IS NULL OR media_byte_size BETWEEN 1 AND 10485760),
  ADD CONSTRAINT whatsapp_message_media_checksum_check
    CHECK (media_checksum_sha256 IS NULL OR media_checksum_sha256 ~ '^[0-9a-f]{64}$'),
  ADD CONSTRAINT whatsapp_message_media_error_check
    CHECK (media_error_code IS NULL OR media_error_code ~ '^[a-z][a-z0-9_.-]{0,119}$'),
  ADD CONSTRAINT whatsapp_message_media_consistency_check
    CHECK (
      (message_type = 'text'
        AND provider_media_id IS NULL
        AND media_mime_hint IS NULL
        AND caption IS NULL
        AND media_status = 'not_applicable'
        AND media_storage_bucket IS NULL
        AND media_storage_path IS NULL
        AND media_byte_size IS NULL
        AND media_checksum_sha256 IS NULL
        AND media_error_code IS NULL
        AND media_stored_at IS NULL)
      OR
      (message_type = 'image'
        AND provider_media_id IS NOT NULL
        AND media_status <> 'not_applicable'
        AND (media_status = 'stored') = (
          media_storage_bucket IS NOT NULL
          AND media_storage_path IS NOT NULL
          AND media_byte_size IS NOT NULL
          AND media_checksum_sha256 IS NOT NULL
          AND media_stored_at IS NOT NULL
        ))
    );

ALTER TABLE public.whatsapp_message_events
  ADD CONSTRAINT whatsapp_message_organization_id_unique UNIQUE (organization_id, id);

CREATE INDEX whatsapp_message_events_media_queue_idx
  ON public.whatsapp_message_events (organization_id, media_status, created_at ASC)
  WHERE message_type = 'image';

ALTER TABLE public.whatsapp_conversations
  ADD COLUMN IF NOT EXISTS ai_enabled boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS conversation_type text NOT NULL DEFAULT 'unknown',
  ADD COLUMN IF NOT EXISTS property_owner_id uuid,
  ADD COLUMN IF NOT EXISTS property_id uuid,
  ADD COLUMN IF NOT EXISTS structured_state jsonb NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS ai_state_version integer NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS last_ai_processed_message_id uuid,
  ADD COLUMN IF NOT EXISTS last_customer_message_at timestamptz,
  ADD COLUMN IF NOT EXISTS last_ai_message_at timestamptz,
  ADD COLUMN IF NOT EXISTS ai_error_code text,
  ADD COLUMN IF NOT EXISTS next_follow_up_at timestamptz,
  ADD COLUMN IF NOT EXISTS confirmation_status text NOT NULL DEFAULT 'none',
  ADD COLUMN IF NOT EXISTS confirmation_key text,
  ADD COLUMN IF NOT EXISTS confirmation_token uuid,
  ADD COLUMN IF NOT EXISTS confirmation_claimed_at timestamptz,
  ADD COLUMN IF NOT EXISTS confirmation_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS confirmation_result jsonb NOT NULL DEFAULT '{}'::jsonb;

ALTER TABLE public.whatsapp_conversations
  ADD CONSTRAINT whatsapp_conversation_type_check
    CHECK (conversation_type IN ('unknown', 'owner_onboarding', 'client_sales', 'existing_customer')),
  ADD CONSTRAINT whatsapp_conversation_state_object_check
    CHECK (jsonb_typeof(structured_state) = 'object' AND char_length(structured_state::text) <= 50000),
  ADD CONSTRAINT whatsapp_conversation_ai_state_version_check
    CHECK (ai_state_version > 0),
  ADD CONSTRAINT whatsapp_conversation_ai_error_check
    CHECK (ai_error_code IS NULL OR ai_error_code ~ '^[a-z][a-z0-9_.-]{0,119}$'),
  ADD CONSTRAINT whatsapp_conversation_confirmation_status_check
    CHECK (confirmation_status IN ('none', 'claimed', 'confirmed', 'partially_applied', 'needs_review')),
  ADD CONSTRAINT whatsapp_conversation_confirmation_key_check
    CHECK (confirmation_key IS NULL OR char_length(btrim(confirmation_key)) BETWEEN 1 AND 160),
  ADD CONSTRAINT whatsapp_conversation_confirmation_payload_check
    CHECK (jsonb_typeof(confirmation_payload) = 'object' AND char_length(confirmation_payload::text) <= 30000),
  ADD CONSTRAINT whatsapp_conversation_confirmation_result_check
    CHECK (jsonb_typeof(confirmation_result) = 'object' AND char_length(confirmation_result::text) <= 30000),
  ADD CONSTRAINT whatsapp_conversation_confirmation_claim_check
    CHECK ((confirmation_token IS NULL) = (confirmation_claimed_at IS NULL));

ALTER TABLE public.whatsapp_conversations
  ADD CONSTRAINT whatsapp_conversation_organization_id_unique UNIQUE (organization_id, id),
  ADD CONSTRAINT whatsapp_conversation_owner_tenant_fk
    FOREIGN KEY (organization_id, property_owner_id)
    REFERENCES public.property_owners (organization_id, id) ON DELETE RESTRICT,
  ADD CONSTRAINT whatsapp_conversation_property_tenant_fk
    FOREIGN KEY (organization_id, property_id)
    REFERENCES public.properties (organization_id, id) ON DELETE RESTRICT,
  ADD CONSTRAINT whatsapp_conversation_last_ai_message_tenant_fk
    FOREIGN KEY (organization_id, last_ai_processed_message_id)
    REFERENCES public.whatsapp_message_events (organization_id, id) ON DELETE RESTRICT;

CREATE INDEX whatsapp_conversations_ai_queue_idx
  ON public.whatsapp_conversations (organization_id, ai_enabled, status, last_customer_message_at DESC);

-- ---------------------------------------------------------------------------
-- Furnished-rental inventory fields
-- ---------------------------------------------------------------------------

ALTER TABLE public.properties
  ADD COLUMN IF NOT EXISTS bathrooms integer,
  ADD COLUMN IF NOT EXISTS area_sqm numeric(10, 2),
  ADD COLUMN IF NOT EXISTS floor text,
  ADD COLUMN IF NOT EXISTS furnished boolean,
  ADD COLUMN IF NOT EXISTS district text,
  ADD COLUMN IF NOT EXISTS rent_daily boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS rent_weekly boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS rent_monthly boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS daily_price numeric(19, 2),
  ADD COLUMN IF NOT EXISTS weekly_price numeric(19, 2),
  ADD COLUMN IF NOT EXISTS monthly_price numeric(19, 2),
  ADD COLUMN IF NOT EXISTS currency text,
  ADD COLUMN IF NOT EXISTS amenities text[],
  ADD COLUMN IF NOT EXISTS minimum_stay_nights integer,
  ADD COLUMN IF NOT EXISTS marketing_description text;

ALTER TABLE public.properties
  ADD CONSTRAINT properties_bathrooms_valid
    CHECK (bathrooms IS NULL OR bathrooms BETWEEN 0 AND 100),
  ADD CONSTRAINT properties_area_sqm_valid
    CHECK (area_sqm IS NULL OR (area_sqm > 0 AND area_sqm <= 100000)),
  ADD CONSTRAINT properties_floor_valid
    CHECK (floor IS NULL OR char_length(btrim(floor)) BETWEEN 1 AND 80),
  ADD CONSTRAINT properties_district_valid
    CHECK (district IS NULL OR char_length(btrim(district)) BETWEEN 1 AND 160),
  ADD CONSTRAINT properties_price_valid
    CHECK ((daily_price IS NULL OR daily_price >= 0)
      AND (weekly_price IS NULL OR weekly_price >= 0)
      AND (monthly_price IS NULL OR monthly_price >= 0)),
  ADD CONSTRAINT properties_currency_valid
    CHECK (currency IS NULL OR currency ~ '^[A-Z]{3}$'),
  ADD CONSTRAINT properties_price_currency_consistent
    CHECK ((daily_price IS NULL AND weekly_price IS NULL AND monthly_price IS NULL) OR currency IS NOT NULL),
  ADD CONSTRAINT properties_amenities_valid
    CHECK (amenities IS NULL OR cardinality(amenities) BETWEEN 0 AND 50),
  ADD CONSTRAINT properties_minimum_stay_valid
    CHECK (minimum_stay_nights IS NULL OR minimum_stay_nights BETWEEN 1 AND 3650),
  ADD CONSTRAINT properties_marketing_description_valid
    CHECK (marketing_description IS NULL OR char_length(marketing_description) BETWEEN 1 AND 4000);

ALTER TABLE public.ai_runs
  ADD COLUMN IF NOT EXISTS whatsapp_conversation_id uuid;

ALTER TABLE public.ai_runs
  DROP CONSTRAINT IF EXISTS ai_runs_agent_kind_check;

ALTER TABLE public.ai_runs
  ADD CONSTRAINT ai_runs_agent_kind_check
    CHECK (agent_kind IN ('sales', 'booking', 'finance', 'manager', 'copilot', 'data_entry', 'whatsapp')) NOT VALID;

ALTER TABLE public.ai_runs VALIDATE CONSTRAINT ai_runs_agent_kind_check;

ALTER TABLE public.ai_runs
  ADD CONSTRAINT ai_run_whatsapp_conversation_tenant_fk
    FOREIGN KEY (organization_id, whatsapp_conversation_id)
    REFERENCES public.whatsapp_conversations (organization_id, id) ON DELETE RESTRICT;

CREATE INDEX ai_runs_whatsapp_conversation_idx
  ON public.ai_runs (organization_id, whatsapp_conversation_id, created_at DESC)
  WHERE whatsapp_conversation_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- Signed webhook ingest and compatibility wrapper
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.ingest_whatsapp_webhook_event_v1(
  p_provider text,
  p_external_channel_id text,
  p_external_conversation_key text,
  p_event_key text,
  p_sender_phone text,
  p_message_type text,
  p_body_text text,
  p_provider_media_id text DEFAULT NULL,
  p_media_mime_hint text DEFAULT NULL,
  p_caption text DEFAULT NULL,
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
  v_contact_method_id uuid;
  v_message_id uuid;
  v_run_id uuid;
  v_received_at timestamptz := coalesce(p_received_at, timezone('utc', now()));
  v_contact_idempotency text;
  v_body_text text;
  v_caption text := NULLIF(btrim(p_caption), '');
  v_mime_hint text := NULLIF(lower(btrim(p_media_mime_hint)), '');
BEGIN
  IF p_provider IS NULL OR p_provider !~ '^[a-z][a-z0-9_.-]{0,79}$'
    OR p_external_channel_id IS NULL OR char_length(btrim(p_external_channel_id)) NOT BETWEEN 1 AND 256
    OR p_external_conversation_key IS NULL OR char_length(btrim(p_external_conversation_key)) NOT BETWEEN 1 AND 256
    OR p_event_key IS NULL OR char_length(btrim(p_event_key)) NOT BETWEEN 1 AND 320
    OR p_sender_phone IS NULL OR char_length(btrim(p_sender_phone)) NOT BETWEEN 1 AND 80
    OR p_message_type IS NULL OR p_message_type NOT IN ('text', 'image') THEN
    RAISE EXCEPTION 'webhook event input is invalid' USING ERRCODE = '22023';
  END IF;
  IF p_message_type = 'text' THEN
    IF p_body_text IS NULL OR char_length(btrim(p_body_text)) NOT BETWEEN 1 AND 4096
      OR p_provider_media_id IS NOT NULL OR v_mime_hint IS NOT NULL OR v_caption IS NOT NULL THEN
      RAISE EXCEPTION 'webhook text input is invalid' USING ERRCODE = '22023';
    END IF;
    v_body_text := btrim(p_body_text);
  ELSE
    IF p_provider_media_id IS NULL OR char_length(btrim(p_provider_media_id)) NOT BETWEEN 1 AND 320
      OR (v_mime_hint IS NOT NULL AND v_mime_hint NOT IN ('image/jpeg', 'image/png', 'image/webp'))
      OR (p_body_text IS NOT NULL AND char_length(btrim(p_body_text)) > 0) THEN
      RAISE EXCEPTION 'webhook image input is invalid' USING ERRCODE = '22023';
    END IF;
    v_body_text := coalesce(v_caption, 'صورة مرفقة');
  END IF;
  IF char_length(v_body_text) NOT BETWEEN 1 AND 4096 THEN
    RAISE EXCEPTION 'webhook message text is invalid' USING ERRCODE = '22023';
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

  v_contact_idempotency := 'whatsapp-inbound-contact:'
    || encode(extensions.digest(btrim(p_sender_phone), 'sha256'), 'hex');
  SELECT contact.id INTO v_contact_method_id
  FROM public.crm_contact_methods AS contact
  WHERE contact.organization_id = v_channel.organization_id
    AND contact.kind = 'whatsapp'
    AND contact.normalized_value = btrim(p_sender_phone)
  FOR UPDATE;
  IF v_contact_method_id IS NULL THEN
    INSERT INTO public.crm_contact_methods (
      organization_id, kind, normalized_value, display_value,
      idempotency_key, created_by_membership_id
    ) VALUES (
      v_channel.organization_id, 'whatsapp', btrim(p_sender_phone), btrim(p_sender_phone),
      v_contact_idempotency, v_channel.created_by_membership_id
    )
    ON CONFLICT (organization_id, kind, normalized_value) DO NOTHING
    RETURNING id INTO v_contact_method_id;
    IF v_contact_method_id IS NULL THEN
      SELECT contact.id INTO v_contact_method_id
      FROM public.crm_contact_methods AS contact
      WHERE contact.organization_id = v_channel.organization_id
        AND contact.kind = 'whatsapp'
        AND contact.normalized_value = btrim(p_sender_phone);
    END IF;
  END IF;

  SELECT conversation.* INTO v_conversation
  FROM public.whatsapp_conversations AS conversation
  WHERE conversation.organization_id = v_channel.organization_id
    AND conversation.channel_id = v_channel.id
    AND conversation.external_conversation_key = btrim(p_external_conversation_key)
  FOR UPDATE;

  IF NOT FOUND THEN
    INSERT INTO public.whatsapp_conversations (
      organization_id, channel_id, contact_method_id, external_conversation_key,
      status, last_message_at, last_customer_message_at
    ) VALUES (
      v_channel.organization_id, v_channel.id, v_contact_method_id,
      btrim(p_external_conversation_key), 'open', v_received_at, v_received_at
    )
    ON CONFLICT (organization_id, channel_id, external_conversation_key) DO UPDATE
      SET contact_method_id = coalesce(public.whatsapp_conversations.contact_method_id, EXCLUDED.contact_method_id),
          last_message_at = greatest(coalesce(public.whatsapp_conversations.last_message_at, EXCLUDED.last_message_at), EXCLUDED.last_message_at),
          last_customer_message_at = greatest(coalesce(public.whatsapp_conversations.last_customer_message_at, EXCLUDED.last_customer_message_at), EXCLUDED.last_customer_message_at)
    RETURNING * INTO v_conversation;
  ELSIF v_conversation.contact_method_id IS NULL THEN
    UPDATE public.whatsapp_conversations
    SET contact_method_id = v_contact_method_id
    WHERE id = v_conversation.id AND organization_id = v_channel.organization_id;
    v_conversation.contact_method_id := v_contact_method_id;
  END IF;

  INSERT INTO public.whatsapp_message_events (
    organization_id, conversation_id, event_key, direction, body_text,
    delivery_status, created_at, idempotency_key, message_type,
    provider_media_id, media_mime_hint, caption, media_status
  ) VALUES (
    v_channel.organization_id, v_conversation.id, btrim(p_event_key), 'inbound',
    v_body_text, 'received', v_received_at, 'provider:' || btrim(p_event_key),
    p_message_type, NULLIF(btrim(p_provider_media_id), ''), v_mime_hint, v_caption,
    CASE WHEN p_message_type = 'image' THEN 'pending' ELSE 'not_applicable' END
  )
  ON CONFLICT (organization_id, event_key) DO NOTHING
  RETURNING id INTO v_message_id;

  IF v_message_id IS NULL THEN
    SELECT message.id INTO v_message_id
    FROM public.whatsapp_message_events AS message
    WHERE message.organization_id = v_channel.organization_id
      AND message.event_key = btrim(p_event_key);
    RETURN v_message_id;
  END IF;

  UPDATE public.whatsapp_conversations
  SET last_message_at = greatest(coalesce(last_message_at, v_received_at), v_received_at),
      last_customer_message_at = greatest(coalesce(last_customer_message_at, v_received_at), v_received_at),
      status = CASE WHEN status = 'closed' THEN 'open' ELSE status END,
      ai_error_code = NULL,
      ai_state_version = ai_state_version + 1
  WHERE id = v_conversation.id AND organization_id = v_channel.organization_id;

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
    )
    ON CONFLICT (organization_id, idempotency_key) DO NOTHING;

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
    )
    ON CONFLICT (organization_id, event_type, dedupe_key) DO NOTHING;
  END IF;

  INSERT INTO public.audit_events (
    organization_id, actor_type, action, resource_type, resource_id,
    outcome, after_delta
  ) VALUES (
    v_channel.organization_id, 'system', 'whatsapp.webhook.received',
    'whatsapp_message_event', v_message_id, 'success',
    jsonb_build_object(
      'provider', p_provider,
      'channel_id', v_channel.id,
      'direction', 'inbound',
      'message_type', p_message_type,
      'has_media', p_message_type = 'image'
    )
  );
  RETURN v_message_id;
END;
$$;

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
  v_contact_method_id uuid;
  v_message_id uuid;
  v_received_at timestamptz := coalesce(p_received_at, timezone('utc', now()));
  v_contact_idempotency text := 'whatsapp-inbound-contact:' || encode(extensions.digest(btrim(p_sender_phone), 'sha256'), 'hex');
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
  IF NOT FOUND THEN RAISE EXCEPTION 'webhook channel is unavailable' USING ERRCODE = '42501'; END IF;
  SELECT message.* INTO v_existing
  FROM public.whatsapp_message_events AS message
  WHERE message.organization_id = v_channel.organization_id
    AND message.event_key = btrim(p_event_key);
  IF FOUND THEN RETURN v_existing.id; END IF;
  SELECT contact.id INTO v_contact_method_id
  FROM public.crm_contact_methods AS contact
  WHERE contact.organization_id = v_channel.organization_id
    AND contact.kind = 'whatsapp'
    AND contact.normalized_value = btrim(p_sender_phone)
  FOR UPDATE;
  IF v_contact_method_id IS NULL THEN
    INSERT INTO public.crm_contact_methods (
      organization_id, kind, normalized_value, display_value,
      idempotency_key, created_by_membership_id
    ) VALUES (
      v_channel.organization_id, 'whatsapp', btrim(p_sender_phone), btrim(p_sender_phone),
      v_contact_idempotency, v_channel.created_by_membership_id
    ) ON CONFLICT (organization_id, kind, normalized_value) DO NOTHING
    RETURNING id INTO v_contact_method_id;
    IF v_contact_method_id IS NULL THEN
      SELECT contact.id INTO v_contact_method_id
      FROM public.crm_contact_methods AS contact
      WHERE contact.organization_id = v_channel.organization_id
        AND contact.kind = 'whatsapp'
        AND contact.normalized_value = btrim(p_sender_phone);
    END IF;
  END IF;
  SELECT conversation.* INTO v_conversation
  FROM public.whatsapp_conversations AS conversation
  WHERE conversation.organization_id = v_channel.organization_id
    AND conversation.channel_id = v_channel.id
    AND conversation.external_conversation_key = btrim(p_external_conversation_key)
  FOR UPDATE;
  IF NOT FOUND THEN
    INSERT INTO public.whatsapp_conversations (
      organization_id, channel_id, contact_method_id, external_conversation_key,
      status, last_message_at, last_customer_message_at
    ) VALUES (
      v_channel.organization_id, v_channel.id, v_contact_method_id,
      btrim(p_external_conversation_key), 'open', v_received_at, v_received_at
    ) ON CONFLICT (organization_id, channel_id, external_conversation_key) DO UPDATE
      SET contact_method_id = coalesce(public.whatsapp_conversations.contact_method_id, EXCLUDED.contact_method_id),
          last_message_at = greatest(coalesce(public.whatsapp_conversations.last_message_at, EXCLUDED.last_message_at), EXCLUDED.last_message_at),
          last_customer_message_at = greatest(coalesce(public.whatsapp_conversations.last_customer_message_at, EXCLUDED.last_customer_message_at), EXCLUDED.last_customer_message_at)
    RETURNING * INTO v_conversation;
  END IF;
  INSERT INTO public.whatsapp_message_events (
    organization_id, conversation_id, event_key, direction, body_text,
    delivery_status, created_at, idempotency_key
  ) VALUES (
    v_channel.organization_id, v_conversation.id, btrim(p_event_key), 'inbound',
    btrim(p_body_text), 'received', v_received_at, 'provider:' || btrim(p_event_key)
  ) ON CONFLICT (organization_id, event_key) DO NOTHING
  RETURNING id INTO v_message_id;
  IF v_message_id IS NULL THEN
    SELECT message.id INTO v_message_id
    FROM public.whatsapp_message_events AS message
    WHERE message.organization_id = v_channel.organization_id
      AND message.event_key = btrim(p_event_key);
    RETURN v_message_id;
  END IF;
  UPDATE public.whatsapp_conversations
  SET last_message_at = greatest(coalesce(last_message_at, v_received_at), v_received_at),
      last_customer_message_at = greatest(coalesce(last_customer_message_at, v_received_at), v_received_at),
      status = CASE WHEN status = 'closed' THEN 'open' ELSE status END
  WHERE id = v_conversation.id AND organization_id = v_channel.organization_id;
  INSERT INTO public.audit_events (
    organization_id, actor_type, action, resource_type, resource_id, outcome, after_delta
  ) VALUES (
    v_channel.organization_id, 'system', 'whatsapp.webhook.received',
    'whatsapp_message_event', v_message_id, 'success',
    jsonb_build_object('provider', p_provider, 'channel_id', v_channel.id, 'direction', 'inbound', 'message_type', 'text')
  );
  RETURN v_message_id;
END;
$$;

REVOKE ALL ON FUNCTION public.ingest_whatsapp_webhook_event_v1(text, text, text, text, text, text, text, text, text, text, timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ingest_whatsapp_webhook_event_v1(text, text, text, text, text, text, text, text, text, text, timestamptz) TO service_role;
REVOKE ALL ON FUNCTION public.ingest_whatsapp_webhook_event(text, text, text, text, text, text, timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ingest_whatsapp_webhook_event(text, text, text, text, text, text, timestamptz) TO service_role;

-- ---------------------------------------------------------------------------
-- Worker-owned private media state
-- ---------------------------------------------------------------------------

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
    AND event.event_type = 'whatsapp.ai.respond_requested'
    AND event.state = 'processing'
    AND event.locked_by = p_worker_id
    AND event.locked_until > timezone('utc', now());
  IF NOT FOUND OR (v_event.payload ->> 'message_id')::uuid <> p_message_id THEN
    RETURN false;
  END IF;

  SELECT message.* INTO v_message
  FROM public.whatsapp_message_events AS message
  WHERE message.organization_id = v_event.organization_id
    AND message.id = p_message_id
    AND message.message_type = 'image';
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
    AND event.event_type = 'whatsapp.ai.respond_requested'
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

REVOKE ALL ON FUNCTION public.store_whatsapp_media_v1(uuid, text, uuid, text, text, bigint, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.fail_whatsapp_media_v1(uuid, text, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.store_whatsapp_media_v1(uuid, text, uuid, text, text, bigint, text) TO voya_outbox_worker, service_role;
GRANT EXECUTE ON FUNCTION public.fail_whatsapp_media_v1(uuid, text, uuid, text) TO voya_outbox_worker, service_role;

-- ---------------------------------------------------------------------------
-- Bounded worker context
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.resolve_whatsapp_ai_execution_v1(
  p_event_id uuid,
  p_worker_id text
)
RETURNS TABLE (
  run_id uuid,
  organization_id uuid,
  conversation_id uuid,
  message_id uuid,
  provider text,
  phone_number_id text,
  recipient_phone text,
  conversation_status text,
  ai_enabled boolean,
  conversation_type text,
  structured_state jsonb,
  source_message jsonb,
  recent_messages jsonb,
  linked_lead jsonb,
  linked_client jsonb,
  linked_owner jsonb,
  should_process boolean,
  skip_reason text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  IF p_event_id IS NULL OR p_worker_id IS NULL OR char_length(btrim(p_worker_id)) NOT BETWEEN 1 AND 120 THEN
    RAISE EXCEPTION 'WhatsApp AI context input is invalid' USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  SELECT run.id,
         event.organization_id,
         conversation.id,
         message.id,
         channel.provider,
         channel.external_channel_id,
         contact.normalized_value,
         conversation.status,
         conversation.ai_enabled,
         conversation.conversation_type,
         conversation.structured_state,
         jsonb_build_object(
           'id', message.id,
           'message_type', message.message_type,
           'body_text', left(message.body_text, 4096),
           'caption', message.caption,
           'provider_media_id', message.provider_media_id,
           'media_mime_hint', message.media_mime_hint,
           'media_status', message.media_status,
           'media_storage_bucket', message.media_storage_bucket,
           'media_storage_path', message.media_storage_path,
           'media_byte_size', message.media_byte_size,
           'media_checksum_sha256', message.media_checksum_sha256,
           'created_at', message.created_at
         ),
         coalesce((
           SELECT jsonb_agg(
             jsonb_build_object(
               'id', recent.id,
               'direction', recent.direction,
               'message_type', recent.message_type,
               'body_text', left(recent.body_text, 2000),
               'caption', recent.caption,
               'media_status', recent.media_status,
               'media_storage_bucket', recent.media_storage_bucket,
               'media_storage_path', recent.media_storage_path,
               'created_at', recent.created_at
             ) ORDER BY recent.created_at ASC, recent.id ASC
           )
           FROM (
             SELECT history.id, history.direction, history.message_type,
                    history.body_text, history.caption, history.media_status,
                    history.media_storage_bucket, history.media_storage_path,
                    history.created_at
             FROM public.whatsapp_message_events AS history
             WHERE history.organization_id = event.organization_id
               AND history.conversation_id = conversation.id
             ORDER BY history.created_at DESC, history.id DESC
             LIMIT 20
           ) AS recent
         ), '[]'::jsonb),
         CASE WHEN lead_record.id IS NULL THEN NULL ELSE jsonb_build_object(
           'id', lead_record.id,
           'name', lead_record.name,
           'phone', lead_record.phone,
           'whatsapp', lead_record.whatsapp,
           'email', lead_record.email,
           'requested_area', lead_record.requested_area,
           'requested_check_in', lead_record.requested_check_in,
           'requested_check_out', lead_record.requested_check_out,
           'guests', lead_record.guests,
           'bedrooms', lead_record.bedrooms,
           'budget_text', lead_record.budget_text,
           'notes', lead_record.notes,
           'status', lead_record.status
         ) END,
         CASE WHEN client_record.id IS NULL THEN NULL ELSE jsonb_build_object(
           'id', client_record.id,
           'display_name', client_record.display_name,
           'phone', client_record.phone,
           'whatsapp', client_record.whatsapp,
           'email', client_record.email,
           'preferred_language', client_record.preferred_language,
           'notes', client_record.notes
         ) END,
         CASE WHEN owner_record.id IS NULL THEN NULL ELSE jsonb_build_object(
           'id', owner_record.id,
           'display_name', owner_record.display_name,
           'phone', owner_record.phone,
           'whatsapp', owner_record.whatsapp,
           'email', owner_record.email,
           'preferred_contact_method', owner_record.preferred_contact_method,
           'notes', owner_record.notes
         ) END,
         conversation.ai_enabled
           AND conversation.status <> 'closed'
           AND (conversation.last_ai_processed_message_id IS NULL
             OR processed.created_at IS NULL
             OR message.created_at >= processed.created_at)
           AND (message.message_type = 'text' OR message.media_status IN ('pending', 'stored')),
         CASE
           WHEN NOT conversation.ai_enabled THEN 'ai_disabled'
           WHEN conversation.status = 'closed' THEN 'conversation_closed'
           WHEN processed.created_at IS NOT NULL AND message.created_at < processed.created_at THEN 'message_reordered'
           WHEN message.message_type = 'image' AND message.media_status IN ('failed', 'expired') THEN 'media_unavailable'
           WHEN message.message_type = 'image' AND message.media_status NOT IN ('pending', 'stored') THEN 'media_not_ready'
           ELSE NULL
         END
  FROM public.outbox_events AS event
  JOIN public.ai_runs AS run
    ON run.organization_id = event.organization_id
   AND run.id::text = event.payload ->> 'run_id'
   AND run.agent_kind = 'whatsapp'
   AND run.status IN ('queued', 'running')
  JOIN public.whatsapp_conversations AS conversation
    ON conversation.organization_id = event.organization_id
   AND conversation.id::text = event.payload ->> 'conversation_id'
  JOIN public.whatsapp_message_events AS message
    ON message.organization_id = event.organization_id
   AND message.id::text = event.payload ->> 'message_id'
   AND message.conversation_id = conversation.id
  JOIN public.whatsapp_channels AS channel
    ON channel.organization_id = event.organization_id
   AND channel.id = conversation.channel_id
  JOIN public.crm_contact_methods AS contact
    ON contact.organization_id = event.organization_id
   AND contact.id = conversation.contact_method_id
   AND contact.kind = 'whatsapp'
  LEFT JOIN public.whatsapp_message_events AS processed
    ON processed.organization_id = conversation.organization_id
   AND processed.id = conversation.last_ai_processed_message_id
  LEFT JOIN public.leads AS lead_record
    ON lead_record.organization_id = conversation.organization_id
   AND lead_record.id = conversation.lead_id
  LEFT JOIN public.clients AS client_record
    ON client_record.organization_id = conversation.organization_id
   AND client_record.id = conversation.client_id
  LEFT JOIN public.property_owners AS owner_record
    ON owner_record.organization_id = conversation.organization_id
   AND owner_record.id = conversation.property_owner_id
  WHERE event.id = p_event_id
    AND event.event_type = 'whatsapp.ai.respond_requested'
    AND event.state = 'processing'
    AND event.locked_by = p_worker_id
    AND event.locked_until > timezone('utc', now());
END;
$$;

REVOKE ALL ON FUNCTION public.resolve_whatsapp_ai_execution_v1(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_whatsapp_ai_execution_v1(uuid, text) TO voya_outbox_worker, service_role;

-- ---------------------------------------------------------------------------
-- Extend the existing leased outbox set with the WhatsApp AI event
-- ---------------------------------------------------------------------------

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
      'whatsapp.ai.respond_requested'
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
DECLARE v_updated_count integer;
BEGIN
  IF p_event_id IS NULL OR p_worker_id IS NULL OR char_length(btrim(p_worker_id)) NOT BETWEEN 1 AND 120
    OR p_lease_seconds IS NULL OR p_lease_seconds NOT BETWEEN 1 AND 900 THEN
    RAISE EXCEPTION 'WhatsApp AI lease input is invalid' USING ERRCODE = '22023';
  END IF;
  UPDATE public.outbox_events
  SET locked_until = timezone('utc', now()) + make_interval(secs => p_lease_seconds)
  WHERE id = p_event_id
    AND event_type = 'whatsapp.ai.respond_requested'
    AND state = 'processing'
    AND locked_by = p_worker_id
    AND locked_until > timezone('utc', now());
  GET DIAGNOSTICS v_updated_count = ROW_COUNT;
  RETURN v_updated_count = 1;
END;
$$;

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
DECLARE v_updated_count integer;
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
  WHERE event.id = p_event_id
    AND event.organization_id = run.organization_id
    AND event.event_type = 'whatsapp.ai.respond_requested'
    AND event.state = 'processing'
    AND event.locked_by = p_worker_id
    AND event.locked_until > timezone('utc', now())
    AND run.id::text = event.payload ->> 'run_id'
    AND run.agent_kind = 'whatsapp'
    AND run.status IN ('queued', 'running');
  GET DIAGNOSTICS v_updated_count = ROW_COUNT;
  RETURN v_updated_count = 1;
END;
$$;

CREATE OR REPLACE FUNCTION public.succeed_whatsapp_ai_run_v1(
  p_event_id uuid,
  p_worker_id text,
  p_result_summary jsonb
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE v_updated_count integer;
BEGIN
  IF p_result_summary IS NULL OR jsonb_typeof(p_result_summary) <> 'object'
    OR char_length(p_result_summary::text) > 20000 THEN
    RAISE EXCEPTION 'WhatsApp AI result summary is invalid' USING ERRCODE = '22023';
  END IF;
  UPDATE public.ai_runs AS run
  SET status = 'succeeded', result_summary = p_result_summary,
      finished_at = timezone('utc', now()), error_code = NULL
  FROM public.outbox_events AS event
  WHERE event.id = p_event_id
    AND event.organization_id = run.organization_id
    AND event.event_type = 'whatsapp.ai.respond_requested'
    AND event.state = 'processing'
    AND event.locked_by = p_worker_id
    AND event.locked_until > timezone('utc', now())
    AND run.id::text = event.payload ->> 'run_id'
    AND run.agent_kind = 'whatsapp'
    AND run.status IN ('queued', 'running');
  GET DIAGNOSTICS v_updated_count = ROW_COUNT;
  RETURN v_updated_count = 1;
END;
$$;

CREATE OR REPLACE FUNCTION public.fail_whatsapp_ai_run_v1(
  p_event_id uuid,
  p_worker_id text,
  p_error_code text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE v_updated_count integer;
BEGIN
  IF p_error_code IS NULL OR p_error_code !~ '^[a-z][a-z0-9_.-]{0,119}$' THEN
    RAISE EXCEPTION 'WhatsApp AI error code is invalid' USING ERRCODE = '22023';
  END IF;
  UPDATE public.ai_runs AS run
  SET status = 'failed', finished_at = timezone('utc', now()), error_code = p_error_code
  FROM public.outbox_events AS event
  WHERE event.id = p_event_id
    AND event.organization_id = run.organization_id
    AND event.event_type = 'whatsapp.ai.respond_requested'
    AND event.state = 'processing'
    AND event.locked_by = p_worker_id
    AND event.locked_until > timezone('utc', now())
    AND run.id::text = event.payload ->> 'run_id'
    AND run.agent_kind = 'whatsapp'
    AND run.status IN ('queued', 'running');
  GET DIAGNOSTICS v_updated_count = ROW_COUNT;
  RETURN v_updated_count = 1;
END;
$$;

REVOKE ALL ON FUNCTION public.claim_outbox_delivery_events(text, integer, integer) FROM PUBLIC, authenticated, anon;
REVOKE ALL ON FUNCTION public.renew_whatsapp_ai_event_lease_v1(uuid, text, integer) FROM PUBLIC, authenticated, anon;
REVOKE ALL ON FUNCTION public.start_whatsapp_ai_run_v1(uuid, text, text, text) FROM PUBLIC, authenticated, anon;
REVOKE ALL ON FUNCTION public.succeed_whatsapp_ai_run_v1(uuid, text, jsonb) FROM PUBLIC, authenticated, anon;
REVOKE ALL ON FUNCTION public.fail_whatsapp_ai_run_v1(uuid, text, text) FROM PUBLIC, authenticated, anon;
GRANT EXECUTE ON FUNCTION public.claim_outbox_delivery_events(text, integer, integer) TO voya_outbox_worker, service_role;
GRANT EXECUTE ON FUNCTION public.renew_whatsapp_ai_event_lease_v1(uuid, text, integer) TO voya_outbox_worker, service_role;
GRANT EXECUTE ON FUNCTION public.start_whatsapp_ai_run_v1(uuid, text, text, text) TO voya_outbox_worker, service_role;
GRANT EXECUTE ON FUNCTION public.succeed_whatsapp_ai_run_v1(uuid, text, jsonb) TO voya_outbox_worker, service_role;
GRANT EXECUTE ON FUNCTION public.fail_whatsapp_ai_run_v1(uuid, text, text) TO voya_outbox_worker, service_role;

-- ---------------------------------------------------------------------------
-- Apply only the validated proposal: state/lead projection and optional reply
-- ---------------------------------------------------------------------------

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
  v_contact public.crm_contact_methods%ROWTYPE;
  v_lead public.leads%ROWTYPE;
  v_lead_data jsonb;
  v_outcome text := 'applied';
  v_lead_id uuid;
  v_outbound_message_id uuid;
  v_lead_name text;
  v_phone text;
  v_whatsapp text;
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
  v_email := NULLIF(left(lower(btrim(v_lead_data ->> 'email')), 320), '');
  v_requested_area := NULLIF(left(btrim(v_lead_data ->> 'requestedArea'), 320), '');
  v_budget_text := NULLIF(left(btrim(v_lead_data ->> 'budgetText'), 320), '');
  v_notes := NULLIF(left(btrim(v_lead_data ->> 'notes'), 2000), '');
  v_normalized_phone := public.crm_normalize_phone(coalesce(v_phone, v_whatsapp, v_contact.normalized_value));
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
      v_title := left(coalesce(v_lead_name, 'WhatsApp ' || v_contact.normalized_value), 160);
      INSERT INTO public.leads (
        organization_id, title, name, phone, whatsapp, email,
        normalized_phone, normalized_email, source, status,
        requested_check_in, requested_check_out, requested_area,
        guests, bedrooms, budget_text, notes, next_follow_up_at,
        idempotency_key
      ) VALUES (
        v_event.organization_id, v_title, v_lead_name,
        coalesce(v_phone, v_contact.normalized_value),
        coalesce(v_whatsapp, v_contact.normalized_value), v_email,
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

REVOKE ALL ON FUNCTION public.apply_whatsapp_ai_result_v1(uuid, text, text, jsonb, text, text, text, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.apply_whatsapp_ai_result_v1(uuid, text, text, jsonb, text, text, text, boolean) TO voya_outbox_worker, service_role;

-- ---------------------------------------------------------------------------
-- Staff reads and the explicit AI kill switch
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.list_whatsapp_conversations_ai_v1(
  p_organization_id uuid
)
RETURNS TABLE (
  id uuid,
  channel_id uuid,
  channel_name text,
  contact_label text,
  status text,
  assigned_membership_id uuid,
  last_message_at timestamptz,
  last_message_preview text,
  last_message_direction text,
  ai_enabled boolean,
  conversation_type text,
  lead_id uuid,
  client_id uuid,
  property_owner_id uuid,
  property_id uuid,
  structured_state jsonb,
  last_customer_message_at timestamptz,
  last_ai_message_at timestamptz,
  next_follow_up_at timestamptz,
  ai_state_version integer,
  recent_messages jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE v_role text; v_actor uuid;
BEGIN
  SELECT membership.role, membership.id INTO v_role, v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active';
  IF v_role IS NULL OR v_role NOT IN ('owner', 'manager', 'sales_agent', 'operations') THEN
    RAISE EXCEPTION 'conversation AI read is not permitted' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT conversation.id,
         conversation.channel_id,
         channel.display_name,
         coalesce(contact.display_value, client_record.display_name, lead_record.title, 'جهة اتصال غير معروفة'),
         conversation.status,
         conversation.assigned_membership_id,
         latest.created_at,
         CASE WHEN latest.message_type = 'image' THEN coalesce(latest.caption, 'صورة مرفقة') ELSE latest.body_text END,
         latest.direction,
         conversation.ai_enabled,
         conversation.conversation_type,
         conversation.lead_id,
         conversation.client_id,
         conversation.property_owner_id,
         conversation.property_id,
         conversation.structured_state,
         conversation.last_customer_message_at,
         conversation.last_ai_message_at,
         conversation.next_follow_up_at,
         conversation.ai_state_version,
         coalesce((
           SELECT jsonb_agg(
             jsonb_build_object(
               'id', recent.id,
               'direction', recent.direction,
               'message_type', recent.message_type,
               'body_text', left(recent.body_text, 2000),
               'caption', recent.caption,
               'delivery_status', recent.delivery_status,
               'media_status', recent.media_status,
               'media_mime_hint', recent.media_mime_hint,
               'media_byte_size', recent.media_byte_size,
               'media_checksum_sha256', recent.media_checksum_sha256,
               'media_storage_bucket', recent.media_storage_bucket,
               'media_storage_path', recent.media_storage_path,
               'created_at', recent.created_at
             ) ORDER BY recent.created_at ASC, recent.id ASC
           )
           FROM (
             SELECT message.id, message.direction, message.message_type,
                    message.body_text, message.caption, message.delivery_status,
                    message.media_status, message.media_mime_hint,
                    message.media_byte_size, message.media_checksum_sha256,
                    message.media_storage_bucket, message.media_storage_path,
                    message.created_at
             FROM public.whatsapp_message_events AS message
             WHERE message.organization_id = conversation.organization_id
               AND message.conversation_id = conversation.id
             ORDER BY message.created_at DESC, message.id DESC
             LIMIT 20
           ) AS recent
         ), '[]'::jsonb)
  FROM public.whatsapp_conversations AS conversation
  JOIN public.whatsapp_channels AS channel
    ON channel.organization_id = conversation.organization_id
   AND channel.id = conversation.channel_id
  LEFT JOIN public.crm_contact_methods AS contact
    ON contact.organization_id = conversation.organization_id
   AND contact.id = conversation.contact_method_id
  LEFT JOIN public.leads AS lead_record
    ON lead_record.organization_id = conversation.organization_id
   AND lead_record.id = conversation.lead_id
  LEFT JOIN public.clients AS client_record
    ON client_record.organization_id = conversation.organization_id
   AND client_record.id = conversation.client_id
  LEFT JOIN LATERAL (
    SELECT message.created_at, message.message_type, message.caption, message.body_text, message.direction
    FROM public.whatsapp_message_events AS message
    WHERE message.organization_id = conversation.organization_id
      AND message.conversation_id = conversation.id
    ORDER BY message.created_at DESC, message.id DESC
    LIMIT 1
  ) AS latest ON true
  WHERE conversation.organization_id = p_organization_id
    AND (v_role IN ('owner', 'manager') OR conversation.assigned_membership_id IS NULL OR conversation.assigned_membership_id = v_actor)
  ORDER BY conversation.last_message_at DESC NULLS LAST, conversation.created_at DESC, conversation.id DESC;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_whatsapp_media_v1(
  p_organization_id uuid,
  p_message_id uuid
)
RETURNS TABLE (
  message_id uuid,
  conversation_id uuid,
  storage_bucket text,
  storage_path text,
  mime_type text,
  byte_size bigint,
  media_status text,
  caption text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE v_role text; v_actor uuid;
BEGIN
  SELECT membership.role, membership.id INTO v_role, v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active';
  IF v_role IS NULL OR v_role NOT IN ('owner', 'manager', 'sales_agent', 'operations') THEN
    RAISE EXCEPTION 'WhatsApp media read is not permitted' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT message.id, message.conversation_id, message.media_storage_bucket,
         message.media_storage_path, message.media_mime_hint, message.media_byte_size,
         message.media_status, message.caption
  FROM public.whatsapp_message_events AS message
  JOIN public.whatsapp_conversations AS conversation
    ON conversation.organization_id = message.organization_id
   AND conversation.id = message.conversation_id
  WHERE message.organization_id = p_organization_id
    AND message.id = p_message_id
    AND message.message_type = 'image'
    AND message.media_status = 'stored'
    AND (v_role IN ('owner', 'manager') OR conversation.assigned_membership_id IS NULL OR conversation.assigned_membership_id = v_actor);
END;
$$;

CREATE OR REPLACE FUNCTION public.set_whatsapp_ai_enabled_v1(
  p_organization_id uuid,
  p_conversation_id uuid,
  p_enabled boolean,
  p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE v_actor uuid; v_before public.whatsapp_conversations%ROWTYPE; v_updated_count integer;
BEGIN
  IF p_conversation_id IS NULL OR p_enabled IS NULL THEN
    RAISE EXCEPTION 'WhatsApp AI state input is invalid' USING ERRCODE = '22023';
  END IF;
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'sales_agent', 'operations');
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'WhatsApp AI state change is not permitted' USING ERRCODE = '42501';
  END IF;
  SELECT conversation.* INTO v_before
  FROM public.whatsapp_conversations AS conversation
  WHERE conversation.organization_id = p_organization_id
    AND conversation.id = p_conversation_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'WhatsApp conversation was not found' USING ERRCODE = '23503'; END IF;
  IF p_enabled AND v_before.status = 'closed' THEN
    RAISE EXCEPTION 'closed WhatsApp conversation cannot return to AI' USING ERRCODE = '22023';
  END IF;
  UPDATE public.whatsapp_conversations
  SET ai_enabled = p_enabled,
      status = CASE WHEN p_enabled AND status = 'handoff' THEN 'open' WHEN NOT p_enabled AND status <> 'closed' THEN 'handoff' ELSE status END,
      ai_error_code = NULL,
      ai_state_version = ai_state_version + 1
  WHERE organization_id = p_organization_id AND id = p_conversation_id;
  GET DIAGNOSTICS v_updated_count = ROW_COUNT;
  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, before_delta, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'whatsapp.ai.state_changed',
    'whatsapp_conversation', p_conversation_id, 'success', p_request_id,
    jsonb_build_object('ai_enabled', v_before.ai_enabled, 'status', v_before.status),
    jsonb_build_object('ai_enabled', p_enabled, 'status', CASE WHEN p_enabled AND v_before.status = 'handoff' THEN 'open' WHEN NOT p_enabled AND v_before.status <> 'closed' THEN 'handoff' ELSE v_before.status END)
  );
  RETURN v_updated_count = 1;
END;
$$;

REVOKE ALL ON FUNCTION public.list_whatsapp_conversations_ai_v1(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_whatsapp_media_v1(uuid, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.set_whatsapp_ai_enabled_v1(uuid, uuid, boolean, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_whatsapp_conversations_ai_v1(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_whatsapp_media_v1(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_whatsapp_ai_enabled_v1(uuid, uuid, boolean, uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- Backward-compatible furnished-property command overloads
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.create_property_v1(
  p_organization_id uuid,
  p_code text,
  p_name text,
  p_timezone text,
  p_address text,
  p_city text,
  p_unit_label text,
  p_bedrooms integer,
  p_max_guests integer,
  p_operational_notes text,
  p_bathrooms integer,
  p_area_sqm numeric,
  p_floor text,
  p_furnished boolean,
  p_district text,
  p_rent_daily boolean,
  p_rent_weekly boolean,
  p_rent_monthly boolean,
  p_daily_price numeric,
  p_weekly_price numeric,
  p_monthly_price numeric,
  p_currency text,
  p_amenities text[],
  p_minimum_stay_nights integer,
  p_marketing_description text,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_actor_membership_id uuid;
  v_existing public.properties%ROWTYPE;
  v_property_id uuid;
BEGIN
  IF p_organization_id IS NULL
    OR p_code IS NULL OR char_length(btrim(p_code)) = 0
    OR p_name IS NULL OR char_length(btrim(p_name)) = 0
    OR p_timezone IS NULL OR char_length(btrim(p_timezone)) = 0
    OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) = 0
    OR p_bedrooms IS NOT NULL AND (p_bedrooms < 0 OR p_bedrooms > 100)
    OR p_max_guests IS NOT NULL AND (p_max_guests < 1 OR p_max_guests > 1000)
    OR p_bathrooms IS NOT NULL AND (p_bathrooms < 0 OR p_bathrooms > 100)
    OR p_area_sqm IS NOT NULL AND (p_area_sqm <= 0 OR p_area_sqm > 100000)
    OR p_minimum_stay_nights IS NOT NULL AND (p_minimum_stay_nights < 1 OR p_minimum_stay_nights > 3650)
    OR p_currency IS NOT NULL AND p_currency !~ '^[A-Z]{3}$'
    OR p_daily_price IS NOT NULL AND p_daily_price < 0
    OR p_weekly_price IS NOT NULL AND p_weekly_price < 0
    OR p_monthly_price IS NOT NULL AND p_monthly_price < 0
    OR (p_daily_price IS NOT NULL OR p_weekly_price IS NOT NULL OR p_monthly_price IS NOT NULL) AND p_currency IS NULL
    OR p_marketing_description IS NOT NULL AND char_length(btrim(p_marketing_description)) NOT BETWEEN 1 AND 4000
    OR p_amenities IS NOT NULL AND cardinality(p_amenities) > 50 THEN
    RAISE EXCEPTION 'property furnished-rental input is invalid' USING ERRCODE = '22023';
  END IF;
  SELECT membership.id INTO v_actor_membership_id
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'operations');
  IF v_actor_membership_id IS NULL THEN
    RAISE EXCEPTION 'property creation is not permitted' USING ERRCODE = '42501';
  END IF;
  SELECT property_record.* INTO v_existing
  FROM public.properties AS property_record
  WHERE property_record.organization_id = p_organization_id
    AND property_record.idempotency_key = btrim(p_idempotency_key);
  IF FOUND THEN
    IF v_existing.code = btrim(p_code)
      AND v_existing.name = btrim(p_name)
      AND v_existing.timezone = btrim(p_timezone)
      AND v_existing.address IS NOT DISTINCT FROM NULLIF(btrim(p_address), '')
      AND v_existing.city IS NOT DISTINCT FROM NULLIF(btrim(p_city), '')
      AND v_existing.unit_label IS NOT DISTINCT FROM NULLIF(btrim(p_unit_label), '')
      AND v_existing.bedrooms IS NOT DISTINCT FROM p_bedrooms
      AND v_existing.max_guests IS NOT DISTINCT FROM p_max_guests
      AND v_existing.operational_notes IS NOT DISTINCT FROM NULLIF(btrim(p_operational_notes), '')
      AND v_existing.bathrooms IS NOT DISTINCT FROM p_bathrooms
      AND v_existing.area_sqm IS NOT DISTINCT FROM p_area_sqm
      AND v_existing.floor IS NOT DISTINCT FROM NULLIF(btrim(p_floor), '')
      AND v_existing.furnished IS NOT DISTINCT FROM p_furnished
      AND v_existing.district IS NOT DISTINCT FROM NULLIF(btrim(p_district), '')
      AND v_existing.rent_daily = coalesce(p_rent_daily, false)
      AND v_existing.rent_weekly = coalesce(p_rent_weekly, false)
      AND v_existing.rent_monthly = coalesce(p_rent_monthly, false)
      AND v_existing.daily_price IS NOT DISTINCT FROM p_daily_price
      AND v_existing.weekly_price IS NOT DISTINCT FROM p_weekly_price
      AND v_existing.monthly_price IS NOT DISTINCT FROM p_monthly_price
      AND v_existing.currency IS NOT DISTINCT FROM p_currency
      AND v_existing.amenities IS NOT DISTINCT FROM p_amenities
      AND v_existing.minimum_stay_nights IS NOT DISTINCT FROM p_minimum_stay_nights
      AND v_existing.marketing_description IS NOT DISTINCT FROM NULLIF(btrim(p_marketing_description), '')
      AND v_existing.status = 'active' THEN
      RETURN v_existing.id;
    END IF;
    RAISE EXCEPTION 'idempotency key belongs to a different property' USING ERRCODE = '23505';
  END IF;
  INSERT INTO public.properties (
    organization_id, code, name, timezone, address, city, unit_label,
    bedrooms, max_guests, operational_notes, bathrooms, area_sqm, floor,
    furnished, district, rent_daily, rent_weekly, rent_monthly,
    daily_price, weekly_price, monthly_price, currency, amenities,
    minimum_stay_nights, marketing_description, status, idempotency_key
  ) VALUES (
    p_organization_id, btrim(p_code), btrim(p_name), btrim(p_timezone),
    NULLIF(btrim(p_address), ''), NULLIF(btrim(p_city), ''), NULLIF(btrim(p_unit_label), ''),
    p_bedrooms, p_max_guests, NULLIF(btrim(p_operational_notes), ''), p_bathrooms,
    p_area_sqm, NULLIF(btrim(p_floor), ''), p_furnished, NULLIF(btrim(p_district), ''),
    coalesce(p_rent_daily, false), coalesce(p_rent_weekly, false), coalesce(p_rent_monthly, false),
    p_daily_price, p_weekly_price, p_monthly_price, p_currency, p_amenities,
    p_minimum_stay_nights, NULLIF(btrim(p_marketing_description), ''), 'active', btrim(p_idempotency_key)
  ) RETURNING id INTO v_property_id;
  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor_membership_id, 'property.created',
    'property', v_property_id, 'success', p_request_id,
    jsonb_build_object('code', btrim(p_code), 'name', btrim(p_name), 'status', 'active', 'city', NULLIF(btrim(p_city), ''), 'furnished', p_furnished)
  );
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload)
  VALUES (
    p_organization_id, 'property.created', 1, 'property-v1:' || v_property_id::text,
    jsonb_build_object('property_id', v_property_id)
  );
  RETURN v_property_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.list_properties_v1_extended(p_organization_id uuid)
RETURNS TABLE (
  id uuid, code text, name text, timezone text, address text, city text,
  unit_label text, bedrooms integer, max_guests integer, operational_notes text,
  bathrooms integer, area_sqm numeric, floor text, furnished boolean, district text,
  rent_daily boolean, rent_weekly boolean, rent_monthly boolean,
  daily_price numeric, weekly_price numeric, monthly_price numeric, currency text,
  amenities text[], minimum_stay_nights integer, marketing_description text,
  status text, version integer, created_at timestamptz, updated_at timestamptz,
  archived_at timestamptz, current_property_owner_id uuid,
  current_property_owner_name text, image_count integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.organization_memberships AS membership
    WHERE membership.organization_id = p_organization_id
      AND membership.user_id = auth.uid()
      AND membership.status = 'active'
  ) THEN
    RAISE EXCEPTION 'property read is not permitted' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT property_record.id, property_record.code, property_record.name,
    property_record.timezone, property_record.address, property_record.city,
    property_record.unit_label, property_record.bedrooms, property_record.max_guests,
    property_record.operational_notes, property_record.bathrooms, property_record.area_sqm,
    property_record.floor, property_record.furnished, property_record.district,
    property_record.rent_daily, property_record.rent_weekly, property_record.rent_monthly,
    property_record.daily_price, property_record.weekly_price, property_record.monthly_price,
    property_record.currency, property_record.amenities, property_record.minimum_stay_nights,
    property_record.marketing_description, property_record.status, property_record.version,
    property_record.created_at, property_record.updated_at, property_record.archived_at,
    current_owner.property_owner_id, current_owner.display_name,
    (SELECT count(*)::integer FROM public.property_images AS image
     WHERE image.organization_id = p_organization_id
       AND image.property_id = property_record.id AND image.status = 'active')
  FROM public.properties AS property_record
  LEFT JOIN LATERAL (
    SELECT period.property_owner_id, owner_record.display_name
    FROM public.property_ownership_periods AS period
    JOIN public.property_owners AS owner_record
      ON owner_record.organization_id = period.organization_id
     AND owner_record.id = period.property_owner_id
    WHERE period.organization_id = p_organization_id
      AND period.property_id = property_record.id
      AND period.start_date <= CURRENT_DATE
      AND period.end_date > CURRENT_DATE
      AND owner_record.status = 'active'
    ORDER BY period.is_primary_contact DESC, period.start_date DESC, period.id DESC
    LIMIT 1
  ) AS current_owner ON true
  WHERE property_record.organization_id = p_organization_id
  ORDER BY property_record.created_at DESC, property_record.id DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.create_property_v1(uuid, text, text, text, text, text, text, integer, integer, text, integer, numeric, text, boolean, text, boolean, boolean, boolean, numeric, numeric, numeric, text, text[], integer, text, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_properties_v1_extended(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_property_v1(uuid, text, text, text, text, text, text, integer, integer, text, integer, numeric, text, boolean, text, boolean, boolean, boolean, numeric, numeric, numeric, text, text[], integer, text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_properties_v1_extended(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.update_property_v1(
  p_organization_id uuid,
  p_property_id uuid,
  p_code text,
  p_name text,
  p_timezone text,
  p_address text,
  p_city text,
  p_unit_label text,
  p_bedrooms integer,
  p_max_guests integer,
  p_operational_notes text,
  p_status text,
  p_bathrooms integer,
  p_area_sqm numeric,
  p_floor text,
  p_furnished boolean,
  p_district text,
  p_rent_daily boolean,
  p_rent_weekly boolean,
  p_rent_monthly boolean,
  p_daily_price numeric,
  p_weekly_price numeric,
  p_monthly_price numeric,
  p_currency text,
  p_amenities text[],
  p_minimum_stay_nights integer,
  p_marketing_description text,
  p_expected_version integer,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_actor_membership_id uuid;
  v_existing_command public.property_v1_command_idempotency%ROWTYPE;
  v_before public.properties%ROWTYPE;
  v_new_version integer;
BEGIN
  IF p_organization_id IS NULL OR p_property_id IS NULL
    OR p_code IS NULL OR char_length(btrim(p_code)) = 0
    OR p_name IS NULL OR char_length(btrim(p_name)) = 0
    OR p_timezone IS NULL OR char_length(btrim(p_timezone)) = 0
    OR p_status NOT IN ('active', 'inactive')
    OR p_expected_version IS NULL OR p_expected_version < 1
    OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) = 0
    OR p_bedrooms IS NOT NULL AND (p_bedrooms < 0 OR p_bedrooms > 100)
    OR p_max_guests IS NOT NULL AND (p_max_guests < 1 OR p_max_guests > 1000)
    OR p_bathrooms IS NOT NULL AND (p_bathrooms < 0 OR p_bathrooms > 100)
    OR p_area_sqm IS NOT NULL AND (p_area_sqm <= 0 OR p_area_sqm > 100000)
    OR p_minimum_stay_nights IS NOT NULL AND (p_minimum_stay_nights < 1 OR p_minimum_stay_nights > 3650)
    OR p_currency IS NOT NULL AND p_currency !~ '^[A-Z]{3}$'
    OR p_daily_price IS NOT NULL AND p_daily_price < 0
    OR p_weekly_price IS NOT NULL AND p_weekly_price < 0
    OR p_monthly_price IS NOT NULL AND p_monthly_price < 0
    OR (p_daily_price IS NOT NULL OR p_weekly_price IS NOT NULL OR p_monthly_price IS NOT NULL) AND p_currency IS NULL
    OR p_marketing_description IS NOT NULL AND char_length(btrim(p_marketing_description)) NOT BETWEEN 1 AND 4000
    OR p_amenities IS NOT NULL AND cardinality(p_amenities) > 50 THEN
    RAISE EXCEPTION 'property furnished-rental update input is invalid' USING ERRCODE = '22023';
  END IF;
  SELECT membership.id INTO v_actor_membership_id
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'operations');
  IF v_actor_membership_id IS NULL THEN
    RAISE EXCEPTION 'property update is not permitted' USING ERRCODE = '42501';
  END IF;
  SELECT command_record.* INTO v_existing_command
  FROM public.property_v1_command_idempotency AS command_record
  WHERE command_record.organization_id = p_organization_id
    AND command_record.command = 'property.update'
    AND command_record.idempotency_key = btrim(p_idempotency_key);
  IF FOUND THEN
    IF v_existing_command.resource_id = p_property_id THEN RETURN true; END IF;
    RAISE EXCEPTION 'idempotency key belongs to a different property update' USING ERRCODE = '23505';
  END IF;
  SELECT property_record.* INTO v_before
  FROM public.properties AS property_record
  WHERE property_record.organization_id = p_organization_id
    AND property_record.id = p_property_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'property was not found' USING ERRCODE = '23503'; END IF;
  IF v_before.status = 'archived' THEN
    RAISE EXCEPTION 'archived property must be restored before editing' USING ERRCODE = '22023';
  END IF;
  UPDATE public.properties
  SET code = btrim(p_code), name = btrim(p_name), timezone = btrim(p_timezone),
      address = NULLIF(btrim(p_address), ''), city = NULLIF(btrim(p_city), ''),
      unit_label = NULLIF(btrim(p_unit_label), ''), bedrooms = p_bedrooms,
      max_guests = p_max_guests, operational_notes = NULLIF(btrim(p_operational_notes), ''),
      status = p_status, bathrooms = p_bathrooms, area_sqm = p_area_sqm,
      floor = NULLIF(btrim(p_floor), ''), furnished = p_furnished,
      district = NULLIF(btrim(p_district), ''), rent_daily = coalesce(p_rent_daily, false),
      rent_weekly = coalesce(p_rent_weekly, false), rent_monthly = coalesce(p_rent_monthly, false),
      daily_price = p_daily_price, weekly_price = p_weekly_price,
      monthly_price = p_monthly_price, currency = p_currency, amenities = p_amenities,
      minimum_stay_nights = p_minimum_stay_nights,
      marketing_description = NULLIF(btrim(p_marketing_description), ''),
      archived_at = NULL, version = version + 1
  WHERE organization_id = p_organization_id
    AND id = p_property_id
    AND version = p_expected_version
  RETURNING version INTO v_new_version;
  IF NOT FOUND THEN RAISE EXCEPTION 'property version is stale' USING ERRCODE = '40001'; END IF;
  INSERT INTO public.property_v1_command_idempotency (
    organization_id, command, resource_id, idempotency_key, result_version
  ) VALUES (p_organization_id, 'property.update', p_property_id, btrim(p_idempotency_key), v_new_version);
  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, before_delta, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor_membership_id, 'property.updated',
    'property', p_property_id, 'success', p_request_id,
    jsonb_build_object('version', v_before.version, 'status', v_before.status),
    jsonb_build_object('version', v_new_version, 'status', p_status, 'furnished', p_furnished)
  );
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload)
  VALUES (
    p_organization_id, 'property.updated', 1,
    'property-v1-update:' || p_property_id::text || ':' || btrim(p_idempotency_key),
    jsonb_build_object('property_id', p_property_id, 'version', v_new_version)
  );
  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.update_property_v1(uuid, uuid, text, text, text, text, text, text, integer, integer, text, text, integer, numeric, text, boolean, text, boolean, boolean, boolean, numeric, numeric, numeric, text, text[], integer, text, integer, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_property_v1(uuid, uuid, text, text, text, text, text, text, integer, integer, text, text, integer, numeric, text, boolean, text, boolean, boolean, boolean, numeric, numeric, numeric, text, text[], integer, text, integer, text, uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- Human-owned property draft confirmation claim/finalization
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.claim_whatsapp_property_confirmation_v1(
  p_organization_id uuid,
  p_conversation_id uuid,
  p_confirmation_payload jsonb,
  p_expected_version integer,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS TABLE (
  outcome text,
  confirmation_token uuid,
  conversation_version integer,
  confirmation_payload jsonb,
  confirmation_result jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_actor uuid;
  v_conversation public.whatsapp_conversations%ROWTYPE;
  v_token uuid;
BEGIN
  IF p_conversation_id IS NULL OR p_confirmation_payload IS NULL
    OR jsonb_typeof(p_confirmation_payload) <> 'object'
    OR char_length(p_confirmation_payload::text) > 30000
    OR p_expected_version IS NULL OR p_expected_version < 1
    OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160 THEN
    RAISE EXCEPTION 'WhatsApp property confirmation input is invalid' USING ERRCODE = '22023';
  END IF;
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'operations');
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'WhatsApp property confirmation is not permitted' USING ERRCODE = '42501';
  END IF;
  SELECT conversation.* INTO v_conversation
  FROM public.whatsapp_conversations AS conversation
  WHERE conversation.organization_id = p_organization_id
    AND conversation.id = p_conversation_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'WhatsApp conversation was not found' USING ERRCODE = '23503'; END IF;
  IF v_conversation.conversation_type <> 'owner_onboarding' THEN
    RAISE EXCEPTION 'conversation is not an owner draft' USING ERRCODE = '22023';
  END IF;
  IF v_conversation.confirmation_key = btrim(p_idempotency_key)
    AND v_conversation.confirmation_status IN ('confirmed', 'partially_applied', 'needs_review') THEN
    RETURN QUERY SELECT v_conversation.confirmation_status, v_conversation.confirmation_token,
      v_conversation.ai_state_version, v_conversation.confirmation_payload, v_conversation.confirmation_result;
    RETURN;
  END IF;
  IF v_conversation.confirmation_status = 'claimed'
    AND v_conversation.confirmation_key = btrim(p_idempotency_key)
    AND v_conversation.confirmation_token IS NOT NULL THEN
    RETURN QUERY SELECT 'claimed', v_conversation.confirmation_token,
      v_conversation.ai_state_version, v_conversation.confirmation_payload, v_conversation.confirmation_result;
    RETURN;
  END IF;
  IF v_conversation.confirmation_status = 'claimed'
    AND v_conversation.confirmation_claimed_at > timezone('utc', now()) - interval '30 minutes' THEN
    RETURN QUERY SELECT 'in_progress', v_conversation.confirmation_token,
      v_conversation.ai_state_version, v_conversation.confirmation_payload, v_conversation.confirmation_result;
    RETURN;
  END IF;
  IF v_conversation.ai_state_version <> p_expected_version THEN
    RAISE EXCEPTION 'WhatsApp property draft version is stale' USING ERRCODE = '40001';
  END IF;
  v_token := extensions.gen_random_uuid();
  UPDATE public.whatsapp_conversations
  SET confirmation_status = 'claimed',
      confirmation_key = btrim(p_idempotency_key),
      confirmation_token = v_token,
      confirmation_claimed_at = timezone('utc', now()),
      confirmation_payload = p_confirmation_payload,
      ai_state_version = ai_state_version + 1
  WHERE organization_id = p_organization_id AND id = p_conversation_id;
  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'whatsapp.property_confirmation.claimed',
    'whatsapp_conversation', p_conversation_id, 'success', p_request_id,
    jsonb_build_object('confirmation_key', btrim(p_idempotency_key))
  );
  RETURN QUERY SELECT 'claimed', v_token, v_conversation.ai_state_version + 1,
    p_confirmation_payload, v_conversation.confirmation_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.finalize_whatsapp_property_confirmation_v1(
  p_organization_id uuid,
  p_conversation_id uuid,
  p_confirmation_token uuid,
  p_property_owner_id uuid,
  p_property_id uuid,
  p_status text,
  p_confirmation_result jsonb,
  p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_actor uuid;
  v_conversation public.whatsapp_conversations%ROWTYPE;
  v_updated_count integer;
BEGIN
  IF p_conversation_id IS NULL OR p_confirmation_token IS NULL
    OR p_status IS NULL OR p_status NOT IN ('confirmed', 'partially_applied', 'needs_review')
    OR p_confirmation_result IS NULL OR jsonb_typeof(p_confirmation_result) <> 'object'
    OR char_length(p_confirmation_result::text) > 30000 THEN
    RAISE EXCEPTION 'WhatsApp property finalization input is invalid' USING ERRCODE = '22023';
  END IF;
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'operations');
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'WhatsApp property finalization is not permitted' USING ERRCODE = '42501';
  END IF;
  IF p_property_owner_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.property_owners AS owner_record
    WHERE owner_record.organization_id = p_organization_id
      AND owner_record.id = p_property_owner_id
      AND owner_record.status = 'active'
  ) THEN RAISE EXCEPTION 'property owner is invalid' USING ERRCODE = '23503'; END IF;
  IF p_property_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.properties AS property_record
    WHERE property_record.organization_id = p_organization_id
      AND property_record.id = p_property_id
      AND property_record.status <> 'archived'
  ) THEN RAISE EXCEPTION 'property is invalid' USING ERRCODE = '23503'; END IF;
  SELECT conversation.* INTO v_conversation
  FROM public.whatsapp_conversations AS conversation
  WHERE conversation.organization_id = p_organization_id
    AND conversation.id = p_conversation_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'WhatsApp conversation was not found' USING ERRCODE = '23503'; END IF;
  IF v_conversation.confirmation_token <> p_confirmation_token THEN
    RAISE EXCEPTION 'WhatsApp property confirmation token is stale' USING ERRCODE = '40001';
  END IF;
  IF p_status = 'confirmed' AND (p_property_owner_id IS NULL OR p_property_id IS NULL) THEN
    RAISE EXCEPTION 'confirmed property result is incomplete' USING ERRCODE = '22023';
  END IF;
  IF p_status = 'confirmed' AND NOT EXISTS (
    SELECT 1
    FROM public.property_ownership_periods AS period
    WHERE period.organization_id = p_organization_id
      AND period.property_id = p_property_id
      AND period.property_owner_id = p_property_owner_id
  ) THEN
    RAISE EXCEPTION 'confirmed property owner relationship is missing' USING ERRCODE = '23503';
  END IF;
  UPDATE public.whatsapp_conversations
  SET property_owner_id = coalesce(p_property_owner_id, property_owner_id),
      property_id = coalesce(p_property_id, property_id),
      confirmation_status = p_status,
      confirmation_result = p_confirmation_result,
      confirmation_token = CASE WHEN p_status = 'confirmed' THEN NULL ELSE confirmation_token END,
      confirmation_claimed_at = CASE WHEN p_status = 'confirmed' THEN NULL ELSE confirmation_claimed_at END,
      ai_state_version = ai_state_version + 1
  WHERE organization_id = p_organization_id
    AND id = p_conversation_id
    AND confirmation_token = p_confirmation_token;
  GET DIAGNOSTICS v_updated_count = ROW_COUNT;
  IF v_updated_count = 1 THEN
    INSERT INTO public.audit_events (
      organization_id, actor_type, actor_membership_id, action, resource_type,
      resource_id, outcome, request_id, after_delta
    ) VALUES (
      p_organization_id, 'user', v_actor, 'whatsapp.property_confirmation.finalized',
      'whatsapp_conversation', p_conversation_id, 'success', p_request_id,
      jsonb_build_object('status', p_status, 'property_owner_id', p_property_owner_id, 'property_id', p_property_id)
    );
  END IF;
  RETURN v_updated_count = 1;
END;
$$;

REVOKE ALL ON FUNCTION public.claim_whatsapp_property_confirmation_v1(uuid, uuid, jsonb, integer, text, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.finalize_whatsapp_property_confirmation_v1(uuid, uuid, uuid, uuid, uuid, text, jsonb, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.claim_whatsapp_property_confirmation_v1(uuid, uuid, jsonb, integer, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.finalize_whatsapp_property_confirmation_v1(uuid, uuid, uuid, uuid, uuid, text, jsonb, uuid) TO authenticated;
