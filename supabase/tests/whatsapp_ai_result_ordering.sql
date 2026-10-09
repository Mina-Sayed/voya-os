-- R04: two workers can resolve the same WhatsApp AI snapshot before either
-- result applies. A later message result must keep the conversation cursor and
-- structured state ahead of any older in-flight result.
--
-- Run after the checkout migrations on a disposable database. This proof uses
-- the seeded local sandbox channel and worker/service-role RPC boundary.

\set ON_ERROR_STOP on

DO $$
BEGIN
  IF has_function_privilege('anon', 'public.apply_whatsapp_ai_result_v1(uuid,text,text,jsonb,text,text,text,boolean)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.apply_whatsapp_ai_result_v1(uuid,text,text,jsonb,text,text,text,boolean)', 'EXECUTE')
    OR has_function_privilege('service_role', 'public.apply_whatsapp_ai_result_v1_legacy(uuid,text,text,jsonb,text,text,text,boolean)', 'EXECUTE')
    OR has_function_privilege('voya_outbox_worker', 'public.apply_whatsapp_ai_result_v1_legacy(uuid,text,text,jsonb,text,text,text,boolean)', 'EXECUTE')
    OR NOT has_function_privilege('service_role', 'public.apply_whatsapp_ai_result_v1(uuid,text,text,jsonb,text,text,text,boolean)', 'EXECUTE')
    OR NOT has_function_privilege('voya_outbox_worker', 'public.apply_whatsapp_ai_result_v1(uuid,text,text,jsonb,text,text,text,boolean)', 'EXECUTE') THEN
    RAISE EXCEPTION 'R04 must preserve the guarded service-role/worker result boundary';
  END IF;
END;
$$;

SELECT gen_random_uuid()::text AS nonce \gset
SELECT clock_timestamp()::timestamptz::text AS base_time \gset
SELECT (:'base_time'::timestamptz - interval '2 minutes')::text AS a_received_at \gset
SELECT (:'base_time'::timestamptz - interval '1 minute')::text AS b_received_at \gset

SET ROLE service_role;
SELECT public.ingest_whatsapp_webhook_event_v1(
  'meta_cloud_sandbox', 'sandbox-channel-a', 'r04-ordering-' || :'nonce',
  'r04-ordering-a-' || :'nonce', '+201001234599', 'text', 'رسالة A الأقدم',
  NULL, NULL, NULL, :'a_received_at'::timestamptz
) AS a_message_id \gset
SELECT public.ingest_whatsapp_webhook_event_v1(
  'meta_cloud_sandbox', 'sandbox-channel-a', 'r04-ordering-' || :'nonce',
  'r04-ordering-b-' || :'nonce', '+201001234599', 'text', 'رسالة B الأحدث',
  NULL, NULL, NULL, :'b_received_at'::timestamptz
) AS b_message_id \gset
RESET ROLE;

SELECT conversation_id::text AS conversation_id
FROM public.whatsapp_message_events
WHERE id = :'a_message_id'::uuid \gset
SELECT id::text AS a_event_id
FROM public.outbox_events
WHERE event_type = 'whatsapp.ai.respond_requested'
  AND dedupe_key = 'whatsapp-ai:' || :'a_message_id' \gset
SELECT id::text AS b_event_id
FROM public.outbox_events
WHERE event_type = 'whatsapp.ai.respond_requested'
  AND dedupe_key = 'whatsapp-ai:' || :'b_message_id' \gset

SELECT set_config('voya.test.r04_a_message_id', :'a_message_id', false);
SELECT set_config('voya.test.r04_b_message_id', :'b_message_id', false);
SELECT set_config('voya.test.r04_conversation_id', :'conversation_id', false);
SELECT set_config('voya.test.r04_a_event_id', :'a_event_id', false);
SELECT set_config('voya.test.r04_b_event_id', :'b_event_id', false);

SET ROLE service_role;
DO $$
DECLARE
  v_round integer;
  v_claimed record;
  v_a_claimed boolean := false;
  v_b_claimed boolean := false;
BEGIN
  FOR v_round IN 1..100 LOOP
    FOR v_claimed IN
      SELECT claimed.id
      FROM public.claim_outbox_delivery_events('r04-ordering-worker', 20, 300) AS claimed
    LOOP
      v_a_claimed := v_a_claimed
        OR v_claimed.id = current_setting('voya.test.r04_a_event_id')::uuid;
      v_b_claimed := v_b_claimed
        OR v_claimed.id = current_setting('voya.test.r04_b_event_id')::uuid;
    END LOOP;
    EXIT WHEN v_a_claimed AND v_b_claimed;
  END LOOP;

  IF NOT v_a_claimed OR NOT v_b_claimed THEN
    RAISE EXCEPTION 'R04 fixtures must be claimed by the service-role worker';
  END IF;
