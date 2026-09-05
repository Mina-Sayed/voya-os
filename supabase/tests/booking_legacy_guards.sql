-- Legacy booking write entrypoints must not bypass the commercial booking flow.
\set ON_ERROR_STOP on

DO $$
BEGIN
  IF has_function_privilege('anon', 'public.request_booking_approval(uuid, uuid, text, uuid)', 'EXECUTE')
    OR has_function_privilege('anon', 'public.confirm_booking(uuid, uuid, text, uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'anon must not execute legacy booking commands';
  END IF;
END;
$$;

INSERT INTO auth.users (id)
VALUES ('66666666-6666-6666-6666-666666666666')
ON CONFLICT DO NOTHING;
INSERT INTO public.profiles (id, display_name)
VALUES ('66666666-6666-6666-6666-666666666666', 'Booking sales')
ON CONFLICT DO NOTHING;
INSERT INTO public.organization_memberships (organization_id, user_id, role, status)
VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '66666666-6666-6666-6666-666666666666', 'sales_agent', 'active')
ON CONFLICT DO NOTHING;
-- The manager actor below is inserted locally (not borrowed from
-- booking_lifecycle.sql) so this suite stays order-independent.
INSERT INTO auth.users (id)
VALUES ('55555555-5555-5555-5555-555555555555')
ON CONFLICT DO NOTHING;
INSERT INTO public.profiles (id, display_name)
VALUES ('55555555-5555-5555-5555-555555555555', 'Booking manager')
ON CONFLICT DO NOTHING;
INSERT INTO public.organization_memberships (organization_id, user_id, role, status)
VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '55555555-5555-5555-5555-555555555555', 'manager', 'active')
ON CONFLICT DO NOTHING;

INSERT INTO public.bookings (
  id, organization_id, property_id, client_id, status, check_in, check_out
) VALUES (
  'aaaaaaaa-0000-0000-0000-000000000301',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'aaaaaaaa-0000-0000-0000-000000000001',
  'aaaaaaaa-0000-0000-0000-000000000002',
  'draft', DATE '2036-01-10', DATE '2036-01-12'
);

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '55555555-5555-5555-5555-555555555555', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.request_booking_approval(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000301',
      'legacy-incomplete-approval-301', NULL
    );
    RAISE EXCEPTION 'legacy approval request accepted an incomplete booking';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
END;
$$;
RESET ROLE;

DO $$
BEGIN
  IF (SELECT status FROM public.bookings WHERE id = 'aaaaaaaa-0000-0000-0000-000000000301') <> 'draft'
    OR EXISTS (
      SELECT 1 FROM public.approval_requests
      WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        AND resource_id = 'aaaaaaaa-0000-0000-0000-000000000301'
        AND proposed_action = 'booking.confirm'
    ) THEN
    RAISE EXCEPTION 'legacy approval request changed an incomplete booking';
  END IF;
END;
$$;

INSERT INTO public.bookings (
  id, organization_id, property_id, client_id, status, check_in, check_out
) VALUES (
  'aaaaaaaa-0000-0000-0000-000000000302',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'aaaaaaaa-0000-0000-0000-000000000001',
  'aaaaaaaa-0000-0000-0000-000000000002',
  'pending_approval', DATE '2036-02-10', DATE '2036-02-12'
);

