-- OpenWA ingestion is tenant-bound, idempotent, and service-role only.
\set ON_ERROR_STOP on

DO $$
BEGIN
  IF to_regprocedure('public.ingest_whatsapp_openwa_event_v1(text,text,text,text,text,text,text,text,text,text,text,text,text,timestamptz)') IS NULL THEN
    RAISE EXCEPTION 'OpenWA webhook ingestion RPC is missing';
  END IF;
  IF has_function_privilege('anon', 'public.ingest_whatsapp_openwa_event_v1(text,text,text,text,text,text,text,text,text,text,text,text,text,timestamptz)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.ingest_whatsapp_openwa_event_v1(text,text,text,text,text,text,text,text,text,text,text,text,text,timestamptz)', 'EXECUTE') THEN
    RAISE EXCEPTION 'OpenWA webhook ingestion must not be callable by browser roles';
  END IF;
  IF NOT has_function_privilege('service_role', 'public.ingest_whatsapp_openwa_event_v1(text,text,text,text,text,text,text,text,text,text,text,text,text,timestamptz)', 'EXECUTE') THEN
    RAISE EXCEPTION 'service role must be able to invoke OpenWA webhook ingestion';
  END IF;
  IF has_table_privilege('authenticated', 'public.whatsapp_message_events', 'INSERT')
    OR has_table_privilege('authenticated', 'public.whatsapp_message_events', 'UPDATE') THEN
    RAISE EXCEPTION 'OpenWA must preserve browser write denial';
  END IF;
END;
$$;

SELECT id AS openwa_creator_a
FROM public.organization_memberships
WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  AND user_id = '11111111-1111-1111-1111-111111111111' \gset
SELECT id AS openwa_creator_b
FROM public.organization_memberships
WHERE organization_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
  AND user_id = '22222222-2222-2222-2222-222222222222' \gset

INSERT INTO public.whatsapp_channels (
  organization_id, provider, external_channel_id, display_name, created_by_membership_id
) VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'openwa', 'opaque-openwa-session-a', 'OpenWA A', :'openwa_creator_a'::uuid),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'openwa', 'opaque-openwa-session-b', 'OpenWA B', :'openwa_creator_b'::uuid);

SELECT id AS openwa_channel_a
FROM public.whatsapp_channels
WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  AND provider = 'openwa'
  AND external_channel_id = 'opaque-openwa-session-a' \gset
SELECT id AS openwa_channel_b
FROM public.whatsapp_channels
WHERE organization_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
  AND provider = 'openwa'
  AND external_channel_id = 'opaque-openwa-session-b' \gset

INSERT INTO public.whatsapp_conversations (
  organization_id, channel_id, external_conversation_key, ai_enabled
) VALUES (
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'openwa_channel_a'::uuid, '201001234567@c.us', true
), (
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'openwa_channel_a'::uuid, '93847561029384@lid', true
);
INSERT INTO public.whatsapp_conversations (
  organization_id, channel_id, external_conversation_key, last_message_at
) VALUES (
  'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', :'openwa_channel_b'::uuid,
  '201001234567@c.us', '2020-01-01T00:00:00Z'
);

DO $$
BEGIN
  IF public.resolve_whatsapp_webhook_provider_v1('opaque-openwa-session-a', 'openwa') <> 'openwa' THEN
    RAISE EXCEPTION 'active OpenWA session must resolve to its OpenWA provider';
  END IF;
  IF public.resolve_whatsapp_webhook_provider_v1(' sandbox-channel-a ', 'meta_cloud_sandbox') <> 'meta_cloud_sandbox' THEN
    RAISE EXCEPTION 'OpenWA canonical rejection must preserve Meta resolver input behavior';
  END IF;

  BEGIN
    INSERT INTO public.whatsapp_channels (
      organization_id, provider, external_channel_id, display_name, created_by_membership_id
    ) VALUES (
      'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'openwa', 'opaque-openwa-session-a', 'Duplicate OpenWA B',
      (SELECT id FROM public.organization_memberships
       WHERE organization_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
         AND user_id = '22222222-2222-2222-2222-222222222222')
    );
    RAISE EXCEPTION 'duplicate OpenWA session IDs across organizations must be rejected';
  EXCEPTION WHEN unique_violation THEN
    NULL;
  END;

  BEGIN
    PERFORM public.resolve_whatsapp_webhook_provider_v1('unknown-openwa-session', 'openwa');
    RAISE EXCEPTION 'unknown OpenWA session must not resolve';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

  BEGIN
    PERFORM public.ingest_whatsapp_openwa_event_v1(
      'sandbox-channel-a', '201001234567@c.us', 'openwa:wrong-provider', 'wrong-provider-message',
      '201001234567@c.us', '201001234567', NULL, 'inbound', 'text', 'wrong provider',
      NULL, NULL, NULL, timezone('utc', now())
    );
    RAISE EXCEPTION 'OpenWA ingest must reject an external channel configured for Meta';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END;
