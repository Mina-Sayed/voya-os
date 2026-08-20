-- Voya OS V1 completion: controlled AI execution, task assignment notice, and
-- deployment-safe release metadata live in the checkout. Provider and managed
-- environment enablement remain separate rollout gates.

ALTER TABLE public.ai_runs
  ADD COLUMN IF NOT EXISTS result_summary jsonb;

ALTER TABLE public.ai_runs
  DROP CONSTRAINT IF EXISTS ai_run_result_summary_object;

ALTER TABLE public.ai_runs
  ADD CONSTRAINT ai_run_result_summary_object
  CHECK (result_summary IS NULL OR jsonb_typeof(result_summary) = 'object');

CREATE OR REPLACE FUNCTION public.claim_outbox_delivery_events(
  p_worker_id text,
  p_limit integer,
  p_lease_seconds integer
)
RETURNS SETOF public.outbox_events
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  IF p_worker_id IS NULL OR char_length(btrim(p_worker_id)) = 0 OR char_length(p_worker_id) > 120 THEN
    RAISE EXCEPTION 'worker id is invalid' USING ERRCODE = '22023';
  END IF;
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 20 THEN
    RAISE EXCEPTION 'delivery batch must be between 1 and 20' USING ERRCODE = '22023';
  END IF;
  IF p_lease_seconds IS NULL OR p_lease_seconds < 1 OR p_lease_seconds > 900 THEN
    RAISE EXCEPTION 'lease duration must be between 1 and 900 seconds' USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  WITH eligible AS (
    SELECT event.id
    FROM public.outbox_events AS event
    WHERE event.event_type IN (
      'organization.invitation.send_requested',
      'member.invitation.resent',
      'whatsapp.message.send_requested',
      'ai.run.requested'
    )
      AND (
        (event.state IN ('pending', 'retry_wait') AND event.available_at <= timezone('utc', now()))
        OR (event.state = 'processing' AND event.locked_until <= timezone('utc', now()))
      )
    ORDER BY
      CASE WHEN event.state = 'processing' THEN event.locked_until ELSE event.available_at END ASC,
      event.created_at ASC
    LIMIT p_limit
    FOR UPDATE SKIP LOCKED
  )
  UPDATE public.outbox_events AS event
  SET state = 'processing',
      attempts = event.attempts + 1,
      locked_by = p_worker_id,
      locked_until = timezone('utc', now()) + make_interval(secs => p_lease_seconds),
      last_error_code = NULL
  FROM eligible
  WHERE event.id = eligible.id
  RETURNING event.*;
END;
$$;

