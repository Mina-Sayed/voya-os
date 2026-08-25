-- A booking transitioning to confirmed creates one normal task-engine reconfirmation task.

DO $$
DECLARE
  v_booking_id uuid := 'aaaaaaaa-0000-0000-0000-000000000591';
  v_task_id uuid;
  v_expected_due_at timestamptz;
  v_requester uuid;
BEGIN
  IF to_regprocedure('public.create_booking_reconfirmation_task()') IS NULL
    OR NOT EXISTS (
      SELECT 1
      FROM pg_trigger
      WHERE tgrelid = 'public.bookings'::regclass
        AND tgname = 'bookings_create_reconfirmation_task'
        AND NOT tgisinternal
    ) THEN
    RAISE EXCEPTION 'booking reconfirmation trigger is missing';
  END IF;
  IF has_function_privilege('authenticated', 'public.create_booking_reconfirmation_task()', 'EXECUTE') THEN
    RAISE EXCEPTION 'browser role must not execute the reconfirmation trigger function';
  END IF;

  SELECT id INTO v_requester
  FROM public.organization_memberships
  WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    AND user_id = '55555555-5555-5555-5555-555555555555'
    AND status = 'active'
  LIMIT 1;
  IF v_requester IS NULL THEN
    RAISE EXCEPTION 'reconfirmation fixture requester is missing';
  END IF;

  INSERT INTO public.bookings (
    id, organization_id, property_id, client_id, status, check_in, check_out,
    agreed_total_amount_minor, currency, commercial_completion_status,
    created_by_membership_id, idempotency_key
  ) VALUES (
    v_booking_id,
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'aaaaaaaa-0000-0000-0000-000000000001',
    'aaaaaaaa-0000-0000-0000-000000000002',
    'draft', DATE '2050-01-10', DATE '2050-01-13',
    1000000, 'EGP', 'complete', v_requester, 'reconfirmation-fixture-591'
  ) ON CONFLICT (id) DO UPDATE
  SET status = 'draft';

  -- The production trigger intentionally runs on a status transition into
  -- confirmed. Supply a real active actor so its creator-membership lookup
  -- follows the same path as the application confirmation flow.
  PERFORM set_config('request.jwt.claim.sub', '55555555-5555-5555-5555-555555555555', true);
  UPDATE public.bookings
  SET status = 'confirmed'
  WHERE id = v_booking_id;

  IF (SELECT status FROM public.bookings WHERE id = v_booking_id) <> 'confirmed' THEN
    RAISE EXCEPTION 'isolated reconfirmation fixture did not produce a confirmed booking';
  END IF;

  SELECT id, due_at INTO v_task_id, v_expected_due_at
  FROM public.operations_tasks
  WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    AND booking_id = v_booking_id
    AND idempotency_key = 'booking-reconfirmation:' || v_booking_id::text;
  IF v_task_id IS NULL THEN
    RAISE EXCEPTION 'confirmed booking must create a reconfirmation task';
  END IF;
  IF (SELECT count(*) FROM public.operations_tasks WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND idempotency_key = 'booking-reconfirmation:' || v_booking_id::text) <> 1 THEN
    RAISE EXCEPTION 'reconfirmation task must be idempotent';
  END IF;
  IF (SELECT task_type FROM public.operations_tasks WHERE id = v_task_id) <> 'reconfirm_booking'
    OR (SELECT status FROM public.operations_tasks WHERE id = v_task_id) <> 'open'
    OR (SELECT title FROM public.operations_tasks WHERE id = v_task_id) <> 'إعادة تأكيد الإقامة قبل الوصول' THEN
    RAISE EXCEPTION 'reconfirmation task fields are invalid';
  END IF;
  IF v_expected_due_at <> (DATE '2050-01-10'::timestamp AT TIME ZONE 'Africa/Cairo') - interval '24 hours' THEN
    RAISE EXCEPTION 'reconfirmation task due time must be one day before local check-in';
  END IF;
  IF (SELECT count(*) FROM public.audit_events WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND action = 'booking.reconfirmation_task.created' AND resource_id = v_task_id) <> 1 THEN
    RAISE EXCEPTION 'reconfirmation task must have audit evidence';
  END IF;
  IF (SELECT count(*) FROM public.outbox_events WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND event_type = 'operations.task.created' AND dedupe_key = 'operations-task:' || v_task_id::text) <> 1 THEN
    RAISE EXCEPTION 'reconfirmation task must enqueue one task event';
  END IF;
END;
$$;

SELECT 'booking reconfirmation task database integration tests passed' AS result;
