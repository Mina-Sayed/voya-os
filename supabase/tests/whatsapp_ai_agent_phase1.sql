-- Phase 1 WhatsApp AI: media/state/outbox/lead projection boundaries.

DO $$
BEGIN
  IF has_function_privilege('anon', 'public.ingest_whatsapp_webhook_event_v1(text,text,text,text,text,text,text,text,text,text,timestamptz)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.ingest_whatsapp_webhook_event_v1(text,text,text,text,text,text,text,text,text,text,timestamptz)', 'EXECUTE') THEN
    RAISE EXCEPTION 'WhatsApp AI webhook ingest must remain service-role only';
  END IF;
  IF has_function_privilege('anon', 'public.resolve_whatsapp_ai_execution_v1(uuid,text)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.apply_whatsapp_ai_result_v1(uuid,text,text,jsonb,text,text,text,boolean)', 'EXECUTE') THEN
    RAISE EXCEPTION 'WhatsApp AI worker projection must remain off browser roles';
  END IF;
  IF has_table_privilege('authenticated', 'public.whatsapp_message_events', 'SELECT')
    OR has_table_privilege('authenticated', 'public.whatsapp_conversations', 'UPDATE') THEN
    RAISE EXCEPTION 'WhatsApp AI rows must remain RPC-owned';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM pg_attribute
    WHERE attrelid = 'public.properties'::regclass
      AND attname IN ('bathrooms', 'district', 'rent_daily', 'daily_price')
    GROUP BY attrelid
    HAVING count(*) = 4
  ) THEN
    RAISE EXCEPTION 'furnished-rental property fields are missing';
  END IF;
END;
$$;

SET ROLE service_role;

SELECT public.ingest_whatsapp_webhook_event_v1(
  'meta_cloud_sandbox', 'sandbox-channel-a', 'phase1-owner-thread',
  'phase1-owner-image-1', '+201001234568', 'image', NULL,
  'meta-media-phase1-1', 'image/jpeg', 'واجهة العقار', timezone('utc', now())
) AS image_message_id \gset

SELECT public.ingest_whatsapp_webhook_event_v1(
  'meta_cloud_sandbox', 'sandbox-channel-a', 'phase1-owner-thread',
  'phase1-owner-image-1', '+201001234568', 'image', NULL,
  'meta-media-phase1-1', 'image/jpeg', 'واجهة العقار', timezone('utc', now())
);

RESET ROLE;

SELECT conversation_id::text AS image_conversation_id
FROM public.whatsapp_message_events
WHERE id = :'image_message_id'::uuid \gset

SELECT set_config('voya.test.image_message_id', :'image_message_id', false);
SELECT set_config('voya.test.image_conversation_id', :'image_conversation_id', false);

DO $$
BEGIN
  IF (SELECT count(*) FROM public.whatsapp_message_events WHERE id = current_setting('voya.test.image_message_id')::uuid AND message_type = 'image' AND caption = 'واجهة العقار' AND media_status = 'pending') <> 1 THEN
    RAISE EXCEPTION 'image webhook must persist one pending media message with caption';
  END IF;
  IF (SELECT count(*) FROM public.outbox_events WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND event_type = 'whatsapp.ai.respond_requested' AND dedupe_key = 'whatsapp-ai:' || current_setting('voya.test.image_message_id')) <> 1 THEN
    RAISE EXCEPTION 'image webhook must enqueue exactly one AI response event';
  END IF;
  IF (SELECT count(*) FROM public.ai_runs WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND agent_kind = 'whatsapp' AND whatsapp_conversation_id = current_setting('voya.test.image_conversation_id')::uuid) <> 1 THEN
    RAISE EXCEPTION 'image webhook must create one linked WhatsApp AI run';
  END IF;
END;
$$;

SELECT id AS image_event_id
FROM public.outbox_events
WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  AND event_type = 'whatsapp.ai.respond_requested'
  AND dedupe_key = 'whatsapp-ai:' || :'image_message_id' \gset

SET ROLE service_role;
SELECT id AS claimed_image_event_id
FROM public.claim_outbox_delivery_events('phase1-worker-image', 20, 300)
WHERE id = :'image_event_id'::uuid \gset

SELECT 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/' || :'image_conversation_id' || '/' || :'image_message_id' || '.jpg' AS image_storage_path \gset
SELECT set_config('voya.test.image_storage_path', :'image_storage_path', false);

SELECT public.store_whatsapp_media_v1(
  :'image_event_id'::uuid, 'phase1-worker-image', :'image_message_id'::uuid,
  :'image_storage_path', 'image/jpeg', 10, repeat('a', 64)
);

RESET ROLE;

DO $$
BEGIN
  IF (SELECT count(*) FROM public.whatsapp_message_events WHERE id = current_setting('voya.test.image_message_id')::uuid AND media_status = 'stored' AND media_storage_bucket = 'ai-intake' AND media_storage_path = current_setting('voya.test.image_storage_path')) <> 1 THEN
    RAISE EXCEPTION 'stored media metadata must be tenant/path bound';
  END IF;
END;
$$;

SELECT public.complete_outbox_event(:'image_event_id'::uuid, 'phase1-worker-image');

SET ROLE service_role;
SELECT public.ingest_whatsapp_webhook_event_v1(
  'meta_cloud_sandbox', 'sandbox-channel-a', 'phase1-client-thread',
  'phase1-client-text-1', '+201001234569', 'text',
  'محتاج شقة 3 غرف في مدينة نصر من 2026-09-05 إلى 2026-09-10 لخمسة أفراد بميزانية 2500 يوميا',
  NULL, NULL, NULL, timezone('utc', now())
) AS client_message_id \gset

