-- Voya OS: governed AI run/tool telemetry and proposal request queue.
-- This migration does not call a model or execute a domain mutation.

CREATE TABLE public.ai_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  agent_kind text NOT NULL CHECK (agent_kind IN ('sales', 'booking', 'finance', 'manager')),
  agent_version text NOT NULL CHECK (agent_version ~ '^[a-zA-Z0-9._-]{1,80}$'),
  status text NOT NULL CHECK (status IN ('queued', 'running', 'succeeded', 'failed', 'cancelled', 'stopped')),
  purpose text NOT NULL CHECK (char_length(btrim(purpose)) BETWEEN 1 AND 280),
  model_name text NOT NULL CHECK (char_length(btrim(model_name)) BETWEEN 1 AND 120),
  prompt_version text NOT NULL CHECK (char_length(btrim(prompt_version)) BETWEEN 1 AND 120),
  initiated_by_membership_id uuid NOT NULL,
  idempotency_key text NOT NULL CHECK (char_length(btrim(idempotency_key)) BETWEEN 1 AND 160),
  started_at timestamptz,
  finished_at timestamptz,
  error_code text,
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  CONSTRAINT ai_run_initiator_in_organization_fk
    FOREIGN KEY (organization_id, initiated_by_membership_id)
    REFERENCES public.organization_memberships(organization_id, id) ON DELETE RESTRICT,
  CONSTRAINT ai_run_organization_id_unique UNIQUE (organization_id, id),
  CONSTRAINT ai_run_idempotency_unique UNIQUE (organization_id, idempotency_key),
  CONSTRAINT ai_run_finished_state_check CHECK ((finished_at IS NULL) OR status IN ('succeeded', 'failed', 'cancelled', 'stopped'))
);

CREATE INDEX ai_runs_queue_idx ON public.ai_runs (organization_id, status, created_at DESC);
CREATE INDEX ai_runs_initiator_idx ON public.ai_runs (organization_id, initiated_by_membership_id, created_at DESC);
CREATE TRIGGER ai_runs_set_updated_at
  BEFORE UPDATE ON public.ai_runs
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TABLE public.ai_tool_calls (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  run_id uuid NOT NULL,
  tool_name text NOT NULL CHECK (tool_name ~ '^[a-z][a-z0-9_]{1,120}$'),
  tool_version text NOT NULL CHECK (tool_version ~ '^[a-zA-Z0-9._-]{1,80}$'),
  effect text NOT NULL CHECK (effect IN ('read', 'proposal')),
  policy_decision text NOT NULL CHECK (policy_decision IN ('allowed', 'denied')),
  status text NOT NULL CHECK (status IN ('requested', 'succeeded', 'failed', 'denied')),
  request_summary jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(request_summary) = 'object'),
  response_summary jsonb CHECK (response_summary IS NULL OR jsonb_typeof(response_summary) = 'object'),
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  CONSTRAINT ai_tool_call_run_in_organization_fk
    FOREIGN KEY (organization_id, run_id)
    REFERENCES public.ai_runs(organization_id, id) ON DELETE RESTRICT
);

CREATE INDEX ai_tool_calls_run_idx ON public.ai_tool_calls (organization_id, run_id, created_at ASC);

ALTER TABLE public.ai_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ai_tool_calls ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ai_runs FORCE ROW LEVEL SECURITY;
ALTER TABLE public.ai_tool_calls FORCE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.ai_runs, public.ai_tool_calls FROM PUBLIC;

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
  IF p_agent_kind IS NULL OR p_agent_kind NOT IN ('sales', 'booking', 'finance', 'manager')
    OR p_purpose IS NULL OR char_length(btrim(p_purpose)) NOT BETWEEN 1 AND 280
    OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160 THEN
    RAISE EXCEPTION 'AI run request is invalid' USING ERRCODE = '22023';
  END IF;
  v_agent_allowed := CASE
    WHEN p_agent_kind = 'sales' THEN v_role IN ('owner', 'manager', 'sales_agent')
    WHEN p_agent_kind = 'booking' THEN v_role IN ('owner', 'manager', 'sales_agent', 'operations')
    WHEN p_agent_kind = 'manager' THEN v_role IN ('owner', 'manager')
    ELSE false
  END;
  IF NOT v_agent_allowed THEN RAISE EXCEPTION 'AI agent is disabled or not permitted' USING ERRCODE = '42501'; END IF;

  SELECT * INTO v_existing
  FROM public.ai_runs
  WHERE organization_id = p_organization_id AND idempotency_key = btrim(p_idempotency_key);
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

