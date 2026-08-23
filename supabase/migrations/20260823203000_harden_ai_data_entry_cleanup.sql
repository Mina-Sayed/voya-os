-- Make AI data-entry private-input cleanup retryable and metadata-consistent.
--
-- Confirmation cleanup archives unused inputs while the trusted execution token
-- is still owned. Worker terminal failure archives active inputs in the same
-- transaction that marks the run and draft failed, before object storage cleanup.

CREATE OR REPLACE FUNCTION public.archive_ai_data_entry_inputs_v1(
  p_organization_id uuid,
  p_draft_id uuid,
  p_input_ids uuid[],
  p_execution_token uuid
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_actor uuid;
  v_found integer;
  v_updated integer;
BEGIN
  IF p_organization_id IS NULL OR p_draft_id IS NULL OR p_input_ids IS NULL
    OR p_execution_token IS NULL OR cardinality(p_input_ids) > 100
    OR cardinality(p_input_ids) <> (
      SELECT count(DISTINCT input_id)::integer
      FROM unnest(p_input_ids) AS requested(input_id)
    ) THEN
    RAISE EXCEPTION 'AI data-entry input archive request is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT draft.confirmed_by_membership_id INTO v_actor
  FROM public.ai_data_entry_drafts AS draft
  WHERE draft.organization_id = p_organization_id
    AND draft.id = p_draft_id
    AND draft.status = 'confirmed'
    AND draft.confirmation_execution_token = p_execution_token
    AND draft.expires_at > timezone('utc', now())
  FOR UPDATE;
  IF NOT FOUND OR v_actor IS NULL THEN
    RAISE EXCEPTION 'AI data-entry input archive claim is stale' USING ERRCODE = '40001';
  END IF;

  IF cardinality(p_input_ids) = 0 THEN
    RETURN true;
  END IF;

  PERFORM 1
  FROM public.ai_data_entry_inputs AS input
  WHERE input.organization_id = p_organization_id
    AND input.draft_id = p_draft_id
    AND input.id = ANY (p_input_ids)
    AND input.status IN ('active', 'archived')
  ORDER BY input.id
  FOR UPDATE;

  SELECT count(*)::integer INTO v_found
  FROM public.ai_data_entry_inputs AS input
  WHERE input.organization_id = p_organization_id
    AND input.draft_id = p_draft_id
    AND input.id = ANY (p_input_ids)
    AND input.status IN ('active', 'archived');
  IF v_found <> cardinality(p_input_ids) THEN
    RAISE EXCEPTION 'AI data-entry input archive set is stale' USING ERRCODE = '40001';
  END IF;

  UPDATE public.ai_data_entry_inputs AS input
  SET status = 'archived'
  WHERE input.organization_id = p_organization_id
    AND input.draft_id = p_draft_id
    AND input.id = ANY (p_input_ids)
    AND input.status = 'active';
  GET DIAGNOSTICS v_updated = ROW_COUNT;

  IF v_updated > 0 THEN
    INSERT INTO public.audit_events (
      organization_id, actor_type, actor_membership_id, action, resource_type,
      resource_id, outcome, after_delta
    ) VALUES (
      p_organization_id, 'user', v_actor, 'ai.data_entry.inputs.archived',
      'ai_data_entry_draft', p_draft_id, 'success',
      jsonb_build_object('input_count', v_updated)
    );
  END IF;

  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.finalize_ai_data_entry_failure_v1(
  p_event_id uuid,
  p_worker_id text,
  p_error_code text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_event public.outbox_events%ROWTYPE;
  v_run public.ai_runs%ROWTYPE;
  v_draft public.ai_data_entry_drafts%ROWTYPE;
BEGIN
  IF p_event_id IS NULL OR p_worker_id IS NULL OR char_length(btrim(p_worker_id)) = 0
    OR p_error_code IS NULL OR p_error_code !~ '^[a-z][a-z0-9_.-]{0,119}$' THEN
    RAISE EXCEPTION 'AI data-entry failure input is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT event.* INTO v_event
  FROM public.outbox_events AS event
  WHERE event.id = p_event_id
    AND event.event_type = 'ai.data_entry.requested'
    AND event.state = 'processing'
    AND event.locked_by = p_worker_id
    AND event.locked_until > timezone('utc', now())
  FOR UPDATE;
  IF NOT FOUND THEN RETURN false; END IF;

  SELECT run.* INTO v_run
  FROM public.ai_runs AS run
  WHERE run.organization_id = v_event.organization_id
    AND run.id::text = v_event.payload ->> 'run_id'
    AND run.agent_kind = 'data_entry'
    AND run.status IN ('queued', 'running', 'failed')
  FOR UPDATE;
  IF NOT FOUND THEN RETURN false; END IF;

  SELECT draft.* INTO v_draft
  FROM public.ai_data_entry_drafts AS draft
  WHERE draft.organization_id = v_event.organization_id
    AND draft.id::text = v_event.payload ->> 'draft_id'
    AND draft.ai_run_id = v_run.id
    AND draft.status IN ('queued', 'extracting', 'failed')
  FOR UPDATE;
  IF NOT FOUND THEN RETURN false; END IF;

  IF v_run.status <> 'failed' THEN
    UPDATE public.ai_runs
    SET status = 'failed',
        finished_at = timezone('utc', now()),
        error_code = p_error_code
    WHERE organization_id = v_run.organization_id AND id = v_run.id;
  END IF;

  IF v_draft.status <> 'failed' THEN
    UPDATE public.ai_data_entry_drafts
    SET status = 'failed',
        error_code = p_error_code,
        version = version + 1
    WHERE organization_id = v_draft.organization_id AND id = v_draft.id;
  END IF;

  -- Once provider execution is terminal, private input metadata must no longer
  -- advertise active/retryable objects. Storage deletion happens afterwards and
  -- is retryable independently if the provider is unavailable.
  UPDATE public.ai_data_entry_inputs AS input
  SET status = 'archived'
  WHERE input.organization_id = v_draft.organization_id
    AND input.draft_id = v_draft.id
    AND input.status = 'active';

  INSERT INTO public.notifications (
    organization_id, recipient_membership_id, category, title, body,
    resource_type, resource_id, dedupe_key
  ) VALUES (
    v_run.organization_id,
    v_run.initiated_by_membership_id,
    'system',
    'تعذر إكمال اقتراح AI',
    'تعذر تشغيل طلب الاقتراح. راجع الإعدادات أو أعد الطلب يدوياً.',
    'ai_run',
    v_run.id,
    'ai-run-failed:' || v_run.id::text || ':' || p_error_code
  ) ON CONFLICT (organization_id, dedupe_key) DO NOTHING;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.archive_ai_data_entry_inputs_v1(uuid,uuid,uuid[],uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.archive_ai_data_entry_inputs_v1(uuid,uuid,uuid[],uuid) TO service_role;

REVOKE ALL ON FUNCTION public.finalize_ai_data_entry_failure_v1(uuid,text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.finalize_ai_data_entry_failure_v1(uuid,text,text) TO voya_outbox_worker, service_role;
