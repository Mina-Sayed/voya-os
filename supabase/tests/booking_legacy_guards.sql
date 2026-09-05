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
