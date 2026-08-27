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

-- Owner onboarding remains a draft until an authenticated inventory role
-- explicitly confirms the owner, property, ownership period, and photos.
SET ROLE service_role;
SELECT public.ingest_whatsapp_webhook_event_v1(
  'meta_cloud_sandbox', 'sandbox-channel-a', 'phase1-owner-confirm-thread',
  'phase1-owner-confirm-image', '+201001234570', 'image', NULL,
  'meta-media-phase1-confirm', 'image/jpeg', 'صور الوحدة', timezone('utc', now())
) AS owner_confirm_message_id \gset
RESET ROLE;
SELECT conversation_id::text AS owner_confirm_conversation_id
FROM public.whatsapp_message_events
WHERE id = :'owner_confirm_message_id'::uuid \gset
SELECT id AS owner_confirm_event_id
FROM public.outbox_events
WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  AND event_type = 'whatsapp.ai.respond_requested'
  AND dedupe_key = 'whatsapp-ai:' || :'owner_confirm_message_id' \gset
SET ROLE service_role;
SELECT id AS claimed_owner_confirm_event_id
FROM public.claim_outbox_delivery_events('phase1-worker-owner-confirm', 20, 300)
WHERE id = :'owner_confirm_event_id'::uuid \gset
SELECT 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/' || :'owner_confirm_conversation_id' || '/' || :'owner_confirm_message_id' || '.jpg' AS owner_confirm_storage_path \gset
SELECT public.store_whatsapp_media_v1(
  :'owner_confirm_event_id'::uuid, 'phase1-worker-owner-confirm', :'owner_confirm_message_id'::uuid,
  :'owner_confirm_storage_path', 'image/jpeg', 10, repeat('b', 64)
);
SELECT public.apply_whatsapp_ai_result_v1(
  :'owner_confirm_event_id'::uuid, 'phase1-worker-owner-confirm', 'owner_onboarding',
  jsonb_build_object(
    'language', 'ar',
    'owner', jsonb_build_object(
      'displayName', 'مالك واتساب تجريبي', 'phone', '+201001234570',
      'whatsapp', '+201001234570', 'email', NULL,
      'preferredContactMethod', 'whatsapp', 'notes', NULL
    ),
    'property', jsonb_build_object(
      'address', 'شارع عباس العقاد', 'city', 'Nasr City', 'district', 'مدينة نصر',
      'bedrooms', 3, 'bathrooms', 2, 'areaSqm', 90.5, 'floor', '3', 'furnished', true,
      'rentDaily', false, 'rentWeekly', false, 'rentMonthly', true,
      'dailyPrice', NULL, 'weeklyPrice', NULL, 'monthlyPrice', 35000,
      'currency', 'EGP', 'amenities', jsonb_build_array('wifi', 'ac'),
      'minimumStayNights', 2, 'marketingDescription', 'شقة مفروشة في مدينة نصر',
      'availabilityText', 'متاحة من الآن'
    ),
    'lead', NULL, 'missingFields', jsonb_build_array(),
    'confidence', 'high', 'imageMessageIds', jsonb_build_array(:'owner_confirm_message_id'::uuid)
  ),
  NULL, 'ready_for_review', 'high', false
);
SELECT public.succeed_whatsapp_ai_run_v1(
  :'owner_confirm_event_id'::uuid, 'phase1-worker-owner-confirm',
  jsonb_build_object('status', 'owner_draft')
);
SELECT public.complete_outbox_event(:'owner_confirm_event_id'::uuid, 'phase1-worker-owner-confirm');
RESET ROLE;

SELECT ai_state_version AS owner_confirm_version
FROM public.whatsapp_conversations
WHERE id = :'owner_confirm_conversation_id'::uuid \gset

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT * FROM public.claim_whatsapp_property_confirmation_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'owner_confirm_conversation_id'::uuid,
  jsonb_build_object(
    'owner', jsonb_build_object('displayName', 'مالك واتساب تجريبي', 'phone', '+201001234570', 'whatsapp', '+201001234570', 'preferredContactMethod', 'whatsapp'),
    'property', jsonb_build_object('code', 'PHASE1-CONFIRM', 'name', 'شقة واتساب مؤكدة', 'timezone', 'Africa/Cairo', 'city', 'Nasr City', 'district', 'مدينة نصر', 'bedrooms', 3, 'bathrooms', 2, 'areaSqm', 90.5, 'floor', '3', 'furnished', true, 'rentDaily', false, 'rentWeekly', false, 'rentMonthly', true, 'monthlyPrice', 35000, 'currency', 'EGP', 'amenities', jsonb_build_array('wifi', 'ac'), 'minimumStayNights', 2, 'marketingDescription', 'شقة مفروشة في مدينة نصر'),
    'ownershipStartDate', '2026-08-27', 'ownershipEndDate', '2099-12-31'
  ),
  :'owner_confirm_version', 'phase1-owner-confirmation-1', 'aaaaaaaa-0000-0000-0000-0000000004f3'
) \gset owner_claim_
RESET ROLE;

SELECT count(*)::text AS owner_property_before_confirmation
FROM public.properties
WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND code = 'PHASE1-CONFIRM' \gset
SELECT set_config('voya.test.owner_property_before_confirmation', :'owner_property_before_confirmation', false);
DO $$
BEGIN
  IF current_setting('voya.test.owner_property_before_confirmation') <> '0' THEN
    RAISE EXCEPTION 'AI owner onboarding must not create a live property before confirmation';
  END IF;
