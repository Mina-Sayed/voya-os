-- Voya OS V1: operational health facts and overdue-task notifications.
-- Worker state is private; operators receive only a redacted aggregate through
-- get_system_health_v1().

CREATE TABLE public.outbox_worker_runs (
  id uuid PRIMARY KEY DEFAULT extensions.gen_random_uuid(),
  worker_id text NOT NULL CHECK (char_length(btrim(worker_id)) BETWEEN 1 AND 120),
  status text NOT NULL DEFAULT 'running' CHECK (status IN ('running', 'completed', 'failed')),
  started_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  finished_at timestamptz,
  claimed_count integer NOT NULL DEFAULT 0 CHECK (claimed_count >= 0),
  completed_count integer NOT NULL DEFAULT 0 CHECK (completed_count >= 0),
  retried_count integer NOT NULL DEFAULT 0 CHECK (retried_count >= 0),
  failed_count integer NOT NULL DEFAULT 0 CHECK (failed_count >= 0),
  needs_review_count integer NOT NULL DEFAULT 0 CHECK (needs_review_count >= 0),
  error_code text CHECK (error_code IS NULL OR error_code ~ '^[a-z][a-z0-9_.-]{0,119}$')
);

CREATE INDEX outbox_worker_runs_started_idx
  ON public.outbox_worker_runs (started_at DESC);

ALTER TABLE public.outbox_worker_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.outbox_worker_runs FORCE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.outbox_worker_runs FROM PUBLIC, anon, authenticated, voya_outbox_worker, service_role;

