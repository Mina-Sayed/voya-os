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

SELECT public.complete_booking_commercial_snapshot(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'booking_id',
  '2500000', 'EGP', 'استكمال snapshot التجاري للاختبار',
  'lifecycle-commercial-completion-1',
  'aaaaaaaa-0000-0000-0000-0000000000b1'
);
SELECT set_config('voya.test.lifecycle_booking_id', :'booking_id', false);

SELECT public.request_booking_approval(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'booking_id', 'lifecycle-approval-1',
  'aaaaaaaa-0000-0000-0000-0000000000b2'
) AS approval_id \gset
SELECT set_config('voya.test.lifecycle_approval_id', :'approval_id', false);

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

DO $$
BEGIN
  IF (SELECT agreed_total_amount_minor FROM public.bookings WHERE id = current_setting('voya.test.lifecycle_booking_id')::uuid) <> 2500000
    OR (SELECT currency FROM public.bookings WHERE id = current_setting('voya.test.lifecycle_booking_id')::uuid) <> 'EGP'
    OR (SELECT commercial_completion_status FROM public.bookings WHERE id = current_setting('voya.test.lifecycle_booking_id')::uuid) <> 'complete' THEN
    RAISE EXCEPTION 'legacy compatibility confirmation must preserve the commercial snapshot';
  END IF;
  IF (SELECT proposal_snapshot->>'agreed_total_amount_minor'
      FROM public.approval_requests WHERE id = current_setting('voya.test.lifecycle_approval_id')::uuid) <> '2500000'
    OR (SELECT proposal_snapshot->>'currency'
        FROM public.approval_requests WHERE id = current_setting('voya.test.lifecycle_approval_id')::uuid) <> 'EGP' THEN
    RAISE EXCEPTION 'legacy compatibility approval must include commercial fields';
  END IF;
END;
$$;

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

DO $$
DECLARE
  v_requester uuid := (
    SELECT id FROM public.organization_memberships
    WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND user_id = '55555555-5555-5555-5555-555555555555'
  );
  v_snapshot jsonb;
