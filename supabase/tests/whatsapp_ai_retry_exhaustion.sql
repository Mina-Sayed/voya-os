-- A terminal outbox failure and its WhatsApp AI run must be finalized in one
-- lease-owned transaction.
\set ON_ERROR_STOP on

INSERT INTO public.ai_runs (
  id, organization_id, agent_kind, agent_version, status, purpose, model_name,
  prompt_version, initiated_by_membership_id, idempotency_key, started_at
) VALUES (
  'aaaaaaaa-0000-0000-0000-000000000801',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'whatsapp', '1', 'running',
  'retry exhaustion regression', 'test-model', 'test-v1',
  (SELECT id FROM public.organization_memberships
   WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
     AND user_id = '11111111-1111-1111-1111-111111111111'),
  'whatsapp-retry-exhaustion-regression', timezone('utc', now())
);
INSERT INTO public.outbox_events (
  id, organization_id, event_type, schema_version, dedupe_key, payload,
  state, attempts, locked_by, locked_until
) VALUES (
  'aaaaaaaa-0000-0000-0000-000000000802',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'whatsapp.ai.respond_requested', 1,
  'whatsapp-retry-exhaustion-regression',
  jsonb_build_object('run_id', 'aaaaaaaa-0000-0000-0000-000000000801'),
  'processing', 6, 'review-exhaustion-worker', timezone('utc', now()) + interval '5 minutes'
);

SET ROLE voya_outbox_worker;
DO $$
DECLARE v_finalized boolean;
BEGIN
  v_finalized := public.fail_whatsapp_ai_delivery_v1(
    'aaaaaaaa-0000-0000-0000-000000000802', 'review-exhaustion-worker',
    'provider_unavailable'
  );
  IF NOT v_finalized THEN RAISE EXCEPTION 'retry exhaustion must finalize the AI run with the event'; END IF;
END;
$$;
RESET ROLE;

DO $$
BEGIN
  IF (SELECT state FROM public.outbox_events WHERE id = 'aaaaaaaa-0000-0000-0000-000000000802') <> 'dead_letter'
    OR (SELECT status FROM public.ai_runs WHERE id = 'aaaaaaaa-0000-0000-0000-000000000801') <> 'failed'
    OR (SELECT locked_by FROM public.outbox_events WHERE id = 'aaaaaaaa-0000-0000-0000-000000000802') IS NOT NULL THEN
    RAISE EXCEPTION 'exhausted WhatsApp AI event and run must both be terminal';
  END IF;
END;
$$;

SELECT 'WhatsApp AI retry exhaustion tests passed' AS result;
