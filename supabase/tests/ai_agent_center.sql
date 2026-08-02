-- Governed AI Agent Center integration checks.

DO $$
BEGIN
  IF has_table_privilege('authenticated', 'public.ai_runs', 'SELECT')
    OR has_table_privilege('authenticated', 'public.ai_tool_calls', 'INSERT') THEN
    RAISE EXCEPTION 'browser role must use AI RPCs, not direct telemetry table access';
  END IF;
  IF has_function_privilege('anon', 'public.list_ai_runs(uuid,integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'anon must not execute the AI run read function';
  END IF;
END;
$$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);

SELECT public.create_ai_run_request(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'sales', 'اقتراح متابعة لطلب جديد', 'ai-run-a-1',
  'aaaaaaaa-0000-0000-0000-0000000000f1'
) AS run_id \gset

SELECT public.create_ai_run_request(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'sales', 'اقتراح متابعة لطلب جديد', 'ai-run-a-1',
  'aaaaaaaa-0000-0000-0000-0000000000f2'
);

DO $$
BEGIN
  IF (SELECT count(*) FROM public.list_ai_runs('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 30)) <> 1 THEN
    RAISE EXCEPTION 'idempotent AI run request must persist exactly once';
  END IF;
END;
$$;

RESET ROLE;

INSERT INTO public.ai_tool_calls (
  organization_id, run_id, tool_name, tool_version, effect, policy_decision, status,
  request_summary, response_summary
) VALUES (
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'run_id', 'search_properties_v1', 'registry-v1',
  'read', 'allowed', 'succeeded', '{"limit":5}'::jsonb, '{"count":0}'::jsonb
);

DO $$
BEGIN
  IF (SELECT count(*) FROM public.outbox_events WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND event_type = 'ai.run.requested') <> 1 THEN
    RAISE EXCEPTION 'AI run request must enqueue exactly one outbox event';
  END IF;
  IF (SELECT count(*) FROM public.audit_events WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND action = 'ai.run.requested') <> 1 THEN
    RAISE EXCEPTION 'AI run request must append audit evidence';
  END IF;
END;
$$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
DO $$
BEGIN
  IF (SELECT count(*) FROM public.list_ai_tool_calls(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    (SELECT id FROM public.list_ai_runs('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 30)
     WHERE purpose = 'اقتراح متابعة لطلب جديد')
  )) <> 1 THEN
    RAISE EXCEPTION 'owner must see the AI tool call trail';
  END IF;
END;
$$;
RESET ROLE;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '33333333-3333-3333-3333-333333333333', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.create_ai_run_request(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'manager', 'مرفوض', 'ai-run-denied', NULL
    );
    RAISE EXCEPTION 'suspended viewer must not request an AI run';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END;
$$;
RESET ROLE;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.create_ai_run_request(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'finance', 'لا يجب تشغيل مساعد المالية', 'ai-run-finance-denied', NULL
    );
    RAISE EXCEPTION 'finance AI must remain disabled';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END;
$$;
RESET ROLE;

SELECT 'AI Agent Center database integration tests passed' AS result;
