-- Booking approval and stay lifecycle integration checks.

DO $$
BEGIN
  IF to_regprocedure('extensions.digest(text,text)') IS NULL THEN
    RAISE EXCEPTION 'Supabase pgcrypto digest must be available in the extensions schema';
  END IF;
  IF pg_get_functiondef(to_regprocedure('public.decide_booking_approval(uuid,uuid,text,text,uuid)'))
     LIKE '%v_approver_role%' THEN
    RAISE EXCEPTION 'booking approval function must not retain unused approver role state';
  END IF;
  IF has_table_privilege('authenticated', 'public.booking_stay_events', 'INSERT')
    OR has_table_privilege('authenticated', 'public.bookings', 'UPDATE') THEN
    RAISE EXCEPTION 'browser role must use booking lifecycle RPCs';
  END IF;
  IF has_function_privilege('anon', 'public.confirm_booking(uuid, uuid, text, uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'anon must not confirm bookings';
  END IF;
END;
$$;

INSERT INTO auth.users (id)
VALUES ('55555555-5555-5555-5555-555555555555')
ON CONFLICT DO NOTHING;
INSERT INTO public.profiles (id, display_name)
VALUES ('55555555-5555-5555-5555-555555555555', 'Booking manager')
ON CONFLICT DO NOTHING;
INSERT INTO public.organization_memberships (organization_id, user_id, role, status)
VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '55555555-5555-5555-5555-555555555555', 'manager', 'active')
ON CONFLICT DO NOTHING;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '55555555-5555-5555-5555-555555555555', false);

SELECT public.create_booking_draft(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'aaaaaaaa-0000-0000-0000-000000000001',
  'aaaaaaaa-0000-0000-0000-000000000002',
  DATE '2028-04-20', DATE '2028-04-23', 'lifecycle-draft-1',
  'aaaaaaaa-0000-0000-0000-0000000000b1'
) AS booking_id \gset

SELECT public.request_booking_approval(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'booking_id', 'lifecycle-approval-1',
  'aaaaaaaa-0000-0000-0000-0000000000b2'
) AS approval_id \gset

SELECT public.request_booking_approval(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'booking_id', 'lifecycle-approval-1',
  'aaaaaaaa-0000-0000-0000-0000000000b3'
);

RESET ROLE;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT public.decide_booking_approval(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'approval_id', 'approved', 'تمت مراجعة التواريخ والطلب.',
  'aaaaaaaa-0000-0000-0000-0000000000b4'
);
SELECT public.confirm_booking(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'booking_id', 'lifecycle-confirm-1',
  'aaaaaaaa-0000-0000-0000-0000000000b5'
);
SELECT public.confirm_booking(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'booking_id', 'lifecycle-confirm-1',
  'aaaaaaaa-0000-0000-0000-0000000000b6'
);
RESET ROLE;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
DO $$
DECLARE v_booking_id uuid;
BEGIN
  SELECT id INTO v_booking_id
  FROM public.bookings
  WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    AND check_in = DATE '2028-04-20'
    AND check_out = DATE '2028-04-23'
  ORDER BY created_at DESC
  LIMIT 1;
  BEGIN
    PERFORM public.record_booking_stay_event('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_booking_id, 'check_out', NULL, 'lifecycle-checkout-before-in', NULL);
    RAISE EXCEPTION 'check-out must require check-in';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM NOT LIKE '%check-in is required%' THEN RAISE; END IF;
  END;
END;
$$;

SELECT public.record_booking_stay_event(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'booking_id', 'check_in', 'تم التسليم واستلام المفاتيح.', 'lifecycle-checkin-1',
  'aaaaaaaa-0000-0000-0000-0000000000b7'
) AS checkin_id \gset
SELECT public.record_booking_stay_event(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'booking_id', 'check_in', 'تم التسليم واستلام المفاتيح.', 'lifecycle-checkin-1',
  'aaaaaaaa-0000-0000-0000-0000000000b8'
);
SELECT public.record_booking_stay_event(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'booking_id', 'check_out', 'تمت المغادرة.', 'lifecycle-checkout-1',
  'aaaaaaaa-0000-0000-0000-0000000000b9'
);
RESET ROLE;

DO $$
BEGIN
  IF (SELECT status FROM public.bookings WHERE idempotency_key = 'lifecycle-draft-1') <> 'completed' THEN
    RAISE EXCEPTION 'check-out must complete the booking';
  END IF;
  IF (SELECT count(*) FROM public.booking_stay_events WHERE booking_id = (SELECT id FROM public.bookings WHERE check_in = DATE '2028-04-20' AND check_out = DATE '2028-04-23' ORDER BY created_at DESC LIMIT 1)) <> 2 THEN
    RAISE EXCEPTION 'idempotent stay events must persist exactly once per event type';
  END IF;
  IF (SELECT count(*) FROM public.approval_decisions WHERE approval_request_id = (SELECT id FROM public.approval_requests WHERE resource_id = (SELECT id FROM public.bookings WHERE check_in = DATE '2028-04-20' AND check_out = DATE '2028-04-23' ORDER BY created_at DESC LIMIT 1) ORDER BY created_at DESC LIMIT 1)) <> 1 THEN
    RAISE EXCEPTION 'booking approval decision must be immutable evidence';
  END IF;
  IF (SELECT count(*) FROM public.audit_events WHERE resource_id = (SELECT id FROM public.bookings WHERE idempotency_key IS NULL AND check_in = DATE '2028-04-20' AND check_out = DATE '2028-04-23' ORDER BY created_at DESC LIMIT 1) AND action IN ('booking.approval_requested', 'booking.confirmed', 'booking.check_in', 'booking.check_out')) <> 4 THEN
    RAISE EXCEPTION 'booking lifecycle must append audit evidence';
  END IF;
END;
$$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '33333333-3333-3333-3333-333333333333', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.list_booking_work_queue('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
    RAISE EXCEPTION 'suspended viewer must not read booking work queue';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END;
$$;
RESET ROLE;

SELECT 'booking lifecycle database integration tests passed' AS result;