BEGIN
  IF to_regclass('public.booking_command_idempotency') IS NULL THEN
    RAISE EXCEPTION 'booking command idempotency bindings are missing';
  END IF;
  IF has_table_privilege('authenticated', 'public.booking_command_idempotency', 'SELECT') THEN
    RAISE EXCEPTION 'browser role must not read booking command idempotency bindings';
  END IF;

  INSERT INTO public.bookings (
    id, organization_id, property_id, client_id, status, check_in, check_out,
    agreed_total_amount_minor, currency, commercial_completion_status
  ) VALUES (
    'aaaaaaaa-0000-0000-0000-000000000201',
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'aaaaaaaa-0000-0000-0000-000000000001',
    'aaaaaaaa-0000-0000-0000-000000000002',
    'pending_approval', DATE '2032-01-01', DATE '2032-01-03', 100000, 'EGP', 'complete'
  );
  v_snapshot := jsonb_build_object(
    'booking_id', 'aaaaaaaa-0000-0000-0000-000000000201'::uuid,
    'booking_version', 1,
    'property_id', 'aaaaaaaa-0000-0000-0000-000000000001'::uuid,
    'client_id', 'aaaaaaaa-0000-0000-0000-000000000002'::uuid,
    'check_in', DATE '2032-01-01', 'check_out', DATE '2032-01-03',
    'agreed_total_amount_minor', 100000, 'currency', 'EGP',
    'status', 'draft'
  );
  INSERT INTO public.approval_requests (
    id, organization_id, resource_type, resource_id, proposed_action,
    proposal_snapshot, snapshot_hash, requester_membership_id, status, expires_at
  ) VALUES (
    'aaaaaaaa-0000-0000-0000-000000000211',
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'booking',
    'aaaaaaaa-0000-0000-0000-000000000201', 'booking.confirm',
    v_snapshot, encode(extensions.digest(v_snapshot::text, 'sha256'), 'hex'),
    v_requester, 'approved', clock_timestamp() - interval '1 second'
  );

  INSERT INTO public.bookings (
    id, organization_id, property_id, client_id, status, check_in, check_out,
    agreed_total_amount_minor, currency, commercial_completion_status
  ) VALUES (
    'aaaaaaaa-0000-0000-0000-000000000202',
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'aaaaaaaa-0000-0000-0000-000000000001',
    'aaaaaaaa-0000-0000-0000-000000000002',
    'pending_approval', DATE '2032-02-01', DATE '2032-02-03', 100000, 'EGP', 'complete'
  );
  v_snapshot := jsonb_build_object(
    'booking_id', 'aaaaaaaa-0000-0000-0000-000000000202'::uuid,
    'booking_version', 1,
    'property_id', 'aaaaaaaa-0000-0000-0000-000000000001'::uuid,
    'client_id', 'aaaaaaaa-0000-0000-0000-000000000002'::uuid,
    'check_in', DATE '2032-02-01', 'check_out', DATE '2032-02-03',
    'agreed_total_amount_minor', 100000, 'currency', 'EGP',
    'status', 'draft'
  );
  INSERT INTO public.approval_requests (
    id, organization_id, resource_type, resource_id, proposed_action,
    proposal_snapshot, snapshot_hash, requester_membership_id, status, expires_at
  ) VALUES (
    'aaaaaaaa-0000-0000-0000-000000000212',
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'booking',
    'aaaaaaaa-0000-0000-0000-000000000202', 'booking.confirm',
    v_snapshot, encode(extensions.digest(v_snapshot::text, 'sha256'), 'hex'),
    v_requester, 'approved', clock_timestamp()
  );

  INSERT INTO public.bookings (
    id, organization_id, property_id, client_id, status, check_in, check_out,
    agreed_total_amount_minor, currency, commercial_completion_status
  ) VALUES (
    'aaaaaaaa-0000-0000-0000-000000000203',
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'aaaaaaaa-0000-0000-0000-000000000001',
    'aaaaaaaa-0000-0000-0000-000000000002',
    'pending_approval', DATE '2032-03-01', DATE '2032-03-03', 100000, 'EGP', 'complete'
  );
  v_snapshot := jsonb_build_object(
    'booking_id', 'aaaaaaaa-0000-0000-0000-000000000203'::uuid,
    'booking_version', 1,
    'property_id', 'aaaaaaaa-0000-0000-0000-000000000001'::uuid,
    'client_id', 'aaaaaaaa-0000-0000-0000-000000000002'::uuid,
    'check_in', DATE '2032-03-01', 'check_out', DATE '2032-03-03',
    'agreed_total_amount_minor', 100000, 'currency', 'EGP',
    'status', 'draft'
  );
  INSERT INTO public.approval_requests (
    id, organization_id, resource_type, resource_id, proposed_action,
    proposal_snapshot, snapshot_hash, requester_membership_id, status, expires_at
  ) VALUES (
    'aaaaaaaa-0000-0000-0000-000000000213',
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'booking',
    'aaaaaaaa-0000-0000-0000-000000000203', 'booking.confirm',
    v_snapshot, encode(extensions.digest(v_snapshot::text, 'sha256'), 'hex'),
    v_requester, 'pending', clock_timestamp() - interval '1 second'
  );

  INSERT INTO public.bookings (
    id, organization_id, property_id, client_id, status, check_in, check_out,
    agreed_total_amount_minor, currency, commercial_completion_status
  ) VALUES
    ('aaaaaaaa-0000-0000-0000-000000000204', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
     'aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000002',
     'draft', DATE '2032-04-01', DATE '2032-04-03', 100000, 'EGP', 'complete'),
    ('aaaaaaaa-0000-0000-0000-000000000205', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
     'aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000002',
     'draft', DATE '2032-05-01', DATE '2032-05-03', 100000, 'EGP', 'complete'),
    ('aaaaaaaa-0000-0000-0000-000000000206', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
     'aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000002',
     'pending_approval', DATE '2032-06-01', DATE '2032-06-03', 100000, 'EGP', 'complete'),
    ('aaaaaaaa-0000-0000-0000-000000000207', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
     'aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000002',
     'confirmed', DATE '2034-01-01', DATE '2034-01-03', NULL, NULL, 'needs_completion'),
    ('aaaaaaaa-0000-0000-0000-000000000208', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
     'aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000002',
     'pending_approval', DATE '2032-07-01', DATE '2032-07-03', 100000, 'EGP', 'complete');

  INSERT INTO public.approval_requests (
    id, organization_id, resource_type, resource_id, proposed_action,
    proposal_snapshot, snapshot_hash, requester_membership_id, status, expires_at
  ) VALUES (
    'aaaaaaaa-0000-0000-0000-000000000216',
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'booking',
    'aaaaaaaa-0000-0000-0000-000000000206', 'booking.confirm',
    '{}'::jsonb, encode(extensions.digest('{}'::jsonb::text, 'sha256'), 'hex'),
    v_requester, 'approved', clock_timestamp() + interval '1 hour'
  );
END;
$$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.confirm_booking(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000201',
      'expired-confirm-key', NULL
    );
    RAISE EXCEPTION 'expired approval confirmed a booking';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  BEGIN
    PERFORM public.confirm_booking(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000202',
      'boundary-confirm-key', NULL
    );
    RAISE EXCEPTION 'approval at the exact expiration boundary confirmed a booking';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  BEGIN
    PERFORM public.confirm_booking(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000206',
      'tampered-snapshot-confirm-key', NULL
    );
    RAISE EXCEPTION 'approval with a stale/tampered snapshot confirmed a booking';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