CREATE OR REPLACE FUNCTION public.resolve_ai_run_execution(
  p_event_id uuid,
  p_worker_id text
)
RETURNS TABLE (
  run_id uuid,
  organization_id uuid,
  agent_kind text,
  purpose text,
  initiated_by_membership_id uuid
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  IF p_event_id IS NULL OR p_worker_id IS NULL OR char_length(btrim(p_worker_id)) = 0 THEN
    RAISE EXCEPTION 'worker AI context is invalid' USING ERRCODE = '22023';
  END IF;
  RETURN QUERY
  SELECT run.id, run.organization_id, run.agent_kind, run.purpose, run.initiated_by_membership_id
  FROM public.outbox_events AS event
  JOIN public.ai_runs AS run
    ON run.id::text = event.payload ->> 'run_id'
   AND run.organization_id = event.organization_id
  WHERE event.id = p_event_id
    AND event.event_type = 'ai.run.requested'
    AND event.state = 'processing'
    AND event.locked_by = p_worker_id
    AND event.locked_until > timezone('utc', now())
    AND run.status IN ('queued', 'running');
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_ai_run_started(
  p_event_id uuid,
  p_worker_id text,
  p_model_name text,
  p_prompt_version text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE v_run_id uuid;
BEGIN
  IF p_model_name IS NULL OR char_length(btrim(p_model_name)) NOT BETWEEN 1 AND 120
    OR p_prompt_version IS NULL OR char_length(btrim(p_prompt_version)) NOT BETWEEN 1 AND 120 THEN
    RAISE EXCEPTION 'AI execution metadata is invalid' USING ERRCODE = '22023';
  END IF;
  UPDATE public.ai_runs AS run
  SET status = 'running',
      model_name = btrim(p_model_name),
      prompt_version = btrim(p_prompt_version),
      started_at = coalesce(run.started_at, timezone('utc', now())),
      finished_at = NULL,
      error_code = NULL
  FROM public.outbox_events AS event
  WHERE event.id = p_event_id
    AND event.event_type = 'ai.run.requested'
    AND event.state = 'processing'
    AND event.locked_by = p_worker_id
    AND event.locked_until > timezone('utc', now())
    AND run.id::text = event.payload ->> 'run_id'
    AND run.organization_id = event.organization_id
    AND run.status IN ('queued', 'running')
  RETURNING run.id INTO v_run_id;
  RETURN v_run_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_ai_run_succeeded(
  p_event_id uuid,
  p_worker_id text,
  p_result_summary jsonb
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_run_id uuid;
  v_organization_id uuid;
  v_membership_id uuid;
  v_updated_count integer;
BEGIN
  IF p_result_summary IS NULL OR jsonb_typeof(p_result_summary) <> 'object'
    OR char_length(p_result_summary::text) > 20000 THEN
    RAISE EXCEPTION 'AI result summary is invalid' USING ERRCODE = '22023';
  END IF;
  UPDATE public.ai_runs AS run
  SET status = 'succeeded',
      result_summary = p_result_summary,
      finished_at = timezone('utc', now()),
      error_code = NULL
  FROM public.outbox_events AS event
  WHERE event.id = p_event_id
    AND event.event_type = 'ai.run.requested'
    AND event.state = 'processing'
    AND event.locked_by = p_worker_id
    AND event.locked_until > timezone('utc', now())
    AND run.id::text = event.payload ->> 'run_id'
    AND run.organization_id = event.organization_id
    AND run.status IN ('queued', 'running')
  RETURNING run.id, run.organization_id, run.initiated_by_membership_id
  INTO v_run_id, v_organization_id, v_membership_id;
  GET DIAGNOSTICS v_updated_count = ROW_COUNT;
  IF v_updated_count = 1 THEN
    INSERT INTO public.notifications (
      organization_id, recipient_membership_id, category, title, body,
      resource_type, resource_id, dedupe_key
    ) VALUES (
      v_organization_id, v_membership_id, 'system', 'اقتراح AI جاهز',
      'اكتمل طلب الاقتراح ويمكن مراجعته من مركز الذكاء.',
      'ai_run', v_run_id, 'ai-run-succeeded:' || v_run_id::text
    ) ON CONFLICT (organization_id, dedupe_key) DO NOTHING;
  END IF;
  RETURN v_updated_count = 1;
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_ai_run_failed(
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
  v_run_id uuid;
  v_organization_id uuid;
  v_membership_id uuid;
  v_updated_count integer;
BEGIN
  IF p_error_code IS NULL OR p_error_code !~ '^[a-z][a-z0-9_.-]{0,119}$' THEN
    RAISE EXCEPTION 'AI error code is invalid' USING ERRCODE = '22023';
  END IF;
  UPDATE public.ai_runs AS run
  SET status = 'failed',
      finished_at = timezone('utc', now()),
      error_code = p_error_code
  FROM public.outbox_events AS event
  WHERE event.id = p_event_id
    AND event.event_type = 'ai.run.requested'
    AND event.state = 'processing'
    AND event.locked_by = p_worker_id
    AND event.locked_until > timezone('utc', now())
    AND run.id::text = event.payload ->> 'run_id'
    AND run.organization_id = event.organization_id
    AND run.status IN ('queued', 'running');
  GET DIAGNOSTICS v_updated_count = ROW_COUNT;
  IF v_updated_count = 1 THEN
    SELECT run.id, run.organization_id, run.initiated_by_membership_id
    INTO v_run_id, v_organization_id, v_membership_id
    FROM public.ai_runs AS run
    JOIN public.outbox_events AS event
      ON event.id = p_event_id AND event.organization_id = run.organization_id
    WHERE run.id::text = event.payload ->> 'run_id';
    INSERT INTO public.notifications (
      organization_id, recipient_membership_id, category, title, body,
      resource_type, resource_id, dedupe_key
    ) VALUES (
      v_organization_id, v_membership_id, 'system', 'تعذر إكمال اقتراح AI',
      'تعذر تشغيل طلب الاقتراح. راجع الإعدادات أو أعد الطلب يدوياً.',
      'ai_run', v_run_id, 'ai-run-failed:' || v_run_id::text || ':' || p_error_code
    ) ON CONFLICT (organization_id, dedupe_key) DO NOTHING;
  END IF;
  RETURN v_updated_count = 1;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_ai_run_result_v1(
  p_organization_id uuid,
  p_run_id uuid
)
RETURNS TABLE (status text, result_summary jsonb)
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
    RAISE EXCEPTION 'AI result read is not permitted' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT run.status, run.result_summary
  FROM public.ai_runs AS run
  WHERE run.organization_id = p_organization_id
    AND run.id = p_run_id
    AND (v_role IN ('owner', 'manager') OR run.initiated_by_membership_id = v_actor);
END;
$$;

CREATE OR REPLACE FUNCTION public.notify_operations_task_assignee()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  IF NEW.assigned_membership_id IS NOT NULL THEN
    INSERT INTO public.notifications (
      organization_id, recipient_membership_id, category, title, body,
      resource_type, resource_id, dedupe_key
    ) VALUES (
      NEW.organization_id, NEW.assigned_membership_id, 'operational', 'مهمة تشغيل جديدة',
      'تم إسناد مهمة تشغيلية جديدة إليك للمراجعة والتنفيذ.',
      'operations_task', NEW.id, 'operations-task-assigned:' || NEW.id::text
    ) ON CONFLICT (organization_id, dedupe_key) DO NOTHING;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS operations_tasks_notify_assignee ON public.operations_tasks;
CREATE TRIGGER operations_tasks_notify_assignee
  AFTER INSERT ON public.operations_tasks
  FOR EACH ROW EXECUTE FUNCTION public.notify_operations_task_assignee();

REVOKE ALL ON FUNCTION public.resolve_ai_run_execution(uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.mark_ai_run_started(uuid, text, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.mark_ai_run_succeeded(uuid, text, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.mark_ai_run_failed(uuid, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.get_ai_run_result_v1(uuid, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.notify_operations_task_assignee() FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.resolve_ai_run_execution(uuid, text) TO voya_outbox_worker, service_role;
GRANT EXECUTE ON FUNCTION public.mark_ai_run_started(uuid, text, text, text) TO voya_outbox_worker, service_role;
GRANT EXECUTE ON FUNCTION public.mark_ai_run_succeeded(uuid, text, jsonb) TO voya_outbox_worker, service_role;
GRANT EXECUTE ON FUNCTION public.mark_ai_run_failed(uuid, text, text) TO voya_outbox_worker, service_role;
GRANT EXECUTE ON FUNCTION public.get_ai_run_result_v1(uuid, uuid) TO authenticated;

COMMENT ON COLUMN public.ai_runs.result_summary IS 'Bounded provider output for human review; never a source-of-record mutation.';
