-- Read-only AI Copilot tenant, role, and worker-context proof.

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'ai_runs_agent_kind_check'
      AND pg_get_constraintdef(oid) LIKE '%copilot%'
  ) THEN
    RAISE EXCEPTION 'AI run agent constraint must include copilot';
  END IF;
  IF to_regprocedure('public.resolve_ai_copilot_execution(uuid,text)') IS NULL
    OR to_regprocedure('public.record_ai_copilot_context_read(uuid,text,jsonb)') IS NULL THEN
    RAISE EXCEPTION 'AI copilot worker RPCs are missing';
  END IF;
  IF NOT has_function_privilege('voya_outbox_worker', 'public.resolve_ai_copilot_execution(uuid,text)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.resolve_ai_copilot_execution(uuid,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'AI copilot context RPC must be worker-only';
  END IF;
END;
$$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);

SELECT public.create_ai_run_request(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'copilot', 'لخص أولويات التشغيل', 'ai-copilot-v1',
  'aaaaaaaa-0000-0000-0000-0000000000f3'
) AS run_id \gset

RESET ROLE;

SELECT id AS ai_event_id
FROM public.claim_outbox_delivery_events('ai-copilot-worker', 20, 300)
WHERE event_type = 'ai.run.requested'
  AND payload ->> 'run_id' = :'run_id'
LIMIT 1 \gset

SELECT set_config('voya.test.ai_event_id', :'ai_event_id', false);
SELECT set_config('voya.test.ai_run_id', :'run_id', false);

DO $$
DECLARE
  v_context jsonb;
  v_event_id uuid := current_setting('voya.test.ai_event_id')::uuid;
BEGIN
  SELECT context INTO v_context
  FROM public.resolve_ai_copilot_execution(v_event_id, 'ai-copilot-worker');
  IF jsonb_typeof(v_context) <> 'object'
    OR NOT (v_context ? 'as_of_date')
    OR NOT (v_context ? 'properties')
    OR NOT (v_context ? 'leads')
    OR NOT (v_context ? 'bookings')
    OR NOT (v_context ? 'tasks') THEN
    RAISE EXCEPTION 'copilot context must contain bounded operational summaries';
  END IF;
  IF v_context ? 'organization_id' OR v_context ? 'membership_id' THEN
    RAISE EXCEPTION 'copilot context must not expose trusted identity values';
  END IF;
  IF NOT ((v_context -> 'leads') ? 'won') OR ((v_context -> 'leads') ? 'converted') THEN
    RAISE EXCEPTION 'copilot lead context must use the V1 won status';
  END IF;
END;
$$;

SELECT public.record_ai_copilot_context_read(
  current_setting('voya.test.ai_event_id')::uuid, 'ai-copilot-worker',
  '{"scope":"organization","fields":["properties","leads","bookings","tasks"]}'::jsonb
);
SELECT public.complete_outbox_event(current_setting('voya.test.ai_event_id')::uuid, 'ai-copilot-worker');

DO $$
BEGIN
  IF (SELECT count(*) FROM public.ai_tool_calls WHERE run_id = current_setting('voya.test.ai_run_id')::uuid AND tool_name = 'read_copilot_context_v1' AND effect = 'read' AND policy_decision = 'allowed' AND status = 'succeeded') <> 1 THEN
    RAISE EXCEPTION 'copilot context read must leave one allowed tool record';
  END IF;
END;
$$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT public.create_ai_run_request(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'copilot', 'تعليق بعد التعليق', 'ai-copilot-suspended', NULL
) AS suspended_run_id \gset
RESET ROLE;

SELECT id AS suspended_event_id
FROM public.claim_outbox_delivery_events('ai-copilot-worker-suspended', 20, 300)
WHERE event_type = 'ai.run.requested'
  AND payload ->> 'run_id' = :'suspended_run_id'
LIMIT 1 \gset

SELECT set_config('voya.test.ai_suspended_event_id', :'suspended_event_id', false);
UPDATE public.organization_memberships
SET status = 'suspended'
WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  AND user_id = '11111111-1111-1111-1111-111111111111';

DO $$
BEGIN
  BEGIN
    PERFORM public.resolve_ai_copilot_execution(
      current_setting('voya.test.ai_suspended_event_id')::uuid,
      'ai-copilot-worker-suspended'
    );
    RAISE EXCEPTION 'suspended membership must not execute a queued copilot run';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END;
$$;

UPDATE public.organization_memberships
SET status = 'active'
WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  AND user_id = '11111111-1111-1111-1111-111111111111';

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '33333333-3333-3333-3333-333333333333', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.create_ai_run_request(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'copilot', 'مرفوض', 'ai-copilot-denied', NULL
    );
    RAISE EXCEPTION 'suspended viewer must not request copilot access';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END;
$$;
RESET ROLE;

SELECT 'AI Copilot read-only database tests passed' AS result;