CREATE OR REPLACE FUNCTION public.start_outbox_worker_run(
  p_worker_id text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_id uuid;
BEGIN
  IF p_worker_id IS NULL OR char_length(btrim(p_worker_id)) NOT BETWEEN 1 AND 120 THEN
    RAISE EXCEPTION 'worker id is invalid' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.outbox_worker_runs (worker_id)
  VALUES (btrim(p_worker_id))
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.finish_outbox_worker_run(
  p_run_id uuid,
  p_worker_id text,
  p_status text,
  p_claimed_count integer,
  p_completed_count integer,
  p_retried_count integer,
  p_failed_count integer,
  p_needs_review_count integer,
  p_error_code text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_updated integer;
BEGIN
  IF p_run_id IS NULL
    OR p_worker_id IS NULL
    OR char_length(btrim(p_worker_id)) NOT BETWEEN 1 AND 120
    OR p_status NOT IN ('completed', 'failed')
    OR p_claimed_count IS NULL OR p_claimed_count < 0
    OR p_completed_count IS NULL OR p_completed_count < 0
    OR p_retried_count IS NULL OR p_retried_count < 0
    OR p_failed_count IS NULL OR p_failed_count < 0
    OR p_needs_review_count IS NULL OR p_needs_review_count < 0
    OR (p_error_code IS NOT NULL AND p_error_code !~ '^[a-z][a-z0-9_.-]{0,119}$') THEN
    RAISE EXCEPTION 'worker run result is invalid' USING ERRCODE = '22023';
  END IF;

  UPDATE public.outbox_worker_runs
  SET status = p_status,
      finished_at = timezone('utc', now()),
      claimed_count = p_claimed_count,
      completed_count = p_completed_count,
      retried_count = p_retried_count,
      failed_count = p_failed_count,
      needs_review_count = p_needs_review_count,
      error_code = p_error_code
  WHERE id = p_run_id
    AND worker_id = btrim(p_worker_id)
    AND status = 'running';
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RETURN v_updated = 1;
END;
$$;

CREATE OR REPLACE FUNCTION public.emit_overdue_task_notifications(
  p_worker_id text,
  p_now timestamptz DEFAULT NULL,
  p_limit integer DEFAULT 100
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_inserted integer;
BEGIN
  IF p_worker_id IS NULL OR char_length(btrim(p_worker_id)) NOT BETWEEN 1 AND 120
    OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 1000 THEN
    RAISE EXCEPTION 'overdue task worker input is invalid' USING ERRCODE = '22023';
  END IF;

  WITH overdue AS (
    SELECT task.id, task.organization_id, task.assigned_membership_id, task.title
    FROM public.operations_tasks AS task
    WHERE task.status IN ('open', 'in_progress')
      AND task.due_at IS NOT NULL
      AND task.due_at <= coalesce(p_now, timezone('utc', now()))
      AND task.assigned_membership_id IS NOT NULL
    ORDER BY task.due_at ASC, task.id ASC
    LIMIT p_limit
    FOR UPDATE SKIP LOCKED
  ), inserted AS (
    INSERT INTO public.notifications (
      organization_id, recipient_membership_id, category, title, body,
      resource_type, resource_id, dedupe_key
    )
    SELECT overdue.organization_id,
      overdue.assigned_membership_id,
      'operational',
      'مهمة متأخرة',
      'المهمة "' || btrim(overdue.title) || '" تجاوزت موعدها وتحتاج إلى متابعة.',
      'operations_task',
      overdue.id,
      'operations-task-overdue:' || overdue.id::text
    FROM overdue
    ON CONFLICT (organization_id, dedupe_key) DO NOTHING
    RETURNING organization_id, resource_id
  )
  INSERT INTO public.audit_events (
    organization_id, actor_type, action, resource_type, resource_id, outcome, after_delta
  )
  SELECT inserted.organization_id,
    'system',
    'operations.task.overdue',
    'operations_task',
    inserted.resource_id,
    'success',
    jsonb_build_object('worker_id', btrim(p_worker_id))
  FROM inserted;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;
  RETURN v_inserted;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_system_health_v1(
  p_organization_id uuid
)
RETURNS TABLE (
  database_status text,
  last_worker_run_at timestamptz,
  last_worker_status text,
  pending_outbox_count bigint,
  oldest_due_event_at timestamptz,
  dead_letter_count bigint,
  email_failure_count bigint,
  whatsapp_failure_count bigint,
  ai_failure_count bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_role text;
BEGIN
  SELECT membership.role INTO v_role
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active';
  IF v_role IS NULL OR v_role NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'system health read is not permitted' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    'ok'::text,
    coalesce(worker.finished_at, worker.started_at),
    worker.status,
    (
      SELECT count(*)
      FROM public.outbox_events AS event
      WHERE event.organization_id = p_organization_id
        AND event.state IN ('pending', 'retry_wait', 'processing')
    ),
    (
      SELECT min(event.available_at)
      FROM public.outbox_events AS event
      WHERE event.organization_id = p_organization_id
        AND event.state IN ('pending', 'retry_wait')
        AND event.available_at <= timezone('utc', now())
    ),
    (
      SELECT count(*)
      FROM public.outbox_events AS event
      WHERE event.organization_id = p_organization_id
        AND event.state = 'dead_letter'
    ),
    (
      SELECT count(*)
      FROM public.outbox_events AS event
      WHERE event.organization_id = p_organization_id
        AND event.event_type IN ('organization.invitation.send_requested', 'member.invitation.resent')
        AND event.state IN ('dead_letter', 'needs_review')
    ),
    (
      SELECT count(*)
      FROM public.outbox_events AS event
      WHERE event.organization_id = p_organization_id
        AND event.event_type = 'whatsapp.message.send_requested'
        AND event.state IN ('dead_letter', 'needs_review')
    ),
    (
      SELECT count(*)
      FROM public.ai_runs AS run
      WHERE run.organization_id = p_organization_id
        AND (
          run.status = 'failed'
          OR EXISTS (
            SELECT 1
            FROM public.outbox_events AS event
            WHERE event.organization_id = p_organization_id
              AND event.event_type = 'ai.run.requested'
              AND event.state IN ('dead_letter', 'needs_review')
              AND event.payload ->> 'run_id' = run.id::text
          )
        )
    )
  FROM (
    SELECT run.started_at, run.finished_at, run.status
    FROM public.outbox_worker_runs AS run
    ORDER BY run.started_at DESC, run.id DESC
    LIMIT 1
  ) AS worker;

  IF NOT FOUND THEN
    RETURN QUERY SELECT
      'ok'::text, NULL::timestamptz, NULL::text,
      (SELECT count(*) FROM public.outbox_events AS event WHERE event.organization_id = p_organization_id AND event.state IN ('pending', 'retry_wait', 'processing')),
      (SELECT min(event.available_at) FROM public.outbox_events AS event WHERE event.organization_id = p_organization_id AND event.state IN ('pending', 'retry_wait') AND event.available_at <= timezone('utc', now())),
      (SELECT count(*) FROM public.outbox_events AS event WHERE event.organization_id = p_organization_id AND event.state = 'dead_letter'),
      (SELECT count(*) FROM public.outbox_events AS event WHERE event.organization_id = p_organization_id AND event.event_type IN ('organization.invitation.send_requested', 'member.invitation.resent') AND event.state IN ('dead_letter', 'needs_review')),
      (SELECT count(*) FROM public.outbox_events AS event WHERE event.organization_id = p_organization_id AND event.event_type = 'whatsapp.message.send_requested' AND event.state IN ('dead_letter', 'needs_review')),
      (SELECT count(*) FROM public.ai_runs AS run WHERE run.organization_id = p_organization_id AND run.status = 'failed');
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.start_outbox_worker_run(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.finish_outbox_worker_run(uuid, text, text, integer, integer, integer, integer, integer, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.emit_overdue_task_notifications(text, timestamptz, integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.get_system_health_v1(uuid) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.start_outbox_worker_run(text) TO voya_outbox_worker, service_role;
GRANT EXECUTE ON FUNCTION public.finish_outbox_worker_run(uuid, text, text, integer, integer, integer, integer, integer, text) TO voya_outbox_worker, service_role;
GRANT EXECUTE ON FUNCTION public.emit_overdue_task_notifications(text, timestamptz, integer) TO voya_outbox_worker, service_role;
GRANT EXECUTE ON FUNCTION public.get_system_health_v1(uuid) TO authenticated;

COMMENT ON TABLE public.outbox_worker_runs IS
  'Private worker heartbeat and aggregate run facts for the operator health page.';
COMMENT ON FUNCTION public.emit_overdue_task_notifications(text, timestamptz, integer) IS
  'Emits one tenant-scoped in-app notification per overdue assigned task; safe to rerun.';
