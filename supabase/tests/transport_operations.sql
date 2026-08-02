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

SELECT 'transport operations database integration tests passed' AS result;
