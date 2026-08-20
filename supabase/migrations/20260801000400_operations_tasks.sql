-- Voya OS: tenant-scoped operational task registry.

CREATE TABLE public.operations_tasks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  task_type text NOT NULL CHECK (task_type ~ '^[a-z][a-z0-9_.-]{0,79}$'),
  title text NOT NULL CHECK (char_length(btrim(title)) BETWEEN 1 AND 200),
  description text CHECK (description IS NULL OR char_length(btrim(description)) BETWEEN 1 AND 2000),
  status text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'in_progress', 'completed', 'cancelled')),
  due_at timestamptz,
  booking_id uuid REFERENCES public.bookings(id) ON DELETE RESTRICT,
  assigned_membership_id uuid,
  created_by_membership_id uuid NOT NULL,
  idempotency_key text NOT NULL CHECK (char_length(btrim(idempotency_key)) BETWEEN 1 AND 160),
  created_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  updated_at timestamptz NOT NULL DEFAULT timezone('utc', now()),
  CONSTRAINT operations_task_assignee_in_organization_fk
    FOREIGN KEY (organization_id, assigned_membership_id)
    REFERENCES public.organization_memberships(organization_id, id) ON DELETE RESTRICT,
  CONSTRAINT operations_task_creator_in_organization_fk
    FOREIGN KEY (organization_id, created_by_membership_id)
    REFERENCES public.organization_memberships(organization_id, id) ON DELETE RESTRICT,
  CONSTRAINT operations_task_idempotency_unique UNIQUE (organization_id, idempotency_key)
);

CREATE INDEX operations_tasks_queue_idx ON public.operations_tasks (organization_id, status, due_at NULLS LAST, created_at DESC);

CREATE INDEX operations_tasks_assignee_idx ON public.operations_tasks (organization_id, assigned_membership_id, status, due_at NULLS LAST);

CREATE INDEX operations_tasks_booking_idx ON public.operations_tasks (organization_id, booking_id, created_at DESC);

