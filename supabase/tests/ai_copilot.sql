-- Read-only Copilot Phase 1: tenant-safe context, role-scoped field families,
-- tool audit, immutable outbox execution, and no mutation authority.

DO $$
BEGIN
  IF to_regprocedure('public.read_ai_copilot_context_v1(uuid)') IS NULL
    OR to_regprocedure('public.resolve_ai_copilot_execution(uuid,text)') IS NULL
    OR to_regprocedure('public.record_ai_copilot_context_read(uuid,text,jsonb)') IS NULL THEN
    RAISE EXCEPTION 'AI Copilot Phase 1 database contract is incomplete';
  END IF;
END;
$$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT public.create_ai_run_request(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'copilot', 'ملخص تشغيلي', 'ai-copilot-1', NULL
) AS ai_run_id \gset
RESET ROLE;

SELECT id AS ai_event_id
FROM public.claim_outbox_delivery_events('ai-copilot-worker', 20, 300)
WHERE event_type = 'ai.run.requested'
  AND payload ->> 'run_id' = :'ai_run_id'
LIMIT 1 \gset
SELECT set_config('voya.test.ai_event_id', :'ai_event_id', false);
SELECT set_config('voya.test.ai_run_id', :'ai_run_id', false);

DO $$
DECLARE
  v_context jsonb;
BEGIN
  SELECT context INTO v_context
  FROM public.resolve_ai_copilot_execution(current_setting('voya.test.ai_event_id')::uuid, 'ai-copilot-worker');
  IF jsonb_typeof(v_context -> 'properties') <> 'object'
    OR jsonb_typeof(v_context -> 'leads') <> 'object'
    OR jsonb_typeof(v_context -> 'bookings') <> 'object'
    OR jsonb_typeof(v_context -> 'tasks') <> 'object' THEN
    RAISE EXCEPTION 'copilot context must expose the governed read families';
  END IF;
  IF NOT ((v_context -> 'bookings') ? 'draft'
    AND (v_context -> 'bookings') ? 'pending_approval'
    AND (v_context -> 'bookings') ? 'confirmed'
    AND (v_context -> 'bookings') ? 'checked_in'
    AND (v_context -> 'bookings') ? 'checked_out'
    AND (v_context -> 'bookings') ? 'completed'
    AND (v_context -> 'bookings') ? 'cancelled') THEN
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

SELECT id AS sales_agent_membership_id
FROM public.organization_memberships
WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  AND user_id = '11111111-1111-1111-1111-111111111111' \gset

SELECT set_config(
  'voya.test.sales_agent_draft_baseline',
  (
    SELECT count(*)::text
    FROM public.bookings
    WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND status = 'draft'
      AND (
        created_by_membership_id IS NULL
        OR created_by_membership_id = :'sales_agent_membership_id'::uuid
      )
  ),
  false
);
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
  AND user_id = '66666666-6666-6666-6666-666666666666' \gset
INSERT INTO public.operations_tasks (
  id, organization_id, title, status, priority, assigned_to_membership_id, created_by_membership_id
) VALUES
  (
    'aaaaaaaa-0000-0000-0000-0000000000c1', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'Copilot operations-only task', 'open', 'medium', :'operations_membership_id'::uuid, :'operations_membership_id'::uuid
  );

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT public.create_ai_run_request(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'copilot', 'ملخص للمالك', 'ai-copilot-owner', NULL
) AS owner_run_id \gset
RESET ROLE;

SELECT id AS owner_event_id
FROM public.claim_outbox_delivery_events('ai-copilot-owner-worker', 20, 300)
WHERE event_type = 'ai.run.requested'
  AND payload ->> 'run_id' = :'owner_run_id'
LIMIT 1 \gset
SELECT set_config('voya.test.ai_owner_event_id', :'owner_event_id', false);

DO $$
DECLARE
  v_context jsonb;
BEGIN
  SELECT context INTO v_context
  FROM public.resolve_ai_copilot_execution(current_setting('voya.test.ai_owner_event_id')::uuid, 'ai-copilot-owner-worker');
  IF (v_context -> 'tasks' ->> 'open')::integer <> current_setting('voya.test.operations_open_baseline')::integer + 1 THEN
    RAISE EXCEPTION 'owner copilot context must include organization-wide open operations tasks';
  END IF;
END;
$$;

SELECT public.record_ai_copilot_context_read(
  current_setting('voya.test.ai_owner_event_id')::uuid, 'ai-copilot-owner-worker',
  '{"scope":"organization","fields":["properties","leads","bookings","tasks"]}'::jsonb
);
SELECT public.complete_outbox_event(current_setting('voya.test.ai_owner_event_id')::uuid, 'ai-copilot-owner-worker');

DO $$
BEGIN
  IF has_function_privilege('authenticated', 'public.resolve_ai_copilot_execution(uuid,text)', 'EXECUTE')
    OR has_function_privilege('anon', 'public.resolve_ai_copilot_execution(uuid,text)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.record_ai_copilot_context_read(uuid,text,jsonb)', 'EXECUTE')
    OR has_function_privilege('anon', 'public.record_ai_copilot_context_read(uuid,text,jsonb)', 'EXECUTE') THEN
    RAISE EXCEPTION 'copilot worker RPCs must remain service-only';
  END IF;
END;
$$;

SELECT 'AI Copilot Phase 1 database integration tests passed' AS result;
