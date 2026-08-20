-- Fleet, driver, and transport request integration checks.

DO $$
BEGIN
  IF has_table_privilege('authenticated', 'public.fleet_vehicles', 'SELECT')
    OR has_table_privilege('authenticated', 'public.fleet_drivers', 'INSERT')
    OR has_table_privilege('authenticated', 'public.transport_requests', 'UPDATE') THEN
    RAISE EXCEPTION 'browser role must use fleet and transport RPCs';
  END IF;
  IF has_function_privilege('anon', 'public.list_transport_requests(uuid, integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'anon must not execute transport reads';
  END IF;
END;
$$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);

SELECT public.create_fleet_vehicle(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'فان المطار 1', 'van', 'EG-TR-001', 7,
  'aaaaaaaa-0000-0000-0000-0000000000a1'
) AS vehicle_id \gset

SELECT public.create_fleet_driver(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'سائق الاختبار', '+201001234567',
  'aaaaaaaa-0000-0000-0000-0000000000a2'
) AS driver_id \gset

SELECT public.create_transport_request(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'airport_transfer', 'ضيف الاختبار',
  'مطار القاهرة', 'A-101', '2026-08-20 14:00:00+00', 2, NULL,
  'aaaaaaaa-0000-0000-0000-000000000003', 'استقبال يدوي فقط', 'transport-a-1',
  'aaaaaaaa-0000-0000-0000-0000000000a3'
) AS request_id \gset

SELECT public.create_transport_request(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'airport_transfer', 'ضيف الاختبار',
  'مطار القاهرة', 'A-101', '2026-08-20 14:00:00+00', 2, NULL,
  'aaaaaaaa-0000-0000-0000-000000000003', 'استقبال يدوي فقط', 'transport-a-1',
  'aaaaaaaa-0000-0000-0000-0000000000a4'
);

SELECT public.assign_transport_request(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'request_id', :'vehicle_id', :'driver_id',
  'aaaaaaaa-0000-0000-0000-0000000000a5'
);

SELECT public.update_transport_request_status(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'request_id', 'in_progress',
  'aaaaaaaa-0000-0000-0000-0000000000a6'
);