INSERT INTO public.approval_requests (
  id, organization_id, resource_type, resource_id, proposed_action,
  proposal_snapshot, snapshot_hash, requester_membership_id, status, expires_at
) VALUES (
  'aaaaaaaa-0000-0000-0000-000000000312',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'booking',
  'aaaaaaaa-0000-0000-0000-000000000302', 'booking.confirm',
  jsonb_build_object(
    'booking_id', 'aaaaaaaa-0000-0000-0000-000000000302'::uuid,
    'property_id', 'aaaaaaaa-0000-0000-0000-000000000001'::uuid,
    'client_id', 'aaaaaaaa-0000-0000-0000-000000000002'::uuid,
    'check_in', DATE '2036-02-10', 'check_out', DATE '2036-02-12',
    'status', 'draft'
  ),
  encode(extensions.digest((jsonb_build_object(
    'booking_id', 'aaaaaaaa-0000-0000-0000-000000000302'::uuid,
    'property_id', 'aaaaaaaa-0000-0000-0000-000000000001'::uuid,
    'client_id', 'aaaaaaaa-0000-0000-0000-000000000002'::uuid,
    'check_in', DATE '2036-02-10', 'check_out', DATE '2036-02-12',
    'status', 'draft'
  ))::text, 'sha256'), 'hex'),
  (SELECT id FROM public.organization_memberships
   WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
     AND user_id = '55555555-5555-5555-5555-555555555555'),
  'approved', clock_timestamp() + interval '1 hour'
);

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '66666666-6666-6666-6666-666666666666', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.confirm_booking(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000302',
      'legacy-sales-confirm-302', NULL
    );
    RAISE EXCEPTION 'sales agent confirmed a booking through the legacy command';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END;
$$;
RESET ROLE;

DO $$
BEGIN
  IF (SELECT status FROM public.bookings WHERE id = 'aaaaaaaa-0000-0000-0000-000000000302') <> 'pending_approval' THEN
    RAISE EXCEPTION 'legacy confirmation changed an incomplete booking';
  END IF;
END;
$$;

INSERT INTO public.bookings (
  id, organization_id, property_id, client_id, status, check_in, check_out
) VALUES (
  'aaaaaaaa-0000-0000-0000-000000000303',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'aaaaaaaa-0000-0000-0000-000000000001',
  'aaaaaaaa-0000-0000-0000-000000000002',
  'pending_approval', DATE '2036-03-10', DATE '2036-03-12'
);

INSERT INTO public.approval_requests (
  id, organization_id, resource_type, resource_id, proposed_action,
  proposal_snapshot, snapshot_hash, requester_membership_id, status, expires_at
) VALUES (
  'aaaaaaaa-0000-0000-0000-000000000313',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'booking',
  'aaaaaaaa-0000-0000-0000-000000000303', 'booking.confirm',
  jsonb_build_object(
    'booking_id', 'aaaaaaaa-0000-0000-0000-000000000303'::uuid,
    'booking_version', 1,
    'property_id', 'aaaaaaaa-0000-0000-0000-000000000001'::uuid,
    'client_id', 'aaaaaaaa-0000-0000-0000-000000000002'::uuid,
    'check_in', DATE '2036-03-10', 'check_out', DATE '2036-03-12',
    'agreed_total_amount_minor', NULL,
    'currency', NULL,
    'status', 'draft'
  ),
  encode(extensions.digest((jsonb_build_object(
    'booking_id', 'aaaaaaaa-0000-0000-0000-000000000303'::uuid,
    'booking_version', 1,
    'property_id', 'aaaaaaaa-0000-0000-0000-000000000001'::uuid,
    'client_id', 'aaaaaaaa-0000-0000-0000-000000000002'::uuid,
    'check_in', DATE '2036-03-10', 'check_out', DATE '2036-03-12',
    'agreed_total_amount_minor', NULL,
    'currency', NULL,
    'status', 'draft'
  ))::text, 'sha256'), 'hex'),
  (SELECT id FROM public.organization_memberships
   WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
     AND user_id = '55555555-5555-5555-5555-555555555555'),
  'approved', clock_timestamp() + interval '1 hour'
);

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.confirm_commercial_booking(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000303',
      'commercial-incomplete-confirm-303', NULL
    );
    RAISE EXCEPTION 'commercial confirmation accepted an incomplete booking';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
END;
$$;
RESET ROLE;

DO $$
BEGIN
  IF (SELECT status FROM public.bookings WHERE id = 'aaaaaaaa-0000-0000-0000-000000000303') <> 'pending_approval' THEN
    RAISE EXCEPTION 'commercial confirmation changed an incomplete booking';
  END IF;
END;
$$;

