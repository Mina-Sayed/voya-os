-- Voya OS: tenant-scoped, read-only AI Copilot context.
-- The worker receives aggregate operational facts only; no domain mutation is exposed.

ALTER TABLE public.ai_runs DROP CONSTRAINT IF EXISTS ai_runs_agent_kind_check;
ALTER TABLE public.ai_runs
  ADD CONSTRAINT ai_runs_agent_kind_check
  CHECK (agent_kind IN ('sales', 'booking', 'finance', 'manager', 'copilot'));

CREATE OR REPLACE FUNCTION public.create_ai_run_request(
  p_organization_id uuid,
  p_agent_kind text,
  p_purpose text,
  p_idempotency_key text,
  p_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_actor uuid;
  v_role text;
  v_existing public.ai_runs%ROWTYPE;
  v_id uuid;
  v_agent_allowed boolean := false;
BEGIN
  SELECT membership.id, membership.role INTO v_actor, v_role
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active';
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AI run request is not permitted' USING ERRCODE = '42501'; END IF;
  IF p_agent_kind IS NULL OR p_agent_kind NOT IN ('sales', 'booking', 'finance', 'manager', 'copilot')
    OR p_purpose IS NULL OR char_length(btrim(p_purpose)) NOT BETWEEN 1 AND 280
    OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160 THEN
    RAISE EXCEPTION 'AI run request is invalid' USING ERRCODE = '22023';
  END IF;
  v_agent_allowed := CASE
    WHEN p_agent_kind = 'sales' THEN v_role IN ('owner', 'manager', 'sales_agent')
    WHEN p_agent_kind = 'booking' THEN v_role IN ('owner', 'manager', 'sales_agent', 'operations')
    WHEN p_agent_kind = 'manager' THEN v_role IN ('owner', 'manager')
    WHEN p_agent_kind = 'copilot' THEN v_role IN ('owner', 'manager', 'sales_agent', 'operations')
    ELSE false
  END;
  IF NOT v_agent_allowed THEN RAISE EXCEPTION 'AI agent is disabled or not permitted' USING ERRCODE = '42501'; END IF;

  SELECT * INTO v_existing
  FROM public.ai_runs AS run
  WHERE run.organization_id = p_organization_id AND run.idempotency_key = btrim(p_idempotency_key);
  IF FOUND THEN
    IF v_existing.agent_kind = p_agent_kind AND v_existing.purpose = btrim(p_purpose) THEN RETURN v_existing.id; END IF;
    RAISE EXCEPTION 'AI run idempotency key belongs to a different request' USING ERRCODE = '23505';
  END IF;

  INSERT INTO public.ai_runs (
    organization_id, agent_kind, agent_version, status, purpose,
    model_name, prompt_version, initiated_by_membership_id, idempotency_key
  ) VALUES (
    p_organization_id, p_agent_kind, 'registry-v1', 'queued', btrim(p_purpose),
    'unconfigured', 'unconfigured', v_actor, btrim(p_idempotency_key)
  ) RETURNING id INTO v_id;

  INSERT INTO public.outbox_events (
    organization_id, event_type, schema_version, dedupe_key, payload
  ) VALUES (
    p_organization_id, 'ai.run.requested', 1, 'ai-run:' || v_id::text,
    jsonb_build_object('run_id', v_id, 'agent_kind', p_agent_kind)
  );
  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'ai.run.requested', 'ai_run',
    v_id, 'success', p_request_id, jsonb_build_object('agent_kind', p_agent_kind, 'status', 'queued')
  );
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.resolve_ai_copilot_execution(
  p_event_id uuid,
  p_worker_id text
)
RETURNS TABLE (
  run_id uuid,
  organization_id uuid,
  agent_kind text,
  purpose text,
  initiated_by_membership_id uuid,
  context jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_run_id uuid;
  v_organization_id uuid;
  v_purpose text;
  v_membership_id uuid;
  v_role text;
  v_context jsonb;
BEGIN
  IF p_event_id IS NULL OR p_worker_id IS NULL OR char_length(btrim(p_worker_id)) = 0 THEN
    RAISE EXCEPTION 'worker AI context is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT run.id, run.organization_id, run.purpose, run.initiated_by_membership_id,
         membership.role
  INTO v_run_id, v_organization_id, v_purpose, v_membership_id, v_role
  FROM public.outbox_events AS event
  JOIN public.ai_runs AS run
    ON run.id::text = event.payload ->> 'run_id'
   AND run.organization_id = event.organization_id
  JOIN public.organization_memberships AS membership
    ON membership.organization_id = run.organization_id
    AND membership.id = run.initiated_by_membership_id
    AND membership.status = 'active'
  WHERE event.id = p_event_id
    AND event.event_type = 'ai.run.requested'
    AND event.state = 'processing'
    AND event.locked_by = p_worker_id
    AND event.locked_until > timezone('utc', now())
    AND run.agent_kind = 'copilot'
    AND run.status IN ('queued', 'running');

  IF v_run_id IS NULL OR v_role NOT IN ('owner', 'manager', 'sales_agent', 'operations') THEN
    RAISE EXCEPTION 'AI copilot execution is not permitted' USING ERRCODE = '42501';
  END IF;

  SELECT jsonb_build_object(
    'as_of_date', to_char(timezone('utc', now())::date, 'YYYY-MM-DD'),
    'properties', jsonb_build_object(
      'active', count(*) FILTER (WHERE property.status = 'active'),
      'inactive', count(*) FILTER (WHERE property.status = 'inactive')
    ),
    'leads', (
      SELECT jsonb_build_object(
        'new', count(*) FILTER (WHERE lead.status = 'new'),
        'qualified', count(*) FILTER (WHERE lead.status = 'qualified'),
        'won', count(*) FILTER (WHERE lead.status = 'won'),
        'lost', count(*) FILTER (WHERE lead.status = 'lost')
      )
      FROM public.leads AS lead
      WHERE lead.organization_id = v_organization_id
        AND (v_role IN ('owner', 'manager', 'operations')
          OR lead.assigned_membership_id IS NULL
          OR lead.assigned_membership_id = v_membership_id)
    ),
    'bookings', (
      SELECT jsonb_build_object(
        'draft', count(*) FILTER (WHERE booking.status = 'draft'),
        'pendingApproval', count(*) FILTER (WHERE booking.status = 'pending_approval'),
        'confirmed', count(*) FILTER (WHERE booking.status = 'confirmed'),
        'completed', count(*) FILTER (WHERE booking.status = 'completed'),
        'cancelled', count(*) FILTER (WHERE booking.status = 'cancelled'),
        'next30Days', count(*) FILTER (
          WHERE booking.status = 'confirmed'
            AND booking.check_in >= timezone('utc', now())::date
            AND booking.check_in < timezone('utc', now())::date + 30
        )
      )
      FROM public.bookings AS booking
      WHERE booking.organization_id = v_organization_id
    ),
    'tasks', (
      SELECT jsonb_build_object(
        'open', count(*) FILTER (WHERE task.status = 'open'),
        'inProgress', count(*) FILTER (WHERE task.status = 'in_progress'),
        'completed', count(*) FILTER (WHERE task.status = 'completed'),
        'cancelled', count(*) FILTER (WHERE task.status = 'cancelled'),
        'overdue', count(*) FILTER (
          WHERE task.status IN ('open', 'in_progress')
            AND task.due_at IS NOT NULL
            AND task.due_at < timezone('utc', now())
        )
      )
      FROM public.operations_tasks AS task
      WHERE task.organization_id = v_organization_id
        AND (v_role IN ('owner', 'manager', 'operations')
          OR task.assigned_membership_id IS NULL
          OR task.assigned_membership_id = v_membership_id)
    )
  ) INTO v_context
  FROM public.properties AS property
  WHERE property.organization_id = v_organization_id;

  RETURN QUERY SELECT v_run_id, v_organization_id, 'copilot', v_purpose, v_membership_id, v_context;
END;
$$;

CREATE OR REPLACE FUNCTION public.record_ai_copilot_context_read(
  p_event_id uuid,
  p_worker_id text,
  p_context_summary jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_run_id uuid;
  v_organization_id uuid;
  v_tool_id uuid;
BEGIN
  IF p_event_id IS NULL OR p_worker_id IS NULL OR char_length(btrim(p_worker_id)) = 0
    OR p_context_summary IS NULL OR jsonb_typeof(p_context_summary) <> 'object'
    OR char_length(p_context_summary::text) > 4000 THEN
    RAISE EXCEPTION 'AI copilot context audit is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT run.id, run.organization_id INTO v_run_id, v_organization_id
  FROM public.outbox_events AS event
  JOIN public.ai_runs AS run
    ON run.id::text = event.payload ->> 'run_id'
   AND run.organization_id = event.organization_id
  JOIN public.organization_memberships AS membership
    ON membership.organization_id = run.organization_id
   AND membership.id = run.initiated_by_membership_id
   AND membership.status = 'active'
  WHERE event.id = p_event_id
    AND event.event_type = 'ai.run.requested'
    AND event.state = 'processing'
    AND event.locked_by = p_worker_id
    AND event.locked_until > timezone('utc', now())
    AND run.agent_kind = 'copilot';

  IF v_run_id IS NULL THEN
    RAISE EXCEPTION 'AI copilot context audit is not permitted' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.ai_tool_calls (
    organization_id, run_id, tool_name, tool_version, effect,
    policy_decision, status, request_summary, response_summary
  ) VALUES (
    v_organization_id, v_run_id, 'read_copilot_context_v1', 'copilot-v1', 'read',
    'allowed', 'succeeded', '{"scope":"organization"}'::jsonb, p_context_summary
  ) RETURNING id INTO v_tool_id;
  RETURN v_tool_id;
END;
$$;

REVOKE ALL ON FUNCTION public.resolve_ai_copilot_execution(uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.record_ai_copilot_context_read(uuid, text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_ai_copilot_execution(uuid, text), public.record_ai_copilot_context_read(uuid, text, jsonb) TO voya_outbox_worker, service_role;
