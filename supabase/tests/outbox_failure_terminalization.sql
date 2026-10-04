-- R11/R12: outbox terminal failure and its domain delivery/AI state transition atomically.
\set ON_ERROR_STOP on

BEGIN;

INSERT INTO public.whatsapp_channels (
  id, organization_id, provider, external_channel_id, display_name, created_by_membership_id
) VALUES (
  'aaaaaaaa-0000-0000-0000-00000000c901', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'meta_cloud_sandbox', 'r11-channel', 'R11 test',
  (SELECT id FROM public.organization_memberships WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND user_id = '11111111-1111-1111-1111-111111111111')
);
INSERT INTO public.whatsapp_conversations (id, organization_id, channel_id, external_conversation_key)
VALUES ('aaaaaaaa-0000-0000-0000-00000000c902', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-00000000c901', 'r11-thread');

INSERT INTO public.ai_runs (
  id, organization_id, agent_kind, agent_version, status, purpose, model_name,
  prompt_version, initiated_by_membership_id, idempotency_key, whatsapp_conversation_id
) VALUES
  ('aaaaaaaa-0000-0000-0000-00000000c903', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'whatsapp', 'v1', 'running', 'terminal retry proof', 'fake', 'v1',
   (SELECT id FROM public.organization_memberships WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND user_id = '11111111-1111-1111-1111-111111111111'), 'r11-run-exhausted', 'aaaaaaaa-0000-0000-0000-00000000c902'),
  ('aaaaaaaa-0000-0000-0000-00000000c904', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'whatsapp', 'v1', 'queued', 'retryable transient proof', 'fake', 'v1',
   (SELECT id FROM public.organization_memberships WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND user_id = '11111111-1111-1111-1111-111111111111'), 'r11-run-retry', 'aaaaaaaa-0000-0000-0000-00000000c902');

INSERT INTO public.whatsapp_message_events (
  id, organization_id, conversation_id, event_key, direction, body_text,
  delivery_status, created_by_membership_id, idempotency_key
) VALUES
  ('aaaaaaaa-0000-0000-0000-00000000c905', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-00000000c902', 'r12-message-final', 'outbound', 'synthetic failure', 'queued',
   (SELECT id FROM public.organization_memberships WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND user_id = '11111111-1111-1111-1111-111111111111'), 'r12-message-final'),
  ('aaaaaaaa-0000-0000-0000-00000000c906', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-0000-0000-0000-00000000c902', 'r12-message-retry', 'outbound', 'synthetic transient', 'queued',
   (SELECT id FROM public.organization_memberships WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND user_id = '11111111-1111-1111-1111-111111111111'), 'r12-message-retry');

INSERT INTO public.organization_invitations (
  id, organization_id, normalized_email, role, token_digest, expires_at, created_by_membership_id, delivery_status
) VALUES (
  'aaaaaaaa-0000-0000-0000-00000000c907', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'r12-invite@example.test', 'manager', repeat('a', 64), timezone('utc', now()) + interval '1 day',
  (SELECT id FROM public.organization_memberships WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND user_id = '11111111-1111-1111-1111-111111111111'), 'pending'
);

INSERT INTO public.outbox_events (
  id, organization_id, event_type, schema_version, dedupe_key, payload,
  state, attempts, locked_by, locked_until
) VALUES
  ('aaaaaaaa-0000-0000-0000-00000000c911', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'whatsapp.ai.respond_requested', 1, 'r11-final',
   jsonb_build_object('run_id', 'aaaaaaaa-0000-0000-0000-00000000c903', 'conversation_id', 'aaaaaaaa-0000-0000-0000-00000000c902'),
   'processing', 6, 'r11-worker', timezone('utc', now()) + interval '5 minutes'),
  ('aaaaaaaa-0000-0000-0000-00000000c912', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'whatsapp.ai.respond_requested', 1, 'r11-retry',
   jsonb_build_object('run_id', 'aaaaaaaa-0000-0000-0000-00000000c904', 'conversation_id', 'aaaaaaaa-0000-0000-0000-00000000c902'),
   'processing', 5, 'r11-worker', timezone('utc', now()) + interval '5 minutes'),
  ('aaaaaaaa-0000-0000-0000-00000000c913', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'whatsapp.message.send_requested', 1, 'r12-final',
   jsonb_build_object('message_id', 'aaaaaaaa-0000-0000-0000-00000000c905'),
   'processing', 6, 'r12-worker', timezone('utc', now()) + interval '5 minutes'),
  ('aaaaaaaa-0000-0000-0000-00000000c914', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'whatsapp.message.send_requested', 1, 'r12-retry',
   jsonb_build_object('message_id', 'aaaaaaaa-0000-0000-0000-00000000c906'),
   'processing', 5, 'r12-worker', timezone('utc', now()) + interval '5 minutes'),
  ('aaaaaaaa-0000-0000-0000-00000000c915', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'organization.invitation.send_requested', 1, 'r12-invitation',
   jsonb_build_object('invitation_id', 'aaaaaaaa-0000-0000-0000-00000000c907'),
   'processing', 6, 'r12-worker', timezone('utc', now()) + interval '5 minutes');

DO $$
BEGIN
  IF to_regprocedure('public.fail_whatsapp_ai_outbox_event_v1(uuid,text,text,integer,integer)') IS NULL
    OR to_regprocedure('public.fail_outbox_delivery_event_v1(uuid,text,text,integer,integer)') IS NULL THEN
    RAISE EXCEPTION 'R11/R12 terminal transition RPCs are missing';
  END IF;
END;
$$;

SET LOCAL ROLE service_role;
DO $$
DECLARE v_result text;
BEGIN
  v_result := public.fail_whatsapp_ai_outbox_event_v1('aaaaaaaa-0000-0000-0000-00000000c911', 'r11-worker', 'ai_provider_request_failed', 30, 6);
  IF v_result <> 'dead_letter' THEN RAISE EXCEPTION 'R11 expected dead_letter, got %', v_result; END IF;
  v_result := public.fail_whatsapp_ai_outbox_event_v1('aaaaaaaa-0000-0000-0000-00000000c912', 'r11-worker', 'whatsapp_media_not_ready', 30, 6);
  IF v_result <> 'retry_wait' THEN RAISE EXCEPTION 'R11 transient failure must remain retryable, got %', v_result; END IF;

  v_result := public.fail_outbox_delivery_event_v1('aaaaaaaa-0000-0000-0000-00000000c913', 'r12-worker', 'provider_failure', 30, 6);
  IF v_result <> 'dead_letter' THEN RAISE EXCEPTION 'R12 expected WhatsApp dead_letter, got %', v_result; END IF;
  v_result := public.fail_outbox_delivery_event_v1('aaaaaaaa-0000-0000-0000-00000000c914', 'r12-worker', 'rate_limited', 30, 6);
  IF v_result <> 'retry_wait' THEN RAISE EXCEPTION 'R12 transient WhatsApp failure must retry, got %', v_result; END IF;
  v_result := public.fail_outbox_delivery_event_v1('aaaaaaaa-0000-0000-0000-00000000c915', 'r12-worker', 'provider_failure', 30, 6);
  IF v_result <> 'dead_letter' THEN RAISE EXCEPTION 'R12 expected invitation dead_letter, got %', v_result; END IF;
END;
$$;
RESET ROLE;

DO $$
BEGIN
  IF (SELECT state FROM public.outbox_events WHERE id = 'aaaaaaaa-0000-0000-0000-00000000c911') <> 'dead_letter'
    OR (SELECT status FROM public.ai_runs WHERE id = 'aaaaaaaa-0000-0000-0000-00000000c903') <> 'failed'
    OR (SELECT error_code FROM public.ai_runs WHERE id = 'aaaaaaaa-0000-0000-0000-00000000c903') <> 'whatsapp_ai_retry_exhausted'
    OR (SELECT state FROM public.outbox_events WHERE id = 'aaaaaaaa-0000-0000-0000-00000000c912') <> 'retry_wait'
    OR (SELECT status FROM public.ai_runs WHERE id = 'aaaaaaaa-0000-0000-0000-00000000c904') <> 'queued' THEN
    RAISE EXCEPTION 'R11 AI run and outbox terminal/retry states diverged';
  END IF;

  IF (SELECT state FROM public.outbox_events WHERE id = 'aaaaaaaa-0000-0000-0000-00000000c913') <> 'dead_letter'
    OR (SELECT delivery_status FROM public.whatsapp_message_events WHERE id = 'aaaaaaaa-0000-0000-0000-00000000c905') <> 'failed'
    OR (SELECT state FROM public.outbox_events WHERE id = 'aaaaaaaa-0000-0000-0000-00000000c914') <> 'retry_wait'
    OR (SELECT delivery_status FROM public.whatsapp_message_events WHERE id = 'aaaaaaaa-0000-0000-0000-00000000c906') <> 'queued'
    OR (SELECT state FROM public.outbox_events WHERE id = 'aaaaaaaa-0000-0000-0000-00000000c915') <> 'dead_letter'
    OR (SELECT delivery_status FROM public.organization_invitations WHERE id = 'aaaaaaaa-0000-0000-0000-00000000c907') <> 'failed' THEN
    RAISE EXCEPTION 'R12 delivery and outbox terminal/retry states diverged';
  END IF;

  IF has_function_privilege('anon', 'public.fail_whatsapp_ai_outbox_event_v1(uuid,text,text,integer,integer)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.fail_whatsapp_ai_outbox_event_v1(uuid,text,text,integer,integer)', 'EXECUTE')
    OR has_function_privilege('anon', 'public.fail_outbox_delivery_event_v1(uuid,text,text,integer,integer)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.fail_outbox_delivery_event_v1(uuid,text,text,integer,integer)', 'EXECUTE')
    OR NOT has_function_privilege('voya_outbox_worker', 'public.fail_whatsapp_ai_outbox_event_v1(uuid,text,text,integer,integer)', 'EXECUTE')
    OR NOT has_function_privilege('service_role', 'public.fail_outbox_delivery_event_v1(uuid,text,text,integer,integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'R11/R12 worker RPC grants are not narrowly scoped';
  END IF;
END;
$$;

ROLLBACK;
SELECT 'R11/R12 atomic outbox failure tests passed' AS result;
