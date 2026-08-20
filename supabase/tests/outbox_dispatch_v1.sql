-- Voya OS V1 outbox delivery worker contract.
\set ON_ERROR_STOP on

DO $$
BEGIN
  IF to_regprocedure('public.claim_outbox_delivery_events(text,integer,integer)') IS NULL
    OR to_regprocedure('public.mark_outbox_event_needs_review(uuid,text,text)') IS NULL
    OR to_regprocedure('public.resolve_whatsapp_outbox_delivery(uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'V1 outbox delivery RPCs are missing';
  END IF;
  IF has_function_privilege('authenticated', 'public.claim_outbox_delivery_events(text,integer,integer)', 'EXECUTE')
    OR has_function_privilege('anon', 'public.claim_outbox_delivery_events(text,integer,integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'browser roles must not execute delivery claim';
  END IF;
  IF NOT has_function_privilege('voya_outbox_worker', 'public.claim_outbox_delivery_events(text,integer,integer)', 'EXECUTE')
    OR NOT has_function_privilege('voya_outbox_worker', 'public.mark_outbox_event_needs_review(uuid,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'dedicated worker must execute V1 delivery RPCs';
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
  IF NOT public.mark_whatsapp_message_sent(event_id, 'outbox-v1-whatsapp-worker', 'wamid-v1-784')
    OR NOT public.complete_outbox_event(event_id, 'outbox-v1-whatsapp-worker') THEN
    RAISE EXCEPTION 'worker must record and complete a sent WhatsApp message';
  END IF;
  IF (SELECT delivery_status FROM public.whatsapp_message_events WHERE id = message_id) <> 'sent'
    OR (SELECT provider_message_id FROM public.whatsapp_message_events WHERE id = message_id) <> 'wamid-v1-784' THEN
    RAISE EXCEPTION 'WhatsApp provider delivery evidence is missing';
  END IF;
END;
$$;

SELECT 'outbox dispatch V1 database integration tests passed' AS result;