CREATE OR REPLACE FUNCTION public.list_ai_runs(
  p_organization_id uuid,
  p_limit integer DEFAULT 30
)
RETURNS TABLE (
  id uuid,
  agent_kind text,
  agent_version text,
  status text,
  purpose text,
  model_name text,
  prompt_version text,
  initiated_by_membership_id uuid,
  created_at timestamptz,
  started_at timestamptz,
  finished_at timestamptz,
  error_code text,
  tool_call_count bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE v_role text; v_actor uuid;
BEGIN
  SELECT membership.role, membership.id INTO v_role, v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active';
  IF v_role IS NULL OR v_role NOT IN ('owner', 'manager', 'sales_agent', 'operations', 'accountant') THEN
    RAISE EXCEPTION 'AI run read is not permitted' USING ERRCODE = '42501';
  END IF;
  IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'AI run limit is invalid' USING ERRCODE = '22023'; END IF;
  RETURN QUERY
  SELECT run.id, run.agent_kind, run.agent_version, run.status, run.purpose,
         run.model_name, run.prompt_version, run.initiated_by_membership_id,
         run.created_at, run.started_at, run.finished_at, run.error_code,
         count(tool.id)::bigint
  FROM public.ai_runs AS run
  LEFT JOIN public.ai_tool_calls AS tool
    ON tool.organization_id = run.organization_id AND tool.run_id = run.id
  WHERE run.organization_id = p_organization_id
    AND (v_role IN ('owner', 'manager') OR run.initiated_by_membership_id = v_actor)
  GROUP BY run.id
  ORDER BY run.created_at DESC, run.id DESC
  LIMIT p_limit;
END;
$$;

CREATE OR REPLACE FUNCTION public.list_ai_tool_calls(
  p_organization_id uuid,
  p_run_id uuid
)
RETURNS TABLE (
  id uuid,
  tool_name text,
  tool_version text,
  effect text,
  policy_decision text,
  status text,
  request_summary jsonb,
  response_summary jsonb,
  created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE v_role text; v_actor uuid;
BEGIN
  SELECT membership.role, membership.id INTO v_role, v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active';
  IF v_role IS NULL OR v_role NOT IN ('owner', 'manager', 'sales_agent', 'operations', 'accountant') THEN
    RAISE EXCEPTION 'AI tool read is not permitted' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.ai_runs AS run
    WHERE run.organization_id = p_organization_id AND run.id = p_run_id
      AND (v_role IN ('owner', 'manager') OR run.initiated_by_membership_id = v_actor)
  ) THEN RAISE EXCEPTION 'AI run is not permitted' USING ERRCODE = '42501'; END IF;
  RETURN QUERY
  SELECT tool.id, tool.tool_name, tool.tool_version, tool.effect, tool.policy_decision,
         tool.status, tool.request_summary, tool.response_summary, tool.created_at
  FROM public.ai_tool_calls AS tool
  WHERE tool.organization_id = p_organization_id AND tool.run_id = p_run_id
  ORDER BY tool.created_at ASC, tool.id ASC;
END;
$$;

REVOKE ALL ON FUNCTION public.create_ai_run_request(uuid, text, text, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_ai_runs(uuid, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_ai_tool_calls(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  public.create_ai_run_request(uuid, text, text, text, uuid),
  public.list_ai_runs(uuid, integer),
  public.list_ai_tool_calls(uuid, uuid)
TO authenticated;