$$;

SET ROLE service_role;
DO $$
BEGIN
  BEGIN
    PERFORM public.resolve_whatsapp_webhook_provider_v1('opaque-openwa-session-a ', 'openwa');
    RAISE EXCEPTION 'provider resolver must reject a session ID changed by trimming';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    NULL;
  END;

  BEGIN
    PERFORM public.ingest_whatsapp_openwa_event_v1(
      ' opaque-openwa-session-a ', '201001234568@c.us', 'openwa:padded-session', 'OPENWA_PADDED_001',
      '201001234568@c.us', '201001234568', NULL, 'inbound', 'text', 'padded session',
      NULL, NULL, NULL, timezone('utc', now())
    );
    RAISE EXCEPTION 'ingest must reject a session ID changed by trimming';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    NULL;
  END;

  BEGIN
    PERFORM public.ingest_whatsapp_openwa_event_v1(
      'opaque-openwa-session-a', ' 201001234568@c.us ', 'openwa:padded-chat', 'OPENWA_PADDED_002',
      ' 201001234568@c.us ', '201001234568', NULL, 'inbound', 'text', 'padded chat',
      NULL, NULL, NULL, timezone('utc', now())
    );
    RAISE EXCEPTION 'ingest must reject a chat JID changed by trimming';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    NULL;
  END;

  BEGIN
    PERFORM public.ingest_whatsapp_openwa_event_v1(
      'opaque-openwa-session-a', '201001234568@c.us', ' openwa:padded-event ', 'OPENWA_PADDED_003',
      '201001234568@c.us', '201001234568', NULL, 'inbound', 'text', 'padded event key',
      NULL, NULL, NULL, timezone('utc', now())
    );
    RAISE EXCEPTION 'ingest must reject an event key changed by trimming';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    NULL;
  END;

  BEGIN
    PERFORM public.ingest_whatsapp_openwa_event_v1(
      'opaque-openwa-session-a', '201001234568@c.us', 'openwa:padded-message', ' OPENWA_PADDED_004 ',
      '201001234568@c.us', '201001234568', NULL, 'inbound', 'text', 'padded message ID',
      NULL, NULL, NULL, timezone('utc', now())
    );
    RAISE EXCEPTION 'ingest must reject a provider message ID changed by trimming';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    NULL;
  END;

  BEGIN
    PERFORM public.ingest_whatsapp_openwa_event_v1(
      'opaque-openwa-session-a', '201001234568@c.us', 'openwa:padded-jid', 'OPENWA_PADDED_005',
      ' 201001234568@c.us ', '201001234568', NULL, 'inbound', 'text', 'padded contact JID',
      NULL, NULL, NULL, timezone('utc', now())
    );
    RAISE EXCEPTION 'ingest must reject a contact JID changed by trimming';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    NULL;
  END;

  BEGIN
    PERFORM public.ingest_whatsapp_openwa_event_v1(
      'opaque-openwa-session-a', '201001234568@c.us', 'openwa:padded-media-id', 'OPENWA_PADDED_006',
      '201001234568@c.us', '201001234568', NULL, 'inbound', 'image', NULL,
      ' OPENWA_PADDED_006 ', 'image/jpeg', NULL, timezone('utc', now())
    );
    RAISE EXCEPTION 'ingest must reject a provider media ID changed by trimming';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    NULL;
  END;
END;
$$;
RESET ROLE;

SET ROLE service_role;
SELECT public.resolve_whatsapp_webhook_provider_v1('opaque-openwa-session-a', 'openwa') AS resolved_provider \gset
SELECT public.ingest_whatsapp_openwa_event_v1(
  'opaque-openwa-session-a', '201001234567@c.us', 'openwa:inbound-event-a', 'OPENWA_MESSAGE_IN_001',
  '201001234567@c.us', '201001234567', 'Customer A', 'inbound', 'text', 'Inbound OpenWA message',
  NULL, NULL, NULL, timezone('utc', now())
) AS openwa_inbound_id \gset
SELECT public.ingest_whatsapp_openwa_event_v1(
  'opaque-openwa-session-a', '201001234567@c.us', 'openwa:inbound-event-a', 'OPENWA_MESSAGE_IN_001',
  '201001234567@c.us', '201001234567', 'Customer A', 'inbound', 'text', 'Inbound OpenWA message',
  NULL, NULL, NULL, timezone('utc', now())
) AS openwa_inbound_duplicate_id \gset
RESET ROLE;