RESET ROLE;

SELECT conversation_id::text AS client_conversation_id
FROM public.whatsapp_message_events
WHERE id = :'client_message_id'::uuid \gset
SELECT set_config('voya.test.client_message_id', :'client_message_id', false);
SELECT set_config('voya.test.client_conversation_id', :'client_conversation_id', false);

SELECT id AS client_event_id
FROM public.outbox_events
WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  AND event_type = 'whatsapp.ai.respond_requested'
  AND dedupe_key = 'whatsapp-ai:' || :'client_message_id' \gset

SET ROLE service_role;
SELECT id AS claimed_client_event_id
FROM public.claim_outbox_delivery_events('phase1-worker-client', 20, 300)
WHERE id = :'client_event_id'::uuid \gset

SELECT lead_id::text AS projected_lead_id, outbound_message_id::text AS projected_outbound_id, outcome
FROM public.apply_whatsapp_ai_result_v1(
  :'client_event_id'::uuid, 'phase1-worker-client', 'client_sales',
  jsonb_build_object(
    'language', 'ar',
    'lead', jsonb_build_object(
      'name', NULL, 'phone', '+201001234569', 'whatsapp', '+201001234569',
      'requestedArea', 'Nasr City', 'checkIn', '2026-09-05',
      'checkOut', '2026-09-10', 'guests', 5, 'bedrooms', 3,
      'budgetText', '2500 EGP/day', 'notes', NULL
    ),
    'owner', NULL,
    'property', NULL,
    'missingFields', jsonb_build_array(),
    'confidence', 'high'
  ),
  'سأراجع الخيارات المناسبة لك.', 'continue', 'high', false
) \gset

RESET ROLE;
SELECT set_config('voya.test.projected_outcome', :'outcome', false);
SELECT set_config('voya.test.projected_lead_id', :'projected_lead_id', false);
SELECT set_config('voya.test.projected_conversation_id', :'client_conversation_id', false);

DO $$
BEGIN
  IF current_setting('voya.test.projected_outcome') <> 'applied' THEN RAISE EXCEPTION 'client AI result must apply once'; END IF;
  IF (SELECT count(*) FROM public.leads WHERE id = current_setting('voya.test.projected_lead_id')::uuid AND source = 'whatsapp' AND requested_area = 'Nasr City' AND requested_check_in = DATE '2026-09-05' AND requested_check_out = DATE '2026-09-10' AND guests = 5 AND bedrooms = 3 AND status = 'qualified') <> 1 THEN
    RAISE EXCEPTION 'client AI result must project a qualified existing CRM lead';
  END IF;
  IF (SELECT count(*) FROM public.whatsapp_conversations WHERE id = current_setting('voya.test.projected_conversation_id')::uuid AND lead_id = current_setting('voya.test.projected_lead_id')::uuid AND conversation_type = 'client_sales') <> 1 THEN
    RAISE EXCEPTION 'client lead must be linked to its WhatsApp conversation';
  END IF;
  IF (SELECT count(*) FROM public.properties WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND city = 'Nasr City' AND bedrooms = 3) <> 0 THEN
    RAISE EXCEPTION 'AI client projection must not create an operational property';
  END IF;
END;
$$;

SELECT public.complete_outbox_event(:'client_event_id'::uuid, 'phase1-worker-client');

SET ROLE service_role;
SELECT public.ingest_whatsapp_webhook_event_v1(
  'meta_cloud_sandbox', 'sandbox-channel-a', 'phase1-client-thread',
  'phase1-client-text-2', '+201001234569', 'text', 'هل يوجد شيء آخر؟',
  NULL, NULL, NULL, timezone('utc', now())
) AS handoff_message_id \gset

RESET ROLE;

SELECT conversation_id::text AS handoff_conversation_id
FROM public.whatsapp_message_events
WHERE id = :'handoff_message_id'::uuid \gset
SELECT set_config('voya.test.handoff_conversation_id', :'handoff_conversation_id', false);

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT public.set_whatsapp_ai_enabled_v1('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'handoff_conversation_id'::uuid, false, 'aaaaaaaa-0000-0000-0000-0000000004f1');
RESET ROLE;

SET ROLE service_role;
SELECT public.ingest_whatsapp_webhook_event_v1(
  'meta_cloud_sandbox', 'sandbox-channel-a', 'phase1-client-thread',
  'phase1-client-after-handoff', '+201001234569', 'text', 'رد بشري من فضلك',
  NULL, NULL, NULL, timezone('utc', now())
) AS after_handoff_message_id \gset
SELECT set_config('voya.test.after_handoff_message_id', :'after_handoff_message_id', false);
RESET ROLE;

DO $$
BEGIN
  IF (SELECT ai_enabled FROM public.whatsapp_conversations WHERE id = current_setting('voya.test.handoff_conversation_id')::uuid) THEN
    RAISE EXCEPTION 'takeover must disable AI on the conversation';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.outbox_events
    WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND event_type = 'whatsapp.ai.respond_requested'
      AND payload ->> 'message_id' = current_setting('voya.test.after_handoff_message_id')
  ) THEN
    RAISE EXCEPTION 'takeover must prevent new AI response events';
  END IF;
END;
$$;

SET ROLE authenticated;
SELECT public.set_whatsapp_ai_enabled_v1('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'handoff_conversation_id'::uuid, true, 'aaaaaaaa-0000-0000-0000-0000000004f2');
RESET ROLE;

RESET ROLE;

SELECT 'WhatsApp AI Phase 1 database integration tests passed' AS result;
