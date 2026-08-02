-- CRM contact evidence and staff-operated inbox integration checks.

DO $$
BEGIN
  IF has_table_privilege('authenticated', 'public.crm_contact_methods', 'SELECT')
    OR has_table_privilege('authenticated', 'public.whatsapp_message_events', 'SELECT')
    OR has_table_privilege('authenticated', 'public.whatsapp_conversations', 'INSERT') THEN
    RAISE EXCEPTION 'browser role must use CRM/WhatsApp commands and reads, not direct table access';
  END IF;
  IF has_function_privilege('anon', 'public.list_whatsapp_conversations(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'anon must not execute the inbox read function';
  END IF;
END;
$$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);

SELECT public.create_crm_contact_method(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'whatsapp', '+201001234567', '+20 100 123 4567',
  NULL, 'aaaaaaaa-0000-0000-0000-000000000002', 'crm-contact-a-1',
  'aaaaaaaa-0000-0000-0000-0000000000e1'
) AS contact_method_id \gset

SELECT public.create_crm_contact_method(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'whatsapp', '+201001234567', '+20 100 123 4567',
  NULL, 'aaaaaaaa-0000-0000-0000-000000000002', 'crm-contact-a-1',
  'aaaaaaaa-0000-0000-0000-0000000000e2'
);

SELECT public.record_crm_consent(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'contact_method_id', 'service', 'granted', 'staff', 'case-a-1',
  'aaaaaaaa-0000-0000-0000-0000000000e3'
);

SELECT public.create_whatsapp_channel(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'meta_cloud_sandbox', 'sandbox-channel-a', 'قناة الاختبار',
  'aaaaaaaa-0000-0000-0000-0000000000e4'
) AS channel_id \gset

SELECT public.create_whatsapp_conversation(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'channel_id', 'customer-thread-a', :'contact_method_id', NULL,
  'aaaaaaaa-0000-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-0000000000e5'
) AS conversation_id \gset

SELECT public.create_whatsapp_conversation(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'channel_id', 'customer-thread-a', :'contact_method_id', NULL,
  'aaaaaaaa-0000-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-0000000000e6'
);

SELECT public.create_whatsapp_message(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'conversation_id', 'مرحباً، سنراجع طلبك الآن.', 'whatsapp-message-a-1',
  'aaaaaaaa-0000-0000-0000-0000000000e7'
) AS message_id \gset

SELECT public.create_whatsapp_message(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'conversation_id', 'مرحباً، سنراجع طلبك الآن.', 'whatsapp-message-a-1',
  'aaaaaaaa-0000-0000-0000-0000000000e8'
);

SELECT public.add_whatsapp_internal_note(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'conversation_id', 'تم التحقق من بيانات العميل.',
  'aaaaaaaa-0000-0000-0000-0000000000e9'
);

DO $$
BEGIN
  IF (SELECT count(*) FROM public.list_whatsapp_channels('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')) <> 1 THEN
    RAISE EXCEPTION 'owner must read exactly one tenant channel';
  END IF;
  IF (SELECT count(*) FROM public.list_whatsapp_conversations('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')) <> 1 THEN
    RAISE EXCEPTION 'owner must read exactly one tenant conversation';
  END IF;
  IF (SELECT count(*) FROM public.list_whatsapp_messages(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    public.create_whatsapp_conversation(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      (SELECT id FROM public.list_whatsapp_channels('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')
       WHERE external_channel_id = 'sandbox-channel-a'),
      'customer-thread-a', NULL, NULL,
      'aaaaaaaa-0000-0000-0000-000000000002', NULL
    )
  )) <> 1 THEN
    RAISE EXCEPTION 'idempotent message command must persist exactly one message';
  END IF;
END;
$$;

RESET ROLE;

DO $$
BEGIN
  IF (SELECT count(*) FROM public.crm_contact_methods WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') <> 1 THEN
    RAISE EXCEPTION 'contact method command must persist exactly once';
  END IF;
  IF (SELECT count(*) FROM public.crm_consent_events WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND status = 'granted') <> 1 THEN
    RAISE EXCEPTION 'consent event must be append-only evidence';
  END IF;
  IF (SELECT count(*) FROM public.outbox_events WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND event_type = 'whatsapp.message.send_requested') <> 1 THEN
    RAISE EXCEPTION 'queued message must create one outbox event';
  END IF;
  IF (SELECT count(*) FROM public.audit_events WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND action = 'whatsapp.message.queued') <> 1 THEN
    RAISE EXCEPTION 'queued message must create audit evidence';
  END IF;
END;
$$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.list_whatsapp_conversations('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
    RAISE EXCEPTION 'cross-tenant inbox read must fail';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END;
$$;
RESET ROLE;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '33333333-3333-3333-3333-333333333333', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.create_whatsapp_message(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '00000000-0000-0000-0000-000000000000', 'مرفوض', 'denied-message', NULL
    );
    RAISE EXCEPTION 'suspended viewer must not send WhatsApp messages';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END;
$$;
RESET ROLE;

SELECT 'CRM and WhatsApp inbox database integration tests passed' AS result;