SELECT set_config('voya.test.openwa_inbound_id', :'openwa_inbound_id', false);
SELECT set_config('voya.test.openwa_inbound_duplicate_id', :'openwa_inbound_duplicate_id', false);
SELECT set_config(
  'voya.test.openwa_conversation_id',
  (SELECT conversation_id::text FROM public.whatsapp_message_events WHERE id = :'openwa_inbound_id'::uuid),
  false
);

DO $$
BEGIN
  IF current_setting('voya.test.openwa_inbound_id') <> current_setting('voya.test.openwa_inbound_duplicate_id') THEN
    RAISE EXCEPTION 'OpenWA retries must return the original message ID';
  END IF;
  IF (SELECT count(*) FROM public.whatsapp_message_events
      WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND event_key = 'openwa:inbound-event-a'
        AND direction = 'inbound'
        AND provider_message_id = 'OPENWA_MESSAGE_IN_001') <> 1 THEN
    RAISE EXCEPTION 'inbound OpenWA event must be stored once with its provider ID';
  END IF;
  IF (SELECT count(*) FROM public.ai_runs
      WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND idempotency_key = 'whatsapp-message:' || current_setting('voya.test.openwa_inbound_id')) <> 1 THEN
    RAISE EXCEPTION 'eligible inbound OpenWA event must enqueue exactly one AI run';
  END IF;
  IF (SELECT count(*) FROM public.outbox_events
      WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND event_type = 'whatsapp.ai.respond_requested'
        AND dedupe_key = 'whatsapp-ai:' || current_setting('voya.test.openwa_inbound_id')) <> 1 THEN
    RAISE EXCEPTION 'eligible inbound OpenWA event must enqueue exactly one AI outbox event';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.whatsapp_message_events AS message
    WHERE message.organization_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
      AND message.conversation_id = (
        SELECT conversation.id FROM public.whatsapp_conversations AS conversation
        WHERE conversation.organization_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
          AND conversation.external_conversation_key = '201001234567@c.us'
      )
  ) THEN
    RAISE EXCEPTION 'OpenWA ingest must not write a same-JID conversation in another tenant';
  END IF;
END;
$$;

SELECT count(*) AS prior_ai_runs
FROM public.ai_runs
WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' \gset
SELECT count(*) AS prior_ai_outbox
FROM public.outbox_events
WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  AND event_type = 'whatsapp.ai.respond_requested' \gset
SELECT last_customer_message_at AS prior_customer_at
FROM public.whatsapp_conversations
WHERE id = current_setting('voya.test.openwa_conversation_id')::uuid \gset
SELECT set_config('voya.test.prior_ai_runs', :'prior_ai_runs', false);
SELECT set_config('voya.test.prior_ai_outbox', :'prior_ai_outbox', false);
SELECT set_config('voya.test.prior_customer_at', coalesce(:'prior_customer_at', ''), false);

SET ROLE service_role;
SELECT public.ingest_whatsapp_openwa_event_v1(
  'opaque-openwa-session-a', '201001234567@c.us', 'openwa:outbound-event-a', 'OPENWA_MESSAGE_OUT_001',
  '201001234567@c.us', '201001234567', NULL, 'outbound', 'text', 'Phone-originated echo',
  NULL, NULL, NULL, timezone('utc', now())
) AS openwa_outbound_id \gset
RESET ROLE;

SELECT set_config('voya.test.openwa_outbound_id', :'openwa_outbound_id', false);

