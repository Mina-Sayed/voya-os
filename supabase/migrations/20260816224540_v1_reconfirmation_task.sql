-- Voya OS V1: turn a confirmed booking into a normal reconfirmation task.
-- Reconfirmation is intentionally modeled by the existing task engine.

CREATE OR REPLACE FUNCTION public.create_booking_reconfirmation_task()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_creator_membership_id uuid;
  v_assignee_membership_id uuid;
  v_timezone text;
  v_task_id uuid;
  v_due_at timestamptz;
BEGIN
  IF OLD.status IS NOT DISTINCT FROM NEW.status OR NEW.status <> 'confirmed' THEN
    RETURN NEW;
  END IF;

  SELECT membership.id
  INTO v_creator_membership_id
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = NEW.organization_id
    AND membership.user_id = auth.uid()
    AND membership.status = 'active'
  ORDER BY membership.created_at ASC, membership.id ASC
  LIMIT 1;

  IF v_creator_membership_id IS NULL THEN
    SELECT decision.approver_membership_id
    INTO v_creator_membership_id
    FROM public.approval_decisions AS decision
    JOIN public.approval_requests AS request
      ON request.organization_id = decision.organization_id
     AND request.id = decision.approval_request_id
    WHERE decision.organization_id = NEW.organization_id
      AND request.resource_type = 'booking'
      AND request.resource_id = NEW.id
      AND request.proposed_action = 'booking.confirm'
      AND decision.decision = 'approved'
    ORDER BY decision.created_at DESC, decision.id DESC
    LIMIT 1;
  END IF;

  IF v_creator_membership_id IS NULL THEN
    RAISE EXCEPTION 'reconfirmation task actor is unavailable' USING ERRCODE = '42501';
  END IF;

  SELECT membership.id
  INTO v_assignee_membership_id
  FROM public.organization_memberships AS membership
  WHERE membership.organization_id = NEW.organization_id
    AND membership.status = 'active'
    AND membership.role = 'operations'
  ORDER BY membership.created_at ASC, membership.id ASC
  LIMIT 1;

  SELECT organization.timezone
  INTO v_timezone
  FROM public.organizations AS organization
  WHERE organization.id = NEW.organization_id;

  v_due_at := (NEW.check_in::timestamp AT TIME ZONE coalesce(v_timezone, 'Africa/Cairo')) - interval '24 hours';

  INSERT INTO public.operations_tasks (
    organization_id,
    task_type,
    title,
    description,
    due_at,
    booking_id,
    assigned_membership_id,
    created_by_membership_id,
    idempotency_key
  ) VALUES (
    NEW.organization_id,
    'reconfirm_booking',
    'إعادة تأكيد الإقامة قبل الوصول',
    'راجع تفاصيل الوصول وتواصل مع العميل قبل موعد الدخول.',
    v_due_at,
    NEW.id,
    v_assignee_membership_id,
    v_creator_membership_id,
    'booking-reconfirmation:' || NEW.id::text
  )
  ON CONFLICT (organization_id, idempotency_key) DO NOTHING
  RETURNING id INTO v_task_id;

  IF v_task_id IS NULL THEN
    RETURN NEW;
  END IF;

  INSERT INTO public.audit_events (
    organization_id,
    actor_type,
    actor_membership_id,
    action,
    resource_type,
    resource_id,
    outcome,
    after_delta
  ) VALUES (
    NEW.organization_id,
    'user',
    v_creator_membership_id,
    'booking.reconfirmation_task.created',
    'operations_task',
    v_task_id,
    'success',
    jsonb_build_object('booking_id', NEW.id, 'due_at', v_due_at, 'task_type', 'reconfirm_booking')
  );

  INSERT INTO public.outbox_events (
    organization_id,
    event_type,
    schema_version,
    dedupe_key,
    payload
  ) VALUES (
    NEW.organization_id,
    'operations.task.created',
    1,
    'operations-task:' || v_task_id::text,
    jsonb_build_object('task_id', v_task_id, 'booking_id', NEW.id, 'source', 'booking_confirmation')
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS bookings_create_reconfirmation_task ON public.bookings;
CREATE TRIGGER bookings_create_reconfirmation_task
  AFTER UPDATE OF status ON public.bookings
  FOR EACH ROW EXECUTE FUNCTION public.create_booking_reconfirmation_task();

REVOKE ALL ON FUNCTION public.create_booking_reconfirmation_task() FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public.create_booking_reconfirmation_task() IS
  'Creates one tenant-scoped reconfirmation task when a booking becomes confirmed.';