CREATE TRIGGER operations_tasks_set_updated_at
  BEFORE UPDATE ON public.operations_tasks
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.operations_tasks ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.operations_tasks FORCE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.operations_tasks FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.create_operations_task(
  p_organization_id uuid,
  p_task_type text,
  p_title text,
  p_description text DEFAULT NULL,
  p_due_at timestamptz DEFAULT NULL,
  p_booking_id uuid DEFAULT NULL,
  p_assigned_membership_id uuid DEFAULT NULL,
  p_idempotency_key text DEFAULT NULL,
  p_request_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_actor uuid;
  v_existing public.operations_tasks%ROWTYPE;
  v_id uuid;
BEGIN
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'operations');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'task creation is not permitted' USING ERRCODE = '42501'; END IF;
  IF p_task_type IS NULL OR p_task_type !~ '^[a-z][a-z0-9_.-]{0,79}$'
    OR p_title IS NULL OR char_length(btrim(p_title)) NOT BETWEEN 1 AND 200
    OR (p_description IS NOT NULL AND char_length(btrim(p_description)) NOT BETWEEN 1 AND 2000)
    OR p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 160 THEN
    RAISE EXCEPTION 'task input is invalid' USING ERRCODE = '22023';
  END IF;
  IF p_booking_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.bookings WHERE id = p_booking_id AND organization_id = p_organization_id
  ) THEN RAISE EXCEPTION 'task booking is invalid' USING ERRCODE = '23503'; END IF;
  IF p_assigned_membership_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.organization_memberships
    WHERE id = p_assigned_membership_id AND organization_id = p_organization_id AND status = 'active'
  ) THEN RAISE EXCEPTION 'task assignee is invalid' USING ERRCODE = '23503'; END IF;

  SELECT * INTO v_existing
  FROM public.operations_tasks
  WHERE organization_id = p_organization_id AND idempotency_key = btrim(p_idempotency_key);
  IF FOUND THEN
    IF v_existing.task_type = p_task_type AND v_existing.title = btrim(p_title)
      AND v_existing.description IS NOT DISTINCT FROM NULLIF(btrim(p_description), '')
      AND v_existing.due_at IS NOT DISTINCT FROM p_due_at
      AND v_existing.booking_id IS NOT DISTINCT FROM p_booking_id
      AND v_existing.assigned_membership_id IS NOT DISTINCT FROM p_assigned_membership_id THEN
      RETURN v_existing.id;
    END IF;
    RAISE EXCEPTION 'task idempotency key belongs to a different task' USING ERRCODE = '23505';
  END IF;

  INSERT INTO public.operations_tasks (
    organization_id, task_type, title, description, due_at, booking_id,
    assigned_membership_id, created_by_membership_id, idempotency_key
  ) VALUES (
    p_organization_id, p_task_type, btrim(p_title), NULLIF(btrim(p_description), ''), p_due_at,
    p_booking_id, p_assigned_membership_id, v_actor, btrim(p_idempotency_key)
  ) RETURNING id INTO v_id;
  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'operations.task.created', 'operations_task',
    v_id, 'success', p_request_id, jsonb_build_object('task_type', p_task_type, 'booking_id', p_booking_id)
  );
  INSERT INTO public.outbox_events (
    organization_id, event_type, schema_version, dedupe_key, payload
  ) VALUES (
    p_organization_id, 'operations.task.created', 1, 'operations-task:' || v_id::text,
    jsonb_build_object('task_id', v_id)
  );
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.list_operations_tasks(
  p_organization_id uuid,
  p_limit integer DEFAULT 100
)
RETURNS TABLE (
  id uuid,
  task_type text,
  title text,
  description text,
  status text,
  due_at timestamptz,
  booking_id uuid,
  assigned_membership_id uuid,
  created_at timestamptz,
  updated_at timestamptz
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
  IF v_role IS NULL OR v_role NOT IN ('owner', 'manager', 'operations') THEN
    RAISE EXCEPTION 'task read is not permitted' USING ERRCODE = '42501';
  END IF;
  IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 200 THEN RAISE EXCEPTION 'task limit is invalid' USING ERRCODE = '22023'; END IF;
  RETURN QUERY
  SELECT task.id, task.task_type, task.title, task.description, task.status,
         task.due_at, task.booking_id, task.assigned_membership_id, task.created_at, task.updated_at
  FROM public.operations_tasks AS task
  WHERE task.organization_id = p_organization_id
    AND (v_role IN ('owner', 'manager') OR task.assigned_membership_id IS NULL OR task.assigned_membership_id = v_actor)
  ORDER BY (task.status IN ('completed', 'cancelled')), task.due_at NULLS LAST, task.created_at DESC, task.id DESC
  LIMIT p_limit;
END;
$$;

CREATE OR REPLACE FUNCTION public.update_operations_task_status(
  p_organization_id uuid,
  p_task_id uuid,
  p_status text,
  p_request_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE v_actor uuid; v_old text;
BEGIN
  SELECT membership.id INTO v_actor
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = p_organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
    AND membership.role IN ('owner', 'manager', 'operations');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'task update is not permitted' USING ERRCODE = '42501'; END IF;
  IF p_status IS NULL OR p_status NOT IN ('open', 'in_progress', 'completed', 'cancelled') THEN RAISE EXCEPTION 'task status is invalid' USING ERRCODE = '22023'; END IF;
  SELECT task.status INTO v_old FROM public.operations_tasks AS task WHERE task.id = p_task_id AND task.organization_id = p_organization_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'task is invalid' USING ERRCODE = '23503'; END IF;
  UPDATE public.operations_tasks SET status = p_status WHERE id = p_task_id AND organization_id = p_organization_id;
  INSERT INTO public.audit_events (
    organization_id, actor_type, actor_membership_id, action, resource_type,
    resource_id, outcome, request_id, before_delta, after_delta
  ) VALUES (
    p_organization_id, 'user', v_actor, 'operations.task.status_changed', 'operations_task',
    p_task_id, 'success', p_request_id, jsonb_build_object('status', v_old), jsonb_build_object('status', p_status)
  );
  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.create_operations_task(uuid, text, text, text, timestamptz, uuid, uuid, text, uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION public.list_operations_tasks(uuid, integer) FROM PUBLIC;

REVOKE ALL ON FUNCTION public.update_operations_task_status(uuid, uuid, text, uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION
  public.create_operations_task(uuid, text, text, text, timestamptz, uuid, uuid, text, uuid),
  public.list_operations_tasks(uuid, integer),
  public.update_operations_task_status(uuid, uuid, text, uuid)
TO authenticated;