END;
$$;
RESET ROLE;

DO $$
BEGIN
  IF (
    SELECT count(*)
    FROM public.outbox_events
    WHERE id IN (
      current_setting('voya.test.r04_a_event_id')::uuid,
      current_setting('voya.test.r04_b_event_id')::uuid
    )
      AND state = 'processing'
      AND locked_by = 'r04-ordering-worker'
  ) <> 2 THEN
    RAISE EXCEPTION 'R04 fixtures must be owned by the service-role worker';
  END IF;
END;
$$;

SET ROLE service_role;

-- Both RPC reads happen before either result applies and must observe the same
-- initial conversation state, reproducing the model-work interleaving.
DO $$
DECLARE
  v_a_state jsonb;
  v_b_state jsonb;
  v_a_should_process boolean;
  v_b_should_process boolean;
BEGIN
  SELECT execution.structured_state, execution.should_process
  INTO v_a_state, v_a_should_process
  FROM public.resolve_whatsapp_ai_execution_v1(
    current_setting('voya.test.r04_a_event_id')::uuid,
    'r04-ordering-worker'
  ) AS execution;
  SELECT execution.structured_state, execution.should_process
  INTO v_b_state, v_b_should_process
  FROM public.resolve_whatsapp_ai_execution_v1(
    current_setting('voya.test.r04_b_event_id')::uuid,
    'r04-ordering-worker'
  ) AS execution;

  IF v_a_state IS DISTINCT FROM '{}'::jsonb
    OR v_b_state IS DISTINCT FROM v_a_state
    OR v_a_should_process IS DISTINCT FROM true
    OR v_b_should_process IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'R04 fixture must resolve A and B against the same actionable state';
  END IF;
END;
$$;

SELECT outcome AS b_outcome
FROM public.apply_whatsapp_ai_result_v1(
  current_setting('voya.test.r04_b_event_id')::uuid,
  'r04-ordering-worker', 'unknown', '{"lead":{"name":"New"}}'::jsonb,
  NULL, 'continue', 'high', false
) \gset
SELECT set_config('voya.test.r04_b_outcome', :'b_outcome', false);

SELECT outcome AS b_replay_outcome
FROM public.apply_whatsapp_ai_result_v1(
  current_setting('voya.test.r04_b_event_id')::uuid,
  'r04-ordering-worker', 'unknown', '{"lead":{"name":"New"}}'::jsonb,
  NULL, 'continue', 'high', false
) \gset
SELECT set_config('voya.test.r04_b_replay_outcome', :'b_replay_outcome', false);

SELECT outcome AS a_outcome
FROM public.apply_whatsapp_ai_result_v1(
  current_setting('voya.test.r04_a_event_id')::uuid,
  'r04-ordering-worker', 'unknown', '{"lead":{"name":"Old"}}'::jsonb,
  NULL, 'continue', 'high', false
) \gset
SELECT set_config('voya.test.r04_a_outcome', :'a_outcome', false);
RESET ROLE;

DO $$
DECLARE
  v_cursor uuid;
  v_state jsonb;
BEGIN
  SELECT conversation.last_ai_processed_message_id, conversation.structured_state
  INTO v_cursor, v_state
  FROM public.whatsapp_conversations AS conversation
  WHERE conversation.id = current_setting('voya.test.r04_conversation_id')::uuid;

  IF current_setting('voya.test.r04_b_outcome') <> 'applied'
    OR current_setting('voya.test.r04_b_replay_outcome') <> 'replayed'
    OR current_setting('voya.test.r04_a_outcome') <> 'stale'
    OR v_cursor IS DISTINCT FROM current_setting('voya.test.r04_b_message_id')::uuid
    OR v_state IS DISTINCT FROM '{"lead":{"name":"New"}}'::jsonb THEN
    RAISE EXCEPTION 'R04 stale-result regression: B=%, B replay=%, A=%, cursor=%, state=%',
      current_setting('voya.test.r04_b_outcome'),
      current_setting('voya.test.r04_b_replay_outcome'),
      current_setting('voya.test.r04_a_outcome'),
      v_cursor,
      v_state;
  END IF;
END;
$$;

SELECT 'WhatsApp AI result ordering proof passed' AS result;