END;
$$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT public.create_property_owner_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'مالك واتساب تجريبي', '+201001234570', '+201001234570',
  NULL, 'whatsapp', NULL, 'phase1-owner-confirm-owner', 'aaaaaaaa-0000-0000-0000-0000000004f4'
) AS confirmed_owner_id \gset
SELECT public.create_property_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'PHASE1-CONFIRM', 'شقة واتساب مؤكدة', 'Africa/Cairo',
  'شارع عباس العقاد', 'Nasr City', '3B', 3, 5, 'تمت المراجعة بشرياً',
  2, 90.5, '3', true, 'مدينة نصر', false, false, true,
  NULL, NULL, 35000, 'EGP', ARRAY['wifi', 'ac']::text[], 2,
  'شقة مفروشة في مدينة نصر', 'phase1-owner-confirm-property', 'aaaaaaaa-0000-0000-0000-0000000004f5'
) AS confirmed_property_id \gset
SELECT public.assign_property_owner_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'confirmed_property_id'::uuid, :'confirmed_owner_id'::uuid,
  DATE '2026-08-27', DATE '2099-12-31', true, 'phase1-owner-confirm-ownership', 'aaaaaaaa-0000-0000-0000-0000000004f6'
) AS confirmed_ownership_id \gset
SELECT 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/' || :'confirmed_property_id' || '/' || :'owner_confirm_message_id' || '.jpg' AS confirmed_property_image_path \gset
SELECT public.register_property_image_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'confirmed_property_id'::uuid, :'confirmed_property_image_path',
  'image/jpeg', 10, NULL, NULL, 'phase1-owner-confirm-image', 'aaaaaaaa-0000-0000-0000-0000000004f7'
) AS confirmed_property_image_id \gset
SELECT public.finalize_whatsapp_property_confirmation_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'owner_confirm_conversation_id'::uuid,
  :'owner_claim_confirmation_token'::uuid, :'confirmed_owner_id'::uuid, :'confirmed_property_id'::uuid,
  'confirmed', jsonb_build_object('propertyOwnerId', :'confirmed_owner_id'::uuid, 'propertyId', :'confirmed_property_id'::uuid, 'propertyImageId', :'confirmed_property_image_id'::uuid),
  'aaaaaaaa-0000-0000-0000-0000000004f8'
);
RESET ROLE;

SELECT set_config('voya.test.owner_confirm_conversation_id', :'owner_confirm_conversation_id', false);
SELECT set_config('voya.test.confirmed_owner_id', :'confirmed_owner_id', false);
SELECT set_config('voya.test.confirmed_property_id', :'confirmed_property_id', false);
SELECT set_config('voya.test.confirmed_property_image_id', :'confirmed_property_image_id', false);
DO $$
BEGIN
  IF (SELECT count(*) FROM public.properties WHERE id = current_setting('voya.test.confirmed_property_id')::uuid AND status = 'active' AND bathrooms = 2 AND area_sqm = 90.5 AND furnished AND district = 'مدينة نصر' AND rent_monthly AND monthly_price = 35000 AND currency = 'EGP') <> 1 THEN
    RAISE EXCEPTION 'human confirmation must create the furnished property fields';
  END IF;
  IF (SELECT count(*) FROM public.property_ownership_periods WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND property_id = current_setting('voya.test.confirmed_property_id')::uuid AND property_owner_id = current_setting('voya.test.confirmed_owner_id')::uuid) <> 1 THEN
    RAISE EXCEPTION 'human confirmation must assign the owner period';
  END IF;
  IF (SELECT count(*) FROM public.property_images WHERE id = current_setting('voya.test.confirmed_property_image_id')::uuid AND property_id = current_setting('voya.test.confirmed_property_id')::uuid AND status = 'active') <> 1 THEN
    RAISE EXCEPTION 'human confirmation must register the property photo';
  END IF;
  IF (SELECT count(*) FROM public.whatsapp_conversations WHERE id = current_setting('voya.test.owner_confirm_conversation_id')::uuid AND confirmation_status = 'confirmed' AND property_owner_id = current_setting('voya.test.confirmed_owner_id')::uuid AND property_id = current_setting('voya.test.confirmed_property_id')::uuid AND confirmation_token IS NULL) <> 1 THEN
    RAISE EXCEPTION 'human confirmation must finalize the WhatsApp draft';
  END IF;
END;
$$;

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
  'سأراجع الخيارات المناسبة لك.', 'continue', 'high', true
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
  IF (SELECT count(*) FROM public.whatsapp_message_events WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND idempotency_key = 'whatsapp-ai-reply:' || current_setting('voya.test.client_message_id') AND direction = 'outbound' AND body_text = 'سأراجع الخيارات المناسبة لك.' AND delivery_status = 'queued') <> 1 THEN
    RAISE EXCEPTION 'client AI result must queue the validated WhatsApp reply';
  END IF;
  IF (SELECT count(*) FROM public.outbox_events WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND event_type = 'whatsapp.message.send_requested' AND payload ->> 'message_id' = (SELECT id::text FROM public.whatsapp_message_events WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND idempotency_key = 'whatsapp-ai-reply:' || current_setting('voya.test.client_message_id'))) <> 1 THEN
    RAISE EXCEPTION 'client AI reply must use the existing outbound outbox';
  END IF;
  IF (SELECT count(*) FROM public.properties WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND idempotency_key = 'whatsapp-conversation:' || current_setting('voya.test.projected_conversation_id')) <> 0 THEN
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
