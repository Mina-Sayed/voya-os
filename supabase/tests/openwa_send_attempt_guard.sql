-- An OpenWA send can be retried only when the worker proved no provider call happened.
\set ON_ERROR_STOP on

DO $$
DECLARE
  v_org_a uuid := 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  v_org_b uuid := 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
  v_member_a uuid;
  v_member_b uuid;
  v_channel_a uuid := gen_random_uuid();
  v_channel_b uuid := gen_random_uuid();
  v_meta_channel uuid := gen_random_uuid();
  v_conversation_a uuid := gen_random_uuid();
  v_conversation_b uuid := gen_random_uuid();
  v_meta_conversation uuid := gen_random_uuid();
  v_group_conversation uuid := gen_random_uuid();
  v_message_a uuid := gen_random_uuid();
  v_message_b uuid := gen_random_uuid();
  v_meta_message uuid := gen_random_uuid();
  v_group_message uuid := gen_random_uuid();
  v_event_a uuid;
  v_event_cross_tenant uuid;
  v_event_meta uuid;
  v_event_group uuid;
  v_reclaimed_state text;
  v_reclaimed_error text;
BEGIN
  IF to_regprocedure('public.begin_openwa_send_attempt_v1(uuid,text)') IS NULL
    OR to_regprocedure('public.clear_openwa_send_attempt_v1(uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'OpenWA attempt RPCs are missing';
  END IF;
  IF has_function_privilege('anon', 'public.begin_openwa_send_attempt_v1(uuid,text)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.begin_openwa_send_attempt_v1(uuid,text)', 'EXECUTE')
    OR has_function_privilege('anon', 'public.clear_openwa_send_attempt_v1(uuid,text)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.clear_openwa_send_attempt_v1(uuid,text)', 'EXECUTE')
    OR NOT has_function_privilege('voya_outbox_worker', 'public.begin_openwa_send_attempt_v1(uuid,text)', 'EXECUTE')
    OR NOT has_function_privilege('voya_outbox_worker', 'public.clear_openwa_send_attempt_v1(uuid,text)', 'EXECUTE')
    OR NOT has_function_privilege('service_role', 'public.begin_openwa_send_attempt_v1(uuid,text)', 'EXECUTE')
    OR NOT has_function_privilege('service_role', 'public.clear_openwa_send_attempt_v1(uuid,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'OpenWA attempt RPC privileges are unsafe';
  END IF;

  SELECT id INTO v_member_a FROM public.organization_memberships
  WHERE organization_id = v_org_a AND user_id = '11111111-1111-1111-1111-111111111111';
  SELECT id INTO v_member_b FROM public.organization_memberships
  WHERE organization_id = v_org_b AND user_id = '22222222-2222-2222-2222-222222222222';
  IF v_member_a IS NULL OR v_member_b IS NULL THEN
    RAISE EXCEPTION 'disposable tenant fixture is missing';
  END IF;

  INSERT INTO public.whatsapp_channels (id, organization_id, provider, external_channel_id, display_name, created_by_membership_id)
  VALUES
    (v_channel_a, v_org_a, 'openwa', 'attempt-a-session', 'OpenWA A', v_member_a),
    (v_channel_b, v_org_b, 'openwa', 'attempt-b-session', 'OpenWA B', v_member_b),
    (v_meta_channel, v_org_a, 'meta_cloud', 'attempt-meta-phone-id', 'Meta A', v_member_a);

  INSERT INTO public.whatsapp_conversations (id, organization_id, channel_id, external_conversation_key)
  VALUES
    (v_conversation_a, v_org_a, v_channel_a, '201000099901@c.us'),
    (v_conversation_b, v_org_b, v_channel_b, '201000099902@c.us'),
    (v_meta_conversation, v_org_a, v_meta_channel, '+201000099903'),
    (v_group_conversation, v_org_a, v_channel_a, '120363@g.us');

  INSERT INTO public.whatsapp_message_events
    (id, organization_id, conversation_id, event_key, direction, body_text, delivery_status, idempotency_key)
  VALUES
    (v_message_a, v_org_a, v_conversation_a, 'attempt-message-a', 'outbound', 'synthetic A', 'queued', 'attempt-message-a'),
    (v_message_b, v_org_b, v_conversation_b, 'attempt-message-b', 'outbound', 'synthetic B', 'queued', 'attempt-message-b'),
    (v_meta_message, v_org_a, v_meta_conversation, 'attempt-message-meta', 'outbound', 'synthetic Meta', 'queued', 'attempt-message-meta'),
    (v_group_message, v_org_a, v_group_conversation, 'attempt-message-group', 'outbound', 'synthetic Group', 'queued', 'attempt-message-group');

  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload)
  VALUES (v_org_a, 'whatsapp.message.send_requested', 1, 'openwa-attempt-a',
    jsonb_build_object('message_id', v_message_a, 'conversation_id', v_conversation_a)) RETURNING id INTO v_event_a;
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload)
  VALUES (v_org_a, 'whatsapp.message.send_requested', 1, 'openwa-attempt-cross-tenant',
    jsonb_build_object('message_id', v_message_b, 'conversation_id', v_conversation_b)) RETURNING id INTO v_event_cross_tenant;
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload)
  VALUES (v_org_a, 'whatsapp.message.send_requested', 1, 'openwa-attempt-meta',
    jsonb_build_object('message_id', v_meta_message, 'conversation_id', v_meta_conversation)) RETURNING id INTO v_event_meta;
  INSERT INTO public.outbox_events (organization_id, event_type, schema_version, dedupe_key, payload)
  VALUES (v_org_a, 'whatsapp.message.send_requested', 1, 'openwa-attempt-group',
    jsonb_build_object('message_id', v_group_message, 'conversation_id', v_group_conversation)) RETURNING id INTO v_event_group;

  UPDATE public.outbox_events
  SET state = 'processing', locked_by = 'attempt-owner', locked_until = timezone('utc', now()) + interval '5 minutes'
  WHERE id IN (v_event_a, v_event_cross_tenant, v_event_meta, v_event_group);

  IF public.begin_openwa_send_attempt_v1(v_event_a, 'wrong-worker')
    OR public.begin_openwa_send_attempt_v1(v_event_cross_tenant, 'attempt-owner')
    OR public.begin_openwa_send_attempt_v1(v_event_meta, 'attempt-owner')
    OR public.begin_openwa_send_attempt_v1(v_event_group, 'attempt-owner') THEN
    RAISE EXCEPTION 'attempt mark must reject wrong lease, tenant, provider, and group destination';
  END IF;
  IF NOT public.begin_openwa_send_attempt_v1(v_event_a, 'attempt-owner') THEN
    RAISE EXCEPTION 'first leased OpenWA attempt must mark exactly once';
  END IF;
  IF public.begin_openwa_send_attempt_v1(v_event_a, 'attempt-owner')
    OR (SELECT openwa_send_started_at FROM public.outbox_events WHERE id = v_event_a) IS NULL THEN
    RAISE EXCEPTION 'first leased OpenWA attempt must mark exactly once';
  END IF;
  IF public.clear_openwa_send_attempt_v1(v_event_a, 'wrong-worker') THEN
    RAISE EXCEPTION 'only its current lease owner may clear a marked safe refusal';
  END IF;
  IF NOT public.clear_openwa_send_attempt_v1(v_event_a, 'attempt-owner') THEN
    RAISE EXCEPTION 'only its current lease owner may clear a marked safe refusal';
  END IF;
  IF public.clear_openwa_send_attempt_v1(v_event_a, 'attempt-owner')
    OR (SELECT openwa_send_started_at FROM public.outbox_events WHERE id = v_event_a) IS NOT NULL THEN
    RAISE EXCEPTION 'only its current lease owner may clear a marked safe refusal';
  END IF;
  IF NOT public.begin_openwa_send_attempt_v1(v_event_a, 'attempt-owner') THEN
    RAISE EXCEPTION 'a proven safe refusal must permit another attempt';
  END IF;

  UPDATE public.outbox_events SET locked_until = timezone('utc', now()) - interval '100 years'
  WHERE id = v_event_a;
  IF public.begin_openwa_send_attempt_v1(v_event_a, 'attempt-owner')
    OR public.clear_openwa_send_attempt_v1(v_event_a, 'attempt-owner') THEN
    RAISE EXCEPTION 'an expired lease must not mark or clear the attempt';
  END IF;
  PERFORM public.claim_outbox_delivery_events('attempt-reclaimer', 1, 300);
  SELECT state, last_error_code INTO v_reclaimed_state, v_reclaimed_error
  FROM public.outbox_events WHERE id = v_event_a;
  IF v_reclaimed_state IS DISTINCT FROM 'needs_review'
    OR v_reclaimed_error IS DISTINCT FROM 'worker_lease_expired_ambiguous'
    OR (SELECT openwa_send_started_at FROM public.outbox_events WHERE id = v_event_a) IS NULL THEN
    RAISE EXCEPTION 'an expired uncertain send must be quarantined with its mark intact';
  END IF;
  IF public.begin_openwa_send_attempt_v1(v_event_a, 'attempt-reclaimer') THEN
    RAISE EXCEPTION 'a quarantined event must not send again';
  END IF;
END;
$$;