DO $$
BEGIN
  IF (SELECT count(*) FROM public.list_fleet_vehicles('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')) <> 1 THEN
    RAISE EXCEPTION 'owner must read exactly one fleet vehicle';
  END IF;
  IF (SELECT count(*) FROM public.list_fleet_drivers('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')) <> 1 THEN
    RAISE EXCEPTION 'owner must read exactly one fleet driver';
  END IF;
  IF (SELECT count(*) FROM public.list_transport_requests('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 50) WHERE status = 'in_progress' AND vehicle_name = 'فان المطار 1') <> 1 THEN
    RAISE EXCEPTION 'assigned transport request must be visible with status and vehicle';
  END IF;
END;
$$;

RESET ROLE;

DO $$
BEGIN
  IF (SELECT count(*) FROM public.transport_requests WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') <> 1 THEN
    RAISE EXCEPTION 'idempotent transport request must persist exactly once';
  END IF;
  IF (SELECT count(*) FROM public.outbox_events WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND event_type = 'transport.request.created') <> 1 THEN
    RAISE EXCEPTION 'transport request must create one outbox event';
  END IF;
  IF (SELECT count(*) FROM public.audit_events WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND action IN ('fleet.vehicle.created', 'fleet.driver.created', 'transport.request.created', 'transport.request.assigned', 'transport.request.status_changed')) <> 5 THEN
    RAISE EXCEPTION 'transport commands must create audit evidence';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM public.notifications
    WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND resource_type = 'transport_request'
      AND resource_id = (
        SELECT id FROM public.transport_requests WHERE idempotency_key = 'transport-a-1'
      )
      AND title = 'تم إسناد طلب نقل'
      AND body LIKE '%ضيف الاختبار%'
  ) THEN
    RAISE EXCEPTION 'transport assignment must create a recipient-scoped in-app notification';
  END IF;
END;
$$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '33333333-3333-3333-3333-333333333333', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.list_transport_requests('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 50);
    RAISE EXCEPTION 'suspended viewer must not read transport requests';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END;
$$;
RESET ROLE;

DO $$
DECLARE
  v_actor uuid := (
    SELECT id FROM public.organization_memberships
    WHERE organization_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND user_id = '11111111-1111-1111-1111-111111111111'
  );
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.transport_requests'::regclass
      AND conname = 'transport_vehicle_active_allocation_excl'
      AND contype = 'x'
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.transport_requests'::regclass
      AND conname = 'transport_driver_active_allocation_excl'
      AND contype = 'x'
  ) THEN
    RAISE EXCEPTION 'transport allocation exclusion constraints are missing';
  END IF;

  INSERT INTO public.fleet_vehicles (
    id, organization_id, display_name, vehicle_type, registration_code,
    passenger_capacity
  ) VALUES
    ('aaaaaaaa-0000-0000-0000-000000000301', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
     'Overlap vehicle 1', 'van', 'EG-SEC-301', 8),
    ('aaaaaaaa-0000-0000-0000-000000000302', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
     'Overlap vehicle 2', 'van', 'EG-SEC-302', 8);

  INSERT INTO public.fleet_drivers (
    id, organization_id, display_name, phone_e164
  ) VALUES
    ('aaaaaaaa-0000-0000-0000-000000000311', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
     'Overlap driver 1', '+201000000311'),
    ('aaaaaaaa-0000-0000-0000-000000000312', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
     'Overlap driver 2', '+201000000312');

  INSERT INTO public.transport_requests (
    id, organization_id, request_type, status, guest_label,
    pickup_location, dropoff_location, pickup_at, return_at,
    passenger_count, created_by_membership_id, idempotency_key
  ) VALUES
    ('aaaaaaaa-0000-0000-0000-000000000321', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
     'car_rental', 'requested', 'Overlap request 1', 'A', 'B',
     '2041-01-01 10:00:00+00', '2041-01-01 14:00:00+00', 2, v_actor, 'transport-overlap-321'),
    ('aaaaaaaa-0000-0000-0000-000000000322', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
     'car_rental', 'requested', 'Overlap request 2', 'A', 'B',
     '2041-01-01 12:00:00+00', '2041-01-01 16:00:00+00', 2, v_actor, 'transport-overlap-322'),
    ('aaaaaaaa-0000-0000-0000-000000000323', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
     'car_rental', 'requested', 'Overlap request 3', 'A', 'B',
     '2041-01-01 12:00:00+00', '2041-01-01 16:00:00+00', 2, v_actor, 'transport-overlap-323'),
    ('aaaaaaaa-0000-0000-0000-000000000324', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
     'car_rental', 'requested', 'Adjacent request', 'A', 'B',
     '2041-01-01 14:00:00+00', '2041-01-01 18:00:00+00', 2, v_actor, 'transport-adjacent-324'),
    ('aaaaaaaa-0000-0000-0000-000000000325', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
     'car_rental', 'requested', 'Released request', 'A', 'B',
     '2041-01-01 15:00:00+00', '2041-01-01 17:00:00+00', 2, v_actor, 'transport-release-325'),
    ('aaaaaaaa-0000-0000-0000-000000000331', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
     'airport_transfer', 'requested', 'Requested transition', 'A', 'B',
     '2042-01-01 10:00:00+00', '2042-01-01 11:00:00+00', 1, v_actor, 'transport-state-331'),
    ('aaaaaaaa-0000-0000-0000-000000000332', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
     'airport_transfer', 'requested', 'Cancelled transition', 'A', 'B',
     '2042-01-02 10:00:00+00', '2042-01-02 11:00:00+00', 1, v_actor, 'transport-state-332'),
    ('aaaaaaaa-0000-0000-0000-000000000333', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
     'airport_transfer', 'assigned', 'Assigned transition', 'A', 'B',
     '2042-01-03 10:00:00+00', '2042-01-03 11:00:00+00', 1, v_actor, 'transport-state-333'),
    ('aaaaaaaa-0000-0000-0000-000000000334', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
     'airport_transfer', 'assigned', 'Assigned cancellation', 'A', 'B',
     '2042-01-04 10:00:00+00', '2042-01-04 11:00:00+00', 1, v_actor, 'transport-state-334'),
    ('aaaaaaaa-0000-0000-0000-000000000335', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
     'airport_transfer', 'in_progress', 'In-progress cancellation', 'A', 'B',
     '2042-01-05 10:00:00+00', '2042-01-05 11:00:00+00', 1, v_actor, 'transport-state-335');
END;
$$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
DO $$
BEGIN
  PERFORM public.assign_transport_request(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'aaaaaaaa-0000-0000-0000-000000000321',
    'aaaaaaaa-0000-0000-0000-000000000301',
    'aaaaaaaa-0000-0000-0000-000000000311', NULL
  );

  BEGIN
    PERFORM public.assign_transport_request(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000322',
      'aaaaaaaa-0000-0000-0000-000000000301',
      'aaaaaaaa-0000-0000-0000-000000000312', NULL
    );
    RAISE EXCEPTION 'overlapping vehicle allocation was accepted';
  EXCEPTION WHEN exclusion_violation THEN NULL;
  END;

  BEGIN
    PERFORM public.assign_transport_request(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000323',
      'aaaaaaaa-0000-0000-0000-000000000302',
      'aaaaaaaa-0000-0000-0000-000000000311', NULL
    );
    RAISE EXCEPTION 'overlapping driver allocation was accepted';
  EXCEPTION WHEN exclusion_violation THEN NULL;
  END;

  PERFORM public.assign_transport_request(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'aaaaaaaa-0000-0000-0000-000000000324',
    'aaaaaaaa-0000-0000-0000-000000000301',
    'aaaaaaaa-0000-0000-0000-000000000312', NULL
  );
  PERFORM public.update_transport_request_status(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'aaaaaaaa-0000-0000-0000-000000000324', 'cancelled', NULL
  );
  PERFORM public.assign_transport_request(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'aaaaaaaa-0000-0000-0000-000000000325',
    'aaaaaaaa-0000-0000-0000-000000000301',
    'aaaaaaaa-0000-0000-0000-000000000312', NULL
  );

  PERFORM public.update_transport_request_status(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'aaaaaaaa-0000-0000-0000-000000000331', 'requested', NULL
  );
  PERFORM public.update_transport_request_status(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'aaaaaaaa-0000-0000-0000-000000000331', 'in_progress', NULL
  );
  PERFORM public.update_transport_request_status(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'aaaaaaaa-0000-0000-0000-000000000331', 'in_progress', NULL
  );
  PERFORM public.update_transport_request_status(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'aaaaaaaa-0000-0000-0000-000000000331', 'completed', NULL
  );
  BEGIN
    PERFORM public.update_transport_request_status(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000331', 'requested', NULL
    );
    RAISE EXCEPTION 'completed transport request was reopened';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;

  PERFORM public.update_transport_request_status(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'aaaaaaaa-0000-0000-0000-000000000332', 'cancelled', NULL
  );
  BEGIN
    PERFORM public.update_transport_request_status(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'aaaaaaaa-0000-0000-0000-000000000332', 'in_progress', NULL
    );
    RAISE EXCEPTION 'cancelled transport request was reopened';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;

  PERFORM public.update_transport_request_status(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'aaaaaaaa-0000-0000-0000-000000000333', 'in_progress', NULL
  );
  PERFORM public.assign_transport_request(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'aaaaaaaa-0000-0000-0000-000000000333',
    'aaaaaaaa-0000-0000-0000-000000000302',
    'aaaaaaaa-0000-0000-0000-000000000312', NULL
  );
  PERFORM public.assign_transport_request(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'aaaaaaaa-0000-0000-0000-000000000333',
    'aaaaaaaa-0000-0000-0000-000000000301',
    'aaaaaaaa-0000-0000-0000-000000000311', NULL
  );
  PERFORM public.assign_transport_request(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'aaaaaaaa-0000-0000-0000-000000000333',
    'aaaaaaaa-0000-0000-0000-000000000302',
    'aaaaaaaa-0000-0000-0000-000000000312', NULL
  );
  PERFORM public.update_transport_request_status(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'aaaaaaaa-0000-0000-0000-000000000333', 'completed', NULL
  );

  PERFORM public.update_transport_request_status(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'aaaaaaaa-0000-0000-0000-000000000334', 'cancelled', NULL
  );
  PERFORM public.update_transport_request_status(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'aaaaaaaa-0000-0000-0000-000000000335', 'cancelled', NULL
  );
END;
$$;
RESET ROLE;

DO $$
BEGIN
  IF (SELECT status FROM public.transport_requests
      WHERE id = 'aaaaaaaa-0000-0000-0000-000000000333') <> 'completed' THEN
    RAISE EXCEPTION 'resource correction moved in-progress transport backwards';
  END IF;

  IF (SELECT count(*) FROM public.transport_requests
      WHERE id IN (
        'aaaaaaaa-0000-0000-0000-000000000321',
        'aaaaaaaa-0000-0000-0000-000000000325'
      ) AND status = 'assigned') <> 2 THEN
    RAISE EXCEPTION 'adjacent/released allocation behavior did not persist correctly';
  END IF;
END;
$$;

SELECT 'transport operations database integration tests passed' AS result;