-- Stale approval snapshots must fail closed even for an eligible confirmer:
-- sales requests, owner approves, then the commercial terms change before
-- a manager confirms.
INSERT INTO public.bookings (
  id, organization_id, property_id, client_id, status, check_in, check_out,
  agreed_total_amount_minor, currency, commercial_completion_status
) VALUES (
  'aaaaaaaa-0000-0000-0000-000000000304',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'aaaaaaaa-0000-0000-0000-000000000001',
  'aaaaaaaa-0000-0000-0000-000000000002',
  'draft', DATE '2036-04-10', DATE '2036-04-12', 100000, 'EGP', 'complete'
);

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '66666666-6666-6666-6666-666666666666', false);
SELECT public.request_booking_approval(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'aaaaaaaa-0000-0000-0000-000000000304',
  'legacy-stale-request-304', NULL
) AS stale_approval_id \gset
RESET ROLE;

SELECT set_config('voya.test.stale_approval_id', :'stale_approval_id', false);

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SELECT public.decide_booking_approval(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  current_setting('voya.test.stale_approval_id')::uuid,
  'approved', 'مراجعة تجارية مكتملة.',
  'aaaaaaaa-0000-0000-0000-000000000314'
);
RESET ROLE;

-- Commercial terms change after approval: the snapshot is now stale.
UPDATE public.bookings
SET agreed_total_amount_minor = 200000
WHERE id = 'aaaaaaaa-0000-0000-0000-000000000304';

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '55555555-5555-5555-5555-555555555555', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.confirm_booking(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000304',
      'legacy-stale-confirm-304', NULL
    );
    RAISE EXCEPTION 'confirmation accepted a stale approval snapshot';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
END;
$$;
RESET ROLE;

DO $$
BEGIN
  IF (SELECT status FROM public.bookings WHERE id = 'aaaaaaaa-0000-0000-0000-000000000304') <> 'pending_approval' THEN
    RAISE EXCEPTION 'stale snapshot confirmation changed the booking';
  END IF;
END;
$$;

-- Direct INSERTs must not create operational bookings without commercial data.
DO $$
BEGIN
  BEGIN
    INSERT INTO public.bookings (
      id, organization_id, property_id, client_id, status, check_in, check_out
    ) VALUES (
      'aaaaaaaa-0000-0000-0000-000000000305',
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000001',
      'aaaaaaaa-0000-0000-0000-000000000002',
      'confirmed', DATE '2036-05-10', DATE '2036-05-12'
    );
    RAISE EXCEPTION 'direct INSERT created a confirmed booking without commercial data';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
END;
$$;

-- Stay transitions out of an operational state require commercial data too:
-- a complete booking stays movable, but once its commercial fields are
-- cleared it cannot advance to checked_in/completed.
INSERT INTO public.bookings (
  id, organization_id, property_id, client_id, status, check_in, check_out,
  agreed_total_amount_minor, currency, commercial_completion_status
) VALUES (
  'aaaaaaaa-0000-0000-0000-000000000306',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'aaaaaaaa-0000-0000-0000-000000000001',
  'aaaaaaaa-0000-0000-0000-000000000002',
  'confirmed', DATE '2036-06-10', DATE '2036-06-12', 100000, 'EGP', 'complete'
);

DO $$
BEGIN
  UPDATE public.bookings SET status = 'checked_in'
  WHERE id = 'aaaaaaaa-0000-0000-0000-000000000306';
  IF (SELECT status FROM public.bookings WHERE id = 'aaaaaaaa-0000-0000-0000-000000000306') <> 'checked_in' THEN
    RAISE EXCEPTION 'complete booking could not check in';
  END IF;
  UPDATE public.bookings
  SET agreed_total_amount_minor = NULL, currency = NULL, commercial_completion_status = 'needs_completion'
  WHERE id = 'aaaaaaaa-0000-0000-0000-000000000306';
  BEGIN
    UPDATE public.bookings SET status = 'completed'
    WHERE id = 'aaaaaaaa-0000-0000-0000-000000000306';
    RAISE EXCEPTION 'stay completion bypassed commercial data';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
END;
$$;