END;
$$;
RESET ROLE;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '55555555-5555-5555-5555-555555555555', false);
DO $$
DECLARE
  v_first uuid;
  v_second uuid;
  v_recovered uuid;
BEGIN
  v_first := public.request_booking_approval(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'aaaaaaaa-0000-0000-0000-000000000203',
    'approval-renewal-key', NULL
  );
  v_second := public.request_booking_approval(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'aaaaaaaa-0000-0000-0000-000000000203',
    'approval-renewal-key', NULL
  );
  IF v_first = 'aaaaaaaa-0000-0000-0000-000000000213'::uuid OR v_second <> v_first THEN
    RAISE EXCEPTION 'expired pending approval was not renewed idempotently';
  END IF;
  PERFORM public.request_booking_approval(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'aaaaaaaa-0000-0000-0000-000000000204',
    'approval-command-binding-key', NULL
  );
  BEGIN
    PERFORM public.request_booking_approval(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000205',
      'approval-command-binding-key', NULL
    );
    RAISE EXCEPTION 'approval idempotency key was reused for another booking';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;

  v_recovered := public.request_booking_approval(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'aaaaaaaa-0000-0000-0000-000000000208',
    'approval-missing-row-recovery-key', NULL
  );
  IF v_recovered IS NULL THEN
    RAISE EXCEPTION 'pending booking without an approval row was not recovered';
  END IF;
END;
$$;
RESET ROLE;

DO $$
BEGIN
  IF (SELECT status FROM public.approval_requests
      WHERE id = 'aaaaaaaa-0000-0000-0000-000000000213') <> 'expired' THEN
    RAISE EXCEPTION 'stale pending approval was not expired';
  END IF;
  IF (SELECT count(*) FROM public.approval_requests
      WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND resource_id = 'aaaaaaaa-0000-0000-0000-000000000203'
        AND status = 'pending' AND expires_at > clock_timestamp()) <> 1 THEN
    RAISE EXCEPTION 'approval renewal must leave exactly one actionable request';
  END IF;
  IF (SELECT count(*) FROM public.approval_requests
      WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND resource_id = 'aaaaaaaa-0000-0000-0000-000000000208'
        AND status = 'pending' AND expires_at > clock_timestamp()) <> 1 THEN
    RAISE EXCEPTION 'missing approval recovery must create one actionable request';
  END IF;
END;
$$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
DO $$
DECLARE
  v_completed_booking uuid;
BEGIN
  SELECT booking.id INTO v_completed_booking
  FROM public.bookings AS booking
  WHERE booking.organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    AND booking.check_in = DATE '2028-04-20'
    AND booking.check_out = DATE '2028-04-23'
  ORDER BY booking.created_at DESC
  LIMIT 1;

  IF NOT public.confirm_booking(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_completed_booking,
    'lifecycle-confirm-1', NULL
  ) THEN
    RAISE EXCEPTION 'exact confirmation retry did not return its original success';
  END IF;
  BEGIN
    PERFORM public.confirm_booking(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_completed_booking,
      'lifecycle-confirm-different-key', NULL
    );
    RAISE EXCEPTION 'confirmed booking accepted a different idempotency key';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;

  PERFORM public.record_booking_stay_event(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_completed_booking,
    'check_in', 'تم التسليم واستلام المفاتيح.', 'lifecycle-checkin-1', NULL
  );
  BEGIN
    PERFORM public.record_booking_stay_event(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_completed_booking,
      'check_in', 'ملاحظات مختلفة', 'lifecycle-checkin-1', NULL
    );
    RAISE EXCEPTION 'stay-event key accepted a different normalized payload';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
  BEGIN
    PERFORM public.record_booking_stay_event(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000207',
      'check_in', 'تم التسليم واستلام المفاتيح.', 'lifecycle-checkin-1', NULL
    );
    RAISE EXCEPTION 'stay-event key was reused for another booking';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
END;
$$;
RESET ROLE;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.bookings
    WHERE id IN (
      'aaaaaaaa-0000-0000-0000-000000000201',
      'aaaaaaaa-0000-0000-0000-000000000202',
      'aaaaaaaa-0000-0000-0000-000000000206'
    ) AND status = 'confirmed'
  ) THEN
    RAISE EXCEPTION 'invalid approval changed a protected booking';
  END IF;
  IF (SELECT count(*) FROM public.booking_stay_events
      WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND idempotency_key = 'lifecycle-checkin-1') <> 1 THEN
    RAISE EXCEPTION 'exact stay-event retry did not preserve one original event';
  END IF;
END;
$$;

SELECT 'booking lifecycle database integration tests passed' AS result;
