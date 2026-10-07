-- Voya OS V1/V2 outbox delivery worker contract.
\set ON_ERROR_STOP on

DO $$
BEGIN
  IF to_regprocedure('public.claim_outbox_delivery_events(text,integer,integer)') IS NULL
    OR to_regprocedure('public.mark_outbox_event_needs_review(uuid,text,text)') IS NULL
    OR to_regprocedure('public.resolve_whatsapp_outbox_delivery(uuid,text)') IS NULL
    OR to_regprocedure('public.resolve_whatsapp_outbox_delivery_v2(uuid,text)') IS NULL
    OR to_regprocedure('public.mark_whatsapp_message_sent_v2(uuid,text,text)') IS NULL THEN
    RAISE EXCEPTION 'V1 outbox delivery RPCs are missing';
  END IF;
  IF has_function_privilege('authenticated', 'public.claim_outbox_delivery_events(text,integer,integer)', 'EXECUTE')
    OR has_function_privilege('anon', 'public.claim_outbox_delivery_events(text,integer,integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'browser roles must not execute delivery claim';
  END IF;
  IF NOT has_function_privilege('voya_outbox_worker', 'public.claim_outbox_delivery_events(text,integer,integer)', 'EXECUTE')
    OR NOT has_function_privilege('voya_outbox_worker', 'public.mark_outbox_event_needs_review(uuid,text,text)', 'EXECUTE')
    OR NOT has_function_privilege('voya_outbox_worker', 'public.resolve_whatsapp_outbox_delivery_v2(uuid,text)', 'EXECUTE')
    OR NOT has_function_privilege('voya_outbox_worker', 'public.mark_whatsapp_message_sent_v2(uuid,text,text)', 'EXECUTE')
    OR NOT has_function_privilege('service_role', 'public.resolve_whatsapp_outbox_delivery_v2(uuid,text)', 'EXECUTE')
    OR NOT has_function_privilege('service_role', 'public.mark_whatsapp_message_sent_v2(uuid,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'dedicated worker must execute V1 delivery RPCs';
  END IF;
  IF has_function_privilege('authenticated', 'public.resolve_whatsapp_outbox_delivery_v2(uuid,text)', 'EXECUTE')
    OR has_function_privilege('anon', 'public.resolve_whatsapp_outbox_delivery_v2(uuid,text)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.mark_whatsapp_message_sent_v2(uuid,text,text)', 'EXECUTE')
    OR has_function_privilege('anon', 'public.mark_whatsapp_message_sent_v2(uuid,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'browser roles must not execute V2 WhatsApp delivery RPCs';
  END IF;
END;
$$;

DO $$
DECLARE
  delivery_id uuid;
  unsupported_id uuid;
BEGIN
  INSERT INTO public.outbox_events (
    organization_id, event_type, schema_version, dedupe_key, payload
  ) VALUES (
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'organization.invitation.send_requested',
    1,
    'outbox-v1-delivery-claim',
    jsonb_build_object('email', 'delivery@example.test', 'sealed_token', 'v1.sealed.iv.tag0000')
  ) RETURNING id INTO delivery_id;

  INSERT INTO public.outbox_events (
    organization_id, event_type, schema_version, dedupe_key, payload
  ) VALUES (
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'property.v1.unhandled',
    1,
    'outbox-v1-delivery-unsupported',
    '{}'::jsonb
  ) RETURNING id INTO unsupported_id;

  IF NOT EXISTS (
    SELECT 1 FROM public.claim_outbox_delivery_events('outbox-v1-worker', 20, 300)
    WHERE id = delivery_id
  ) THEN
    RAISE EXCEPTION 'delivery worker must claim supported email events';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.claim_outbox_delivery_events('outbox-v1-worker-2', 20, 300)
    WHERE id = unsupported_id
  ) THEN
    RAISE EXCEPTION 'delivery worker must leave unsupported domain events alone';
  END IF;
  IF NOT public.mark_outbox_event_needs_review(delivery_id, 'outbox-v1-worker', 'email_delivery_disabled') THEN
    RAISE EXCEPTION 'worker must be able to move an owned delivery to needs_review';
  END IF;
  IF (SELECT state FROM public.outbox_events WHERE id = delivery_id) <> 'needs_review'
    OR (SELECT locked_by FROM public.outbox_events WHERE id = delivery_id) IS NOT NULL THEN
    RAISE EXCEPTION 'needs_review must release the delivery lease';
  END IF;
END;
$$;

DO $$
DECLARE
  contact_id uuid := 'aaaaaaaa-0000-0000-0000-000000000781';
  channel_id uuid := 'aaaaaaaa-0000-0000-0000-000000000782';
  conversation_id uuid := 'aaaaaaaa-0000-0000-0000-000000000783';
  message_id uuid := 'aaaaaaaa-0000-0000-0000-000000000784';
  membership_id uuid;
  event_id uuid;
  resolved record;
  resolved_v2 record;
BEGIN
  SELECT id INTO membership_id
  FROM public.organization_memberships
  WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    AND user_id = '11111111-1111-1111-1111-111111111111';
  INSERT INTO public.crm_contact_methods (
    id, organization_id, kind, normalized_value, display_value, idempotency_key, created_by_membership_id
  ) VALUES (
    contact_id, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'whatsapp', '+201000000781', '+201000000781',
    'outbox-v1-contact-781', membership_id
  );
  INSERT INTO public.whatsapp_channels (
    id, organization_id, provider, external_channel_id, display_name, created_by_membership_id
  ) VALUES (
    channel_id, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'meta_cloud', 'phone-number-v1', 'V1 channel',
    membership_id
  );
  INSERT INTO public.whatsapp_conversations (
    id, organization_id, channel_id, contact_method_id, external_conversation_key
  ) VALUES (
    conversation_id, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', channel_id, contact_id, '+201000000781'
  );
  INSERT INTO public.whatsapp_message_events (
    id, organization_id, conversation_id, event_key, direction, body_text, delivery_status, idempotency_key
  ) VALUES (
    message_id, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', conversation_id, 'outbox-v1-message-784', 'outbound', 'رسالة اختبار', 'queued', 'outbox-v1-message-idem-784'
  );
  INSERT INTO public.outbox_events (
    organization_id, event_type, schema_version, dedupe_key, payload
  ) VALUES (
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'whatsapp.message.send_requested', 1,
    'outbox-v1-whatsapp-784', jsonb_build_object('message_id', message_id, 'conversation_id', conversation_id)
  ) RETURNING id INTO event_id;

  PERFORM id FROM public.claim_outbox_delivery_events('outbox-v1-whatsapp-worker', 20, 300) WHERE id = event_id;
  SELECT * INTO resolved
  FROM public.resolve_whatsapp_outbox_delivery(event_id, 'outbox-v1-whatsapp-worker');
  IF resolved.phone_number_id <> 'phone-number-v1'
    OR resolved.recipient_phone <> '+201000000781'
    OR resolved.body_text <> 'رسالة اختبار'
    OR resolved.message_id <> message_id THEN
    RAISE EXCEPTION 'worker WhatsApp context must be tenant-derived';
  END IF;
  SELECT * INTO resolved_v2
  FROM public.resolve_whatsapp_outbox_delivery_v2(event_id, 'outbox-v1-whatsapp-worker');
  IF resolved_v2.provider <> 'meta_cloud'
    OR resolved_v2.provider_channel_id <> 'phone-number-v1'
    OR resolved_v2.chat_id <> '+201000000781'
    OR resolved_v2.recipient_phone <> '+201000000781'
    OR resolved_v2.body_text <> 'رسالة اختبار'
    OR resolved_v2.message_id <> message_id THEN
    RAISE EXCEPTION 'V2 Meta delivery context must be tenant-derived';
  END IF;
  IF NOT public.mark_whatsapp_message_sent_v2(event_id, 'outbox-v1-whatsapp-worker', 'wamid-v1-784')
    OR NOT public.complete_outbox_event(event_id, 'outbox-v1-whatsapp-worker') THEN
    RAISE EXCEPTION 'worker must record and complete a sent WhatsApp message';
  END IF;
  IF (SELECT delivery_status FROM public.whatsapp_message_events WHERE id = message_id) <> 'sent'
    OR (SELECT provider_message_id FROM public.whatsapp_message_events WHERE id = message_id) <> 'wamid-v1-784' THEN
    RAISE EXCEPTION 'WhatsApp provider delivery evidence is missing';
  END IF;
END;
$$;

DO $$
DECLARE
  v_organization_id uuid := 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  membership_id uuid;
  contact_id uuid := 'aaaaaaaa-0000-0000-0000-000000000791';
  channel_id uuid := 'aaaaaaaa-0000-0000-0000-000000000792';
  conversation_id uuid := 'aaaaaaaa-0000-0000-0000-000000000793';
  message_id uuid := 'aaaaaaaa-0000-0000-0000-000000000794';
  other_channel_id uuid := 'aaaaaaaa-0000-0000-0000-000000000799';
  other_conversation_id uuid := 'aaaaaaaa-0000-0000-0000-000000000800';
  event_id uuid;
  resolved record;
BEGIN
  SELECT membership.id INTO membership_id
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = v_organization_id
    AND membership.user_id = '11111111-1111-1111-1111-111111111111';
  INSERT INTO public.crm_contact_methods (
    id, organization_id, kind, normalized_value, display_value, idempotency_key, created_by_membership_id
  ) VALUES (
    contact_id, v_organization_id, 'whatsapp', '201000000791', 'OpenWA 791', 'outbox-v2-openwa-contact-791', membership_id
  );
  INSERT INTO public.whatsapp_channels (
    id, organization_id, provider, external_channel_id, display_name, created_by_membership_id
  ) VALUES (
    channel_id, v_organization_id, 'openwa', 'outbox-openwa-session-791', 'OpenWA outbox test', membership_id
  );
  INSERT INTO public.whatsapp_conversations (
    id, organization_id, channel_id, contact_method_id, external_conversation_key
  ) VALUES (
    conversation_id, v_organization_id, channel_id, contact_id, '201000000791@c.us'
  );
  INSERT INTO public.whatsapp_channels (
    id, organization_id, provider, external_channel_id, display_name, created_by_membership_id
  ) VALUES (
    other_channel_id, v_organization_id, 'openwa', 'outbox-openwa-session-792', 'OpenWA wrong-channel test', membership_id
  );
  INSERT INTO public.whatsapp_conversations (
    id, organization_id, channel_id, contact_method_id, external_conversation_key
  ) VALUES (
    other_conversation_id, v_organization_id, other_channel_id, contact_id, '201000000791@c.us'
  );
  INSERT INTO public.whatsapp_message_events (
    id, organization_id, conversation_id, event_key, direction, body_text, delivery_status, idempotency_key
  ) VALUES (
    message_id, v_organization_id, conversation_id, 'outbox-v2-openwa-message-794', 'outbound', 'OpenWA queued test', 'queued',
    'outbox-v2-openwa-message-idem-794'
  );
  INSERT INTO public.outbox_events (
    organization_id, event_type, schema_version, dedupe_key, payload
  ) VALUES (
    v_organization_id, 'whatsapp.message.send_requested', 1, 'outbox-v2-openwa-event-794',
    jsonb_build_object('message_id', message_id, 'conversation_id', conversation_id)
  ) RETURNING id INTO event_id;

  PERFORM id FROM public.claim_outbox_delivery_events('outbox-v2-openwa-worker', 20, 300) WHERE id = event_id;
  SELECT * INTO resolved
  FROM public.resolve_whatsapp_outbox_delivery_v2(event_id, 'outbox-v2-openwa-worker');
  IF resolved.provider <> 'openwa'
    OR resolved.provider_channel_id <> 'outbox-openwa-session-791'
    OR resolved.chat_id <> '201000000791@c.us'
    OR resolved.recipient_phone IS NOT NULL
    OR resolved.body_text <> 'OpenWA queued test'
    OR resolved.message_id <> message_id THEN
    RAISE EXCEPTION 'V2 OpenWA delivery context must use the configured session and one-to-one conversation';
  END IF;

  UPDATE public.outbox_events AS event
  SET payload = jsonb_set(event.payload, '{conversation_id}', to_jsonb(other_conversation_id::text), true)
  WHERE event.id = event_id;
  IF EXISTS (SELECT 1 FROM public.resolve_whatsapp_outbox_delivery_v2(event_id, 'outbox-v2-openwa-worker')) THEN
    RAISE EXCEPTION 'a queued row paired with another channel conversation must not resolve';
  END IF;
  UPDATE public.outbox_events AS event
  SET payload = jsonb_set(event.payload, '{conversation_id}', to_jsonb(conversation_id::text), true)
  WHERE event.id = event_id;

  UPDATE public.whatsapp_channels AS channel SET kill_switch = true WHERE channel.id = channel_id;
  IF EXISTS (SELECT 1 FROM public.resolve_whatsapp_outbox_delivery_v2(event_id, 'outbox-v2-openwa-worker')) THEN
    RAISE EXCEPTION 'an OpenWA channel kill switch must prevent destination resolution';
  END IF;
  IF public.renew_outbox_delivery_lease_v1(event_id, 'outbox-v2-openwa-worker', 300) THEN
    RAISE EXCEPTION 'an OpenWA channel kill switch must prevent the pre-send lease renewal';
  END IF;
  UPDATE public.whatsapp_channels AS channel SET kill_switch = false WHERE channel.id = channel_id;

  UPDATE public.whatsapp_conversations AS conversation
  SET external_conversation_key = '120363000000000000@g.us'
  WHERE conversation.id = conversation_id;
  IF EXISTS (SELECT 1 FROM public.resolve_whatsapp_outbox_delivery_v2(event_id, 'outbox-v2-openwa-worker')) THEN
    RAISE EXCEPTION 'OpenWA groups must not resolve as one-to-one delivery destinations';
  END IF;
  IF public.renew_outbox_delivery_lease_v1(event_id, 'outbox-v2-openwa-worker', 300) THEN
    RAISE EXCEPTION 'OpenWA groups must fail the final pre-send lease validation';
  END IF;
  UPDATE public.whatsapp_conversations AS conversation
  SET external_conversation_key = '201000000791@c.us'
  WHERE conversation.id = conversation_id;

  UPDATE public.outbox_events SET locked_until = timezone('utc', now()) - interval '1 second' WHERE id = event_id;
  IF EXISTS (SELECT 1 FROM public.resolve_whatsapp_outbox_delivery_v2(event_id, 'outbox-v2-openwa-worker')) THEN
    RAISE EXCEPTION 'expired delivery lease must not resolve an OpenWA destination';
  END IF;
  IF public.mark_whatsapp_message_sent_v2(event_id, 'outbox-v2-openwa-worker', 'stale-openwa-message-id') THEN
    RAISE EXCEPTION 'expired delivery lease must not mark an OpenWA message sent';
  END IF;
END;
$$;

DO $$
DECLARE
  v_organization_id uuid := 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  v_other_organization_id uuid := 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
  v_membership_id uuid;
  v_channel_id uuid := 'bbbbbbbb-0000-0000-0000-000000000791';
  v_conversation_id uuid := 'bbbbbbbb-0000-0000-0000-000000000792';
  v_message_id uuid := 'bbbbbbbb-0000-0000-0000-000000000793';
  v_event_id uuid;
BEGIN
  SELECT membership.id INTO v_membership_id
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = v_other_organization_id
    AND membership.user_id = '22222222-2222-2222-2222-222222222222';
  INSERT INTO public.whatsapp_channels (
    id, organization_id, provider, external_channel_id, display_name, created_by_membership_id
  ) VALUES (
    v_channel_id, v_other_organization_id, 'openwa', 'outbox-openwa-cross-tenant',
    'OpenWA cross-tenant fixture', v_membership_id
  );
  INSERT INTO public.whatsapp_conversations (
    id, organization_id, channel_id, external_conversation_key
  ) VALUES (
    v_conversation_id, v_other_organization_id, v_channel_id, '201000000791@c.us'
  );
  INSERT INTO public.whatsapp_message_events (
    id, organization_id, conversation_id, event_key, direction, body_text, delivery_status, idempotency_key
  ) VALUES (
    v_message_id, v_other_organization_id, v_conversation_id, 'outbox-v2-cross-tenant-message',
    'outbound', 'Cross-tenant message', 'queued', 'outbox-v2-cross-tenant-idem'
  );
  INSERT INTO public.outbox_events (
    organization_id, event_type, schema_version, dedupe_key, payload
  ) VALUES (
    v_organization_id, 'whatsapp.message.send_requested', 1, 'outbox-v2-cross-tenant-event',
    jsonb_build_object('message_id', v_message_id, 'conversation_id', v_conversation_id)
  ) RETURNING id INTO v_event_id;
  PERFORM claim.id FROM public.claim_outbox_delivery_events('outbox-v2-cross-tenant-worker', 20, 300) AS claim
  WHERE claim.id = v_event_id;
  IF EXISTS (SELECT 1 FROM public.resolve_whatsapp_outbox_delivery_v2(v_event_id, 'outbox-v2-cross-tenant-worker')) THEN
    RAISE EXCEPTION 'a message event from another tenant must not resolve for this outbox event';
  END IF;
END;
$$;

SELECT 'provider-aware outbox dispatch database integration tests passed' AS result;
