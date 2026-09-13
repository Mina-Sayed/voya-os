-- Prove K-045 upgrades rows created before fleet idempotency existed.
-- This script runs after the legacy fixture, develop hardening, and the
-- forward fleet migration, so the fixture rows must have received generated
-- keys and remain replayable through the V1 RPCs.
\set ON_ERROR_STOP on

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);

SELECT public.create_fleet_vehicle_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Upgrade fixture vehicle', 'van',
  'EG-UPGRADE-909', 8,
  'legacy-vehicle:aaaaaaaa-0000-0000-0000-000000000909',
  'aaaaaaaa-0000-0000-0000-000000000991'
) AS vehicle_id \gset
SELECT set_config('voya.test.upgrade_vehicle_id', :'vehicle_id', false);

SELECT public.create_fleet_driver_v1(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Upgrade fixture driver', '+201000000910',
  'legacy-driver:aaaaaaaa-0000-0000-0000-000000000910',
  'aaaaaaaa-0000-0000-0000-000000000992'
) AS driver_id \gset
SELECT set_config('voya.test.upgrade_driver_id', :'driver_id', false);

RESET ROLE;

DO $$
BEGIN
  IF current_setting('voya.test.upgrade_vehicle_id') <> 'aaaaaaaa-0000-0000-0000-000000000909' THEN
    RAISE EXCEPTION 'legacy vehicle retry must return its original id';
  END IF;
  IF current_setting('voya.test.upgrade_driver_id') <> 'aaaaaaaa-0000-0000-0000-000000000910' THEN
    RAISE EXCEPTION 'legacy driver retry must return its original id';
  END IF;
  IF (SELECT idempotency_key FROM public.fleet_vehicles
      WHERE id = 'aaaaaaaa-0000-0000-0000-000000000909')
      <> 'legacy-vehicle:aaaaaaaa-0000-0000-0000-000000000909' THEN
    RAISE EXCEPTION 'legacy vehicle key was not backfilled deterministically';
  END IF;
  IF (SELECT idempotency_key FROM public.fleet_drivers
      WHERE id = 'aaaaaaaa-0000-0000-0000-000000000910')
      <> 'legacy-driver:aaaaaaaa-0000-0000-0000-000000000910' THEN
    RAISE EXCEPTION 'legacy driver key was not backfilled deterministically';
  END IF;
  IF (SELECT count(*) FROM public.fleet_vehicles
      WHERE idempotency_key = 'legacy-vehicle:aaaaaaaa-0000-0000-0000-000000000909') <> 1 THEN
    RAISE EXCEPTION 'legacy vehicle backfill must preserve one row';
  END IF;
  IF (SELECT count(*) FROM public.fleet_drivers
      WHERE idempotency_key = 'legacy-driver:aaaaaaaa-0000-0000-0000-000000000910') <> 1 THEN
    RAISE EXCEPTION 'legacy driver backfill must preserve one row';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM pg_attribute
    WHERE attrelid = 'public.fleet_vehicles'::regclass
      AND attname = 'idempotency_key'
      AND attnotnull
  ) OR NOT EXISTS (
    SELECT 1
    FROM pg_attribute
    WHERE attrelid = 'public.fleet_drivers'::regclass
      AND attname = 'idempotency_key'
      AND attnotnull
  ) THEN
    RAISE EXCEPTION 'fleet idempotency keys must be NOT NULL after upgrade';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.audit_events
    WHERE resource_id IN (
      'aaaaaaaa-0000-0000-0000-000000000909'::uuid,
      'aaaaaaaa-0000-0000-0000-000000000910'::uuid
    )
      AND action IN ('fleet.vehicle.created', 'fleet.driver.created')
  ) OR EXISTS (
    SELECT 1 FROM public.outbox_events
    WHERE payload ->> 'vehicle_id' = 'aaaaaaaa-0000-0000-0000-000000000909'
       OR payload ->> 'driver_id' = 'aaaaaaaa-0000-0000-0000-000000000910'
  ) THEN
    RAISE EXCEPTION 'replaying a backfilled fleet row must not duplicate evidence';
  END IF;
END;
$$;

SELECT 'fleet idempotency upgrade tests passed' AS result;
