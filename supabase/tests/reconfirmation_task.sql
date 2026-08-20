-- A confirmed booking creates one normal task-engine reconfirmation task.

DO $$
DECLARE
  v_booking_id uuid;
  v_task_id uuid;
  v_expected_due_at timestamptz;
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

  SELECT id INTO v_booking_id
  FROM public.bookings
  WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    AND status = 'confirmed'
    AND check_in = DATE '2050-01-10'
  ORDER BY created_at DESC, id DESC
  LIMIT 1;
  IF v_booking_id IS NULL THEN
    RAISE EXCEPTION 'commercial booking fixture did not produce a confirmed booking';
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
