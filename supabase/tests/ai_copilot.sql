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
    OR NOT has_function_privilege('voya_outbox_worker', 'public.record_ai_copilot_context_read(uuid,text,jsonb)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.resolve_ai_copilot_execution(uuid,text)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.record_ai_copilot_context_read(uuid,text,jsonb)', 'EXECUTE') THEN
    RAISE EXCEPTION 'AI copilot context RPC must be worker-only';
  END IF;
END;
$$;

DO $$
BEGIN
  BEGIN
    UPDATE public.organizations
    SET timezone = 'Cairo-local'
    WHERE id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
    RAISE EXCEPTION 'invalid organization timezone must be rejected';
  EXCEPTION WHEN invalid_parameter_value THEN
    NULL;
  END;
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
    OR NOT (v_context ? 'asOfDate')
    OR NOT (v_context ? 'properties')
    OR NOT (v_context ? 'leads')
    OR NOT (v_context ? 'bookings')
    OR NOT (v_context ? 'tasks') THEN
    RAISE EXCEPTION 'copilot context must contain bounded operational summaries';
  END IF;
  IF v_context ? 'organization_id' OR v_context ? 'membership_id' THEN
    RAISE EXCEPTION 'copilot context must not expose trusted identity values';
  END IF;
  IF v_context ->> 'asOfDate' <> to_char(
      timezone((SELECT organization.timezone FROM public.organizations AS organization WHERE organization.id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'), now())::date,
      'YYYY-MM-DD'
    ) THEN
    RAISE EXCEPTION 'copilot context must use the organization timezone';
  END IF;
  IF NOT ((v_context -> 'leads') ? 'contacted')
    OR NOT ((v_context -> 'leads') ? 'offered')
    OR NOT ((v_context -> 'leads') ? 'won')
    OR ((v_context -> 'leads') ? 'converted') THEN
    RAISE EXCEPTION 'copilot lead context must use all V1 lifecycle statuses';
  END IF;
  IF NOT ((v_context -> 'bookings') ? 'checkedIn')
    OR NOT ((v_context -> 'bookings') ? 'checkedOut') THEN
    RAISE EXCEPTION 'copilot booking context must use all V1 lifecycle statuses';
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

UPDATE public.organization_memberships
SET role = 'sales_agent'
WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  AND user_id = '11111111-1111-1111-1111-111111111111';

SELECT set_config(
  'voya.test.sales_agent_draft_baseline',
  (SELECT count(*)::text FROM public.bookings
   WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND status = 'draft'),
  false
);
SELECT id AS sales_agent_membership_id
FROM public.organization_memberships
WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  AND user_id = '11111111-1111-1111-1111-111111111111' \gset
SELECT id AS manager_membership_id
FROM public.organization_memberships
WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  AND user_id = '55555555-5555-5555-5555-555555555555' \gset

INSERT INTO public.bookings (
  id, organization_id, property_id, client_id, status, check_in, check_out, created_by_membership_id
) VALUES
  (
    'aaaaaaaa-0000-0000-0000-0000000000b1', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000002',
    'draft', DATE '2055-01-10', DATE '2055-01-12', :'manager_membership_id'::uuid
  ),
  (
    'aaaaaaaa-0000-0000-0000-0000000000b2', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000002',
    'draft', DATE '2055-01-15', DATE '2055-01-17', :'sales_agent_membership_id'::uuid
  );

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT public.create_ai_run_request(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'copilot', 'ملخص للمبيعات', 'ai-copilot-sales-agent', NULL
) AS sales_agent_run_id \gset
RESET ROLE;

SELECT id AS sales_agent_event_id
FROM public.claim_outbox_delivery_events('ai-copilot-sales-agent-worker', 20, 300)
WHERE event_type = 'ai.run.requested'
  AND payload ->> 'run_id' = :'sales_agent_run_id'
LIMIT 1 \gset
SELECT set_config('voya.test.ai_sales_agent_event_id', :'sales_agent_event_id', false);

DO $$
DECLARE
  v_context jsonb;
BEGIN
  SELECT context INTO v_context
  FROM public.resolve_ai_copilot_execution(current_setting('voya.test.ai_sales_agent_event_id')::uuid, 'ai-copilot-sales-agent-worker');
  IF jsonb_typeof(v_context -> 'tasks') <> 'null' THEN
    RAISE EXCEPTION 'sales agent copilot must not imply access to operations tasks';
  END IF;
  IF (v_context -> 'bookings' ->> 'draft')::integer <> current_setting('voya.test.sales_agent_draft_baseline')::integer + 1 THEN
    RAISE EXCEPTION 'sales agent copilot must only include unassigned and self-created draft bookings';
  END IF;
END;
$$;

SELECT public.record_ai_copilot_context_read(
  current_setting('voya.test.ai_sales_agent_event_id')::uuid, 'ai-copilot-sales-agent-worker',
  '{"scope":"organization","fields":["properties","leads","bookings"]}'::jsonb
);
SELECT public.complete_outbox_event(current_setting('voya.test.ai_sales_agent_event_id')::uuid, 'ai-copilot-sales-agent-worker');

UPDATE public.organization_memberships
SET role = 'owner'
WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  AND user_id = '11111111-1111-1111-1111-111111111111';

SELECT set_config(
  'voya.test.operations_open_baseline',
  (SELECT count(*)::text FROM public.operations_tasks
   WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND status = 'open'),
  false
);
SELECT id AS operations_membership_id
FROM public.organization_memberships
WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  AND user_id = '11111111-1111-1111-1111-111111111111' \gset

INSERT INTO public.operations_tasks (
  id, organization_id, task_type, title, status,
  assigned_membership_id, created_by_membership_id, idempotency_key
) VALUES
  (
    'aaaaaaaa-0000-0000-0000-0000000000c1', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'copilot_scope', 'Copilot unassigned task', 'open', NULL,
    :'operations_membership_id'::uuid, 'copilot-scope-unassigned'
  ),
  (
    'aaaaaaaa-0000-0000-0000-0000000000c2', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'copilot_scope', 'Copilot manager task', 'open', :'manager_membership_id'::uuid,
    :'operations_membership_id'::uuid, 'copilot-scope-manager'
  ),
  (
    'aaaaaaaa-0000-0000-0000-0000000000c3', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'copilot_scope', 'Copilot operations task', 'open', :'operations_membership_id'::uuid,
    :'operations_membership_id'::uuid, 'copilot-scope-operations'
  );

UPDATE public.organization_memberships
SET role = 'operations'
WHERE id = :'operations_membership_id'::uuid;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT public.create_ai_run_request(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'copilot', 'ملخص للتشغيل', 'ai-copilot-operations', NULL
) AS operations_run_id \gset
RESET ROLE;

SELECT id AS operations_event_id
FROM public.claim_outbox_delivery_events('ai-copilot-operations-worker', 20, 300)
WHERE event_type = 'ai.run.requested'
  AND payload ->> 'run_id' = :'operations_run_id'
LIMIT 1 \gset
SELECT set_config('voya.test.ai_operations_event_id', :'operations_event_id', false);

DO $$
DECLARE
  v_context jsonb;
BEGIN
  SELECT context INTO v_context
  FROM public.resolve_ai_copilot_execution(current_setting('voya.test.ai_operations_event_id')::uuid, 'ai-copilot-operations-worker');
  IF (v_context -> 'tasks' ->> 'open')::integer <> current_setting('voya.test.operations_open_baseline')::integer + 2 THEN
    RAISE EXCEPTION 'operations copilot must only include unassigned and self-assigned open tasks';
  END IF;
END;
$$;

SELECT public.record_ai_copilot_context_read(
  current_setting('voya.test.ai_operations_event_id')::uuid, 'ai-copilot-operations-worker',
  '{"scope":"organization","fields":["properties","leads","bookings","tasks"]}'::jsonb
);
SELECT public.complete_outbox_event(current_setting('voya.test.ai_operations_event_id')::uuid, 'ai-copilot-operations-worker');

UPDATE public.organization_memberships
SET role = 'owner'
WHERE id = :'operations_membership_id'::uuid;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT public.create_ai_run_request(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'copilot', 'اختبار حالة التشغيل النهائية', 'ai-copilot-terminal', NULL
) AS terminal_run_id \gset
RESET ROLE;

SELECT id AS terminal_event_id
FROM public.claim_outbox_delivery_events('ai-copilot-terminal-worker', 20, 300)
WHERE event_type = 'ai.run.requested'
  AND payload ->> 'run_id' = :'terminal_run_id'
LIMIT 1 \gset
SELECT set_config('voya.test.ai_terminal_event_id', :'terminal_event_id', false);

UPDATE public.ai_runs
SET status = 'succeeded', finished_at = timezone('utc', now())
WHERE id = :'terminal_run_id'::uuid;

DO $$
BEGIN
  BEGIN
    PERFORM public.record_ai_copilot_context_read(
      current_setting('voya.test.ai_terminal_event_id')::uuid, 'ai-copilot-terminal-worker', '{"scope":"organization"}'::jsonb
    );
    RAISE EXCEPTION 'terminal AI runs must not receive a copilot context audit record';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END;
$$;

SELECT public.mark_outbox_event_needs_review(current_setting('voya.test.ai_terminal_event_id')::uuid, 'ai-copilot-terminal-worker', 'ai_copilot_context_audit_failed');

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
