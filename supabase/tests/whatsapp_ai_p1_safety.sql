-- R-05: a channel kill switch flipped after enqueue must fail closed at every
-- worker boundary (lease renewal, run start, result apply), and low-confidence
-- model output must never queue an automatic WhatsApp reply.
--
-- Behavioral proof on the disposable database; definition assertions guard the
-- policy text, grant posture keeps the boundary off browser roles.
--
-- Convention: psql client vars (via \gset) are bridged into server session
-- settings with set_config so DO blocks can read them via current_setting.

-- ---------------------------------------------------------------------------
-- 1) Policy text + grant posture
-- ---------------------------------------------------------------------------

DO $$
DECLARE
  v_source text;
BEGIN
  SELECT pg_get_functiondef(
    'public.renew_whatsapp_ai_event_lease_v1(uuid,text,integer)'::regprocedure
  ) INTO v_source;
  IF position('channel.kill_switch = false' IN v_source) = 0
    OR position('channel.status = ''active''' IN v_source) = 0 THEN
    RAISE EXCEPTION 'lease renewal must enforce channel kill switch and active status';
  END IF;

  SELECT pg_get_functiondef(
    'public.start_whatsapp_ai_run_v1(uuid,text,text,text)'::regprocedure
  ) INTO v_source;
  IF position('channel.kill_switch = false' IN v_source) = 0
    OR position('channel.status = ''active''' IN v_source) = 0 THEN
    RAISE EXCEPTION 'run start must enforce channel kill switch and active status';
  END IF;

  SELECT pg_get_functiondef(
    'public.apply_whatsapp_ai_result_v1(uuid,text,text,jsonb,text,text,text,boolean)'::regprocedure
  ) INTO v_source;
  IF position('p_confidence <> ''low''' IN v_source) = 0
    OR position('channel.kill_switch = false' IN v_source) = 0 THEN
    RAISE EXCEPTION 'result boundary must enforce low-confidence and channel safety';
  END IF;

  IF to_regprocedure('public.apply_whatsapp_ai_result_v1_legacy(uuid,text,text,jsonb,text,text,text,boolean)') IS NULL THEN
    RAISE EXCEPTION 'legacy apply primitive must exist as the wrapped implementation';
  END IF;
END;
$$;

DO $$
BEGIN
  IF has_function_privilege('anon', 'public.renew_whatsapp_ai_event_lease_v1(uuid,text,integer)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.renew_whatsapp_ai_event_lease_v1(uuid,text,integer)', 'EXECUTE')
    OR has_function_privilege('anon', 'public.start_whatsapp_ai_run_v1(uuid,text,text,text)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.start_whatsapp_ai_run_v1(uuid,text,text,text)', 'EXECUTE')
    OR has_function_privilege('anon', 'public.apply_whatsapp_ai_result_v1(uuid,text,text,jsonb,text,text,text,boolean)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.apply_whatsapp_ai_result_v1(uuid,text,text,jsonb,text,text,text,boolean)', 'EXECUTE')
    OR has_function_privilege('anon', 'public.apply_whatsapp_ai_result_v1_legacy(uuid,text,text,jsonb,text,text,text,boolean)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.apply_whatsapp_ai_result_v1_legacy(uuid,text,text,jsonb,text,text,text,boolean)', 'EXECUTE') THEN
    RAISE EXCEPTION 'WhatsApp AI worker boundary must remain off browser roles';
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- 2) Fixtures: three independent inbound threads on the seeded channel
-- ---------------------------------------------------------------------------

SET ROLE service_role;

SELECT public.ingest_whatsapp_webhook_event_v1(
  'meta_cloud_sandbox', 'sandbox-channel-a', 'safety-kill-thread',
  'safety-kill-event-1', '+201001234591', 'text', 'عايز شقة في مدينة نصر',
  NULL, NULL, NULL, timezone('utc', now())
) AS kill_message_id \gset

SELECT public.ingest_whatsapp_webhook_event_v1(
  'meta_cloud_sandbox', 'sandbox-channel-a', 'safety-lowconf-thread',
  'safety-lowconf-event-1', '+201001234592', 'text', 'بكام الإيجار الشهري',
  NULL, NULL, NULL, timezone('utc', now())
) AS lowconf_message_id \gset

SELECT public.ingest_whatsapp_webhook_event_v1(
  'meta_cloud_sandbox', 'sandbox-channel-a', 'safety-high-thread',
  'safety-high-event-1', '+201001234593', 'text', 'ابعت صور الشقة',
  NULL, NULL, NULL, timezone('utc', now())
) AS high_message_id \gset

RESET ROLE;

-- All worker RPCs below run as the migration owner (like the other suite
-- fixtures); only ingest above needs the service_role boundary.