DO $$
BEGIN
  IF (SELECT count(*) FROM public.whatsapp_message_events
      WHERE id = current_setting('voya.test.openwa_outbound_id')::uuid
        AND direction = 'outbound'
        AND delivery_status = 'sent'
        AND provider_message_id = 'OPENWA_MESSAGE_OUT_001') <> 1 THEN
    RAISE EXCEPTION 'phone-originated OpenWA echo must be stored as outbound and sent';
  END IF;
  IF (SELECT count(*) FROM public.ai_runs
      WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') <> current_setting('voya.test.prior_ai_runs')::integer
    OR (SELECT count(*) FROM public.outbox_events
        WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
          AND event_type = 'whatsapp.ai.respond_requested') <> current_setting('voya.test.prior_ai_outbox')::integer THEN
    RAISE EXCEPTION 'outbound OpenWA echo must not enqueue AI or outbox work';
  END IF;
  IF (SELECT last_customer_message_at FROM public.whatsapp_conversations
      WHERE id = current_setting('voya.test.openwa_conversation_id')::uuid)
      IS DISTINCT FROM NULLIF(current_setting('voya.test.prior_customer_at'), '')::timestamptz THEN
    RAISE EXCEPTION 'outbound OpenWA echo must not advance last_customer_message_at';
  END IF;
END;
$$;

SET ROLE service_role;
SELECT public.ingest_whatsapp_openwa_event_v1(
  'opaque-openwa-session-a', '93847561029384@lid', 'openwa:lid-event-a', 'OPENWA_LID_MESSAGE_001',
  '93847561029384@lid', NULL, 'LID customer', 'inbound', 'text', 'LID inquiry',
  NULL, NULL, NULL, timezone('utc', now())
) AS openwa_lid_message_id \gset
RESET ROLE;

SELECT conversation_id::text AS openwa_lid_conversation_id
FROM public.whatsapp_message_events
WHERE id = :'openwa_lid_message_id'::uuid \gset
SELECT set_config('voya.test.openwa_lid_conversation_id', :'openwa_lid_conversation_id', false);
SELECT id AS openwa_lid_ai_event_id
FROM public.outbox_events
WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  AND event_type = 'whatsapp.ai.respond_requested'
  AND payload ->> 'message_id' = :'openwa_lid_message_id' \gset

SET ROLE service_role;
SELECT id
FROM public.claim_outbox_delivery_events('openwa-lid-worker', 20, 300)
WHERE id = :'openwa_lid_ai_event_id'::uuid \gset
-- The provider-aware worker must pass false for OpenWA until Task 4 adds the
-- separate OPENWA_OUTBOUND_ENABLED configuration gate.
SELECT * FROM public.apply_whatsapp_ai_result_v1(
  :'openwa_lid_ai_event_id'::uuid,
  'openwa-lid-worker',
  'client_sales',
  jsonb_build_object(
    'language', 'en',
    'lead', jsonb_build_object(
      'name', 'LID customer', 'phone', '93847561029384@lid', 'whatsapp', '93847561029384@lid',
      'requestedArea', NULL, 'checkIn', NULL, 'checkOut', NULL,
      'guests', NULL, 'bedrooms', NULL, 'budgetText', NULL, 'notes', NULL
    ),
    'owner', NULL, 'property', NULL, 'missingFields', jsonb_build_array()
  ),
  NULL, 'continue', 'high', false
);
RESET ROLE;

DO $$
DECLARE
  v_contact public.crm_contact_methods%ROWTYPE;
  v_lead public.leads%ROWTYPE;
  v_failures text[] := ARRAY[]::text[];
BEGIN
  SELECT contact.* INTO v_contact
  FROM public.crm_contact_methods AS contact
  WHERE contact.organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    AND contact.kind = 'whatsapp'
    AND contact.normalized_value = 'openwa-jid:93847561029384@lid';
  IF NOT FOUND OR v_contact.display_value <> 'LID customer' THEN
    v_failures := array_append(v_failures, 'unresolved LID contact/display identity');
  END IF;
  SELECT lead_record.* INTO v_lead
  FROM public.leads AS lead_record
  WHERE lead_record.organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    AND lead_record.idempotency_key = 'whatsapp-conversation:' || current_setting('voya.test.openwa_lid_conversation_id');
  IF NOT FOUND THEN
    v_failures := array_append(v_failures, 'AI lead was not projected');
  ELSE
    IF v_lead.phone IS NOT NULL OR v_lead.whatsapp IS NOT NULL OR v_lead.normalized_phone IS NOT NULL THEN
      v_failures := array_append(v_failures, 'raw LID JID copied or normalized into CRM phone fields');
    END IF;
    IF v_lead.title LIKE '%openwa-jid:%' OR v_lead.title LIKE '%@lid%' THEN
      v_failures := array_append(v_failures, 'raw LID JID copied into CRM lead title');
    END IF;
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.outbox_events AS event
    WHERE event.organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND event.event_type = 'whatsapp.message.send_requested'
      AND event.payload ->> 'conversation_id' = current_setting('voya.test.openwa_lid_conversation_id')
  ) THEN
    v_failures := array_append(v_failures, 'OpenWA AI result queued an outbound reply');
  END IF;
  IF cardinality(v_failures) > 0 THEN
    RAISE EXCEPTION 'OpenWA LID/reply safety regressions: %', array_to_string(v_failures, ', ');
  END IF;
