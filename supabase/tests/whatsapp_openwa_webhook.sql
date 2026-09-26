-- OpenWA ingestion is tenant-bound, idempotent, and service-role only.
\set ON_ERROR_STOP on

DO $$
BEGIN
  IF to_regprocedure('public.ingest_whatsapp_openwa_event_v1(text,text,text,text,text,text,text,text,text,text,text,text,text,timestamptz)') IS NULL THEN
    RAISE EXCEPTION 'OpenWA webhook ingestion RPC is missing';
  END IF;
  IF to_regprocedure('public.resolve_whatsapp_outbox_delivery_v2(uuid,text)') IS NULL
    OR to_regprocedure('public.mark_whatsapp_message_sent_v2(uuid,text,text)') IS NULL THEN
    RAISE EXCEPTION 'provider-aware WhatsApp delivery RPCs are missing';
  END IF;
  IF has_function_privilege('anon', 'public.ingest_whatsapp_openwa_event_v1(text,text,text,text,text,text,text,text,text,text,text,text,text,timestamptz)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.ingest_whatsapp_openwa_event_v1(text,text,text,text,text,text,text,text,text,text,text,text,text,timestamptz)', 'EXECUTE') THEN
    RAISE EXCEPTION 'OpenWA webhook ingestion must not be callable by browser roles';
  END IF;
  IF NOT has_function_privilege('service_role', 'public.ingest_whatsapp_openwa_event_v1(text,text,text,text,text,text,text,text,text,text,text,text,text,timestamptz)', 'EXECUTE') THEN
    RAISE EXCEPTION 'service role must be able to invoke OpenWA webhook ingestion';
  END IF;
  IF has_function_privilege('anon', 'public.ingest_whatsapp_openwa_event_v1(text,text,text,text,text,text,text,text,text,text,text,text,text,timestamptz)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.ingest_whatsapp_openwa_event_v1(text,text,text,text,text,text,text,text,text,text,text,text,text,timestamptz)', 'EXECUTE')
    OR NOT has_function_privilege('service_role', 'public.resolve_whatsapp_outbox_delivery_v2(uuid,text)', 'EXECUTE')
    OR NOT has_function_privilege('voya_outbox_worker', 'public.resolve_whatsapp_outbox_delivery_v2(uuid,text)', 'EXECUTE')
    OR NOT has_function_privilege('service_role', 'public.mark_whatsapp_message_sent_v2(uuid,text,text)', 'EXECUTE')
    OR NOT has_function_privilege('voya_outbox_worker', 'public.mark_whatsapp_message_sent_v2(uuid,text,text)', 'EXECUTE')
    OR has_function_privilege('anon', 'public.resolve_whatsapp_outbox_delivery_v2(uuid,text)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.resolve_whatsapp_outbox_delivery_v2(uuid,text)', 'EXECUTE')
    OR has_function_privilege('anon', 'public.mark_whatsapp_message_sent_v2(uuid,text,text)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.mark_whatsapp_message_sent_v2(uuid,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'WhatsApp delivery RPC grants must remain worker/service-only';
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
SELECT public.ingest_whatsapp_openwa_event_v1(
  'opaque-openwa-session-a', '201001234567@c.us', 'openwa:inbound-event-a', 'OPENWA_MESSAGE_IN_001',
  '201001234567@c.us', '201001234567', 'Customer A', 'inbound', 'text', 'Inbound OpenWA message',
  NULL, NULL, NULL, timezone('utc', now())
) AS task4_setup_inbound_id \gset
RESET ROLE;
SELECT set_config(
  'voya.test.openwa_conversation_id',
  (SELECT message.conversation_id::text FROM public.whatsapp_message_events AS message WHERE message.id = :'task4_setup_inbound_id'::uuid),
  false
);

-- Exercise both provider/worker echo orderings. Echo-first creates a temporary
-- provider row that the worker reconciles into the queued canonical row; the
-- mark-first path updates that canonical row when the signed echo arrives.
DO $$
DECLARE
  v_organization_id uuid := 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  v_membership_id uuid;
  v_main_channel_id uuid;
  v_other_channel_id uuid := 'aaaaaaaa-0000-0000-0000-000000000795';
  v_other_conversation_id uuid := 'aaaaaaaa-0000-0000-0000-000000000796';
  v_echo_first_message_id uuid := 'aaaaaaaa-0000-0000-0000-000000000797';
  v_mark_first_message_id uuid := 'aaaaaaaa-0000-0000-0000-000000000798';
  v_echo_first_event_id uuid;
  v_mark_first_event_id uuid;
  v_echo_first_echo_id uuid;
  v_echo_first_retry_id uuid;
  v_mark_first_echo_id uuid;
  v_mark_first_retry_id uuid;
  v_wrong_channel_echo_id uuid;
  v_wrong_direction_id uuid;
  v_provider_message_id text := 'OPENWA_TASK4_ECHO_FIRST_001';
  v_mark_first_provider_message_id text := 'OPENWA_TASK4_MARK_FIRST_001';
BEGIN
  SELECT membership.id INTO v_membership_id
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = v_organization_id
    AND membership.user_id = '11111111-1111-1111-1111-111111111111';
  SELECT conversation.channel_id INTO v_main_channel_id
  FROM public.whatsapp_conversations AS conversation
  WHERE conversation.id = current_setting('voya.test.openwa_conversation_id')::uuid
    AND conversation.organization_id = v_organization_id;

  INSERT INTO public.whatsapp_channels (
    id, organization_id, provider, external_channel_id, display_name, created_by_membership_id
  ) VALUES (
    v_other_channel_id, v_organization_id, 'openwa', 'opaque-openwa-session-a2',
    'OpenWA second channel', v_membership_id
  );
  INSERT INTO public.whatsapp_conversations (
    id, organization_id, channel_id, contact_method_id, external_conversation_key
  ) VALUES (
    v_other_conversation_id, v_organization_id, v_other_channel_id,
    (SELECT conversation.contact_method_id FROM public.whatsapp_conversations AS conversation
     WHERE conversation.id = current_setting('voya.test.openwa_conversation_id')::uuid),
    '201001234567@c.us'
  );
  INSERT INTO public.whatsapp_message_events (
    id, organization_id, conversation_id, event_key, direction, body_text, delivery_status, idempotency_key
  ) VALUES
    (v_echo_first_message_id, v_organization_id, current_setting('voya.test.openwa_conversation_id')::uuid,
     'task4:canonical:echo-first', 'outbound', 'Queued echo-first body', 'queued', 'task4:idem:echo-first'),
    (v_mark_first_message_id, v_organization_id, current_setting('voya.test.openwa_conversation_id')::uuid,
     'task4:canonical:mark-first', 'outbound', 'Queued mark-first body', 'queued', 'task4:idem:mark-first');
  INSERT INTO public.outbox_events (
    organization_id, event_type, schema_version, dedupe_key, payload
  ) VALUES (
    v_organization_id, 'whatsapp.message.send_requested', 1, 'task4:outbox:echo-first',
    jsonb_build_object('message_id', v_echo_first_message_id, 'conversation_id', current_setting('voya.test.openwa_conversation_id')::uuid)
  ) RETURNING id INTO v_echo_first_event_id;
  INSERT INTO public.outbox_events (
    organization_id, event_type, schema_version, dedupe_key, payload
  ) VALUES (
    v_organization_id, 'whatsapp.message.send_requested', 1, 'task4:outbox:mark-first',
    jsonb_build_object('message_id', v_mark_first_message_id, 'conversation_id', current_setting('voya.test.openwa_conversation_id')::uuid)
  ) RETURNING id INTO v_mark_first_event_id;

  PERFORM claim.id
  FROM public.claim_outbox_delivery_events('openwa-task4-worker', 20, 300) AS claim
  WHERE claim.id IN (v_echo_first_event_id, v_mark_first_event_id);
  IF (SELECT count(*) FROM public.outbox_events AS event
      WHERE event.id IN (v_echo_first_event_id, v_mark_first_event_id)
        AND event.state = 'processing' AND event.locked_by = 'openwa-task4-worker'
        AND event.locked_until > timezone('utc', now())) <> 2 THEN
    RAISE EXCEPTION 'Task 4 echo-ordering fixtures must hold live worker leases';
  END IF;

  v_echo_first_echo_id := public.ingest_whatsapp_openwa_event_v1(
    'opaque-openwa-session-a', '201001234567@c.us', 'openwa:task4:echo-first', v_provider_message_id,
    '201001234567@c.us', '201001234567', NULL, 'outbound', 'text', 'Echo-first provider body',
    NULL, NULL, NULL, timezone('utc', now())
  );
  IF v_echo_first_echo_id = v_echo_first_message_id THEN
    RAISE EXCEPTION 'an echo arriving before the worker mark must first create its provider event row';
  END IF;
  IF NOT public.mark_whatsapp_message_sent_v2(
    v_echo_first_event_id, 'openwa-task4-worker', v_provider_message_id
  ) THEN
    RAISE EXCEPTION 'worker mark must reconcile an earlier exact OpenWA echo';
  END IF;
  IF (SELECT count(*) FROM public.whatsapp_message_events AS message
      WHERE message.organization_id = v_organization_id
        AND message.conversation_id = current_setting('voya.test.openwa_conversation_id')::uuid
        AND message.direction = 'outbound'
        AND message.provider_message_id = v_provider_message_id) <> 1
    OR NOT EXISTS (
      SELECT 1 FROM public.whatsapp_message_events AS message
      WHERE message.id = v_echo_first_message_id
        AND message.delivery_status = 'sent'
        AND message.provider_message_id = v_provider_message_id
        AND message.body_text = 'Echo-first provider body'
    )
    OR EXISTS (SELECT 1 FROM public.whatsapp_message_events AS message WHERE message.id = v_echo_first_echo_id) THEN
    RAISE EXCEPTION 'echo-first reconciliation must keep one canonical outbound row and adopt its body';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.audit_events AS audit
    WHERE audit.organization_id = v_organization_id
      AND audit.action = 'whatsapp.openwa.echo.reconciled'
      AND audit.resource_type = 'whatsapp_message_event'
      AND audit.resource_id = v_echo_first_message_id
      AND audit.outcome = 'success'
      AND audit.after_delta ->> 'provider' = 'openwa'
      AND audit.after_delta ->> 'provider_message_id' = v_provider_message_id
      AND audit.after_delta ->> 'canonical_message_id' = v_echo_first_message_id::text
      AND audit.after_delta ->> 'duplicate_echo_id' = v_echo_first_echo_id::text
  ) THEN
    RAISE EXCEPTION 'echo-first reconciliation must durably audit the canonical row, provider ID, and deleted echo row';
  END IF;

  v_echo_first_retry_id := public.ingest_whatsapp_openwa_event_v1(
    'opaque-openwa-session-a', '201001234567@c.us', 'openwa:task4:echo-first-retry', v_provider_message_id,
    '201001234567@c.us', '201001234567', NULL, 'outbound', 'text', 'Echo-first retry body',
    NULL, NULL, NULL, timezone('utc', now())
  );
  IF v_echo_first_retry_id <> v_echo_first_message_id
    OR (SELECT count(*) FROM public.whatsapp_message_events AS message
        WHERE message.organization_id = v_organization_id
          AND message.conversation_id = current_setting('voya.test.openwa_conversation_id')::uuid
          AND message.direction = 'outbound'
          AND message.provider_message_id = v_provider_message_id) <> 1
    OR (SELECT message.body_text FROM public.whatsapp_message_events AS message
        WHERE message.id = v_echo_first_message_id) <> 'Echo-first retry body' THEN
    RAISE EXCEPTION 'late echo retries must update and return the canonical outbound row without duplication';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.audit_events AS audit
    WHERE audit.organization_id = v_organization_id
      AND audit.action = 'whatsapp.openwa.echo.reconciled'
      AND audit.resource_id = v_echo_first_message_id
      AND audit.after_delta ->> 'provider_message_id' = v_provider_message_id
      AND audit.after_delta ->> 'event_key' = 'openwa:task4:echo-first-retry'
  ) THEN
    RAISE EXCEPTION 'late echo body updates must be durably audited against the canonical outbound row';
  END IF;

  IF NOT public.mark_whatsapp_message_sent_v2(
    v_mark_first_event_id, 'openwa-task4-worker', v_mark_first_provider_message_id
  ) THEN
    RAISE EXCEPTION 'worker mark must record a provider ID before a later echo';
  END IF;
  v_mark_first_echo_id := public.ingest_whatsapp_openwa_event_v1(
    'opaque-openwa-session-a', '201001234567@c.us', 'openwa:task4:mark-first', v_mark_first_provider_message_id,
    '201001234567@c.us', '201001234567', NULL, 'outbound', 'text', 'Mark-first provider body',
    NULL, NULL, NULL, timezone('utc', now())
  );
  v_mark_first_retry_id := public.ingest_whatsapp_openwa_event_v1(
    'opaque-openwa-session-a', '201001234567@c.us', 'openwa:task4:mark-first-retry', v_mark_first_provider_message_id,
    '201001234567@c.us', '201001234567', NULL, 'outbound', 'text', 'Mark-first retry body',
    NULL, NULL, NULL, timezone('utc', now())
  );
  IF v_mark_first_echo_id <> v_mark_first_message_id
    OR v_mark_first_retry_id <> v_mark_first_message_id
    OR (SELECT count(*) FROM public.whatsapp_message_events AS message
        WHERE message.organization_id = v_organization_id
          AND message.conversation_id = current_setting('voya.test.openwa_conversation_id')::uuid
          AND message.direction = 'outbound'
          AND message.provider_message_id = v_mark_first_provider_message_id) <> 1
    OR (SELECT message.body_text FROM public.whatsapp_message_events AS message
        WHERE message.id = v_mark_first_message_id) <> 'Mark-first retry body' THEN
    RAISE EXCEPTION 'mark-first echoes and their retries must return and update the canonical outbound row';
  END IF;

  v_wrong_direction_id := public.ingest_whatsapp_openwa_event_v1(
    'opaque-openwa-session-a', '201001234567@c.us', 'openwa:task4:wrong-direction', v_mark_first_provider_message_id,
    '201001234567@c.us', '201001234567', NULL, 'inbound', 'text', 'Inbound direction is a separate event',
    NULL, NULL, NULL, timezone('utc', now())
  );
  IF v_wrong_direction_id = v_mark_first_message_id
    OR NOT EXISTS (SELECT 1 FROM public.whatsapp_message_events AS message
                   WHERE message.id = v_wrong_direction_id AND message.direction = 'inbound') THEN
    RAISE EXCEPTION 'provider ID matches in the wrong direction must not reconcile an outbound row';
  END IF;

  v_wrong_channel_echo_id := public.ingest_whatsapp_openwa_event_v1(
    'opaque-openwa-session-a2', '201001234567@c.us', 'openwa:task4:wrong-channel', v_mark_first_provider_message_id,
    '201001234567@c.us', '201001234567', NULL, 'outbound', 'text', 'Wrong-channel echo stays separate',
    NULL, NULL, NULL, timezone('utc', now())
  );
  IF v_wrong_channel_echo_id = v_mark_first_message_id
    OR (SELECT count(*) FROM public.whatsapp_message_events AS message
        WHERE message.organization_id = v_organization_id
          AND message.provider_message_id = v_mark_first_provider_message_id
          AND message.direction = 'outbound') <> 2
    OR (SELECT message.body_text FROM public.whatsapp_message_events AS message
        WHERE message.id = v_mark_first_message_id) <> 'Mark-first retry body' THEN
    RAISE EXCEPTION 'same provider IDs on a different OpenWA channel must not reconcile or alter the canonical row';
  END IF;

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