SELECT set_config('voya.test.kill_message_id', :'kill_message_id', false);
SELECT set_config('voya.test.lowconf_message_id', :'lowconf_message_id', false);
SELECT set_config('voya.test.high_message_id', :'high_message_id', false);

-- Claim our three AI events. Earlier suites leave older pending rows behind,
-- and claim takes oldest-first, so batch-claim until each of ours is owned.
-- The Edge worker claims through claim_outbox_delivery_events (the boundary
-- granted to service_role), so the test uses that same entry point.
DO $$
DECLARE
  v_round integer;
BEGIN
  FOR v_round IN 1..10 LOOP
    PERFORM id FROM public.claim_outbox_delivery_events('safety-worker', 20, 300);
    EXIT WHEN (
      SELECT count(*)
      FROM public.outbox_events
      WHERE dedupe_key IN (
        'whatsapp-ai:' || current_setting('voya.test.kill_message_id'),
        'whatsapp-ai:' || current_setting('voya.test.lowconf_message_id'),
        'whatsapp-ai:' || current_setting('voya.test.high_message_id')
      )
      AND state = 'processing'
      AND locked_by = 'safety-worker'
    ) = 3;
  END LOOP;
END;
$$;

SELECT id::text AS kill_event_id FROM public.outbox_events
WHERE dedupe_key = 'whatsapp-ai:' || :'kill_message_id' \gset
SELECT id::text AS lowconf_event_id FROM public.outbox_events
WHERE dedupe_key = 'whatsapp-ai:' || :'lowconf_message_id' \gset
SELECT id::text AS high_event_id FROM public.outbox_events
WHERE dedupe_key = 'whatsapp-ai:' || :'high_message_id' \gset

SELECT set_config('voya.test.kill_event_id', :'kill_event_id', false);
SELECT set_config('voya.test.lowconf_event_id', :'lowconf_event_id', false);
SELECT set_config('voya.test.high_event_id', :'high_event_id', false);

DO $$
BEGIN
  IF (SELECT count(*) FROM public.outbox_events
      WHERE id IN (
        current_setting('voya.test.kill_event_id')::uuid,
        current_setting('voya.test.lowconf_event_id')::uuid,
        current_setting('voya.test.high_event_id')::uuid)
        AND event_type = 'whatsapp.ai.respond_requested'
        AND state = 'processing' AND locked_by = 'safety-worker') <> 3 THEN
    RAISE EXCEPTION 'safety fixtures must own three processing AI events';
  END IF;
  IF (SELECT count(*) FROM public.ai_runs
      WHERE idempotency_key IN (
        'whatsapp-message:' || current_setting('voya.test.kill_message_id'),
        'whatsapp-message:' || current_setting('voya.test.lowconf_message_id'),
        'whatsapp-message:' || current_setting('voya.test.high_message_id'))
        AND agent_kind = 'whatsapp' AND status = 'queued') <> 3 THEN
    RAISE EXCEPTION 'safety fixtures must queue three whatsapp runs';
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- 3) Kill switch fails closed at renew + start, recovers when lifted
-- ---------------------------------------------------------------------------

SELECT public.renew_whatsapp_ai_event_lease_v1(
  current_setting('voya.test.kill_event_id')::uuid, 'safety-worker', 300
) AS kill_renew_open \gset
SELECT public.start_whatsapp_ai_run_v1(
  current_setting('voya.test.kill_event_id')::uuid, 'safety-worker', 'safety-model', 'safety-v1'
) AS kill_start_open \gset
SELECT set_config('voya.test.kill_renew_open', :'kill_renew_open', false);
SELECT set_config('voya.test.kill_start_open', :'kill_start_open', false);

DO $$
BEGIN
  IF current_setting('voya.test.kill_renew_open') <> 't' THEN
    RAISE EXCEPTION 'open channel must renew the lease';
  END IF;
  IF current_setting('voya.test.kill_start_open') <> 't' THEN
    RAISE EXCEPTION 'open channel must start the run';
  END IF;
END;
$$;

UPDATE public.whatsapp_channels SET kill_switch = true
WHERE provider = 'meta_cloud_sandbox' AND external_channel_id = 'sandbox-channel-a';

DO $$
BEGIN
  IF (SELECT kill_switch FROM public.whatsapp_channels
      WHERE provider = 'meta_cloud_sandbox' AND external_channel_id = 'sandbox-channel-a') IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'safety fixture must flip the kill switch on';
  END IF;
END;
$$;

SELECT public.renew_whatsapp_ai_event_lease_v1(
  current_setting('voya.test.kill_event_id')::uuid, 'safety-worker', 300
) AS kill_renew_killed \gset
SELECT public.start_whatsapp_ai_run_v1(
  current_setting('voya.test.kill_event_id')::uuid, 'safety-worker', 'safety-model', 'safety-v1'
) AS kill_start_killed \gset
SELECT set_config('voya.test.kill_renew_killed', :'kill_renew_killed', false);
SELECT set_config('voya.test.kill_start_killed', :'kill_start_killed', false);