END;
$$;

SET ROLE service_role;
SELECT public.ingest_whatsapp_openwa_event_v1(
  'opaque-openwa-session-a', '93847561029384@lid', 'openwa:lid-phone-event-a', 'OPENWA_LID_PHONE_MESSAGE_002',
  '93847561029384@lid', NULL, 'LID customer', 'inbound', 'text', 'Plain phone fact supplied separately',
  NULL, NULL, NULL, timezone('utc', now())
) AS openwa_lid_phone_message_id \gset
RESET ROLE;
SELECT id AS openwa_lid_phone_ai_event_id
FROM public.outbox_events
WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  AND event_type = 'whatsapp.ai.respond_requested'
  AND payload ->> 'message_id' = :'openwa_lid_phone_message_id' \gset

SET ROLE service_role;
SELECT id
FROM public.claim_outbox_delivery_events('openwa-lid-phone-worker', 20, 300)
WHERE id = :'openwa_lid_phone_ai_event_id'::uuid \gset
SELECT * FROM public.apply_whatsapp_ai_result_v1(
  :'openwa_lid_phone_ai_event_id'::uuid,
  'openwa-lid-phone-worker',
  'client_sales',
  jsonb_build_object(
    'language', 'en',
    'lead', jsonb_build_object(
      'name', 'LID customer', 'phone', '+201001234567', 'whatsapp', '+201001234567',
      'requestedArea', NULL, 'checkIn', NULL, 'checkOut', NULL,
      'guests', NULL, 'bedrooms', NULL, 'budgetText', NULL, 'notes', NULL
    ),
    'owner', NULL, 'property', NULL, 'missingFields', jsonb_build_array()
  ),
  NULL, 'continue', 'high', false
);
RESET ROLE;

DO $$
DECLARE
  v_lead public.leads%ROWTYPE;
BEGIN
  SELECT lead_record.* INTO v_lead
  FROM public.leads AS lead_record
  JOIN public.whatsapp_conversations AS conversation
    ON conversation.organization_id = lead_record.organization_id
   AND conversation.lead_id = lead_record.id
  WHERE conversation.organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    AND conversation.external_conversation_key = '93847561029384@lid';
  IF NOT FOUND
    OR v_lead.phone <> '+201001234567'
    OR v_lead.whatsapp <> '+201001234567'
    OR v_lead.normalized_phone <> '201001234567' THEN
    RAISE EXCEPTION 'separately supplied plain phone facts must retain the existing CRM normalization path';
  END IF;
END;
$$;

UPDATE public.whatsapp_channels
SET status = 'disabled'
WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  AND provider = 'openwa'
  AND external_channel_id = 'opaque-openwa-session-a';

SET ROLE service_role;
DO $$
BEGIN
  BEGIN
    PERFORM public.ingest_whatsapp_openwa_event_v1(
      'opaque-openwa-session-a', '201001234568@c.us', 'openwa:disabled-event', 'OPENWA_DISABLED_001',
      '201001234568@c.us', '201001234568', NULL, 'inbound', 'text', 'disabled channel',
      NULL, NULL, NULL, timezone('utc', now())
    );
    RAISE EXCEPTION 'disabled OpenWA channel must reject ingestion';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END;
$$;
RESET ROLE;

UPDATE public.whatsapp_channels
SET status = 'active', kill_switch = true
WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  AND provider = 'openwa'
  AND external_channel_id = 'opaque-openwa-session-a';

SET ROLE service_role;
DO $$
BEGIN
  BEGIN
    PERFORM public.ingest_whatsapp_openwa_event_v1(
      'opaque-openwa-session-a', '201001234568@c.us', 'openwa:killswitch-event', 'OPENWA_KILLSWITCH_001',
      '201001234568@c.us', '201001234568', NULL, 'outbound', 'text', 'disabled channel',
      NULL, NULL, NULL, timezone('utc', now())
    );
    RAISE EXCEPTION 'OpenWA channel kill switch must reject ingestion';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END;
$$;
RESET ROLE;

SELECT 'OpenWA WhatsApp webhook integration tests passed' AS result;