DO $$
BEGIN
  IF current_setting('voya.test.kill_renew_killed') <> 'f' THEN
    RAISE EXCEPTION 'killed channel must refuse lease renewal';
  END IF;
  IF current_setting('voya.test.kill_start_killed') <> 'f' THEN
    RAISE EXCEPTION 'killed channel must refuse run start';
  END IF;
END;
$$;

UPDATE public.whatsapp_channels SET kill_switch = false
WHERE provider = 'meta_cloud_sandbox' AND external_channel_id = 'sandbox-channel-a';

DO $$
BEGIN
  IF (SELECT kill_switch FROM public.whatsapp_channels
      WHERE provider = 'meta_cloud_sandbox' AND external_channel_id = 'sandbox-channel-a') IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'safety fixture must lift the kill switch';
  END IF;
END;
$$;

SELECT public.renew_whatsapp_ai_event_lease_v1(
  current_setting('voya.test.kill_event_id')::uuid, 'safety-worker', 300
) AS kill_renew_recovered \gset
SELECT set_config('voya.test.kill_renew_recovered', :'kill_renew_recovered', false);

DO $$
BEGIN
  IF current_setting('voya.test.kill_renew_recovered') <> 't' THEN
    RAISE EXCEPTION 'lifted kill switch must renew again';
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- 4) Low confidence applies state but queues no reply; high still replies
-- ---------------------------------------------------------------------------

SELECT outcome AS lowconf_outcome FROM public.apply_whatsapp_ai_result_v1(
  current_setting('voya.test.lowconf_event_id')::uuid, 'safety-worker', 'unknown', '{}'::jsonb,
  'رد تلقائي منخفض الثقة', 'continue', 'low', true
) \gset
SELECT set_config('voya.test.lowconf_outcome', :'lowconf_outcome', false);

DO $$
BEGIN
  IF current_setting('voya.test.lowconf_outcome') <> 'applied' THEN
    RAISE EXCEPTION 'low-confidence result must still apply conversation state';
  END IF;
  IF (SELECT count(*) FROM public.whatsapp_message_events
      WHERE idempotency_key = 'whatsapp-ai-reply:' || current_setting('voya.test.lowconf_message_id')) <> 0 THEN
    RAISE EXCEPTION 'low-confidence result must not queue an outbound reply';
  END IF;
  IF (SELECT count(*) FROM public.outbox_events
      WHERE event_type = 'whatsapp.message.send_requested'
        AND payload ->> 'conversation_id' = (
          SELECT conversation_id::text FROM public.whatsapp_message_events
          WHERE id = current_setting('voya.test.lowconf_message_id')::uuid
        )
        AND created_at > timezone('utc', now()) - interval '5 minutes') <> 0 THEN
    RAISE EXCEPTION 'low-confidence result must not enqueue a send request';
  END IF;
  IF (SELECT last_ai_processed_message_id FROM public.whatsapp_conversations
      WHERE id = (
        SELECT conversation_id FROM public.whatsapp_message_events
        WHERE id = current_setting('voya.test.lowconf_message_id')::uuid
      )) IS DISTINCT FROM current_setting('voya.test.lowconf_message_id')::uuid THEN
    RAISE EXCEPTION 'low-confidence result must still mark the message processed';
  END IF;
END;
$$;

SELECT outcome AS high_outcome, outbound_message_id::text AS high_outbound_id
FROM public.apply_whatsapp_ai_result_v1(
  current_setting('voya.test.high_event_id')::uuid, 'safety-worker', 'unknown', '{}'::jsonb,
  'أهلا بك، ابعت صور الشقة من فضلك', 'continue', 'high', true
) \gset
SELECT set_config('voya.test.high_outcome', :'high_outcome', false);
SELECT set_config('voya.test.high_outbound_id', :'high_outbound_id', false);

DO $$
BEGIN
  IF current_setting('voya.test.high_outcome') <> 'applied' THEN
    RAISE EXCEPTION 'high-confidence result must apply';
  END IF;
  IF (SELECT count(*) FROM public.whatsapp_message_events
      WHERE id = current_setting('voya.test.high_outbound_id')::uuid
        AND direction = 'outbound' AND delivery_status = 'queued') <> 1 THEN
    RAISE EXCEPTION 'high-confidence result must queue exactly one outbound reply';
  END IF;
END;
$$;

-- Leave the seeded channel exactly as found for later suites.
UPDATE public.whatsapp_channels SET kill_switch = false
WHERE provider = 'meta_cloud_sandbox' AND external_channel_id = 'sandbox-channel-a';
